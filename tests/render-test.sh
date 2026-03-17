#!/bin/sh
# tests/render-test.sh — Config render regression tests
#
# Tests the validation logic in config-render/render.sh against a matrix of
# valid and invalid env combinations. Config validators (haproxy -c,
# dnsmasq --test, unbound-checkconf) are run against a golden dual-stack render.
#
# Usage:
#   bash tests/render-test.sh
#
# Requires locally built images:
#   docker build -t appc-config-render ./config-render
#   docker build -t appc-dns-steer    ./dns-steer
#   docker build -t appc-dns-upstream ./dns-upstream
#
# Override the render image: RENDER_IMAGE=my-tag bash tests/render-test.sh

set -e

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMPLATES_DIR="${REPO_ROOT}/templates"
RENDER_IMAGE="${RENDER_IMAGE:-appc-config-render}"

_pass=0
_fail=0
_tmpdirs=""

_cleanup() {
    # shellcheck disable=SC2086
    [ -n "${_tmpdirs}" ] && rm -rf ${_tmpdirs}
}
trap _cleanup EXIT

# ----------------------------------------------------------------
# _run_case NAME EXPECT [KEY=VALUE ...]
#   EXPECT: "pass" (exit 0) or "fail" (non-zero exit)
#   Remaining args are written to an env file, one per line.
# ----------------------------------------------------------------
_run_case() {
    _name="$1"
    _expect="$2"
    shift 2

    _tmpdir="$(mktemp -d)"
    _tmpdirs="${_tmpdirs} ${_tmpdir}"
    _config="${_tmpdir}/config"
    _run_appc="${_tmpdir}/run-appc"
    _env_file="${_tmpdir}/test.env"
    mkdir -p "${_config}" "${_run_appc}"

    # Write env file — one KEY=VALUE per line.
    # Values with spaces (e.g. whitespace test) are preserved correctly by
    # docker --env-file, which reads the file literally without word-splitting.
    : > "${_env_file}"
    for _kv; do
        printf '%s\n' "${_kv}" >> "${_env_file}"
    done

    set +e
    docker run --rm \
        --env-file "${_env_file}" \
        -v "${TEMPLATES_DIR}:/templates:ro" \
        -v "${_config}:/config" \
        -v "${_run_appc}:/run/appc" \
        "${RENDER_IMAGE}" > /dev/null 2>&1
    _rc=$?
    set -e

    if [ "${_expect}" = "pass" ] && [ "${_rc}" -ne 0 ]; then
        printf 'FAIL  %s (expected exit 0, got %d)\n' "${_name}" "${_rc}"
        _fail=$((_fail + 1))
    elif [ "${_expect}" = "fail" ] && [ "${_rc}" -eq 0 ]; then
        printf 'FAIL  %s (expected non-zero exit, got 0)\n' "${_name}"
        _fail=$((_fail + 1))
    else
        printf 'ok    %s\n' "${_name}"
        _pass=$((_pass + 1))
    fi
}

# ----------------------------------------------------------------
# Pass cases
# ----------------------------------------------------------------
printf '==> Render pass cases\n'
_run_case "ipv4-only"      pass "INGRESS_IP=10.99.0.1/32"
_run_case "ipv6-only"      pass "INGRESS_IP=2001:db8::1/128"
_run_case "dual-stack"     pass "INGRESS_IP=10.99.0.1/32,2001:db8::1/128"
_run_case "multi-v4"       pass "INGRESS_IP=10.99.0.1/32,10.99.0.2/32"
_run_case "open-mode"      pass "INGRESS_IP=10.99.0.1/32" "SKIP_SNI_ENFORCEMENT=1"
_run_case "egress-ipv6"    pass "INGRESS_IP=10.99.0.1/32" "EGRESS_ACCEPT_FAMILY=ipv6" "EGRESS_PREFER_FAMILY=ipv6"
_run_case "egress-dual-none" pass "INGRESS_IP=10.99.0.1/32" "EGRESS_ACCEPT_FAMILY=dual" "EGRESS_PREFER_FAMILY=none"

# ----------------------------------------------------------------
# Fail cases — expect non-zero exit from render.sh
# ----------------------------------------------------------------
printf '\n==> Render fail cases\n'

