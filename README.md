# ts-appc-gateway

A Tailscale App Connector gateway that routes TLS traffic by SNI hostname, not by IP.

## The problem

Tailscale markets App Connectors as domain-based routing. In practice the implementation is an IP-based router with a DNS discovery layer on top: the connector watches DNS responses for your configured domains, collects the IPs that come back, and routes those IPs through itself.

This breaks in the real world because CDN and SaaS IPs are shared. When `your-app.example.com` resolves to `104.x.x.x`, that same IP serves thousands of other customers on the same CDN. Tailscale has no way to route `your-app.example.com` through the connector without also capturing unintended traffic to that shared IP — or skipping it entirely when IPs rotate before the connector re-observes DNS. Tailscale's own [best practices page](https://tailscale.com/docs/reference/best-practices/app-connectors) explicitly warns against using App Connectors with CDN or shared-IP SaaS infrastructure for this reason.

The abstraction leaks.

## How this fixes it

This stack uses DNS steering to deliver all configured-domain traffic to one or more controlled ingress addresses, then recovers the real destination from the TLS ClientHello SNI at the proxy layer. The routing decision is made at the application layer, not the network layer. Every connection is individually resolved and forwarded by hostname.

- No agent on clients — Tailscale handles routing
- TLS is not terminated — the proxy reads only the ClientHello and forwards the stream
- No per-IP rules to maintain — domain policy lives in the Tailscale admin console
- Shared CDN/SaaS IPs are not a problem — SNI identifies the destination unambiguously

### Key deviations from stock App Connector

**App Connector routing: stock vs. this repo**

| Stock App Connector behavior | This repo |
|---|---|
| Discovers destination IPs from DNS, then advertises subnet routes to those IPs | DNS steers all traffic to one or more ingress addresses; HAProxy reads TLS SNI and resolves the real destination per-connection |
| No application-layer hostname visibility post-routing | Hostname visible at the proxy layer; SNI allowlist enforced per connection |

**Where this repo diverges from Tailscale's documented guidance**

