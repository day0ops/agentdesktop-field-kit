#!/usr/bin/env bash
# Starts agentgateway so Claude Code/Codex traffic actually flows through the
# managed path during the demo. API keys (only needed for programs in api-key
# mode) come from the environment - never hardcoded here.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

usage() {
  cat <<'EOF'
Usage: 21-agentgateway-up.sh [--controller-address ADDR] [--image-tag TAG] [--recreate] [--dry-run]

Starts the agentgateway container (host networking, port 4000) configured to
validate controller-issued JWTs, apply a per-user request rate limit and token
budget, and forward each managed program's traffic upstream. Which programs
and auth modes are configured comes from state/demo.env (MANAGED_PROGRAMS,
CLAUDE_AUTH_MODE, CODEX_AUTH_MODE - see 15-managed-programs.sh):
  claude, api-key:      Anthropic API using ANTHROPIC_API_KEY (must be set)
  claude, subscription: the user's Claude subscription credential
  codex, api-key:       OpenAI API using OPENAI_API_KEY (must be set)
  codex, subscription:  the user's ChatGPT credential (Codex backend)
Run 20-controller-up.sh first.

--controller-address is only needed when the controller runs on a DIFFERENT
machine (defaults to state/demo.env's CONTROLLER_PUBLIC_ADDRESS, then
127.0.0.1). When set, the JWKS fetch targets the controller's fleet endpoint
(:8443, HTTPS) instead of the loopback-only admin UI, and requires a local
copy of the controller's device-ca.pem (see scripts/22-export-controller-ca.sh
on the controller machine) to trust that connection.
EOF
}

image="cr.agentgateway.dev/agentgateway:v1.6.0"
container_name="agentdesktop-agentgateway"
recreate=false
controller_address=""

while (( $# > 0 )); do
  case "$1" in
    --controller-address) controller_address="$2"; shift 2 ;;
    --image-tag) image="cr.agentgateway.dev/agentgateway:$2"; shift 2 ;;
    --recreate) recreate=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) log_error "Unknown argument: $1"; usage >&2; exit 2 ;;
  esac
done

load_env_file
controller_address="${controller_address:-${CONTROLLER_PUBLIC_ADDRESS:-127.0.0.1}}"
config_dir="${STATE_DIR}/config"
keys_dir="${STATE_DIR}/keys"

# Selection and modes are read from persisted state, never re-derived from
# which API keys happen to be set here: in the two-machine topology they were
# resolved on the controller machine, and the daemon.yaml it serves must agree
# with this gateway config. An empty *_mode means that program isn't selected.
require_valid_auth_mode() {
  local program=$1 mode_var=$2
  local mode="${!mode_var:-}"
  [[ "${mode}" == "subscription" || "${mode}" == "api-key" ]] \
    || die "${program} is in MANAGED_PROGRAMS but ${mode_var}='${mode}' in state/demo.env is not 'subscription' or 'api-key'. Re-run 15-managed-programs.sh."
}
claude_mode=""
codex_mode=""
if [[ ",${MANAGED_PROGRAMS:-}," == *,claude,* ]]; then
  require_valid_auth_mode claude CLAUDE_AUTH_MODE
  claude_mode="${CLAUDE_AUTH_MODE}"
fi
if [[ ",${MANAGED_PROGRAMS:-}," == *,codex,* ]]; then
  require_valid_auth_mode codex CODEX_AUTH_MODE
  codex_mode="${CODEX_AUTH_MODE}"
fi
[[ -n "${claude_mode}" || -n "${codex_mode}" ]] \
  || die "No managed programs selected (MANAGED_PROGRAMS='${MANAGED_PROGRAMS:-}' in state/demo.env). Run 15-managed-programs.sh first."

# Only the keys an api-key-mode program actually uses are passed to the container.
key_env_names=()
if [[ "${claude_mode}" == "api-key" ]]; then key_env_names+=(ANTHROPIC_API_KEY); fi
if [[ "${codex_mode}" == "api-key" ]]; then key_env_names+=(OPENAI_API_KEY); fi

if [[ "${DRY_RUN}" == "true" ]]; then
  printf '[dry-run] would render %s/agentgateway.yaml for: claude=%s codex=%s\n' \
    "${config_dir}" "${claude_mode:-not selected}" "${codex_mode:-not selected}"
  printf '[dry-run] docker run -d --name %s --network host \\\n' "${container_name}"
  for name in "${key_env_names[@]+"${key_env_names[@]}"}"; do
    printf '  -e %s=<from environment, not shown> \\\n' "${name}"
  done
  printf '  -v %s/agentgateway.yaml:/etc/agentgateway/config.yaml:ro \\\n' "${config_dir}"
  printf '  %s -f /etc/agentgateway/config.yaml\n' "${image}"
  exit 0
