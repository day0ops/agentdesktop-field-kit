#!/usr/bin/env bash
# Vendored from agentdesktop's downloadable GCP deployment kit
# (deploy/gcp/scripts/upsert-intune-bootstrap.sh), with one addition: az
# CLI's own app can never hold DeviceManagementScripts.ReadWrite.All (Azure
# blocks first-party apps from ad hoc delegated-scope grants - AADSTS65002),
# so the deviceShellScripts calls themselves need a different credential.
# If GRAPH_BEARER_TOKEN is set (see lib/get-graph-app-token.sh), those calls
# use it via curl instead of `az rest`. The tenant-licensing check still
# uses the caller's own az session, which works fine for a plain read.
set -euo pipefail

graph_call() {
  # graph_call METHOD URL [BODY]
  local method=$1 url=$2 body=${3:-}
  if [[ -n "${GRAPH_BEARER_TOKEN:-}" ]]; then
    local args=(--silent --show-error --fail --request "${method}" \
      --header "Authorization: Bearer ${GRAPH_BEARER_TOKEN}" \
      --header "Content-Type: application/json")
    [[ -n "${body}" ]] && args+=(--data "${body}")
    curl "${args[@]}" "${url}"
  else
    local args=(--method "${method}" --output json)
    [[ -n "${body}" ]] && args+=(--body "${body}")
    az rest "${args[@]}" --url "${url}"
  fi
}

display_name="agentdesktop bootstrap"
dry_run=false

usage() {
  cat <<'EOF'
Usage: upsert-intune-script.sh SCRIPT_FILE GROUP_ID [--display-name NAME] [--dry-run]

Creates or updates an Intune macOS shell script through Microsoft Graph beta and
assigns it to exactly one Microsoft Entra group.

GROUP_ID is the Object ID of the Intune deployment security group, not the
Application (client) ID or Enterprise Application object ID.

The Azure CLI session needs the admin-consented delegated Microsoft Graph
permission DeviceManagementScripts.ReadWrite.All and an active Intune license.
EOF
}

