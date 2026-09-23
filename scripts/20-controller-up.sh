#!/usr/bin/env bash
# Runs the published agentdesktop-controller image locally via `docker run`
# (no Kubernetes/Postgres needed - SQLite, matching the project's own local
# quickstart pattern), configured with real Entra ID as the OIDC issuer in
# place of the bundled Dex used in examples/claude.
#
# Requires --network host support in Docker Desktop (macOS: Settings >
# Resources > Network > Enable host networking) because adminListen must
# bind to 127.0.0.1 inside the container, which is unreachable through
# normal `-p` port publishing.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

usage() {
  cat <<'EOF'
Usage: 20-controller-up.sh [--image-tag TAG] [--recreate] [--dry-run]

Renders controller.yaml/daemon.yaml from state/demo.env (OIDC_ISSUER,
OIDC_CLIENT_ID - written by 10-entra-app.sh), generates local dev TLS/CA/JWT
keys on first run, and starts the controller container.
EOF
}

image_repo="ghcr.io/agentdesktop-dev/agentdesktop-controller"
image_tag="v0.1.1"
container_name="agentdesktop-controller"
recreate=false

while (( $# > 0 )); do
  case "$1" in
    --image-tag) image_tag="$2"; shift 2 ;;
    --recreate) recreate=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) log_error "Unknown argument: $1"; usage >&2; exit 2 ;;
  esac
done

load_env_file
: "${OIDC_ISSUER:?Run 10-entra-app.sh first (missing OIDC_ISSUER in state/demo.env)}"
: "${OIDC_CLIENT_ID:?Run 10-entra-app.sh first (missing OIDC_CLIENT_ID in state/demo.env)}"

keys_dir="${STATE_DIR}/keys"
config_dir="${STATE_DIR}/config"
data_dir="${STATE_DIR}/data"

if [[ "${DRY_RUN}" == "true" ]]; then
  cat <<EOF
[dry-run] would generate dev keys in ${keys_dir} (if absent)
[dry-run] would render ${config_dir}/controller.yaml with:
            oidc.issuer:   ${OIDC_ISSUER}
            oidc.clientId: ${OIDC_CLIENT_ID}
[dry-run] docker run -d --name ${container_name} --network host \\
  -v ${config_dir}:/etc/agentdesktop/config:ro \\
  -v ${keys_dir}:/etc/agentdesktop/tls:ro \\
  -v ${data_dir}:/data \\
  --user 65532:65532 \\
  ${image_repo}:${image_tag} --config /etc/agentdesktop/config/controller.yaml
EOF
  exit 0
fi

log_step "Preparing local state directories"
mkdir -p "${keys_dir}" "${config_dir}" "${data_dir}"
chmod 700 "${keys_dir}"
chmod 777 "${data_dir}" # writable by the container's non-root uid regardless of host uid mapping

log_step "Generating local development keys (controller TLS, device CA, gateway JWT)"
key_files=(controller.pem controller-key.pem device-ca.pem device-ca-key.pem gateway-jwt-key.pem)
existing_keys=0
for f in "${key_files[@]}"; do [[ -e "${keys_dir}/${f}" ]] && existing_keys=$((existing_keys + 1)); done

