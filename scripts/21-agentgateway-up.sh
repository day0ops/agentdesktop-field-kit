#!/usr/bin/env bash
# Starts agentgateway so Claude Code traffic actually flows through the
# managed path during the demo. Requires ANTHROPIC_API_KEY in the
# environment - never hardcoded here.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

usage() {
  cat <<'EOF'
Usage: ANTHROPIC_API_KEY=sk-ant-... 21-agentgateway-up.sh [--controller-address ADDR] [--image-tag TAG] [--recreate] [--dry-run]

Starts the agentgateway container (host networking, port 4000) configured to
validate controller-issued JWTs and forward to Anthropic using
ANTHROPIC_API_KEY. Run 20-controller-up.sh first.

--controller-address is only needed when the controller runs on a DIFFERENT
machine (defaults to state/demo.env's CONTROLLER_PUBLIC_ADDRESS, then
127.0.0.1). When set, the JWKS fetch targets the controller's fleet endpoint
(:8443, HTTPS) instead of the loopback-only admin UI, and requires a local
copy of the controller's device-ca.pem (see scripts/22-export-controller-ca.sh
on the controller machine) to trust that connection.
EOF
}

image="cr.agentgateway.dev/agentgateway:v1.4.1"
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

if [[ "${DRY_RUN}" == "true" ]]; then
  cat <<EOF
[dry-run] would render ${config_dir}/agentgateway.yaml
[dry-run] docker run -d --name ${container_name} --network host \\
  -e ANTHROPIC_API_KEY=<from environment, not shown> \\
  -v ${config_dir}/agentgateway.yaml:/etc/agentgateway/config.yaml:ro \\
  ${image} -f /etc/agentgateway/config.yaml
EOF
  exit 0
fi

: "${ANTHROPIC_API_KEY:?Set ANTHROPIC_API_KEY in your environment before running this script}"

ca_mount_args=()
if [[ "${controller_address}" == "127.0.0.1" || "${controller_address}" == "localhost" ]]; then
  jwks_block="      jwks:
        url: http://127.0.0.1:8080/.well-known/jwks.json"
else
  # v1.4.1's jwtAuth/LocalJwtConfig schema has additionalProperties:false and
  # its jwks field only accepts {url|file|inline} - no CA/insecure option
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
  log_success "Fetched controller JWKS to ${jwks_path} (mounted as a local file - sidesteps agentgateway v1.4.1 having no CA-trust option for a live HTTPS fetch)"
fi

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
      issuer: agentdesktop-controller
      audiences: [agentgateway]
${jwks_block}
  models:
  - name: "*"
    provider: anthropic
    params:
      apiKey: \$ANTHROPIC_API_KEY
EOF
log_success "Wrote ${config_dir}/agentgateway.yaml (JWKS target: ${controller_address})"

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
  -e ANTHROPIC_API_KEY \
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