# Whitespace in INGRESS_IP — the real operator typo (comma-space separator)
_run_case "whitespace"          fail "INGRESS_IP=10.99.0.1/32, 2001:db8::1/128"
_run_case "trailing-comma"      fail "INGRESS_IP=10.99.0.1/32,"
_run_case "leading-comma"       fail "INGRESS_IP=,10.99.0.1/32"
_run_case "double-comma"        fail "INGRESS_IP=10.99.0.1/32,,2001:db8::1/128"
_run_case "slash24"             fail "INGRESS_IP=10.99.0.0/24"
_run_case "slash64"             fail "INGRESS_IP=2001:db8::/64"
_run_case "ipv6-as-v4"          fail "INGRESS_IP=2001:db8::1/32"
_run_case "dotted-as-v6"        fail "INGRESS_IP=10.99.0.1/128"
_run_case "egress-v4-pref-v6"   fail "INGRESS_IP=10.99.0.1/32" "EGRESS_ACCEPT_FAMILY=ipv4" "EGRESS_PREFER_FAMILY=ipv6"
_run_case "egress-v6-pref-v4"   fail "INGRESS_IP=10.99.0.1/32" "EGRESS_ACCEPT_FAMILY=ipv6" "EGRESS_PREFER_FAMILY=ipv4"
_run_case "egress-none-non-dual" fail "INGRESS_IP=10.99.0.1/32" "EGRESS_ACCEPT_FAMILY=ipv4" "EGRESS_PREFER_FAMILY=none"
_run_case "missing-ingress"     fail

# ----------------------------------------------------------------
# Config validation — golden dual-stack render
# All ACL files are created by render.sh itself; no manual setup needed.
# ----------------------------------------------------------------
printf '\n==> Config validation (golden dual-stack render)\n'

_golden="$(mktemp -d)"
_tmpdirs="${_tmpdirs} ${_golden}"
_golden_config="${_golden}/config"
_golden_run_appc="${_golden}/run-appc"
_golden_env="${_golden}/test.env"
mkdir -p "${_golden_config}" "${_golden_run_appc}"

printf 'INGRESS_IP=10.99.0.1/32,2001:db8::1/128\n' > "${_golden_env}"

docker run --rm \
    --env-file "${_golden_env}" \
    -v "${TEMPLATES_DIR}:/templates:ro" \
    -v "${_golden_config}:/config" \
    -v "${_golden_run_appc}:/run/appc" \
    "${RENDER_IMAGE}" > /dev/null 2>&1

# haproxy -c (uses external pinned image for exact version match)
set +e
docker run --rm \
    -v "${_golden_config}:/config:ro" \
    -v "${_golden_run_appc}:/run/appc:ro" \
    haproxy:3.2.14-alpine haproxy -c -f /config/haproxy.cfg > /dev/null 2>&1
_rc=$?
set -e
if [ "${_rc}" -eq 0 ]; then
    printf 'ok    haproxy -c\n'
    _pass=$((_pass + 1))
else
    printf 'FAIL  haproxy -c (exit %d)\n' "${_rc}"
    _fail=$((_fail + 1))
fi

# dnsmasq --test
set +e
docker run --rm \
    -v "${_golden_config}:/config:ro" \
    appc-dns-steer dnsmasq --test -C /config/dnsmasq-steer.conf > /dev/null 2>&1
_rc=$?
set -e
if [ "${_rc}" -eq 0 ]; then
    printf 'ok    dnsmasq --test\n'
    _pass=$((_pass + 1))
else
    printf 'FAIL  dnsmasq --test (exit %d)\n' "${_rc}"
    _fail=$((_fail + 1))
fi

# unbound-checkconf
set +e
docker run --rm \
    -v "${_golden_config}:/config:ro" \
    appc-dns-upstream unbound-checkconf /config/unbound.conf > /dev/null 2>&1
_rc=$?
set -e
if [ "${_rc}" -eq 0 ]; then
    printf 'ok    unbound-checkconf\n'
    _pass=$((_pass + 1))
else
    printf 'FAIL  unbound-checkconf (exit %d)\n' "${_rc}"
    _fail=$((_fail + 1))
fi

# ----------------------------------------------------------------
# Summary
# ----------------------------------------------------------------
printf '\n==> Results: %d passed, %d failed\n' "${_pass}" "${_fail}"
[ "${_fail}" -eq 0 ]
