FROM alpine:3.19@sha256:6baf43584bcb78f2e5847d1de515f23499913ac9f12bdf834811a3145eb11ca1
RUN apk add --no-cache nftables iproute2
COPY setup.sh /setup.sh
RUN chmod +x /setup.sh
# Health: nftables TPROXY chain exists AND tailscale0 is present.
# Both conditions must hold — matches the watchdog in setup.sh,
# so the container goes unhealthy the moment tailscale0 disappears,
# not just when it finally dies.
HEALTHCHECK --interval=5s --timeout=3s --start-period=15s --retries=5 \
    CMD nft list chain inet appc_tproxy prerouting >/dev/null 2>&1 \
        && ip link show tailscale0 >/dev/null 2>&1
CMD ["/setup.sh"]
