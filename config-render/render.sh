#!/bin/sh
set -e

TEMPLATES=/templates
CONFIG=/config

# ----------------------------------------------------------------
# Validate and parse INGRESS_IP (comma-separated host CIDRs)
# Each entry must be /32 (IPv4) or /128 (IPv6). Family is detected
# from the suffix. Bare IPs and other prefix lengths are rejected.
# Sets: INGRESS_HAS_IPV4, INGRESS_HAS_IPV6, INGRESS_V4_HOSTS, INGRESS_V6_HOSTS
# ----------------------------------------------------------------
: "${INGRESS_IP:?INGRESS_IP is required (e.g. 10.99.0.1/32 or 10.99.0.1/32,fd00::1/128)}"
case "${INGRESS_IP}" in
    *' '*|*'	'*)
        echo "ERROR: INGRESS_IP must not contain whitespace — use comma-only separators: 10.99.0.1/32,fd00::1/128" >&2
        exit 1
        ;;
    ,*|*,|*,,*)
        echo "ERROR: INGRESS_IP must not contain empty elements (no leading, trailing, or consecutive commas)" >&2
        exit 1
        ;;
esac
INGRESS_HAS_IPV4=false
INGRESS_HAS_IPV6=false
INGRESS_V4_HOSTS=""
INGRESS_V6_HOSTS=""
IFS=','
for _cidr in ${INGRESS_IP}; do
    case "${_cidr}" in
        */32)
            _bare="${_cidr%/*}"
            case "${_bare}" in
                ''|*[!0-9.]*) echo "ERROR: '${_cidr}' is not a valid IPv4 host CIDR (expected dotted-decimal address before /32)" >&2; exit 1 ;;
            esac
            INGRESS_HAS_IPV4=true
            INGRESS_V4_HOSTS="${INGRESS_V4_HOSTS}${INGRESS_V4_HOSTS:+ }${_bare}"
            ;;
        */128)
            _bare="${_cidr%/*}"
            case "${_bare}" in
                *:*) ;;
                *) echo "ERROR: '${_cidr}' is not a valid IPv6 host CIDR (expected colon-hex address before /128)" >&2; exit 1 ;;
            esac
            INGRESS_HAS_IPV6=true
            INGRESS_V6_HOSTS="${INGRESS_V6_HOSTS}${INGRESS_V6_HOSTS:+ }${_bare}"
            ;;
        *)
            echo "ERROR: INGRESS_IP entries must be /32 (IPv4) or /128 (IPv6) host CIDRs: '${_cidr}'" >&2
            exit 1
            ;;
    esac
done
unset IFS

# Apply defaults
TPROXY_PORT=${TPROXY_PORT:-10443}
# DoT (DNS over TLS) to upstream forwarders. Default: Cloudflare + Google over TLS.
# For plain DNS (e.g. corporate resolver): set DNS_UPSTREAM_TLS=no and use bare IPs.
# DNS_UPSTREAM_FORWARDERS is a comma-separated list of forwarder addresses.
# With DoT: include port and TLS name, e.g. 1.1.1.1@853#cloudflare-dns.com
# Plain DNS: bare IPs, e.g. 192.168.1.1,192.168.1.2
DNS_UPSTREAM_TLS=${DNS_UPSTREAM_TLS:-yes}
DNS_UPSTREAM_FORWARDERS=${DNS_UPSTREAM_FORWARDERS:-1.1.1.1@853#cloudflare-dns.com,8.8.8.8@853#dns.google}

# Build forward-addr lines for unbound.conf from the comma-separated list
DNS_UPSTREAM_FORWARD_ADDRS=""
IFS=','
for _addr in ${DNS_UPSTREAM_FORWARDERS}; do
    DNS_UPSTREAM_FORWARD_ADDRS="${DNS_UPSTREAM_FORWARD_ADDRS}    forward-addr: ${_addr}
"
done
unset IFS

# Skip knobs — set to any non-empty value to skip rendering that file.
# Use these when you want to supply a hand-crafted config instead of
# the generated one. The service consuming the skipped file will use
# whatever is already present in the config volume.
#   SKIP_HAPROXY_RENDER=1    — skip haproxy.cfg
#   SKIP_DNSMASQ_RENDER=1    — skip dnsmasq-steer.conf
#   SKIP_UNBOUND_RENDER=1    — skip unbound.conf
SKIP_HAPROXY_RENDER=${SKIP_HAPROXY_RENDER:-}
SKIP_DNSMASQ_RENDER=${SKIP_DNSMASQ_RENDER:-}
SKIP_UNBOUND_RENDER=${SKIP_UNBOUND_RENDER:-}
SKIP_SNI_ENFORCEMENT=${SKIP_SNI_ENFORCEMENT:-}

# Egress address-family policy knobs.
# EGRESS_ACCEPT_FAMILY: which IP families HAProxy will accept from DNS responses.
#   ipv4 — dns-accept-family ipv4 (strict IPv4-only, default)
#   ipv6 — dns-accept-family ipv6 (strict IPv6-only)
#   dual — no dns-accept-family directive (both families accepted)
# EGRESS_PREFER_FAMILY: family preference hint passed to do-resolve.
#   ipv4 — prefer A records (default)
#   ipv6 — prefer AAAA records
#   none — no preference; only valid with EGRESS_ACCEPT_FAMILY=dual
EGRESS_ACCEPT_FAMILY=${EGRESS_ACCEPT_FAMILY:-ipv4}
EGRESS_PREFER_FAMILY=${EGRESS_PREFER_FAMILY:-ipv4}

case "${EGRESS_ACCEPT_FAMILY}" in
    ipv4|ipv6|dual) ;;
    *) echo "ERROR: EGRESS_ACCEPT_FAMILY must be one of: ipv4, ipv6, dual (got: ${EGRESS_ACCEPT_FAMILY})" >&2; exit 1;;
