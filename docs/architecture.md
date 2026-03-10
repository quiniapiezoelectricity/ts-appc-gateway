# Architecture

## Full traffic flow

```
┌─────────────────────────────────────────────────────────────────┐
│  Tailscale client (any peer with App Connector access in ACL)   │
└───────────────┬─────────────────────────────────────────────────┘
                │
    ① DNS query: example.com
                │
                ▼
┌──────────────────────────────────────────────────────────────────┐
│  Tailscale daemon (client side)                                  │
│  Intercepts query for domain configured in nodeAttrs             │
│  Forwards via peerapi (DoH over Tailscale tunnel) to connector   │
└───────────────┬──────────────────────────────────────────────────┘
                │
    peerapi DNS request to connector node
                │
                ▼
┌─────────────────────────────────────────────────────────────────┐
│  tailscale container (connector node)                           │
│  System resolver = dns-steer (172.20.0.3)                       │
│                                                                 │
│  Resolves example.com via dnsmasq-steer                         │
│  → returns INGRESS_IP (catch-all for non-Tailscale domains)     │
│  → Tailscale advertises INGRESS_IP/32 as subnet route           │
└───────────────┬─────────────────────────────────────────────────┘
                │
    ② DNS response: example.com → INGRESS_IP
       Tailscale client now has route: INGRESS_IP via connector
                │
                ▼
┌─────────────────────────────────────────────────────────────────┐
│  Client opens TCP connection to INGRESS_IP:443                  │
│  Tailscale routes the TCP stream through the connector node     │
└───────────────┬─────────────────────────────────────────────────┘
                │
    TCP arrives on tailscale0 in the tailscale container's netns
                │
                ▼
┌──────────────────────────────────────────────────────────────────┐
│  interception container (network_mode: service:tailscale)        │
│  iptables PREROUTING mangle:                                     │
│    -i tailscale0 -d INGRESS_IP/32 -p tcp → TPROXY port rewrite │
│  Policy routing: fwmark 1 → table 100 → local delivery          │
└───────────────┬──────────────────────────────────────────────────┘
                │
    TPROXY delivers to HAProxy's transparent listener
    Original dst IP:port preserved in socket (IP_TRANSPARENT)
                │
                ▼
┌──────────────────────────────────────────────────────────────────┐
│  proxy container — HAProxy (network_mode: service:tailscale)     │
│                                                                  │
│  frontend tls_in (bind 0.0.0.0:TPROXY_PORT transparent)         │
│    tcp-request inspect-delay 5s                                  │
│    accept if TLS ClientHello                                     │
│    set-var(txn.orig_port) dst_port  ← original port from TPROXY │
│                                                                  │
│  backend sni_router                                              │
│    set-var(txn.sni) req.ssl_sni    ← "example.com"              │
│    do-resolve(txn.resolved_ip, upstream_dns) var(txn.sni)       │
│    set-dst     var(txn.resolved_ip)                              │
│    set-dst-port var(txn.orig_port)                               │
│    server fwd 0.0.0.0:0            ← destination overridden     │
└───────────────┬──────────────────────────────────────────────────┘
                │
    ③ HAProxy resolves example.com → real IP
       via dns-upstream (Unbound, 172.20.0.2:5353)
       NOT via dns-steer (would return INGRESS_IP → loop)
                │
    ④ HAProxy opens new TCP connection to real IP:443
       Forwards encrypted TCP stream (no TLS termination)
                │
                ▼
            Real upstream server
```

## Network namespace sharing

`interception` and `proxy` use `network_mode: service:tailscale`, meaning they share the `tailscale` container's Linux network namespace. From the kernel's perspective they all see the same:

