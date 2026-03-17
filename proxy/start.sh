#!/bin/sh
# Wrapper entrypoint for appc-proxy.
# Starts HAProxy and monitors tailscale0. When the interface disappears
# (appc-ts restarted, network namespace became stale), exits so Docker's
# restart: unless-stopped policy re-attaches to the new netns.
# This replaces appc-autoheal for the proxy's only healthcheck condition.
set -e

# Forward SIGTERM/SIGINT to HAProxy so `docker stop` triggers a clean shutdown
# instead of relying on Docker's forced-kill timeout.
# shellcheck disable=SC2329,SC2317  # _cleanup is invoked via trap, not a direct call
_cleanup() {
    kill "${_pid}" 2>/dev/null || true
    wait "${_pid}" 2>/dev/null || true
    exit 0
}
trap _cleanup TERM INT

# Start HAProxy master-worker in the background
haproxy -W -f /config/haproxy.cfg &
_pid=$!

echo "==> appc-proxy: HAProxy started (pid ${_pid})"
echo "==> appc-proxy: watching tailscale0..."

# Watchdog: exit when tailscale0 disappears or HAProxy dies
while kill -0 "${_pid}" 2>/dev/null \
   && grep -q tailscale0 /proc/net/dev 2>/dev/null; do
    sleep 5
done

echo "==> appc-proxy: tailscale0 gone or HAProxy exited — triggering restart"
kill "${_pid}" 2>/dev/null || true
wait "${_pid}" 2>/dev/null || true
exit 1
