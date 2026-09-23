#!/usr/bin/env bash
# Starts agentgateway so Claude Code traffic actually flows through the
# managed path during the demo. Requires ANTHROPIC_API_KEY in the
# environment - never hardcoded here.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

usage() {
  cat <<'EOF'
Usage: ANTHROPIC_API_KEY=sk-ant-... 21-agentgateway-up.sh [--image-tag TAG] [--recreate] [--dry-run]

Starts the agentgateway container (host networking, port 4000) configured to
validate controller-issued JWTs against http://127.0.0.1:8080/.well-known/jwks.json
and forward to Anthropic using ANTHROPIC_API_KEY. Run 20-controller-up.sh first.
EOF
}

image="cr.agentgateway.dev/agentgateway:v1.4.1"
container_name="agentdesktop-agentgateway"
recreate=false

while (( $# > 0 )); do
  case "$1" in
    --image-tag) image="cr.agentgateway.dev/agentgateway:$2"; shift 2 ;;
    --recreate) recreate=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) log_error "Unknown argument: $1"; usage >&2; exit 2 ;;
  esac
done

config_dir="${STATE_DIR}/config"

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

require_cmd docker "brew install --cask docker"
docker_running || die "Docker daemon is not running. Start Docker Desktop and re-run."

mkdir -p "${config_dir}"
cat > "${config_dir}/agentgateway.yaml" <<'EOF'
# yaml-language-server: $schema=https://agentgateway.dev/schema/config
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
      jwks:
        url: http://127.0.0.1:8080/.well-known/jwks.json
  models:
  - name: "*"
    provider: anthropic
    params:
      apiKey: $ANTHROPIC_API_KEY
EOF
log_success "Wrote ${config_dir}/agentgateway.yaml"

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