- `tailscale0` interface (Tailscale's WireGuard tun)
- `eth0` interface (Docker bridge, gateway-net)
- `lo` loopback
- iptables/netfilter state
- routing tables

TPROXY rules applied by `interception` are in this shared namespace. HAProxy's transparent listener in `proxy` binds in this same namespace — so it receives the TPROXY-redirected packets correctly.

`dns-steer` and `dns-upstream` are separate containers on the `gateway-net` bridge. The `tailscale` container (and its shared-namespace companions) can reach them via their fixed IPs (`172.20.0.3`, `172.20.0.2`).

### Restart behavior

If `tailscale` restarts, it gets a new network namespace. Containers sharing its namespace (`interception`, `proxy`) will lose network connectivity and crash. Docker restarts them via `restart: unless-stopped`. On restart:

1. `interception` reconnects to the new Tailscale netns → re-applies TPROXY rules → becomes healthy
2. `proxy` restarts → HAProxy re-listens once `interception` is healthy again

There is a brief gap (seconds) where traffic is not forwarded during Tailscale restart.

## DNS split

```
┌─────────────────────────────────────────────────┐
│  tailscale container's /etc/resolv.conf         │
│  nameserver 172.20.0.3  (dns-steer)             │
└───────────────────┬─────────────────────────────┘
                    │ all DNS queries
                    ▼
┌─────────────────────────────────────────────────┐
│  dns-steer (dnsmasq, 172.20.0.3:53)             │
│                                                 │
│  tailscale.com  → Unbound (real answer)         │
│  tailscale.io   → Unbound (real answer)         │
│  ts.net         → Unbound (real answer)         │
│  *              → INGRESS_IP  (steering)        │
└──────┬──────────────────────────────────────────┘
       │ Tailscale infra domains only
       ▼
┌─────────────────────────────────────────────────┐
│  dns-upstream (Unbound, 172.20.0.2:5353)        │
│  Forwards to real resolver (default: 8.8.8.8)  │
└─────────────────────────────────────────────────┘

HAProxy resolvers section also points at Unbound directly,
bypassing dns-steer entirely for upstream resolution.
```

The split prevents two failure modes:

1. **Loop:** if HAProxy used dns-steer, it would resolve `example.com` → `INGRESS_IP` → connect to itself.
2. **Tailscale bootstrap failure:** if dns-steer had no exceptions, `controlplane.tailscale.com` would resolve to `INGRESS_IP`, breaking Tailscale's ability to connect to its control plane.

## Startup sequence

```
config-render      → (exit 0)
                        │
        ┌───────────────┴───────────────┐
        ▼                               ▼
   dns-upstream                    dns-steer
   (no healthcheck)              (healthcheck: nslookup)
                                        │
                                        ▼ healthy
                                    tailscale
                                  (healthcheck: tailscale status)
                                        │
                                        ▼ healthy
                                   interception
                                  (healthcheck: iptables -L TPROXY_IN)
                                        │
                                        ▼ healthy
                                       proxy
                                  (haproxy starts, TPROXY listener up)
```

## Config render

`config-render` runs as an init container, produces three files in the `config` volume:

| File | Consumer | Key variables |
|---|---|---|
| `haproxy.cfg` | `proxy` | `TPROXY_PORT`, `DNS_UPSTREAM_IP`, `DNS_UPSTREAM_PORT` |
| `dnsmasq-steer.conf` | `dns-steer` | `INGRESS_IP`, `DNS_UPSTREAM_IP`, `DNS_UPSTREAM_PORT` |
| `unbound.conf` | `dns-upstream` | `DNS_UPSTREAM_PORT`, `DNS_UPSTREAM_FORWARDER` |

All runtime services mount `config:/config:ro`. No service does its own config templating.

## Future hardening hooks

These extension points are intentionally left as hooks in the alpha:

### Egress SNI allowlist

The HAProxy backend template has a comment block showing exactly where to add:

```haproxy
acl sni_allowed var(txn.sni) -f /config/egress-allowed-snis.map
tcp-request content reject if !sni_allowed
```

To implement: add a `EGRESS_ALLOWLIST` env var, update `render.sh` to generate `egress-allowed-snis.map`, add the ACL to the template, signal HAProxy to reload (`haproxy -sf`).

No structural changes to the stack are required — the `config` volume is already the config distribution path.

### Per-connector ingress IPs

Replace the single `INGRESS_IP` with multiple IPs, one per connector tag. Each gets its own HAProxy frontend + backend pair. Requires:
- Multiple IPs advertised as subnet routes
- Multiple dnsmasq `address=/domain/IP` mappings per connector
- HAProxy `frontend` per IP or ACL-based routing by `dst`

### Policy sync from Tailscale ACL

A future sidecar or init container that:
1. Reads `nodeAttrs` from Tailscale API
2. Computes the domain→connector mapping
3. Re-renders `dnsmasq-steer.conf` and allowlist maps
4. Signals HAProxy to hot-reload (`kill -USR2`)

All the plumbing (config volume, HAProxy master-worker mode via `-W`) is already in place.

### Plain HTTP (port 80)

TPROXY intercepts all TCP to `INGRESS_IP` regardless of port. Adding a second HAProxy frontend on a second TPROXY listener (e.g., port 10080) with `http-request` rules using the `Host` header would enable port 80. Low priority for alpha since most targets are HTTPS.
