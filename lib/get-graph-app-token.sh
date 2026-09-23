#!/usr/bin/env bash
# Mints an app-only (client credentials) Microsoft Graph access token scoped
# to DeviceManagementScripts.ReadWrite.All.
#
# Why this exists: az CLI's own application (04b07795-8ddb-461a-bbee-...) is
# a Microsoft first-party app, and Microsoft blocks first-party apps from
# being granted new delegated Graph permissions ad hoc (AADSTS65002 -
# "must be configured via preauthorization"). That makes `az rest` calls to
# Intune's deviceShellScripts endpoint fail with 403 Forbidden even for a
# Global Administrator's session. The fix is to call that endpoint as a
# DIFFERENT, tenant-owned app registration holding the equivalent
# *application* permission instead, which we can self-consent normally.
#
# Idempotent: reuses the app registration/role assignment if already set up.
# The client secret is generated fresh every run and never written to disk -
# it is exchanged for a token in-process and then discarded.
#
# Prints ONLY the access token to stdout. All logging goes to stderr, so
# this is safe to call as: token="$(get-graph-app-token.sh)"
set -euo pipefail

display_name="agentdesktop field-kit automation"
graph_resource_app_id="00000003-0000-0000-c000-000000000000"
permission_value="DeviceManagementScripts.ReadWrite.All"

log() { printf '[get-graph-app-token] %s\n' "$*" >&2; }

for c in az jq curl; do
  command -v "${c}" >/dev/null 2>&1 || { echo "${c} is required" >&2; exit 1; }
done

tenant_id="$(az account show --query tenantId --output tsv)"

log "Resolving Microsoft Graph service principal and app role id"
graph_sp_id="$(az ad sp show --id "${graph_resource_app_id}" --query id --output tsv)"
role_id="$(az ad sp show --id "${graph_resource_app_id}" \
  --query "appRoles[?value=='${permission_value}'].id | [0]" --output tsv)"
[[ -n "${role_id}" && "${role_id}" != "None" ]] || { echo "Could not resolve app role id for ${permission_value}" >&2; exit 1; }

log "Looking for existing '${display_name}' app registration"
matches="$(az ad app list --display-name "${display_name}" --all --output json \
  | jq --arg name "${display_name}" '[.[] | select(.displayName == $name)]')"
match_count="$(jq 'length' <<<"${matches}")"
(( match_count <= 1 )) || { echo "More than one app named '${display_name}'; refusing an ambiguous update." >&2; exit 1; }

required_resource_accesses="$(jq -n --arg rid "${role_id}" --arg app "${graph_resource_app_id}" \
  '[{resourceAppId:$app, resourceAccess:[{id:$rid, type:"Role"}]}]')"

if (( match_count == 0 )); then
  log "Creating app registration '${display_name}'"
  app="$(az ad app create \
    --display-name "${display_name}" \
    --sign-in-audience AzureADMyOrg \
    --required-resource-accesses "${required_resource_accesses}" \
    --output json)"
else
  app_id="$(jq -r '.[0].appId' <<<"${matches}")"
  az ad app update --id "${app_id}" --required-resource-accesses "${required_resource_accesses}" --output none
  app="$(az ad app show --id "${app_id}" --output json)"
fi
app_id="$(jq -r .appId <<<"${app}")"

if ! sp="$(az ad sp show --id "${app_id}" --output json 2>/dev/null)"; then
  log "Creating service principal for ${app_id}"
  sp="$(az ad sp create --id "${app_id}" --output json)"
fi
sp_id="$(jq -r .id <<<"${sp}")"

log "Checking application-permission grant"
existing_assignment="$(az rest --method GET \
  --url "https://graph.microsoft.com/v1.0/servicePrincipals/${sp_id}/appRoleAssignments" \
  --output json | jq --arg rid "${role_id}" '[.value[] | select(.appRoleId == $rid)] | length')"

if (( existing_assignment == 0 )); then
  log "Granting ${permission_value} application permission (admin consent)"
  az rest --method POST \
    --url "https://graph.microsoft.com/v1.0/servicePrincipals/${sp_id}/appRoleAssignments" \
    --body "$(jq -n --arg pid "${sp_id}" --arg rid "${graph_sp_id}" --arg role "${role_id}" \
      '{principalId:$pid, resourceId:$rid, appRoleId:$role}')" \
    --output none
else
  log "Application permission already granted"
fi

log "Generating a short-lived client secret (not persisted to disk)"
secret="$(az ad app credential reset --id "${app_id}" --append --years 1 --query password --output tsv)"

log "Requesting app-only access token (retrying briefly for directory propagation)"
access_token=""
for attempt in 1 2 3 4 5 6; do
  http_status="$(curl --silent --output /tmp/.agentdesktop-token-response.$$ --write-out '%{http_code}' \
    --data-urlencode "grant_type=client_credentials" \
    --data-urlencode "client_id=${app_id}" \
    --data-urlencode "client_secret=${secret}" \
    --data-urlencode "scope=https://graph.microsoft.com/.default" \
    "https://login.microsoftonline.com/${tenant_id}/oauth2/v2.0/token")"
  token_response="$(cat /tmp/.agentdesktop-token-response.$$)"
  rm -f /tmp/.agentdesktop-token-response.$$
  if [[ "${http_status}" == "200" ]]; then
    access_token="$(jq -er .access_token <<<"${token_response}")"
    break
  fi
  error_desc="$(jq -r '.error_description // .error // "unknown error"' <<<"${token_response}" 2>/dev/null | head -1)"
  log "Attempt ${attempt}/6 got HTTP ${http_status}: ${error_desc}"
  sleep $((attempt * 5))
done
unset secret
[[ -n "${access_token}" ]] || { log "Failed to acquire a token after retries."; exit 1; }

# Best-effort: drop the credential we just minted once we no longer need it.
# Not fatal if this fails (e.g. transient network blip) - a stray secret on
# a disposable demo app registration is low risk, but no reason to leave it.
az ad app credential list --id "${app_id}" --query '[].keyId' --output tsv 2>/dev/null \
  | while read -r key_id; do
      az ad app credential delete --id "${app_id}" --key-id "${key_id}" >/dev/null 2>&1 || true
    done || true

printf '%s\n' "${access_token}"
