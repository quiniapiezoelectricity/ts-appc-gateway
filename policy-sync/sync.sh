#!/bin/sh
# shellcheck disable=SC3043  # 'local' is a busybox ash extension; this script targets Alpine only
set -e

# ================================================================
# appc-policy-sync
# Reads the App Connector's assigned domain list from Tailscale's
# LocalAPI status JSON and generates HAProxy ACL files for:
#   - SNI allowlisting (exact + wildcard)
#   - DNS rebinding protection (deny-cidrs)
# Updates HAProxy's in-memory ACLs via the runtime stats socket
# for zero-downtime policy changes.
# ================================================================

APPC_RUN=/run/appc
HAPROXY_SOCK="${APPC_RUN}/haproxy.sock"
TS_SOCKET="${TS_SOCKET:-/var/run/tailscale/tailscaled.sock}"
POLICY_SYNC_INTERVAL="${POLICY_SYNC_INTERVAL:-30}"
CONNECTOR_TAG="${CONNECTOR_TAG:-}"
EXTRA_DENY_CIDRS="${EXTRA_DENY_CIDRS:-}"

EXACT_ACL="${APPC_RUN}/allowed-snis-exact.acl"
WILDCARD_ACL="${APPC_RUN}/allowed-snis-wildcard.acl"
DENY_CIDRS_ACL="${APPC_RUN}/deny-cidrs.acl"
HEARTBEAT="${APPC_RUN}/.sync-heartbeat"

# Track whether we've logged the "no SNI ACL IDs" message (open mode)
_sni_acl_warned=0
_last_sni_hash=""

# ----------------------------------------------------------------
# Helper: fetch Tailscale LocalAPI status JSON
# ----------------------------------------------------------------
ts_status() {
    curl --fail --silent --unix-socket "$TS_SOCKET" \
        http://local-tailscaled.sock/localapi/v0/status
}

# ----------------------------------------------------------------
# Helper: wait until Tailscale is up and Self is populated
# ----------------------------------------------------------------
wait_for_tailscale() {
    local _backoff=1
    echo "==> Waiting for Tailscale to be ready..."
    while true; do
        _status=$(ts_status 2>/dev/null) || true
        if [ -n "$_status" ] && echo "$_status" | jq -e '.Self != null' >/dev/null 2>&1; then
            echo "==> Tailscale is ready"
            return 0
        fi
        echo "    Tailscale not ready, retrying in ${_backoff}s..."
        sleep "$_backoff"
        _backoff=$(( _backoff * 2 ))
        [ "$_backoff" -gt 30 ] && _backoff=30
    done
}

# ----------------------------------------------------------------
# Helper: get Self.Tags from status JSON
# ----------------------------------------------------------------
get_self_tags() {
    local _status="$1"
    echo "$_status" | jq -r '.Self.Tags // [] | .[]'
}

# ----------------------------------------------------------------
# Helper: compute effective tags from current status
# Returns 0 on success, 1 on validation failure.
# Outputs effective tags (one per line) on stdout.
# ----------------------------------------------------------------
get_effective_tags() {
    local _status="$1"
    local _self_tags
    _self_tags=$(get_self_tags "$_status")

    if [ -n "$CONNECTOR_TAG" ]; then
        # Validate each requested tag against current Self.Tags
        local _result=""
        IFS=','
        for _tag in $CONNECTOR_TAG; do
            _tag=$(echo "$_tag" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            if echo "$_self_tags" | grep -qx "$_tag"; then
                _result="${_result}${_tag}
"
            else
                echo "    [error] CONNECTOR_TAG '$_tag' not in Self.Tags, skipping iteration" >&2
                return 1
            fi
        done
        unset IFS
        echo "$_result" | sed '/^$/d'
    else
        # Union of all Self.Tags
        echo "$_self_tags"
    fi
}

# ----------------------------------------------------------------
# Helper: extract domains from CapMap for effective tags
# Filters CapMap["tailscale.com/app-connectors"] entries whose
# connectors[] overlap with effective tags, flattens domains[].
# ----------------------------------------------------------------
extract_domains() {
    local _status="$1"
    local _tags="$2"

    # Build a jq filter array from effective tags
    local _tags_json
    _tags_json=$(echo "$_tags" | jq -R -s 'split("\n") | map(select(length > 0))')

    echo "$_status" | jq -r --argjson tags "$_tags_json" '
        .Self.CapMap["tailscale.com/app-connectors"] // []
        | map(select(.connectors as $c | ($tags | any(. as $t | $c | any(. == $t)))))
        | { domains: [.[].domains[]] | unique | sort, names: [.[].name] | unique }
    '
}

# ----------------------------------------------------------------
# Helper: split domains into exact and wildcard files
# *.example.com → .example.com (wildcard, suffix match)
# example.com → example.com (exact match)
# *.example.com does NOT include example.com (Tailscale semantics)
# ----------------------------------------------------------------
split_domains() {
    local _domains_json="$1"
    local _exact=""
    local _wildcard=""

    for _domain in $(echo "$_domains_json" | jq -r '.domains[]'); do
        case "$_domain" in
            \*.*)
                # *.example.com → .example.com for -m end suffix match
                _suffix=$(echo "$_domain" | sed 's/^\*//')
                _wildcard="${_wildcard}${_suffix}
"
                ;;
            *)
                _exact="${_exact}${_domain}