fi

if [[ "${claude_mode}" == "api-key" ]]; then
  : "${ANTHROPIC_API_KEY:?Claude is in api-key mode: set ANTHROPIC_API_KEY in your environment before running this script}"
fi
if [[ "${codex_mode}" == "api-key" ]]; then
  : "${OPENAI_API_KEY:?Codex is in api-key mode: set OPENAI_API_KEY in your environment before running this script}"
fi
key_env_args=()
for name in "${key_env_names[@]+"${key_env_names[@]}"}"; do
  key_env_args+=(-e "${name}")
done

ca_mount_args=()
if [[ "${controller_address}" == "127.0.0.1" || "${controller_address}" == "localhost" ]]; then
  jwks_block="      jwks:
        url: http://127.0.0.1:8080/.well-known/jwks.json"
else
  # agentgateway's jwtAuth/LocalJwtConfig schema (v1.4.1, unchanged in v1.6.0)
  # has additionalProperties:false and its jwks field only accepts
  # {url|file|inline} - no CA/insecure option
  # anywhere in it, and the sibling `backendTLS` policy (which does have one)
  # isn't a recognized field inside llm.policies either (both confirmed by
  # hitting the actual schema validator, not guessed). So instead of having
  # agentgateway fetch JWKS itself over HTTPS (which needs TLS trust we can't
  # configure), we fetch it once ourselves - using the CA trust we already
  # know works - and hand it a local file. JWKS is public key material, not
  # secret, so this is a fine trade: a point-in-time snapshot instead of a
  # live fetch, refreshed by just re-running this script.
  device_ca="${keys_dir}/device-ca.pem"
  [[ -f "${device_ca}" ]] || die "No local copy of the controller's device-ca.pem at ${device_ca}. Copy it from the controller machine first (see scripts/22-export-controller-ca.sh there) before running this with --controller-address."
  jwks_path="${config_dir}/controller-jwks.json"
  curl --fail --silent --show-error --cacert "${device_ca}" \
    "https://${controller_address}:8443/.well-known/jwks.json" --output "${jwks_path}" \
    || die "Could not fetch JWKS from https://${controller_address}:8443/.well-known/jwks.json - is the controller running and reachable?"
  jq -e '.keys | length > 0' "${jwks_path}" >/dev/null \
    || die "Fetched JWKS from the controller but it has no keys - check the controller's gatewayJwt config"
  jwks_block="      jwks:
        file: /etc/agentgateway/controller-jwks.json"
  ca_mount_args=(-v "${jwks_path}:/etc/agentgateway/controller-jwks.json:ro")
  log_success "Fetched controller JWKS to ${jwks_path} (mounted as a local file - sidesteps agentgateway having no CA-trust option for a live HTTPS fetch)"
fi

# The daemon has a single llmGateway.url, so both programs share this one
# listener. A lone program keeps the catch-all "*"; with both, each program's
# models are told apart by vendor prefix instead.
claude_model='"*"'
codex_model='"*"'
if [[ -n "${claude_mode}" && -n "${codex_mode}" ]]; then
  claude_model='"claude-*"'
  codex_model='"gpt-*"'
fi

models_block=""
case "${claude_mode}" in
  api-key) models_block+="  - name: ${claude_model}
    provider: anthropic
    params:
      apiKey: \$ANTHROPIC_API_KEY
" ;;
  subscription) models_block+="  - name: ${claude_model}
    provider: anthropic
" ;;
esac
case "${codex_mode}" in
  api-key) models_block+="  - name: ${codex_model}
    provider: openai
    params:
      apiKey: \$OPENAI_API_KEY
" ;;
  subscription) models_block+="  - name: ${codex_model}
    provider: openai
    params:
      baseUrl: https://chatgpt.com/backend-api/codex
" ;;
esac

# Subscription mode: the daemon's credential helper sends a composite bearer,
# "agentdesktop:<provider-token>:<controller-jwt>" for Claude, plus
# ":<chatgpt-account-id>" for Codex. jwtAuth validates the embedded controller
# JWT (a plain JWT bearer from an api-key-mode program still validates as-is),
# then a transformation restores the provider token upstream. Each rule matches
# its program's exact composite shape, so it never touches the other program's
# traffic or a plain JWT.
jwt_location_block=""
transformation_rules=""
if [[ "${claude_mode}" == "subscription" ]]; then
  transformation_rules+='      - condition: |
          request.headers["authorization"].matches("^Bearer agentdesktop:[^: ]+:[^: ]+$")
        request:
          set:
            authorization: |
              "Bearer " + request.headers["authorization"].split(" ")[1].split(":")[1]