esac
case "${EGRESS_PREFER_FAMILY}" in
    ipv4|ipv6|none) ;;
    *) echo "ERROR: EGRESS_PREFER_FAMILY must be one of: ipv4, ipv6, none (got: ${EGRESS_PREFER_FAMILY})" >&2; exit 1;;
esac
if [ "${EGRESS_ACCEPT_FAMILY}" = "ipv4" ] && [ "${EGRESS_PREFER_FAMILY}" = "ipv6" ]; then
    echo "ERROR: EGRESS_ACCEPT_FAMILY=ipv4 conflicts with EGRESS_PREFER_FAMILY=ipv6" >&2; exit 1
fi
if [ "${EGRESS_ACCEPT_FAMILY}" = "ipv6" ] && [ "${EGRESS_PREFER_FAMILY}" = "ipv4" ]; then
    echo "ERROR: EGRESS_ACCEPT_FAMILY=ipv6 conflicts with EGRESS_PREFER_FAMILY=ipv4" >&2; exit 1
fi
if [ "${EGRESS_ACCEPT_FAMILY}" != "dual" ] && [ "${EGRESS_PREFER_FAMILY}" = "none" ]; then
    echo "ERROR: EGRESS_PREFER_FAMILY=none is only valid with EGRESS_ACCEPT_FAMILY=dual" >&2; exit 1
fi

case "${EGRESS_ACCEPT_FAMILY}" in
    ipv4)  DNS_ACCEPT_FAMILY_DIRECTIVE="    dns-accept-family ipv4";;
    ipv6)  DNS_ACCEPT_FAMILY_DIRECTIVE="    dns-accept-family ipv6";;
    dual)  DNS_ACCEPT_FAMILY_DIRECTIVE="";;
esac
case "${EGRESS_PREFER_FAMILY}" in
    ipv4)  DO_RESOLVE_FAMILY_ARG=",ipv4";;
    ipv6)  DO_RESOLVE_FAMILY_ARG=",ipv6";;
    none)  DO_RESOLVE_FAMILY_ARG="";;
esac

# Build dnsmasq address= lines — one per ingress IP.
# dnsmasq auto-returns A for IPv4 addresses and AAAA for IPv6 addresses.
DNSMASQ_ADDRESS_LINES=""
for _ip in ${INGRESS_V4_HOSTS} ${INGRESS_V6_HOSTS}; do
    DNSMASQ_ADDRESS_LINES="${DNSMASQ_ADDRESS_LINES}address=/#/${_ip}
"
done

