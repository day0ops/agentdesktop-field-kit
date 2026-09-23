#!/usr/bin/env bash
# Tears down the local demo footprint. By default this only touches local
# Docker containers and the local daemon/LaunchDaemon - it leaves Entra ID
# and Intune objects in place so you can resume the same demo tomorrow.
# Pass --include-cloud to also delete the Entra/Intune objects this kit
# created, and --wipe-state to also delete generated local keys/config.
# Destructive steps always ask for confirmation unless --yes is given.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

usage() {
  cat <<'EOF'
Usage: 90-teardown.sh [--include-cloud] [--wipe-state] [--yes]

  --include-cloud  Also delete the Entra app registrations, pilot user,
                    Intune groups, and Intune shell script this kit created.
  --wipe-state      Also delete state/ (generated keys, config, demo.env).
  --yes             Don't prompt before destructive actions.
EOF
}

include_cloud=false
wipe_state=false
ASSUME_YES=false

while (( $# > 0 )); do
  case "$1" in
    --include-cloud) include_cloud=true; shift ;;
    --wipe-state) wipe_state=true; shift ;;
    --yes) ASSUME_YES=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) log_error "Unknown argument: $1"; usage >&2; exit 2 ;;
  esac
done
export ASSUME_YES

load_env_file

log_step "Stopping local Docker containers"
if docker_running 2>/dev/null; then
  for name in agentdesktop-agentgateway agentdesktop-controller; do
    if docker ps -a --filter "name=^${name}\$" --format '{{.Names}}' | grep -q "${name}"; then
      docker rm -f "${name}" >/dev/null && log_success "Removed container ${name}"
    else
      log_info "Container ${name} not present"
    fi
  done
else
  log_warn "Docker daemon not running; skipping container cleanup"
fi

log_step "Offboarding the local daemon (if installed via Intune push or manual enrollment)"
plist_path="/Library/LaunchDaemons/dev.agentdesktop.daemon.plist"
if launchctl print system/dev.agentdesktop.daemon >/dev/null 2>&1; then
  sudo launchctl bootout system/dev.agentdesktop.daemon 2>/dev/null || true
  log_success "Unloaded LaunchDaemon"
fi
if [[ -f "${plist_path}" ]]; then
  sudo rm -f "${plist_path}"
  log_success "Removed ${plist_path}"
fi
if [[ -x /usr/local/bin/agentdesktop ]]; then
  if confirm "Remove /usr/local/bin/agentdesktop and /etc/agentdesktop?"; then
    sudo rm -f /usr/local/bin/agentdesktop
    sudo rm -rf /etc/agentdesktop
    log_success "Removed installed binary and config"
  fi
fi
if dscl . -read /Groups/agentdesktop >/dev/null 2>&1; then
  if confirm "Remove the local 'agentdesktop' system group?"; then
    sudo dseditgroup -o delete agentdesktop 2>/dev/null || true
    log_success "Removed agentdesktop group"
  fi
fi
log_info "If a manual 'sudo agentdesktop daemon ...' is running in another terminal, Ctrl-C it there."

if [[ "${include_cloud}" == "true" ]]; then
  log_step "Cloud teardown (Entra ID / Intune)"
  if confirm "This deletes the Entra app registrations, pilot user, and Intune group/script created by this kit. Continue?"; then
    if [[ -n "${INTUNE_PILOT_GROUP_ID:-}" ]]; then
      if GRAPH_BEARER_TOKEN="$(bash "${FIELD_KIT_ROOT}/lib/get-graph-app-token.sh" 2>/dev/null)"; then
        script_match="$(curl --silent --fail \
          --header "Authorization: Bearer ${GRAPH_BEARER_TOKEN}" \
          "https://graph.microsoft.com/beta/deviceManagement/deviceShellScripts?\$select=id,displayName" \
          | jq -r '.value[] | select(.displayName == "agentdesktop bootstrap") | .id' | head -1)"
        if [[ -n "${script_match}" ]]; then
          curl --silent --fail --request DELETE \
            --header "Authorization: Bearer ${GRAPH_BEARER_TOKEN}" \
            "https://graph.microsoft.com/beta/deviceManagement/deviceShellScripts/${script_match}" \
            && log_success "Deleted Intune shell script ${script_match}"
        fi
      fi
      az ad group delete --group "${INTUNE_PILOT_GROUP_ID}" 2>/dev/null \
        && log_success "Deleted group ${INTUNE_PILOT_GROUP_NAME:-${INTUNE_PILOT_GROUP_ID}}"
    fi
    if [[ -n "${PILOT_UPN:-}" ]]; then
      az ad user delete --id "${PILOT_UPN}" 2>/dev/null && log_success "Deleted pilot user ${PILOT_UPN}"
    fi
    if [[ -n "${OIDC_CLIENT_ID:-}" ]]; then
      az ad app delete --id "${OIDC_CLIENT_ID}" 2>/dev/null && log_success "Deleted app registration ${OIDC_CLIENT_ID}"
    fi
    automation_app_id="$(az ad app list --display-name "agentdesktop field-kit automation" --all --query '[0].appId' --output tsv 2>/dev/null)"
    if [[ -n "${automation_app_id}" ]]; then
      az ad app delete --id "${automation_app_id}" 2>/dev/null && log_success "Deleted automation app ${automation_app_id}"
    fi
  else
    log_info "Skipped cloud teardown"
  fi
fi

if [[ "${wipe_state}" == "true" ]]; then
  if confirm "Delete ${STATE_DIR} (generated keys, config, demo.env)?"; then
    rm -rf "${STATE_DIR}"
    log_success "Removed ${STATE_DIR}"
  fi
fi

echo
log_success "Teardown complete."