'
fi
# Codex uses `replace` because both headers derive from the original
# authorization value, which a `set` of authorization would overwrite before
# chatgpt-account-id is computed.
if [[ "${codex_mode}" == "subscription" ]]; then
  transformation_rules+='      - condition: |
          request.headers["authorization"].matches("^Bearer agentdesktop:[^: ]+:[^: ]+:[^: ]+$")
        request:
          replace: |
            request.headers["authorization"].split(" ")[1].split(":").with(parts,
              request.headers.merge({
                "authorization": "Bearer " + parts[1],
                "chatgpt-account-id": parts[3]
              }))
'
fi
transformations_block=""
if [[ -n "${transformation_rules}" ]]; then
  jwt_location_block='      location:
        expression: |
          request.headers["authorization"].split(" ")[1].with(credential,
            credential.split(":").with(parts,
              parts[0] == "agentdesktop" ? parts[2] : credential
            )
          )
'
  transformations_block="    transformations:
      conditional:
${transformation_rules}"
fi

# Per-user limits are keyed on jwt.email, which the controller copies from the
# IdP's email claim. A token without it falls into one bucket shared by all
# such users rather than being rejected.
mkdir -p "${config_dir}"
cat > "${config_dir}/agentgateway.yaml" <<EOF
# yaml-language-server: \$schema=https://agentgateway.dev/schema/config
frontendPolicies:
  logging:
    add:
      llm.client: jwt.client_id
      user: jwt.email
gateways:
  gateway:
    port: 4000
routes:
- name: claude-desktop-reachability
  gateways: gateway
  matches:
  - method: HEAD
    path:
      exact: /
  policies:
    directResponse:
      status: 200
llm:
  gateways: gateway
  policies:
    jwtAuth:
      mode: strict
${jwt_location_block}      issuer: agentdesktop-controller
      audiences: [agentgateway]
${jwks_block}
${transformations_block}    localRateLimit:
    - type: requests
      maxTokens: 20
      tokensPerFill: 20
      fillInterval: 60s
      key: jwt.email
    - type: tokens
      maxTokens: 50000
      tokensPerFill: 50000
      fillInterval: 1h
      key: jwt.email
  models:
${models_block%$'\n'}
EOF
log_success "Wrote ${config_dir}/agentgateway.yaml (claude=${claude_mode:-not selected}, codex=${codex_mode:-not selected}, JWKS target: ${controller_address})"

require_cmd docker "brew install --cask docker"
docker_running || die "Docker daemon is not running. Start Docker Desktop and re-run. (Config above is already prepared, so this is the only remaining blocker.)"

existing_container="$(docker ps -a --filter "name=^${container_name}\$" --format '{{.Names}}' || true)"
if [[ -n "${existing_container}" ]]; then
  if [[ "${recreate}" == "true" ]]; then
    log_step "Removing existing container (--recreate)"
    docker rm -f "${container_name}" >/dev/null
  else
    running="$(docker ps --filter "name=^${container_name}\$" --format '{{.Names}}' || true)"
    if [[ -n "${running}" ]]; then
      log_success "Container ${container_name} already running; leaving it as-is (use --recreate to force)"
      exit 0
    else
      docker start "${container_name}" >/dev/null
      log_success "Started ${container_name}"
      exit 0
    fi
  fi
fi

log_step "Pulling ${image}"
docker pull "${image}"

log_step "Starting agentgateway"
docker run -d \
  --name "${container_name}" \
  --network host \
  --restart unless-stopped \
  "${key_env_args[@]+"${key_env_args[@]}"}" \
  -v "${config_dir}/agentgateway.yaml:/etc/agentgateway/config.yaml:ro" \
  "${ca_mount_args[@]+"${ca_mount_args[@]}"}" \
  "${image}" -f /etc/agentgateway/config.yaml >/dev/null

log_step "Waiting for agentgateway to answer its reachability route"
ready=false
for _ in $(seq 1 20); do
  if curl --silent --fail --head --max-time 2 http://127.0.0.1:4000/ >/dev/null 2>&1; then
    ready=true
    break
  fi
  sleep 1
done

if [[ "${ready}" != "true" ]]; then
  log_error "agentgateway did not answer http://127.0.0.1:4000/ within 20s"
  docker logs --tail 40 "${container_name}" >&2 || true
  die "agentgateway startup failed. Common cause on macOS: host networking not enabled in Docker Desktop (Settings > Resources > Network)."
fi

log_success "agentgateway is up on http://127.0.0.1:4000"
