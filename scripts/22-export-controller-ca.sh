#!/usr/bin/env bash
# Run on the CONTROLLER machine when the daemon/agentgateway live on a
# different machine. Prints the controller's public device CA (not secret -
# it's the trust anchor devices use to verify the controller, no private key
# material) as a ready-to-paste block for the OTHER machine's terminal, plus
# an scp alternative if that machine has SSH reachability. Also prints the
# managed-programs selection (mode strings only, no API keys) so the other
# machine's agentgateway.yaml agrees with the daemon.yaml served from here.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

usage() {
  cat <<'EOF'
Usage: 22-export-controller-ca.sh

Run this on the controller machine after 20-controller-up.sh. Prints:
  1. A copy-paste block to run in a terminal on the OTHER (daemon/gateway)
     machine's field-kit checkout - writes state/keys/device-ca.pem there.
  2. An scp one-liner alternative, if that machine is SSH-reachable.
  3. A 15-managed-programs.sh command to run on the OTHER machine, carrying
     over this machine's MANAGED_PROGRAMS/CLAUDE_AUTH_MODE/CODEX_AUTH_MODE.
EOF
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

device_ca="${STATE_DIR}/keys/device-ca.pem"
[[ -f "${device_ca}" ]] || die "No device CA at ${device_ca}. Run 20-controller-up.sh on this (the controller) machine first."

load_env_file
controller_address="${CONTROLLER_PUBLIC_ADDRESS:-}"

echo
log_success "This is the controller's public trust root - safe to paste/copy anywhere, it's not a secret."
echo
echo "=== Option A: paste this block into a terminal on the OTHER machine ==="
echo "(run it from inside that machine's agentdesktop-field-kit checkout)"
echo
printf 'mkdir -p state/keys && cat > state/keys/device-ca.pem <<'"'"'EOF'"'"'\n'
cat "${device_ca}"
printf 'EOF\n'
echo
echo "=== Option B: scp, if the other machine is SSH-reachable from here ==="
if [[ -n "${controller_address}" ]]; then
  echo "  (run this FROM the other machine, replacing REMOTE_USER/REMOTE_HOST with"
  echo "   this controller machine's own SSH-reachable user/address)"
fi
echo "  scp REMOTE_USER@REMOTE_HOST:$(cd "$(dirname "${device_ca}")" && pwd)/device-ca.pem state/keys/device-ca.pem"
echo
echo "=== Managed programs: also run this on the OTHER machine ==="
if [[ -n "${MANAGED_PROGRAMS:-}" ]]; then
  carry_cmd="./scripts/15-managed-programs.sh --programs ${MANAGED_PROGRAMS}"
  if [[ ",${MANAGED_PROGRAMS}," == *,claude,* ]]; then
    [[ -n "${CLAUDE_AUTH_MODE:-}" ]] || die "claude is in MANAGED_PROGRAMS but CLAUDE_AUTH_MODE is unset in state/demo.env. Re-run 15-managed-programs.sh here first."
    carry_cmd+=" --claude-auth-mode ${CLAUDE_AUTH_MODE}"
  fi
  if [[ ",${MANAGED_PROGRAMS}," == *,codex,* ]]; then
    [[ -n "${CODEX_AUTH_MODE:-}" ]] || die "codex is in MANAGED_PROGRAMS but CODEX_AUTH_MODE is unset in state/demo.env. Re-run 15-managed-programs.sh here first."
    carry_cmd+=" --codex-auth-mode ${CODEX_AUTH_MODE}"
  fi
  echo "(from inside that machine's agentdesktop-field-kit checkout - writes the same selection to its state/demo.env)"
  echo
  echo "${carry_cmd}"
else
  log_warn "No managed programs selected on this machine yet - run the wizard's managed-programs step (or 15-managed-programs.sh) here first, then re-run this script."
fi
echo
reported_address="${controller_address:-<this controller machine address>}"
log_warn "After copying, on the other machine run 21-agentgateway-up.sh / 30-daemon-enroll.sh / 41-intune-push.sh with --controller-address ${reported_address} (or set CONTROLLER_PUBLIC_ADDRESS in its state/demo.env)."
