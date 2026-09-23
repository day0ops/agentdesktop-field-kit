#!/usr/bin/env bash
# Runs through the checks recommended by AgentDesktop's "validate a pilot
# endpoint" guidance, adapted for this local demo. Unlike the setup scripts,
# this one does NOT abort on the first failure - it runs every check and
# reports a pass/fail/skip summary at the end, since its job is diagnosis.
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
set +e # this script intentionally continues past failed checks
trap - ERR # common.sh's generic ERR trap is noisy here; we report our own pass/fail

load_env_file

pass=0 fail=0 skip=0
check_start() { log_step "$*"; }
check_pass() { log_success "$*"; pass=$((pass + 1)); }
check_fail() { log_error "$*"; fail=$((fail + 1)); }
check_skip() { log_warn "SKIP: $*"; skip=$((skip + 1)); }

check_start "Entra ID configuration (state/demo.env)"
if [[ -n "${OIDC_ISSUER:-}" && -n "${OIDC_CLIENT_ID:-}" ]]; then
  check_pass "App registration configured: ${OIDC_CLIENT_ID} @ ${OIDC_ISSUER}"
else
  check_fail "Missing OIDC_ISSUER/OIDC_CLIENT_ID. Run 10-entra-app.sh."
fi
if [[ -n "${PILOT_UPN:-}" ]]; then
  check_pass "Pilot user recorded: ${PILOT_UPN}"
else
  check_fail "No pilot user recorded. Run 05-pilot-user.sh."
fi
if [[ -n "${INTUNE_PILOT_GROUP_ID:-}" ]]; then
  check_pass "Intune pilot group recorded: ${INTUNE_PILOT_GROUP_NAME:-} (${INTUNE_PILOT_GROUP_ID})"
else
  check_skip "No Intune pilot group recorded yet (40-intune-groups.sh not run)"
fi

check_start "Docker containers"
if docker_running; then
  for name in agentdesktop-controller agentdesktop-agentgateway; do
    state="$(docker inspect --format '{{.State.Status}}' "${name}" 2>/dev/null)"
    if [[ "${state}" == "running" ]]; then
      check_pass "${name} is running"
    elif [[ -n "${state}" ]]; then
      check_fail "${name} exists but is '${state}' (docker logs ${name})"
    else
      check_skip "${name} not created yet"
    fi
  done
else
  check_fail "Docker daemon is not running"
fi

check_start "Controller fleet API TLS (127.0.0.1:8443)"
device_ca="${STATE_DIR}/keys/device-ca.pem"
if [[ -f "${device_ca}" ]]; then
  if openssl s_client -connect 127.0.0.1:8443 -servername localhost \
      -CAfile "${device_ca}" -verify_hostname localhost -verify_return_error -alpn h2 \
      </dev/null >/tmp/.agentdesktop-tls-check.$$ 2>&1; then
    if grep -q 'ALPN protocol.*h2' /tmp/.agentdesktop-tls-check.$$; then
      check_pass "TLS handshake verified, ALPN h2 negotiated"
    else
      check_fail "TLS handshake succeeded but ALPN h2 was not negotiated"
    fi
  else
    check_fail "TLS handshake/verification failed (see openssl output)"
    tail -5 /tmp/.agentdesktop-tls-check.$$ >&2
  fi
  rm -f /tmp/.agentdesktop-tls-check.$$
else
  check_skip "No device CA at ${device_ca} (run 20-controller-up.sh)"
fi

check_start "Controller admin UI (127.0.0.1:8080)"
if curl --silent --output /dev/null --max-time 3 http://127.0.0.1:8080/; then
  check_pass "Admin UI is reachable"
else
  check_fail "Admin UI not reachable on http://127.0.0.1:8080/"
fi

check_start "Gateway JWKS endpoint"
jwks="$(curl --silent --max-time 3 --fail http://127.0.0.1:8080/.well-known/jwks.json 2>/dev/null)"
if [[ -n "${jwks}" ]] && jq -e '.keys | length > 0' <<<"${jwks}" >/dev/null 2>&1; then
  check_pass "JWKS published with at least one key"
else
  check_fail "JWKS endpoint not reachable or empty"
fi

check_start "agentgateway reachability (127.0.0.1:4000)"
if curl --silent --fail --head --max-time 3 http://127.0.0.1:4000/ >/dev/null 2>&1; then
  check_pass "agentgateway is reachable"
else
  check_skip "agentgateway not reachable (expected if you skipped 21-agentgateway-up.sh)"
fi

check_start "Local daemon"
if command -v agentdesktop >/dev/null 2>&1; then
  if status_output="$(agentdesktop status 2>&1)"; then
    check_pass "agentdesktop status: ${status_output}"
  else
    check_fail "agentdesktop is installed but 'status' failed: ${status_output}"
  fi
else
  check_skip "agentdesktop binary not on PATH (run 30-daemon-enroll.sh, or it's Intune-managed only)"
fi

if launchctl print system/dev.agentdesktop.daemon >/dev/null 2>&1; then
  check_pass "LaunchDaemon dev.agentdesktop.daemon is loaded"
else
  check_skip "LaunchDaemon dev.agentdesktop.daemon not loaded (expected before Intune sync completes)"
fi

echo
log_step "Summary"
printf '  %s%d passed%s, %s%d failed%s, %d skipped\n' \
  "${_C_GREEN}" "${pass}" "${_C_RESET}" \
  "${_C_RED}" "${fail}" "${_C_RESET}" \
  "${skip}"

(( fail == 0 ))