"
                ;;
        esac
    done

    # Output as two-line JSON for easy consumption
    _exact=$(echo "$_exact" | sed '/^$/d' | sort -u)
    _wildcard=$(echo "$_wildcard" | sed '/^$/d' | sort -u)
    printf '%s\n---\n%s\n' "$_exact" "$_wildcard"
}

# ----------------------------------------------------------------
# Helper: write ACL file atomically (.tmp + mv)
# ----------------------------------------------------------------
write_acl_file() {
    local _path="$1"
    local _content="$2"
    printf '%s\n' "$_content" > "${_path}.tmp"
    mv "${_path}.tmp" "$_path"
}

# ----------------------------------------------------------------
# Helper: build deny-cidrs content from static base + dynamic IPs
# ----------------------------------------------------------------
build_deny_cidrs() {
    local _status="$1"

    # Static dangerous ranges (IPv4 + IPv6)
    # HAProxy -m ip ACL accepts both families; IPv6 entries never match in IPv4-only deployments.
    # 100.64.0.0/10 and fd7a:115c:a1e0::/48 deny tailnet peer ranges by default to prevent
    # ACL bypass. EXTRA_DENY_CIDRS is additive only; to allow tailnet forwarding, remove
    # these ranges from the static base in both this file and config-render/render.sh.
    cat <<'STATIC_EOF'
127.0.0.0/8
169.254.0.0/16
224.0.0.0/4
240.0.0.0/4
100.100.100.100/32
100.64.0.0/10
fd7a:115c:a1e0::/48
::1/128
fe80::/10
ff00::/8
STATIC_EOF

    # EXTRA_DENY_CIDRS from operator
    if [ -n "$EXTRA_DENY_CIDRS" ]; then
        echo "$EXTRA_DENY_CIDRS" | tr ',' '\n'
    fi

    # Self.TailscaleIPs — prevent DNS rebinding to this node
    echo "$_status" | jq -r '.Self.TailscaleIPs // [] | .[]' | while read -r _ip; do
        case "$_ip" in
            *:*)
                # IPv6 — append /128
                echo "${_ip}/128"
                ;;
            *)
                # IPv4 — append /32
                echo "${_ip}/32"
                ;;
        esac
    done
}

# ----------------------------------------------------------------
# Helper: push a single ACL to HAProxy via runtime socket
# Full replacement: prepare → add all entries → commit
# ----------------------------------------------------------------
push_single_acl() {
    local _acl_path="$1"
    local _content="$2"

    # Discover ACL ID by file path — exact field match on column 2 "(path)"
    # to avoid regex dot-matching and substring collisions
    local _acl_id
    _acl_id=$(echo "show acl" | socat - UNIX-CONNECT:"$HAPROXY_SOCK" 2>/dev/null \
        | awk -v path="(${_acl_path})" '$2 == path { print $1; exit }')

    if [ -z "$_acl_id" ]; then
        return 1
    fi

    # HAProxy 3.2 versioned ACL transaction:
    #   prepare acl #<id>            → returns "@<ver>"
    #   add acl @<ver> #<id> <entry> → stages entries
    #   commit acl @<ver> #<id>      → atomically replaces live ACL
    # prepare acl returns "New version created: <N>" — extract N and form "@N"
    local _ver_num _ver
    _ver_num=$(echo "prepare acl #${_acl_id}" | socat - UNIX-CONNECT:"$HAPROXY_SOCK" 2>/dev/null \
        | awk '/New version created:/ { print $NF }' | tr -d '[:space:]')

    if [ -z "$_ver_num" ]; then
        return 1
    fi
    _ver="@${_ver_num}"

    # Stage all entries into the prepared version
    if [ -n "$_content" ]; then
        echo "$_content" | while IFS= read -r _line; do
            [ -z "$_line" ] && continue
            echo "add acl ${_ver} #${_acl_id} ${_line}" | socat - UNIX-CONNECT:"$HAPROXY_SOCK" >/dev/null 2>&1
        done
    fi

    # Atomically replace the live ACL with the prepared version
    echo "commit acl ${_ver} #${_acl_id}" | socat - UNIX-CONNECT:"$HAPROXY_SOCK" >/dev/null 2>&1
}

# ----------------------------------------------------------------
# Helper: push deny-cidrs ACL to HAProxy runtime
# Called on every successful sync.
# ----------------------------------------------------------------
push_deny_cidrs_runtime() {
    local _deny_cidrs="$1"

    [ ! -S "$HAPROXY_SOCK" ] && return 0

    if push_single_acl "$DENY_CIDRS_ACL" "$_deny_cidrs"; then
        echo "    [ok] deny-cidrs pushed to HAProxy runtime"
    else
        echo "    [warn] deny-cidrs ACL ID not found in HAProxy (may not be loaded yet)"
    fi
}

