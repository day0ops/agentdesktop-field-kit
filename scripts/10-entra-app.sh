#!/usr/bin/env bash
# Creates or updates the single-tenant "agentdesktop enrollment" public-client
# app registration, matching exactly what AgentDesktop's production docs
# require: no client secret, PKCE-only public client, loopback redirect URI,
# and only the openid/profile/email/offline_access delegated scopes.
#
# Adapted from the vendored deploy/gcp/scripts/create-entra-app.sh helper
# (same GA `az ad` commands), trimmed of GCP-kit-specific legacy-name
# migration logic that doesn't apply to a fresh app registration.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

usage() {
  cat <<'EOF'
Usage: 10-entra-app.sh [--display-name NAME] [--dry-run]

Creates or updates the agentdesktop enrollment public-client app registration
and its Enterprise Application. Never creates a client secret. Does not
decide who may sign in - run 11-entra-consent.sh for admin consent and
pilot-user assignment.
EOF
}

display_name="agentdesktop enrollment"
redirect_uri="http://127.0.0.1:51327/callback"
# Microsoft Graph delegated scopes: openid, profile, email, offline_access.
required_resource_accesses='[{"resourceAppId":"00000003-0000-0000-c000-000000000000","resourceAccess":[{"id":"37f7f235-527c-4136-accd-4a02d197296e","type":"Scope"},{"id":"14dad69e-099b-42c9-810b-d002981feec1","type":"Scope"},{"id":"64a6cdd6-aab1-4aaf-94b8-3cc8405e90d0","type":"Scope"},{"id":"7427e0e9-2fba-42fe-b0c0-848c9e6a8182","type":"Scope"}]}]'

while (( $# > 0 )); do
  case "$1" in
    --display-name) display_name="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) log_error "Unknown argument: $1"; usage >&2; exit 2 ;;
  esac
done

if [[ "${DRY_RUN}" == "true" ]]; then
  cat <<EOF
[dry-run] az ad app create \\
  --display-name $(printf '%q' "${display_name}") \\
  --sign-in-audience AzureADMyOrg \\
  --is-fallback-public-client true \\
  --public-client-redirect-uris $(printf '%q' "${redirect_uri}") \\
  --required-resource-accesses '<Graph openid/profile/email/offline_access>' \\
  --enable-access-token-issuance false \\
  --enable-id-token-issuance false
[dry-run] az ad sp create --id <APPLICATION_CLIENT_ID>
[dry-run] az ad sp update --id <SP_ID> --set appRoleAssignmentRequired=true
EOF
  exit 0
fi

log_step "Checking Microsoft Graph access"
tenant_id="$(az account show --query tenantId --output tsv)"
az ad app list --all --output tsv --query '[0].appId' >/dev/null 2>&1 \
  || die "Graph calls are failing. Run: az login --tenant ${tenant_id} --allow-no-subscriptions --scope \"https://graph.microsoft.com//.default\""

log_step "Looking for an existing '${display_name}' app registration"
matches="$(az ad app list --display-name "${display_name}" --all --output json \
  | jq --arg name "${display_name}" '[.[] | select(.displayName == $name)]')"
match_count="$(jq 'length' <<<"${matches}")"

if (( match_count > 1 )); then
  die "More than one Entra application named '${display_name}'; refusing an ambiguous update. Resolve manually in the portal."
fi

if (( match_count == 0 )); then
  log_step "Creating app registration '${display_name}'"
  application="$(az ad app create \
    --display-name "${display_name}" \
    --sign-in-audience AzureADMyOrg \
    --is-fallback-public-client true \
    --public-client-redirect-uris "${redirect_uri}" \
    --required-resource-accesses "${required_resource_accesses}" \
    --enable-access-token-issuance false \
    --enable-id-token-issuance false \
    --output json)"
else
  log_step "Updating existing app registration '${display_name}'"
  app_id="$(jq -r '.[0].appId' <<<"${matches}")"
  az ad app update \
    --id "${app_id}" \
    --display-name "${display_name}" \
    --sign-in-audience AzureADMyOrg \
    --is-fallback-public-client true \
    --public-client-redirect-uris "${redirect_uri}" \
    --required-resource-accesses "${required_resource_accesses}" \
    --enable-access-token-issuance false \
    --enable-id-token-issuance false \
    --output none
  application="$(az ad app show --id "${app_id}" --output json)"
fi

app_id="$(jq -r .appId <<<"${application}")"
log_success "App registration ready: ${display_name} (${app_id})"

log_step "Ensuring an Enterprise Application (service principal) exists"
if ! service_principal="$(az ad sp show --id "${app_id}" --output json 2>/dev/null)"; then
  service_principal="$(az ad sp create --id "${app_id}" --output json)"
fi
sp_id="$(jq -r .id <<<"${service_principal}")"

log_step "Requiring explicit user/group assignment (Assignment required = Yes)"
az ad sp update --id "${sp_id}" --set appRoleAssignmentRequired=true --output none
log_success "Enterprise Application ${sp_id} now requires assignment"

log_step "Resolving canonical OIDC issuer"
discovery_url="https://login.microsoftonline.com/${tenant_id}/v2.0/.well-known/openid-configuration"
oidc_issuer="$(curl --fail --silent --show-error "${discovery_url}" | jq -er .issuer)"

env_file_set OIDC_ISSUER "${oidc_issuer}"
env_file_set OIDC_CLIENT_ID "${app_id}"
env_file_set ENTRA_SP_ID "${sp_id}"
env_file_set ENTRA_TENANT_ID "${tenant_id}"

echo
log_success "Entra app registration configured:"
cat <<EOF
  Display name:            ${display_name}
  Application (client) ID: ${app_id}
  Enterprise App object ID: ${sp_id}
  Redirect URI:            ${redirect_uri}
  Delegated scopes:        openid profile email offline_access
  Assignment required:     true
  OIDC issuer:             ${oidc_issuer}

Saved to $(dirname "${ENV_FILE}")/$(basename "${ENV_FILE}") as OIDC_ISSUER / OIDC_CLIENT_ID.

Next: 11-entra-consent.sh grants admin consent and assigns the pilot user.
Until then, sign-in attempts fail with "AgentDesktop needs permission that
only an administrator can grant."
EOF
