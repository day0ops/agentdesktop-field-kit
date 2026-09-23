#!/usr/bin/env bash
# Creates (idempotently) a dedicated Entra ID pilot user for this demo and
# assigns it an Intune license. Never hardcodes a password: one is generated
# at runtime with openssl and printed once. It is never written to disk.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

usage() {
  cat <<'EOF'
Usage: 05-pilot-user.sh --upn USER_PRINCIPAL_NAME [--display-name NAME] [--usage-location CC] [--dry-run]

Creates a dedicated Entra ID user to use as the AgentDesktop demo pilot
identity, sets a randomly generated password (force-change at next sign-in),
and assigns it an available Intune license found in the tenant.
EOF
}

upn=""
display_name="AgentDesktop Pilot"
usage_location="US"
strip_dry_run_flag "$@"
set -- "${STRIPPED_ARGS[@]+"${STRIPPED_ARGS[@]}"}"

while (( $# > 0 )); do
  case "$1" in
    --upn) upn="$2"; shift 2 ;;
    --display-name) display_name="$2"; shift 2 ;;
    --usage-location) usage_location="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) log_error "Unknown argument: $1"; usage >&2; exit 2 ;;
  esac
done

[[ -n "${upn}" ]] || { usage >&2; die "--upn is required"; }

random_chars() {
  local charset=$1 count=$2 pool=""
  while (( ${#pool} < count )); do
    pool+="$(openssl rand -base64 64 | tr -dc "${charset}" || true)"
  done
  printf '%s' "${pool:0:count}"
}

generate_password() {
  local symbols='!@#%^*?-_'
  local lower upper digit symbol idx
  lower="$(random_chars 'a-z' 16)"
  upper="$(random_chars 'A-Z' 4)"
  digit="$(random_chars '0-9' 4)"
  idx=$(( RANDOM % ${#symbols} ))
  symbol="${symbols:idx:1}"
  printf '%s%s%s%s\n' "${lower}" "${upper}" "${digit}" "${symbol}"
}

log_step "Looking for an active Intune SKU in this tenant"
skus_json="$(az rest --method GET \
  --url 'https://graph.microsoft.com/v1.0/subscribedSkus?$select=skuId,skuPartNumber,capabilityStatus,servicePlans' \
  --output json)"
sku_id="$(jq -r '
  [.value[] | select(
    .capabilityStatus == "Enabled" and
    any(.servicePlans[]?; (.servicePlanName | ascii_upcase | contains("INTUNE")) and .provisioningStatus == "Success")
  )] | first | .skuId // empty
' <<<"${skus_json}")"
sku_part="$(jq -r --arg id "${sku_id}" '[.value[] | select(.skuId == $id)] | first | .skuPartNumber // empty' <<<"${skus_json}")"
[[ -n "${sku_id}" ]] || die "No active Intune SKU found. Run 00-preflight.sh for remediation."
log_success "Will license with SKU ${sku_part} (${sku_id})"

if [[ "${DRY_RUN}" == "true" ]]; then
  cat <<EOF
[dry-run] az ad user create --display-name $(printf '%q' "${display_name}") \\
  --user-principal-name $(printf '%q' "${upn}") \\
  --password '<generated-at-runtime, not shown in dry-run>' \\
  --force-change-password-next-sign-in true
[dry-run] az rest --method PATCH --url https://graph.microsoft.com/v1.0/users/<id> --body '{"usageLocation":"${usage_location}"}'
[dry-run] az rest --method POST --url https://graph.microsoft.com/v1.0/users/<id>/assignLicense --body '{"addLicenses":[{"disabledPlans":[],"skuId":"${sku_id}"}],"removeLicenses":[]}'
EOF
  exit 0
fi

log_step "Checking whether ${upn} already exists"
existing_user="$(az ad user show --id "${upn}" --output json 2>/dev/null || true)"

if [[ -n "${existing_user}" ]]; then
  user_id="$(jq -r .id <<<"${existing_user}")"
  log_success "User already exists (object id ${user_id}); skipping creation and password generation"
else
  log_step "Creating pilot user ${upn}"
  password="$(generate_password)"
  created_user="$(az ad user create \
    --display-name "${display_name}" \
    --user-principal-name "${upn}" \
    --password "${password}" \
    --force-change-password-next-sign-in true \
    --output json)"
  user_id="$(jq -r .id <<<"${created_user}")"
  echo
  log_warn "One-time password below. It is NOT stored anywhere by this kit. Capture it now:"
  printf '\n    %s\n\n' "${password}" >&2
  unset password created_user
  log_success "Created user ${upn} (object id ${user_id})"
fi

log_step "Setting usage location (required before Intune license assignment)"
az rest --method PATCH \
  --url "https://graph.microsoft.com/v1.0/users/${user_id}" \
  --body "$(jq -n --arg loc "${usage_location}" '{usageLocation:$loc}')" \
  --output none
log_success "usageLocation=${usage_location}"

log_step "Checking current license assignment"
current_skus="$(az rest --method GET \
  --url "https://graph.microsoft.com/v1.0/users/${user_id}?\$select=assignedLicenses" \
  --output json | jq -r '[.assignedLicenses[].skuId] | join(",")')"

if [[ ",${current_skus}," == *",${sku_id},"* ]]; then
  log_success "Intune license already assigned"
else
  az rest --method POST \
    --url "https://graph.microsoft.com/v1.0/users/${user_id}/assignLicense" \
    --body "$(jq -n --arg sku "${sku_id}" '{addLicenses:[{disabledPlans:[],skuId:$sku}],removeLicenses:[]}')" \
    --output none
  log_success "Assigned Intune license (${sku_part})"
fi

env_file_set PILOT_UPN "${upn}"
env_file_set PILOT_USER_ID "${user_id}"
env_file_set INTUNE_SKU_ID "${sku_id}"

echo
log_success "Pilot user ready: ${upn} (${user_id})"
[[ -n "${existing_user}" ]] || log_warn "Remember: the password was only shown once above. If lost, reset it with: az ad user update --id ${upn} --password '<new>' --force-change-password-next-sign-in true"
