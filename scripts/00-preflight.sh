#!/usr/bin/env bash
# Verifies the local machine and Azure CLI session are ready before any other
# script in this kit runs. Safe to re-run any time; makes no changes.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

log_step "Checking host platform"
require_macos
arch="$(mac_arch)"
log_success "macOS on ${arch}"

log_step "Checking required commands"
failures=0
check() {
  local cmd=$1 hint=$2
  if command -v "${cmd}" >/dev/null 2>&1; then
    log_success "${cmd} found ($(command -v "${cmd}"))"
  else
    log_error "${cmd} missing. Install with: ${hint}"
    failures=$((failures + 1))
  fi
}
check docker  "brew install --cask docker (then launch Docker Desktop once)"
check az      "brew install azure-cli"
check jq      "brew install jq"
check curl    "brew install curl (usually preinstalled on macOS)"
check openssl "brew install openssl@3"
check base64  "part of macOS coreutils, should always be present"

if (( failures > 0 )); then
  die "${failures} required command(s) missing. Install them and re-run."
fi

log_step "Checking Docker daemon"
if docker_running; then
  log_success "Docker daemon is running"
else
  die "Docker daemon is not running. Start Docker Desktop, wait for it to say 'Running', then re-run this script."
fi

log_step "Checking Azure CLI authentication"
tenant_id="$(az account show --query tenantId --output tsv 2>/dev/null || true)"
if [[ -z "${tenant_id}" ]]; then
  die "az is not logged in. Run: az login --tenant <TENANT_ID_OR_DOMAIN> --allow-no-subscriptions --scope \"https://graph.microsoft.com//.default\""
fi
log_success "az is authenticated (tenant ${tenant_id})"

log_step "Checking Microsoft Graph access (this is the part that needs MFA, not ARM)"
if az ad app list --all --output tsv --query '[0].appId' >/dev/null 2>&1; then
  log_success "Microsoft Graph calls work in this session"
else
  cat >&2 <<EOF

Graph calls are failing. This is almost always Conditional Access demanding
MFA specifically for Graph, even though ARM login succeeded. Fix with:

  az login --tenant ${tenant_id} --allow-no-subscriptions --scope "https://graph.microsoft.com//.default"

Then re-run this script.
EOF
  exit 1
fi

log_step "Checking tenant Intune licensing"
skus_json="$(az rest --method GET \
  --url 'https://graph.microsoft.com/v1.0/subscribedSkus?$select=skuPartNumber,capabilityStatus,prepaidUnits,servicePlans' \
  --output json 2>&1)" || die "Could not read subscribedSkus from Graph: ${skus_json}"

if jq -e '
  any(.value[]?;
    .capabilityStatus == "Enabled" and
    any(.servicePlans[]?;
      (.servicePlanName | ascii_upcase | contains("INTUNE")) and
      .provisioningStatus == "Success"
    )
  )
' <<<"${skus_json}" >/dev/null 2>&1; then
  log_success "An active Intune service plan is present in this tenant"
else
  cat >&2 <<'EOF'

No active Intune service plan found in this tenant. Either:
  - Activate a Microsoft Intune Plan 1 (Managed, not Device) trial or license
    in https://admin.microsoft.com, or
  - Use a Microsoft 365 Developer Program sandbox tenant (already has Intune
    licensed, no payment method needed): https://developer.microsoft.com/microsoft-365/dev-program

Then re-run this script.
EOF
  exit 1
fi

echo
log_success "All preflight checks passed. Safe to continue with 05-pilot-user.sh."