# ----------------------------------------------------------------
# Helper: push SNI allowlist ACLs to HAProxy runtime
# Called only on hash change or explicit revocation (not unchanged branch).
# ----------------------------------------------------------------
push_sni_acls_runtime() {
    local _exact="$1"
    local _wildcard="$2"

    [ ! -S "$HAPROXY_SOCK" ] && return 0

    # SNI ACLs may not exist in open mode (SKIP_SNI_ENFORCEMENT=1)
    local _pushed=0
    push_single_acl "$EXACT_ACL" "$_exact" && _pushed=1
    push_single_acl "$WILDCARD_ACL" "$_wildcard" && _pushed=1

    if [ "$_pushed" = "1" ]; then
        echo "    [ok] SNI ACLs pushed to HAProxy runtime"
        _sni_acl_warned=0
    elif [ "$_sni_acl_warned" = "0" ]; then
        echo "    [info] SNI ACL IDs not found in HAProxy (expected in open mode)"
        _sni_acl_warned=1
    fi
}

# ================================================================
# Main loop
# ================================================================

echo "==> appc-policy-sync starting"
echo "    POLICY_SYNC_INTERVAL = ${POLICY_SYNC_INTERVAL}s"
echo "    CONNECTOR_TAG        = ${CONNECTOR_TAG:-<all Self.Tags>}"
echo "    TS_SOCKET             = ${TS_SOCKET}"

wait_for_tailscale

echo "==> Entering sync loop"

while true; do
    # Fetch status JSON
    _status=$(ts_status 2>/dev/null) || true

    if [ -z "$_status" ] || ! echo "$_status" | jq -e '.Self != null' >/dev/null 2>&1; then
        echo "    [error] Failed to fetch Tailscale status, keeping last-known-good"
        sleep "$POLICY_SYNC_INTERVAL"
        continue
    fi

    # Recompute effective tags from current status (tags can change at runtime).
    # Failure or empty result on a successful fetch = fail closed (clear ACLs),
    # not keep-last-known-good. Tag removal is an explicit admin action.
    _effective_tags=""
    _tag_err=$(get_effective_tags "$_status" 2>&1) && _effective_tags="$_tag_err" || true

    if [ -z "$_effective_tags" ]; then
        echo "    [warn] No effective tags — failing closed (treating as 0 domains)"
        _domains_json='{"domains":[],"names":["(no effective tags)"]}'
    else
        # Extract domains for effective tags
        _domains_json=$(extract_domains "$_status" "$_effective_tags")
    fi
    _domain_count=$(echo "$_domains_json" | jq '.domains | length')
    _app_names=$(echo "$_domains_json" | jq -r '.names | join(", ")')

    # Compute SNI hash for change detection
    _sni_hash=$(echo "$_domains_json" | jq -r '.domains | join(",")' | sha256sum | awk '{print $1}')

    # --- deny-cidrs: rebuild unconditionally on every successful sync ---
    _deny_cidrs_content=$(build_deny_cidrs "$_status")
    write_acl_file "$DENY_CIDRS_ACL" "$_deny_cidrs_content"

    # --- SNI ACLs: only update on hash change or first sync ---
    if [ "$_sni_hash" != "$_last_sni_hash" ]; then
        _split_output=$(split_domains "$_domains_json")
        _exact=$(echo "$_split_output" | sed -n '1,/^---$/p' | sed '/^---$/d')
        _wildcard=$(echo "$_split_output" | sed -n '/^---$/,$p' | sed '1d')

        _exact_count=$(echo "$_exact" | grep -c '.' 2>/dev/null || echo 0)
        _wildcard_count=$(echo "$_wildcard" | grep -c '.' 2>/dev/null || echo 0)

        # Write files atomically (empty content for 0 domains = legitimate revocation)
        write_acl_file "$EXACT_ACL" "$_exact"
        write_acl_file "$WILDCARD_ACL" "$_wildcard"

        # Push SNI ACLs + deny-cidrs to HAProxy runtime
        push_sni_acls_runtime "$_exact" "$_wildcard"
        push_deny_cidrs_runtime "$_deny_cidrs_content"

        _last_sni_hash="$_sni_hash"

        echo "    [sync] apps=[${_app_names}] tags=[$(echo "$_effective_tags" | tr '\n' ',' | sed 's/,$//')] domains=${_domain_count} (exact=${_exact_count} wildcard=${_wildcard_count}) CHANGED"
    else
        # SNI unchanged — only push deny-cidrs (rebuilt every sync for fresh Self.TailscaleIPs)
        # Do NOT touch SNI ACLs: push_single_acl does full replacement, empty args = wipe
        push_deny_cidrs_runtime "$_deny_cidrs_content"

        echo "    [sync] apps=[${_app_names}] domains=${_domain_count} unchanged"
    fi

    # Update heartbeat (only on successful parse)
    date +%s > "$HEARTBEAT"

    sleep "$POLICY_SYNC_INTERVAL"
done