# Build HAProxy bind lines — one wildcard bind per family present.
# Duplicate binds on the same port cause HAProxy to fail to start,
# so we emit at most one IPv4 bind and one IPv6 bind regardless of
# how many ingress addresses are in each family.
TPROXY_BIND_LINES=""
if [ "${INGRESS_HAS_IPV4}" = "true" ]; then
    TPROXY_BIND_LINES="${TPROXY_BIND_LINES}    bind 0.0.0.0:${TPROXY_PORT} transparent
"
fi
if [ "${INGRESS_HAS_IPV6}" = "true" ]; then
    # v6only: plain HAProxy bind keyword (not v6only 1). Sets IPV6_V6ONLY so
    # the ::: socket does not accept IPv4-mapped connections when the IPv4
    # bind is also present.
    TPROXY_BIND_LINES="${TPROXY_BIND_LINES}    bind :::${TPROXY_PORT} transparent v6only
"
fi

# Build the SNI enforcement block for haproxy.cfg.tmpl.
# When SKIP_SNI_ENFORCEMENT=1, the template gets a comment instead of
# ACL rules — open mode. deny-cidrs post-resolution check stays active regardless.
if [ "${SKIP_SNI_ENFORCEMENT}" = "1" ]; then
    SNI_ENFORCEMENT='    # SNI enforcement disabled (SKIP_SNI_ENFORCEMENT=1)'
else
    SNI_ENFORCEMENT='    # SNI allowlist (populated by appc-policy-sync)
    # Reject disallowed SNIs BEFORE DNS resolution (prevents DNS oracle).
    # On cold start: empty files = deny-all until policy-sync populates.
    acl sni_exact var(sess.sni) -m str -f /run/appc/allowed-snis-exact.acl
    acl sni_wildcard var(sess.sni) -m end -f /run/appc/allowed-snis-wildcard.acl
    tcp-request content reject if { var(sess.sni) -m found } !sni_exact !sni_wildcard'
fi

export INGRESS_IP TPROXY_PORT \
       DNS_UPSTREAM_TLS DNS_UPSTREAM_FORWARD_ADDRS \
       SNI_ENFORCEMENT \
       DNS_ACCEPT_FAMILY_DIRECTIVE DO_RESOLVE_FAMILY_ARG \
       DNSMASQ_ADDRESS_LINES TPROXY_BIND_LINES

echo "==> config-render starting"
echo "    INGRESS_IP               = ${INGRESS_IP}"
echo "    TPROXY_PORT              = ${TPROXY_PORT}"
echo "    SKIP_SNI_ENFORCEMENT    = ${SKIP_SNI_ENFORCEMENT:-<not set>}"
echo "    EGRESS_ACCEPT_FAMILY     = ${EGRESS_ACCEPT_FAMILY}"
echo "    EGRESS_PREFER_FAMILY     = ${EGRESS_PREFER_FAMILY}"
echo "    DNS_UPSTREAM_TLS         = ${DNS_UPSTREAM_TLS}"
echo "    DNS_UPSTREAM_FORWARDERS  = ${DNS_UPSTREAM_FORWARDERS}"
if [ "${SKIP_SNI_ENFORCEMENT:-0}" = "1" ]; then
    echo "WARNING: SKIP_SNI_ENFORCEMENT=1 — SNI allowlist disabled. All SNIs will be forwarded." >&2
fi

# ----------------------------------------------------------------
# haproxy.cfg — only substitute the specific vars used in the template
# to avoid accidentally expanding HAProxy's own % or $ syntax
# ----------------------------------------------------------------
if [ -n "${SKIP_HAPROXY_RENDER}" ]; then
    echo "    [skip] haproxy.cfg (SKIP_HAPROXY_RENDER set)"
else
    # shellcheck disable=SC2016  # single quotes are intentional: envsubst needs literal ${VAR} syntax
    envsubst '${TPROXY_BIND_LINES} ${TPROXY_PORT} ${SNI_ENFORCEMENT} ${DNS_ACCEPT_FAMILY_DIRECTIVE} ${DO_RESOLVE_FAMILY_ARG}' \
      < ${TEMPLATES}/haproxy.cfg.tmpl \
      > ${CONFIG}/haproxy.cfg
    echo "    [ok] haproxy.cfg"
fi

# ----------------------------------------------------------------
# dnsmasq-steer.conf
# ----------------------------------------------------------------
if [ -n "${SKIP_DNSMASQ_RENDER}" ]; then
    echo "    [skip] dnsmasq-steer.conf (SKIP_DNSMASQ_RENDER set)"