if (( existing_keys == ${#key_files[@]} )); then
  log_success "Keys already present in ${keys_dir}, reusing"
elif (( existing_keys > 0 )); then
  die "${keys_dir} has an incomplete key set (${existing_keys}/${#key_files[@]} files). Remove it and re-run to regenerate."
else
  work_dir="$(mktemp -d)"
  trap 'rm -rf "${work_dir}"' EXIT

  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 \
    -out "${work_dir}/gateway-jwt-key.pem" 2>/dev/null

  cat > "${work_dir}/ca.cnf" <<'EOF'
[req]
distinguished_name = subject
x509_extensions = v3_ca
prompt = no
[subject]
CN = AgentDesktop-demo-device-CA
[v3_ca]
basicConstraints = critical,CA:TRUE
keyUsage = critical,keyCertSign,cRLSign
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always,issuer
EOF
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
    -keyout "${work_dir}/device-ca-key.pem" -out "${work_dir}/device-ca.pem" \
    -days 365 -sha256 -config "${work_dir}/ca.cnf"

  cat > "${work_dir}/controller.cnf" <<'EOF'
[req]
distinguished_name = subject
prompt = no
[subject]
CN = localhost
EOF
  cat > "${work_dir}/controller.ext" <<'EOF'
[v3_server]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = DNS:localhost,IP:127.0.0.1
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer
EOF
  openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
    -keyout "${work_dir}/controller-key.pem" -out "${work_dir}/controller.csr" \
    -config "${work_dir}/controller.cnf"
  openssl x509 -req -in "${work_dir}/controller.csr" \
    -CA "${work_dir}/device-ca.pem" -CAkey "${work_dir}/device-ca-key.pem" \
    -set_serial 1 -days 30 -sha256 \
    -extfile "${work_dir}/controller.ext" -extensions v3_server \
    -out "${work_dir}/controller.pem"

  install -m 600 "${work_dir}/controller-key.pem" "${work_dir}/device-ca-key.pem" "${work_dir}/gateway-jwt-key.pem" "${keys_dir}/"
  install -m 644 "${work_dir}/controller.pem" "${work_dir}/device-ca.pem" "${keys_dir}/"
  rm -rf "${work_dir}"
  trap - EXIT
  log_success "Generated dev keys in ${keys_dir}"
fi

log_step "Rendering controller.yaml and daemon.yaml"
cat > "${config_dir}/controller.yaml" <<EOF
fleetListen: 0.0.0.0:8443
adminListen: 127.0.0.1:8080
databaseUrl: sqlite:///data/agentdesktop-controller.db?mode=rwc
tls: /etc/agentdesktop/tls
allowInsecureDev: true

oidc:
  issuer: "${OIDC_ISSUER}"
  clientId: "${OIDC_CLIENT_ID}"
  redirectUri: http://127.0.0.1:51327/callback

gatewayJwt:
  privateKey: /etc/agentdesktop/tls/gateway-jwt-key.pem

daemonConfig:
  path: /etc/agentdesktop/config/daemon.yaml
EOF

cat > "${config_dir}/daemon.yaml" <<'EOF'
llmGateway:
  url: http://localhost:4000
  authentication:
    type: controllerJwt
    audience: "agentgateway"
    allowedClientIds: [claude-code, claude-desktop, codex, opencode]

telemetry:
  events:
  - session.new
  - tool.use

programs:
  claudeCode:
    companyAnnouncements: ["Managed by AgentDesktop (demo)"]
  claudeDesktop:
    isLocalDevMcpEnabled: true
EOF
log_success "Wrote ${config_dir}/controller.yaml and daemon.yaml"

require_cmd docker "brew install --cask docker"
docker_running || die "Docker daemon is not running. Start Docker Desktop and re-run. (Keys and config above are already prepared, so this is the only remaining blocker.)"

log_step "Checking Docker Desktop host networking"
if ! docker run --rm --network host alpine:3.20 true >/dev/null 2>&1; then
  cat >&2 <<'EOF'
Could not start a container with --network host. On macOS, enable it in
Docker Desktop: Settings > Resources > Network > "Enable host networking",
then Apply & Restart. This is required because the controller's admin UI
binds to 127.0.0.1 inside the container, which normal -p port publishing
cannot reach.
EOF
  exit 1
fi
log_success "Host networking works"

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
      log_step "Starting existing stopped container"
      docker start "${container_name}" >/dev/null
      log_success "Started ${container_name}"
      exit 0
    fi
  fi
fi

log_step "Pulling ${image_repo}:${image_tag}"
docker pull "${image_repo}:${image_tag}"

log_step "Starting controller container"
docker run -d \
  --name "${container_name}" \
  --network host \
  --restart unless-stopped \
  -v "${config_dir}:/etc/agentdesktop/config:ro" \
  -v "${keys_dir}:/etc/agentdesktop/tls:ro" \
  -v "${data_dir}:/data" \
  --user 65532:65532 \
  "${image_repo}:${image_tag}" \
  --config /etc/agentdesktop/config/controller.yaml >/dev/null

log_step "Waiting for the controller to become reachable"
ready=false
for _ in $(seq 1 30); do
  if curl --silent --output /dev/null --max-time 2 http://127.0.0.1:8080/ 2>/dev/null; then
    ready=true
    break
  fi
  sleep 1
done

if [[ "${ready}" != "true" ]]; then
  log_error "Controller did not become reachable on http://127.0.0.1:8080/ within 30s"
  log_error "Recent logs:"
  docker logs --tail 40 "${container_name}" >&2 || true
  die "Controller startup failed. Check the logs above (common causes: OIDC issuer unreachable, bad config)."
fi

log_success "Controller is up: fleet API on https://127.0.0.1:8443, admin UI on http://127.0.0.1:8080"
env_file_set CONTROLLER_ADMIN_URL "http://127.0.0.1:8080"
env_file_set CONTROLLER_FLEET_ADDRESS "https://127.0.0.1:8443"
env_file_set DEVICE_CA_PATH "${keys_dir}/device-ca.pem"