if (( $# < 2 )); then
  usage >&2
  exit 2
fi

script_file="$1"
group_id="$2"
shift 2

while (( $# > 0 )); do
  case "$1" in
    --display-name)
      if (( $# < 2 )); then
        printf '%s requires a value.\n' "$1" >&2
        exit 2
      fi
      display_name="$2"
      shift 2
      ;;
    --dry-run)
      dry_run=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'Unknown argument: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

for command_name in az base64 jq; do
  if ! command -v "${command_name}" >/dev/null 2>&1; then
    printf '%s is required.\n' "${command_name}" >&2
    exit 1
  fi
done

if [[ ! -s "${script_file}" ]]; then
  printf 'Script does not exist or is empty: %s\n' "${script_file}" >&2
  exit 1
fi
if (( $(wc -c <"${script_file}") >= 1048576 )); then
  printf 'Intune macOS shell scripts must be smaller than 1 MB.\n' >&2
  exit 1
fi
if ! head -n 1 "${script_file}" | grep -q '^#!'; then
  printf 'Intune script must start with a shebang.\n' >&2
  exit 1
fi
if [[ ! "${group_id}" =~ ^[0-9a-fA-F-]{36}$ ]]; then
  printf 'GROUP_ID must be the Object ID of a Microsoft Entra security group.\n' >&2
  exit 1
fi

script_content="$(base64 <"${script_file}" | tr -d '\r\n')"
script_body="$(jq -n \
  --arg displayName "${display_name}" \
  --arg description "Installs the agentdesktop daemon and writes its controller bootstrap and public trust root." \
  --arg scriptContent "${script_content}" \
  --arg fileName "$(basename "${script_file}")" \
  '{
    "@odata.type": "#microsoft.graph.deviceShellScript",
    executionFrequency: "P1D",
    retryCount: 3,
    blockExecutionNotifications: true,
    displayName: $displayName,
    description: $description,
    scriptContent: $scriptContent,
    runAsAccount: "system",
    fileName: $fileName
  }')"
assignment_body="$(jq -n \
  --arg groupId "${group_id}" \
  '{
    deviceManagementScriptGroupAssignments: [{
      "@odata.type": "#microsoft.graph.deviceManagementScriptGroupAssignment",
      targetGroupId: $groupId
    }],
    deviceManagementScriptAssignments: []
  }')"

if [[ "${dry_run}" == "true" ]]; then
  jq -n \
    --arg endpoint "https://graph.microsoft.com/beta/deviceManagement/deviceShellScripts" \
    --arg displayName "${display_name}" \
    --arg groupId "${group_id}" \
    --arg fileName "$(basename "${script_file}")" \
    --argjson scriptBytes "$(wc -c <"${script_file}")" \
    '{endpoint:$endpoint,displayName:$displayName,groupId:$groupId,fileName:$fileName,scriptBytes:$scriptBytes,executionFrequency:"P1D",retryCount:3,runAsAccount:"system"}'
  exit 0
fi

graph_base="https://graph.microsoft.com/beta"
if ! subscribed_skus="$(az rest \
  --method GET \
  --url 'https://graph.microsoft.com/v1.0/subscribedSkus?$select=skuPartNumber,capabilityStatus,servicePlans' \
  --output json 2>/dev/null)"; then
  printf 'Azure CLI could not read tenant subscriptions from Microsoft Graph. Reauthenticate to the target tenant.\n' >&2
  exit 1
fi
if ! jq -e '
  any(.value[];
    .capabilityStatus == "Enabled" and
    any(.servicePlans[];
      (.servicePlanName | ascii_upcase | contains("INTUNE")) and
      .provisioningStatus == "Success"
    )
  )
' <<<"${subscribed_skus}" >/dev/null; then
  cat >&2 <<'EOF'
This Microsoft Entra tenant has no active Microsoft Intune service plan. The
Intune Graph API returns "Request not applicable to target tenant" until you add
an Intune Plan 1 license or trial, initialize the Intune MDM authority, and
license the enrolling user or device.
EOF
  exit 1
fi

graph_error="$(mktemp)"
trap 'rm -f "${graph_error}"' EXIT
if ! scripts="$(graph_call GET "${graph_base}/deviceManagement/deviceShellScripts?\$select=id,displayName" 2>"${graph_error}")"; then
  cat "${graph_error}" >&2
  if grep -qi 'Request not applicable to target tenant' "${graph_error}"; then
    cat >&2 <<'EOF'
The tenant has an Intune service plan, but Intune is not ready for API access.
Open https://intune.microsoft.com, set the MDM authority to Microsoft Intune,
and wait for tenant provisioning to finish before retrying.
EOF
  elif grep -Eqi '403|Forbidden|Authorization_RequestDenied|Insufficient privileges' "${graph_error}"; then
    cat >&2 <<'EOF'
Azure CLI could not access Intune through Microsoft Graph. Sign in to the target
tenant with an administrator identity and obtain admin consent for the delegated
permission DeviceManagementScripts.ReadWrite.All, then retry.
EOF
  else
    cat >&2 <<'EOF'
Azure CLI could not access the Intune deviceShellScript API. Verify tenant
provisioning, the Intune Administrator role, and the admin-consented delegated
permission DeviceManagementScripts.ReadWrite.All. This script uses Graph beta
because the macOS deviceShellScript API is not available in v1.0.
EOF
  fi
  exit 1
fi

matches="$(jq --arg name "${display_name}" '[.value[] | select(.displayName == $name)]' <<<"${scripts}")"
match_count="$(jq 'length' <<<"${matches}")"

if (( match_count > 1 )); then
  printf 'More than one Intune shell script has display name %q; refusing an ambiguous update.\n' "${display_name}" >&2
  exit 1
fi

if (( match_count == 0 )); then
  created="$(graph_call POST "${graph_base}/deviceManagement/deviceShellScripts" "${script_body}")"
  script_id="$(jq -er .id <<<"${created}")"
else
  script_id="$(jq -r '.[0].id' <<<"${matches}")"
  graph_call PATCH "${graph_base}/deviceManagement/deviceShellScripts/${script_id}" "${script_body}" >/dev/null
fi

# The assign action replaces this script's assignment set; this command owns it.
graph_call POST "${graph_base}/deviceManagement/deviceShellScripts/${script_id}/assign" "${assignment_body}" >/dev/null

printf 'Created or updated Intune macOS shell script %s and assigned group %s.\n' \
  "${script_id}" "${group_id}"