else
    # shellcheck disable=SC2016  # single quotes are intentional: envsubst needs literal ${VAR} syntax
    envsubst '${DNSMASQ_ADDRESS_LINES}' \
      < ${TEMPLATES}/dnsmasq-steer.conf.tmpl \
      > ${CONFIG}/dnsmasq-steer.conf
    echo "    [ok] dnsmasq-steer.conf"
fi

# ----------------------------------------------------------------
# unbound.conf
# ----------------------------------------------------------------
if [ -n "${SKIP_UNBOUND_RENDER}" ]; then
    echo "    [skip] unbound.conf (SKIP_UNBOUND_RENDER set)"
else
    # shellcheck disable=SC2016  # single quotes are intentional: envsubst needs literal ${VAR} syntax
    envsubst '${DNS_UPSTREAM_TLS} ${DNS_UPSTREAM_FORWARD_ADDRS}' \
      < ${TEMPLATES}/unbound.conf.tmpl \
      > ${CONFIG}/unbound.conf
    echo "    [ok] unbound.conf"
fi

# ----------------------------------------------------------------
# ACL seed files (on /run/appc tmpfs volume)
# ----------------------------------------------------------------
APPC_RUN=/run/appc

# Unsafe-mode marker — written when any safety override is active so other
# services (e.g. appc-proxy) can detect and log the degraded state.
if [ "${SKIP_SNI_ENFORCEMENT:-0}" = "1" ] || \
   [ -n "${SKIP_HAPROXY_RENDER:-}" ] || \
   [ -n "${SKIP_DNSMASQ_RENDER:-}" ] || \
   [ -n "${SKIP_UNBOUND_RENDER:-}" ]; then
    touch "${APPC_RUN}/unsafe-mode"
    echo "    [warn] unsafe-mode marker written to ${APPC_RUN}/unsafe-mode"
else
    rm -f "${APPC_RUN}/unsafe-mode"
fi

# SNI allowlists: seed ONLY IF MISSING — preserve last-known-good
# across stack restarts. Empty = deny-all on first boot only.
if [ ! -f "${APPC_RUN}/allowed-snis-exact.acl" ]; then
    : > "${APPC_RUN}/allowed-snis-exact.acl"
    echo "    [ok] allowed-snis-exact.acl (seeded empty)"
else
    echo "    [ok] allowed-snis-exact.acl (preserved existing)"
fi
if [ ! -f "${APPC_RUN}/allowed-snis-wildcard.acl" ]; then
    : > "${APPC_RUN}/allowed-snis-wildcard.acl"
    echo "    [ok] allowed-snis-wildcard.acl (seeded empty)"
else
    echo "    [ok] allowed-snis-wildcard.acl (preserved existing)"
fi

# deny-cidrs: static base — DNS rebinding / dangerous destination protection.
# Includes IPv6 dangerous ranges unconditionally (HAProxy -m ip ACL accepts both
# families; entries never match in IPv4-only deployments).
# 100.64.0.0/10 (Tailscale CGNAT / tailnet peer range) and
# fd7a:115c:a1e0::/48 (Tailscale IPv6 node range) are denied by default to
# prevent ACL bypass through this gateway. EXTRA_DENY_CIDRS is additive only —
# to allow tailnet forwarding, remove these ranges from the static base directly.
# Policy-sync rebuilds this file on every successful sync with static base
# + EXTRA_DENY_CIDRS + Self.TailscaleIPs + Quad100 (100.100.100.100/32).
cat > "${APPC_RUN}/deny-cidrs.acl" <<'DENY_EOF'
127.0.0.0/8
169.254.0.0/16
224.0.0.0/4
240.0.0.0/4
100.64.0.0/10
fd7a:115c:a1e0::/48
::1/128
fe80::/10
ff00::/8
DENY_EOF
if [ -n "${EXTRA_DENY_CIDRS:-}" ]; then
    echo "${EXTRA_DENY_CIDRS}" | tr ',' '\n' >> "${APPC_RUN}/deny-cidrs.acl"
    echo "    [ok] deny-cidrs.acl (static + EXTRA_DENY_CIDRS)"
else
    echo "    [ok] deny-cidrs.acl (static dangerous ranges)"
fi

echo "==> Config render complete"
