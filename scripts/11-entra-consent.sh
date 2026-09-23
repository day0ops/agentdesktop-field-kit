#!/usr/bin/env bash
# Grants tenant-wide admin consent for the agentdesktop enrollment app's
# delegated scopes, then assigns the pilot user to its Enterprise
# Application so they can actually sign in (Assignment required = Yes was
# set by 10-entra-app.sh, which makes this step mandatory).
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

usage() {
  cat <<'EOF'
Usage: 11-entra-consent.sh [--app-id ID] [--pilot-upn UPN] [--dry-run]

Defaults come from state/demo.env (written by 10-entra-app.sh and
05-pilot-user.sh) when the flags are omitted.
EOF
}

app_id=""
pilot_upn=""
while (( $# > 0 )); do
  case "$1" in
    --app-id) app_id="$2"; shift 2 ;;
    --pilot-upn) pilot_upn="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) log_error "Unknown argument: $1"; usage >&2; exit 2 ;;
  esac
done

load_env_file
app_id="${app_id:-${OIDC_CLIENT_ID:-}}"
pilot_upn="${pilot_upn:-${PILOT_UPN:-}}"

[[ -n "${app_id}" ]] || die "No app id given and none found in state. Run 10-entra-app.sh first, or pass --app-id."
[[ -n "${pilot_upn}" ]] || die "No pilot UPN given and none found in state. Run 05-pilot-user.sh first, or pass --pilot-upn."

if [[ "${DRY_RUN}" == "true" ]]; then
  cat <<EOF
[dry-run] az ad app permission admin-consent --id ${app_id}
[dry-run] az rest --method POST \\
  --url https://graph.microsoft.com/v1.0/servicePrincipals/<sp-id>/appRoleAssignedTo \\
  --body '{"principalId":"<pilot-user-id>","resourceId":"<sp-id>","appRoleId":"00000000-0000-0000-0000-000000000000"}'
EOF
  exit 0
fi

log_step "Resolving service principal and pilot user object IDs"
sp_id="${ENTRA_SP_ID:-}"
if [[ -z "${sp_id}" ]]; then
  sp_id="$(az ad sp show --id "${app_id}" --query id --output tsv)"
fi
user_id="$(az ad user show --id "${pilot_upn}" --query id --output tsv)" \
  || die "Could not resolve pilot user ${pilot_upn}. Run 05-pilot-user.sh first."
log_success "Enterprise App ${sp_id}, pilot user ${user_id}"

log_step "Granting tenant-wide admin consent for openid/profile/email/offline_access"
if consent_err="$(az ad app permission admin-consent --id "${app_id}" 2>&1)"; then
  log_success "Admin consent granted"
else
  if grep -qi 'already' <<<"${consent_err}"; then
    log_success "Admin consent already granted"
  else
    log_error "${consent_err}"
    die "Admin consent failed. You must be signed in as a Global Administrator or Privileged Role Administrator."
  fi
fi

log_step "Checking existing Enterprise Application assignments"
assignments="$(az rest --method GET \
  --url "https://graph.microsoft.com/v1.0/servicePrincipals/${sp_id}/appRoleAssignedTo" \
  --output json)"
already_assigned_count="$(jq --arg pid "${user_id}" '[.value[] | select(.principalId == $pid)] | length' <<<"${assignments}")"

if (( already_assigned_count > 0 )); then
  log_success "${pilot_upn} is already assigned to the Enterprise Application"
else
  az rest --method POST \
    --url "https://graph.microsoft.com/v1.0/servicePrincipals/${sp_id}/appRoleAssignedTo" \
    --body "$(jq -n --arg pid "${user_id}" --arg rid "${sp_id}" \
      '{principalId:$pid, resourceId:$rid, appRoleId:"00000000-0000-0000-0000-000000000000"}')" \
    --output none
  log_success "Assigned ${pilot_upn} to the Enterprise Application"
fi

echo
log_success "Entra ID sign-in is fully configured. ${pilot_upn} can now complete the OIDC enrollment flow."
log_warn "If sign-in still fails with AADSTS50105, double check the assignment above landed on the correct Enterprise App object (${sp_id}), not the app registration object."
