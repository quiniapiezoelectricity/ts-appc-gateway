#!/bin/sh
set -e

INGRESS_IP=${INGRESS_IP:-}
TPROXY_PORT=${TPROXY_PORT:-10443}
TPROXY_MARK=1
TPROXY_TABLE=100

: "${INGRESS_IP:?INGRESS_IP is required}"
# INGRESS_IP is a comma-delimited list of host CIDRs (/32 or /128).
# config-render validates and rejects whitespace before this container starts.

echo "==> interception: INGRESS_IP=${INGRESS_IP} TPROXY_PORT=${TPROXY_PORT}"

# ----------------------------------------------------------------
# Loopback aliases
# Each ingress IP must be a local address so the kernel routes
# HAProxy's responses (src=INGRESS_IP) back via tailscale0 rather
# than the Docker bridge.
# ----------------------------------------------------------------
IFS=','
for _cidr in ${INGRESS_IP}; do
    _bare="${_cidr%/*}"
    case "${_cidr}" in
        */128)
            # 2>/dev/null || true: kernel normalizes IPv6 repr; string matching is unreliable.
            # ip addr add returns EEXIST on re-add — suppress and continue.
            ip -6 addr add "${_bare}/128" dev lo 2>/dev/null || true
            echo "==> ensured ${_bare}/128 on lo"
            ;;
        */32)
            ip addr add "${_bare}/32" dev lo 2>/dev/null || true
            echo "==> ensured ${_bare}/32 on lo"
            ;;
    esac
done
unset IFS

# ----------------------------------------------------------------
# Policy routing — IPv4
# Packets marked with fwmark 1 → table 100 → local delivery to HAProxy
# ----------------------------------------------------------------
while ip rule show | grep -E "fwmark ${TPROXY_MARK}(/${TPROXY_MARK})? .* lookup ${TPROXY_TABLE}" >/dev/null 2>&1; do
    ip rule del fwmark "${TPROXY_MARK}" lookup "${TPROXY_TABLE}" 2>/dev/null || true
done
ip rule add fwmark "${TPROXY_MARK}" lookup "${TPROXY_TABLE}"
ip route replace local 0.0.0.0/0 dev lo table "${TPROXY_TABLE}"

# Policy routing — IPv6 (only if any /128 entries in INGRESS_IP)
_has_ipv6=false
IFS=','
for _cidr in ${INGRESS_IP}; do
    case "${_cidr}" in */128) _has_ipv6=true ;; esac
done
unset IFS

if [ "${_has_ipv6}" = "true" ]; then
    while ip -6 rule show | grep -E "fwmark ${TPROXY_MARK}(/${TPROXY_MARK})? .* lookup ${TPROXY_TABLE}" >/dev/null 2>&1; do
        ip -6 rule del fwmark "${TPROXY_MARK}" lookup "${TPROXY_TABLE}" 2>/dev/null || true
    done
    ip -6 rule add fwmark "${TPROXY_MARK}" lookup "${TPROXY_TABLE}"
    ip -6 route replace local ::/0 dev lo table "${TPROXY_TABLE}"
fi

# ----------------------------------------------------------------
# nftables TPROXY rules — named table inet appc_tproxy
# Delete and rebuild on restart for clean idempotency.
# ----------------------------------------------------------------
nft delete table inet appc_tproxy 2>/dev/null || true
nft add table inet appc_tproxy
nft add chain inet appc_tproxy prerouting \
    '{ type filter hook prerouting priority mangle; policy accept; }'

IFS=','
for _cidr in ${INGRESS_IP}; do
    _bare="${_cidr%/*}"
    case "${_cidr}" in
        */128)
            nft add rule inet appc_tproxy prerouting \
                "iif tailscale0 ip6 daddr ${_bare} meta l4proto tcp tproxy ip6 to :${TPROXY_PORT} meta mark set ${TPROXY_MARK}"
            nft add rule inet appc_tproxy prerouting \
                "iif tailscale0 ip6 daddr ${_bare} meta l4proto udp tproxy ip6 to :${TPROXY_PORT} meta mark set ${TPROXY_MARK}"
            ;;
        */32)
            nft add rule inet appc_tproxy prerouting \
                "iif tailscale0 ip daddr ${_bare} meta l4proto tcp tproxy ip to :${TPROXY_PORT} meta mark set ${TPROXY_MARK}"
            nft add rule inet appc_tproxy prerouting \
                "iif tailscale0 ip daddr ${_bare} meta l4proto udp tproxy ip to :${TPROXY_PORT} meta mark set ${TPROXY_MARK}"
            ;;
    esac
done
unset IFS

echo "==> nftables TPROXY ready: tailscale0/${INGRESS_IP} → local:${TPROXY_PORT}"

# Watchdog — exit when tailscale0 disappears or nftables chain is gone.
# When appc-ts restarts it gets a new network namespace — tailscale0 vanishes
# from this one. Exiting causes Docker to restart this container, which
# re-attaches to the new netns and re-applies the nftables rules.
echo "==> Watching tailscale0 and nftables chain..."
while ip link show tailscale0 >/dev/null 2>&1 \
   && nft list chain inet appc_tproxy prerouting >/dev/null 2>&1; do
    sleep 5
done
echo "==> Health condition lost — exiting to force restart"
exit 1