| Stock Tailscale guidance or example | This repo | Reason |
|---|---|---|
| Official setup guidance [expects a public IP](https://tailscale.com/kb/1342/how-app-connectors-work) | Virtual ingress address; no public IP required | `INGRESS_IP` is a tailnet subnet route, not a host-bound address |
| `grants` example with `tcp:53`/`udp:53` | `grants` with `ip: ["*"]` | peerapi uses high ports (34xxx range), not port 53 |
| `nodeAttrs.target: ["*"]` in many examples | `target: ["tag:connector"]` | Scopes capability to this specific node only |

This design uses proxy-style destination selection rather than Tailscale's native IP-routing model — DNS steers traffic to ingress; the actual forwarding decision is made per-connection at the proxy layer from TLS SNI. It is not a full forward proxy (no HTTP Host/URL policy, no TLS decryption, no per-user enforcement inside the gateway).

## Status

**Technical preview** for controlled internal deployments. Plain HTTP, QUIC/HTTP3, and same-node exit-node operation are out of scope for this design. See *Currently validated* for the concrete test envelope.

**Support boundary:**
- Standard: Tailscale ACLs, tags, and App Connector control plane — all stock Tailscale behavior
- Repo-specific: DNS steering, TPROXY interception, SNI routing, and policy-sync
- Unsupported: same-node exit node, QUIC/HTTP3, plain HTTP (port 80), macOS/Windows host

## Architecture

```
Tailscale client
  │
  ├─[1]─ DNS query for example.com
  │       └─ App Connector peerapi → connector resolves via dnsmasq-steer
  │           → returns INGRESS_IP (A or AAAA depending on family)
  │           → Tailscale advertises INGRESS_IP CIDRs as subnet routes
  │
  └─[2]─ TCP connect to INGRESS_IP:443
          └─ Tailscale routes through connector node
              └─ TPROXY nftables rule intercepts
                  └─ HAProxy reads SNI = "example.com"
                      └─ Unbound resolves example.com → real IP
                          └─ HAProxy forwards TCP stream to real IP:443
```

Seven services:

| Service | Role |
|---|---|
| `appc-config-render` | Init container. Renders all configs from templates + env. Exits 0 on success. |
| `appc-ts` | Tailscale subnet router + App Connector node. |
| `appc-dns-steer` | dnsmasq. Split-horizon resolver; returns `INGRESS_IP` for all steered domains. |
| `appc-dns-upstream` | Unbound. Real upstream resolver used only by HAProxy for egress resolution. |
| `appc-interception` | Applies TPROXY nftables rules in Tailscale's network namespace. |
| `appc-proxy` | HAProxy. TPROXY listener, SNI extraction, upstream forwarding. |
| `appc-policy-sync` | Reads domain assignments from Tailscale LocalAPI; generates SNI allowlist + deny-cidrs ACLs. |

## Prerequisites

### Docker Engine 27+ with Compose v2.24+

Requires Docker Compose v2.24+ (`condition: service_completed_successfully`, `env_file[].required`). Docker Engine 27+ is required for automatic IPv6 subnet allocation on user-defined bridge networks when `enable_ipv6: true` is set without an explicit subnet — needed for dual-stack egress to work without daemon-level IPv6 config. See [Docker Engine 27 release notes](https://docs.docker.com/engine/release-notes/27/).

### Linux host

TPROXY requires Linux kernel support. This stack does not run on macOS or Windows.

**Public IP:** Tailscale's [official setup guidance](https://tailscale.com/kb/1342/how-app-connectors-work) expects a publicly accessible IP on the connector device. Direct WireGuard path, lowest latency, simplest support posture. Follow this for production deployments wherever possible.

**This repo's approach:** `INGRESS_IP` is a virtual host address advertised as a subnet route over the Tailscale overlay. The host needs no public IP. When a direct WireGuard path is unavailable, Tailscale falls back to DERP relay for NAT traversal. This works in practice; it is a non-standard deployment choice with relay latency as the tradeoff.

Choose based on your latency requirements and ops posture.

### Tailscale account with App Connectors enabled

App Connectors are available on all Tailscale plans.

## Quick start

```sh
cp .env.example .env
# Edit .env: set INGRESS_IP and TS_AUTHKEY at minimum
docker compose build
docker compose up
```

Watch startup:

```sh
docker compose logs -f
```

Approve the advertised subnet route in the Tailscale admin console if `autoApprovers` is not configured.

## Tailscale admin console setup

Before starting the stack, configure your ACL policy at [https://login.tailscale.com/admin/acls](https://login.tailscale.com/admin/acls).

The following is a repo-tested policy shape. It differs from Tailscale's stock examples in two specific ways:

| Field | Stock Tailscale example | This repo | Reason |
|---|---|---|---|
| `grants.ip` | `["tcp:53", "udp:53"]` | `["*"]` | peerapi uses high ports (34xxx range), not port 53 |
| `nodeAttrs.target` | `["*"]` | `["tag:connector"]` | Scope App Connector capability to this specific tagged node only |

```jsonc
{
  "tagOwners": {
    "tag:connector": ["autogroup:admin"]
  },
  "autoApprovers": {
    "routes": {
      // Approve the exact host CIDRs this stack advertises (/32 or /128).
      // A covering prefix is also valid when running multiple gateways in
      // the same range: "10.99.0.0/24" auto-approves any /32 within it.
      "10.99.0.1/32": ["tag:connector"],
      "2001:db8:a:b::/64": ["tag:connector"]   // dual-stack only
    }
  },
  // Only needed if your tailnet uses non-default ACLs (i.e. you have
  // explicit acls[] rules). Without an accept rule here, peerapi
  // connections — the channel App Connector uses for DNS forwarding —
  // are blocked by "no rules matched" even when grants are correct.
  "acls": [
    {
      "action": "accept",
      "src": ["autogroup:member"],
      "dst": ["tag:connector:*"]
    }
    // ... your other existing rules ...
  ],
  "grants": [
    {
      // This stack uses ip: ["*"] rather than the minimal tcp:53/udp:53
      // shown in Tailscale's documentation. This is intentional and tested:
      // peerapi — the channel App Connector uses for DNS forwarding — runs
      // on a variable high port (typically 34xxx range), not port 53.
      // Restricting to port 53 breaks the App Connector even when dnsmasq
      // and Tailscale are both healthy. Narrow src to restrict which nodes
      // can use the connector (e.g. ["tag:client"] instead of autogroup:member).
      "src": ["autogroup:member"],
      "dst": ["tag:connector"],
      "ip": ["*"]
    }
  ],
  "nodeAttrs": [
    {
      // target: ["tag:connector"] scopes the App Connector capability to
      // exactly the connector node. Tailscale's documentation examples
      // sometimes use target: ["*"] which applies the capability to all
      // tailnet nodes — appropriate for an account-wide default connector
      // but undesirable when targeting a specific tagged gateway.
      "target": ["tag:connector"],
      "app": {
        "tailscale.com/app-connectors": [
          {
            "name": "my-connector",
            "connectors": ["tag:connector"],
            "domains": ["example.com", "api.example.org"]
          }
        ]
      }
    }
  ]
}
```

Generate an auth key tagged with `tag:connector` for `TS_AUTHKEY`.

The `domains` list controls which domains Tailscale clients route through this connector. The connector does not maintain a local domain list — it returns `INGRESS_IP` for everything it receives, and the admin console is the sole source of truth for domain assignments.

## Ingress addressing

`INGRESS_IP` accepts a comma-separated list of host CIDRs — `/32` for IPv4, `/128` for IPv6:

```sh
# IPv4-only (default)
INGRESS_IP=10.99.0.1/32

# Dual-stack
INGRESS_IP=10.99.0.1/32,2001:db8::1/128

# IPv6-only
INGRESS_IP=2001:db8::1/128
```

**CIDR notation is required.** `tailscale --advertise-routes` only accepts CIDR format; bare IPs are rejected. The `/32`/`/128` suffix also provides unambiguous address-family detection — no heuristics needed.

**No whitespace.** `INGRESS_IP=10.99.0.1/32, 2001:db8::1/128` (space after comma) is rejected at startup with a clear error. Use comma-only separators.

**Uniqueness.** Every gateway on the same tailnet must use a distinct ingress address set. If two gateways advertise the same `/32` or `/128`, Tailscale routes connections to whichever wins the route advertisement — which may not be the one that answered the DNS query. That gateway has no record of the assignment; the connection fails silently.

**Non-overlap.** Check `tailscale status --json | jq '.Peer[].AllowedIPs'` for existing routes before choosing. An ingress address that overlaps an existing subnet route will silently steal traffic from that route.

### Choosing an IPv4 ingress address

Pick any private address not already in use on your LAN or tailnet. The default `10.99.0.1/32` is illustrative — verify it does not collide with anything real. Avoid `100.64.0.0/10` (Tailscale's own CGNAT range).

### Choosing an IPv6 ingress address

Avoid ULA (`fc00::/7`, including `fd00::/8`) — Chrome's [Local Network Access](https://developer.chrome.com/blog/local-network-access) policy treats ULA as private/local address space, which blocks or triggers permission prompts for browser-initiated connections. The examples in this repo use `2001:db8::/32` (RFC 3849 documentation range) — a practical overlay-safe choice for this design. See `.env.example` for address-selection guidance and caveats.

Also avoid `fd7a:115c:a1e0::/48` (Tailscale's own address space) and `fe80::/10` (link-local, non-routable).

**IPv6-only ingress** requires that Tailscale clients have IPv6 connectivity to reach this gateway node over the tailnet. Clients on IPv4-only networks that cannot establish an IPv6 path will not be able to use the connector. **Dual-stack is the safer default for mixed environments** — each client uses whichever family it has a working path for.

**Multiple ingress addresses** are all equivalent: one SNI allowlist, one HAProxy config, one TPROXY ruleset. dnsmasq automatically returns A records for IPv4 ingress addresses and AAAA records for IPv6. HAProxy listens on `0.0.0.0:PORT` for IPv4 and `:::PORT` for IPv6 — one wildcard bind per family, regardless of how many addresses are in each family.

## DNS architecture

Two resolvers with distinct roles:

**dns-steer (dnsmasq, port 53)** — Used by the Tailscale container as its system resolver. Split-horizon: returns the ingress address(es) from `INGRESS_IP` for all domains, except Tailscale infrastructure (`tailscale.com`, `tailscale.io`, `ts.net`) which is forwarded to Unbound for real answers. Returns A records for IPv4 ingress addresses and AAAA for IPv6 automatically, based on the address family.

When the App Connector receives a peerapi DNS query from a client for a configured domain, it resolves via dnsmasq-steer, gets `INGRESS_IP`, and Tailscale advertises the ingress CIDRs as subnet routes.

**dns-upstream (Unbound, port 5353, loopback only)** — Used only by HAProxy to resolve SNI hostnames to real upstream IPs. Never returns `INGRESS_IP` for anything. Forwards to a real public resolver (configurable, default Cloudflare + Google over DoT). Bound to `127.0.0.1:5353`, reachable only from within the Tailscale network namespace.

If HAProxy resolved through dnsmasq-steer, it would receive `INGRESS_IP` for every domain and loop back to itself. The resolver split is what prevents this.

## Security posture

### Default security posture

- **No TLS termination** — proxy reads only the ClientHello; never holds a private key or sees plaintext
- **Fail-closed startup** — config render exits on any invalid env var; SNI ACLs empty until policy-sync populates them
- **Live policy sync** — domain assignments come from Tailscale's admin console via LocalAPI; no local list to drift from the real policy
- **DNS rebinding protection** — deny-cidrs post-resolution check always active, regardless of SNI enforcement mode
- **No Docker socket in default stack** — `appc-autoheal` is tools-profile only
- **Pinned image tags** — no `:latest` in the default stack

### Known hardening exceptions

- `appc-interception` runs `privileged: true` — nftables TPROXY setup requires capabilities not yet reducible to a specific cap list
- `appc-ts` has no `read_only: true` — Tailscale writes state to its volume during operation
- `appc-autoheal` (tools profile only) mounts `/var/run/docker.sock` — root-equivalent host access; excluded from the default stack for this reason

## Trust model

**SNI allowlist (policy-sync).** The `appc-policy-sync` sidecar reads domain assignments from Tailscale's LocalAPI (`Self.CapMap["tailscale.com/app-connectors"]`) and generates HAProxy ACL files. Only SNIs matching admin-console-configured domains are forwarded. On cold start, empty ACL files mean deny-all until policy-sync populates them (typically < 30s).

Without `CONNECTOR_TAG`, the stack unions all local connector tags to determine which CapMap entries apply. Set `CONNECTOR_TAG` to narrow enforcement to specific tags when the node carries multiple.

**DNS rebinding protection (deny-cidrs).** Post-resolution IP validation rejects connections to dangerous destinations. The static base:

| Range | Reason |
|---|---|
| `127.0.0.0/8` | Loopback |
| `169.254.0.0/16` | Link-local |
| `224.0.0.0/4` | Multicast |
| `240.0.0.0/4` | Reserved |
| `100.64.0.0/10` | Tailscale CGNAT range — tailnet peer IPs live here |
| `fd7a:115c:a1e0::/48` | Tailscale IPv6 node range |
| `::1/128` | IPv6 loopback |
| `fe80::/10` | IPv6 link-local |
| `ff00::/8` | IPv6 multicast |

`100.64.0.0/10` and `fd7a:115c:a1e0::/48` are denied by default to prevent an allowed SNI from resolving to a tailnet peer IP and bypassing Tailscale's own ACLs through this gateway. Note: `100.64.0.0/10` is the IANA CGNAT range, not exclusively Tailscale's — enterprises using CGNAT space for their own infrastructure would have those destinations blocked too.

`EXTRA_DENY_CIDRS` is **additive only** — it cannot remove static ranges. To allow forwarding to tailnet peers or non-Tailscale CGNAT destinations, remove the relevant range from the static base — see *Operator overrides* below.

Policy-sync extends deny-cidrs dynamically on every successful sync with `Self.TailscaleIPs` (the node's own Tailscale addresses) and `100.100.100.100/32` (Quad100 / Tailscale MagicDNS).

**Network-level access control** is Tailscale's responsibility. Tailscale ACLs control which peers can reach this node. Peers authorized by Tailscale to reach the ingress address are authorized to use the gateway.

## Egress address-family policy

Two orthogonal knobs control which IP families HAProxy uses for egress:

| Variable | Default | Values | Effect |
|---|---|---|---|
| `EGRESS_ACCEPT_FAMILY` | `ipv4` | `ipv4`, `ipv6`, `dual` | Strict family enforcement via `dns-accept-family` global directive |
| `EGRESS_PREFER_FAMILY` | `ipv4` | `ipv4`, `ipv6`, `none` | Preference hint to `do-resolve`; no strict enforcement on its own |

**Accept** maps directly to HAProxy's `dns-accept-family` directive — controls which DNS record types are kept after resolution. When `dual`, the directive is omitted (both families accepted).

**Prefer** maps to the optional third argument in `do-resolve(var,resolver,family)`. When `none`, no argument is passed.

Valid combinations:

| `EGRESS_ACCEPT_FAMILY` | `EGRESS_PREFER_FAMILY` | Use case |
|---|---|---|
| `ipv4` | `ipv4` | Strict IPv4-only egress (default) |
| `ipv6` | `ipv6` | Strict IPv6-only egress |
| `dual` | `ipv4` | Dual-stack, IPv4 preferred |
| `dual` | `ipv6` | Dual-stack, IPv6 preferred |
| `dual` | `none` | Dual-stack, no preference |

All other combinations are rejected by `config-render` at startup with a clear error message.

**Dual-stack egress** also requires host IPv6 connectivity. The compose file already sets `enable_ipv6: true` on the default network — on Docker Engine 27+, this is sufficient for IPv6 address assignment on the Compose-created user-defined bridge network with no daemon-level config or manual subnet specification needed.

## Configuration reference

| Variable | Default | Description |
|---|---|---|
| `INGRESS_IP` | — | **Required.** Comma-separated host CIDRs (`/32` IPv4, `/128` IPv6). |
| `TS_AUTHKEY` | — | **Required.** Tailscale auth key tagged with `tag:connector`. |
| `TS_HOSTNAME` | `appc-gateway` | Node hostname as it appears in the Tailscale admin console. |
| `TS_AUTH_ONCE` | `true` | Authenticate only on first boot. Set `false` for ephemeral keys. |
| `TPROXY_PORT` | `10443` | Internal TPROXY listener port. |
| `DNS_UPSTREAM_TLS` | `yes` | Enable DoT to upstream resolvers. Set `no` for plain DNS. |
| `DNS_UPSTREAM_FORWARDERS` | `1.1.1.1@853#cloudflare-dns.com,8.8.8.8@853#dns.google` | Upstream resolvers for Unbound (comma-separated). |
| `POLICY_SYNC_INTERVAL` | `30` | Seconds between policy-sync polls of Tailscale LocalAPI. |
| `CONNECTOR_TAG` | — | Narrow policy to specific tags. Without this, unions all `Self.Tags`. |
| `SKIP_SNI_ENFORCEMENT` | — | Set to `1` to disable SNI allowlist (deny-cidrs stays active). |
| `EXTRA_DENY_CIDRS` | — | Additional CIDRs to block as egress destinations. Additive only. |
| `EGRESS_ACCEPT_FAMILY` | `ipv4` | `ipv4`, `ipv6`, or `dual`. |
| `EGRESS_PREFER_FAMILY` | `ipv4` | `ipv4`, `ipv6`, or `none`. |
| `SKIP_HAPROXY_RENDER` | — | Set to skip rendering `haproxy.cfg` (uses existing file in `./config/`). |
| `SKIP_DNSMASQ_RENDER` | — | Set to skip rendering `dnsmasq-steer.conf`. |
| `SKIP_UNBOUND_RENDER` | — | Set to skip rendering `unbound.conf`. |
| `TS_IMAGE` | `tailscale/tailscale:v1.94.2` | Override Tailscale image tag. |
| `HAPROXY_IMAGE` | `haproxy:3.2.14-alpine` | Override HAProxy image tag. |
| `AUTOHEAL_IMAGE` | `willfarrell/autoheal:1.2.0` | Override autoheal image tag (tools profile only). |

## Connection timeouts

The gateway operates in `mode tcp` — after SNI inspection and routing, HAProxy acts as an opaque TCP forwarder:

| Timer | Value | Phase |
|---|---|---|
| `timeout connect` | 10s | TCP connection establishment to upstream |
| `timeout client` / `timeout server` | 30s | Idle time while the tunnel is being established |
| `timeout tunnel` | 1h | Idle time on an established tunnel |

The 1h `timeout tunnel` is a deployment default suited for long-lived TLS sessions (WebSocket, gRPC streaming). Tailscale's WireGuard keepalive generally keeps the underlying path alive during application-layer idle periods, reducing the practical pressure to tune this value. Adjust if your upstream firewalls or load balancers apply tighter idle-kill timers.

## Logging

All services log to stdout/stderr, readable via `docker compose logs <service>`:

| Service | What you see |
|---|---|
| `appc-proxy` | One line per connection: `sni=<host> dst=<ip>:<port> tw=<ms> tc=<ms> tt=<ms> bytes=<n>` |
| `appc-dns-steer` | One line per DNS query/reply (all queries, including Tailscale infra) |
| `appc-dns-upstream` | One line per query HAProxy resolves upstream |
| `appc-ts` | Tailscale daemon log (connection events, route advertisements) |
| `appc-interception` | TPROXY setup trace at startup |
| `appc-config-render` | Rendered file list + validation errors |
| `appc-policy-sync` | Effective tags, matched app names, domain counts, changed/unchanged |

## Inspecting the stack

```sh
# HAProxy config as rendered
docker compose exec appc-proxy cat /config/haproxy.cfg

# dnsmasq config
docker compose exec appc-dns-steer cat /config/dnsmasq-steer.conf

# TPROXY nftables rules
docker compose exec appc-interception nft list table inet appc_tproxy

# DNS split-horizon check
docker compose exec appc-dns-steer nslookup example.com 127.0.0.1
# → should return INGRESS_IP

docker compose exec appc-dns-steer nslookup controlplane.tailscale.com 127.0.0.1
# → should return real IP

# SNI allowlist contents (populated by policy-sync)
docker compose exec appc-proxy cat /run/appc/allowed-snis-exact.acl
docker compose exec appc-proxy cat /run/appc/allowed-snis-wildcard.acl

# deny-cidrs list
docker compose exec appc-proxy cat /run/appc/deny-cidrs.acl

# HAProxy runtime ACLs via stats socket
docker compose exec appc-proxy sh -c 'echo "show acl" | socat - /run/appc/haproxy.sock'
```

## Currently validated

The following have been validated through manual testing. This repo does not yet have CI-backed integration coverage.

- IPv4 ingress (`/32`)
- IPv6 ingress (`/128`)
- Dual-stack ingress (IPv4 + IPv6 simultaneously)
- Live SNI enforcement via policy-sync
- Allowlist expansion and contraction without proxy restart
- Zero-domain fail-closed (empty ACL = all connections denied)
- deny-cidrs rebinding protection active in open mode

## Deployment context

| Scenario | Public IP | Dual-stack | Open mode | tools profile |
|---|---|---|---|---|
| Lab / dev | Optional | Optional | Acceptable | Diagnostic only |
| Internal pilot | Recommended | Recommended | Initial rollout only | Not recommended |
| Production-like | Tailscale recommendation | Recommended | No | No |

## Limitations

### Protocol limitations

- **TLS/SNI only.** Plain HTTP (port 80) and non-TLS protocols are not intercepted. Connections without a TLS ClientHello are rejected by HAProxy.
- **No QUIC/HTTP3.** UDP to `INGRESS_IP` is TPROXY'd by `appc-interception` but silently dropped. Community HAProxy has no plain UDP frontend (`udp4@` bind is only valid in `log-forward` sections; generic UDP proxying requires HAProxy Enterprise). QUIC/HTTP3 is possible via `quic4@` but requires a TLS certificate. The TPROXY plumbing and a hook comment are already in `haproxy.cfg.tmpl`.
- **Single ingress address bucket.** All steered domains resolve to the same `INGRESS_IP` address(es). Per-domain routing is SNI-based at the proxy, not IP-based at the network layer.

### Operational limitations

- **Cold-start deny-all.** On first boot, SNI ACL files are empty until policy-sync populates them. All TLS connections are rejected during this window (typically < 30s). Fail-closed by design — set `SKIP_SNI_ENFORCEMENT=1` if this is unacceptable during initial rollout.
- **Tailscale restart gap.** If `appc-ts` restarts, all shared-netns services (`appc-interception`, `appc-proxy`, `appc-dns-steer`, `appc-dns-upstream`) lose their network namespace reference. `appc-interception` and `appc-proxy` detect this via watchdog and self-exit, triggering Docker's `restart: unless-stopped`. `appc-dns-steer` and `appc-dns-upstream` rely on Docker's own restart policy without active detection — there is a brief window where DNS and proxy are unavailable.
- **Same-node exit node incompatibility.** Using this gateway node as a Tailscale exit node simultaneously is unsupported. The catch-all DNS steering returns `INGRESS_IP` for all domains — this conflicts with the full-tunnel DNS resolution expected of an exit node and will break generic internet routing.
- **Linux only.** TPROXY requires Linux kernel support. Does not run on macOS or Windows.

## Operator overrides

These settings exist for diagnostic and advanced use. They should not be part of a normal deployment.

### Open mode (`SKIP_SNI_ENFORCEMENT=1`)

Disables the SNI allowlist — all SNIs are forwarded regardless of admin-console configuration. The deny-cidrs post-resolution check remains active regardless. `appc-config-render` emits a WARNING in logs at startup when this is set.

For initial rollout testing or diagnostic use only. Not recommended for normal deployments.

### Removing static deny-cidrs ranges

`EXTRA_DENY_CIDRS` is additive only — it cannot remove static ranges. To allow forwarding to tailnet peers or non-Tailscale CGNAT destinations, remove the relevant range from the static base in `config-render/render.sh` and `policy-sync/sync.sh`. This requires a deliberate source change to alter a security default — it cannot be done via env var.

### Tailscale debug envknobs

For path-forcing, DERP relay testing, or magicsock diagnostics, `appc-ts` accepts Tailscale internal `TS_DEBUG_*` envknobs via an optional file at the repo root:

```sh
cp tailscale-debug.env.example tailscale-debug.env
# uncomment desired knobs
docker compose down && docker compose up -d
```

**Important:** `appc-ts` owns the shared network namespace for `appc-proxy`, `appc-interception`, `appc-dns-steer`, and `appc-dns-upstream`. Always do a full-stack restart (`down && up -d`) — partial restarts leave sidecars attached to a stale namespace.

When `tailscale-debug.env` is absent, `appc-ts` starts normally with no effect on default deployments.

These knobs are part of Tailscale's internal debug interface, not a stable public API. Names and behavior may change across Tailscale releases. Not recommended for normal deployments. To inspect active knobs:

```sh
docker compose exec appc-ts env | grep '^TS_DEBUG_'
```

## Future expansion

Not implemented yet:

- **Per-connector ingress buckets.** Multiple `INGRESS_IP` groups with separate HAProxy frontends/backends, each tied to a different connector tag.
- **Plain HTTP support.** Port 80 interception using Host header instead of SNI.
- **Metrics.** HAProxy stats socket/Prometheus endpoint, Unbound and dnsmasq stats. Not wired up yet.
