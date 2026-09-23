#!/usr/bin/env bash
# Creates (idempotently) the Entra security group used to target the Intune
# macOS shell script at the pilot device, and adds the pilot user to it.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

usage() {
  cat <<'EOF'
Usage: 40-intune-groups.sh [--group-name NAME] [--pilot-upn UPN] [--dry-run]

Defaults come from state/demo.env when flags are omitted.
EOF
}

group_name="AgentDesktop-Pilot-macOS"
pilot_upn=""

while (( $# > 0 )); do
  case "$1" in
    --group-name) group_name="$2"; shift 2 ;;
    --pilot-upn) pilot_upn="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) log_error "Unknown argument: $1"; usage >&2; exit 2 ;;
  esac
done

load_env_file
pilot_upn="${pilot_upn:-${PILOT_UPN:-}}"
[[ -n "${pilot_upn}" ]] || die "No pilot UPN given and none found in state. Run 05-pilot-user.sh first, or pass --pilot-upn."

mail_nickname="$(tr '[:upper:]' '[:lower:]' <<<"${group_name}")"

if [[ "${DRY_RUN}" == "true" ]]; then
  cat <<EOF
[dry-run] az ad group create --display-name ${group_name} --mail-nickname ${mail_nickname}
[dry-run] az ad group member add --group <group-id> --member-id <pilot-user-id>
EOF
  exit 0
fi

log_step "Checking whether group '${group_name}' already exists"
existing_group="$(az ad group show --group "${group_name}" --output json 2>/dev/null || true)"

if [[ -n "${existing_group}" ]]; then
  group_id="$(jq -r .id <<<"${existing_group}")"
  log_success "Group already exists (${group_id})"
else
  log_step "Creating group '${group_name}'"
  created_group="$(az ad group create --display-name "${group_name}" --mail-nickname "${mail_nickname}" --output json)"
  group_id="$(jq -r .id <<<"${created_group}")"
  log_success "Created group ${group_name} (${group_id})"
fi

log_step "Resolving pilot user object id"
user_id="$(az ad user show --id "${pilot_upn}" --query id --output tsv)" \
  || die "Could not resolve pilot user ${pilot_upn}. Run 05-pilot-user.sh first."

log_step "Checking group membership"
is_member="$(az ad group member check --group "${group_id}" --member-id "${user_id}" --query value --output tsv)"
if [[ "${is_member}" == "true" ]]; then
  log_success "${pilot_upn} is already a member"
else
  az ad group member add --group "${group_id}" --member-id "${user_id}"
  log_success "Added ${pilot_upn} to ${group_name}"
fi

env_file_set INTUNE_PILOT_GROUP_ID "${group_id}"
env_file_set INTUNE_PILOT_GROUP_NAME "${group_name}"

echo
log_success "Intune pilot group ready: ${group_name} (${group_id})"
