#!/usr/bin/env bash
# Downloads and verifies the released agentdesktop macOS binary, installs it,
# and writes the daemon's local bootstrap config pointing at the demo
# controller. Enrollment itself is an interactive OIDC browser flow that
# needs sudo and a real terminal/browser, so this script prepares everything
# and prints the exact command for you to run yourself rather than trying to
# drive it non-interactively.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

usage() {
  cat <<'EOF'
Usage: 30-daemon-enroll.sh [--version vX.Y.Z] [--dry-run]

Defaults to the latest GitHub release. Installs to /usr/local/bin/agentdesktop
(requires sudo). Writes the bootstrap config to state/config/daemon-bootstrap.yaml.
EOF
}

version=""
repo="agentdesktop-dev/agentdesktop"
install_path="/usr/local/bin/agentdesktop"

while (( $# > 0 )); do
  case "$1" in
    --version) version="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) log_error "Unknown argument: $1"; usage >&2; exit 2 ;;
  esac
done

require_macos
require_cmd curl
require_cmd shasum
require_cmd jq

arch="$(mac_arch)"
asset_name="agentdesktop-darwin-${arch}"

log_step "Resolving release"
if [[ -n "${version}" ]]; then
  release_url="https://api.github.com/repos/${repo}/releases/tags/${version}"
else
  release_url="https://api.github.com/repos/${repo}/releases/latest"
fi
release_json="$(curl --fail --silent --show-error "${release_url}")" \
  || die "Could not fetch release metadata from ${release_url}"
resolved_version="$(jq -r .tag_name <<<"${release_json}")"
bin_url="$(jq -r --arg n "${asset_name}" '.assets[] | select(.name == $n) | .browser_download_url' <<<"${release_json}")"
sha_url="$(jq -r --arg n "${asset_name}.sha256" '.assets[] | select(.name == $n) | .browser_download_url' <<<"${release_json}")"
[[ -n "${bin_url}" && -n "${sha_url}" ]] || die "Could not find ${asset_name} in release ${resolved_version} assets"
log_success "Resolved ${resolved_version} for ${asset_name}"

controller_ca="${STATE_DIR}/keys/device-ca.pem"
bootstrap_path="${STATE_DIR}/config/daemon-bootstrap.yaml"

if [[ "${DRY_RUN}" == "true" ]]; then
  cat <<EOF
[dry-run] would download ${bin_url}
[dry-run] would verify sha256 against ${sha_url}
[dry-run] would install to ${install_path} (requires sudo)
[dry-run] would write ${bootstrap_path}:
            controller:
              address: https://127.0.0.1:8443
              caCertificatePath: ${controller_ca}
              heartbeatInterval: 30s
EOF
  exit 0
fi

[[ -f "${controller_ca}" ]] || die "Device CA not found at ${controller_ca}. Run 20-controller-up.sh first."

log_step "Checking whether the correct version is already installed"
skip_install=false
if [[ -x "${install_path}" ]]; then
  work_dir="$(mktemp -d)"
  trap 'rm -rf "${work_dir}"' EXIT
  if curl --fail --silent --show-error --location --output "${work_dir}/${asset_name}.sha256" "${sha_url}"; then
    expected_hash="$(awk '{print $1}' "${work_dir}/${asset_name}.sha256")"
    actual_hash="$(shasum -a 256 "${install_path}" | awk '{print $1}')"
    if [[ "${expected_hash}" == "${actual_hash}" ]]; then
      log_success "${install_path} already matches ${resolved_version}, skipping download"
      skip_install=true
    fi
  fi
  rm -rf "${work_dir}"
  trap - EXIT
fi

if [[ "${skip_install}" != "true" ]]; then
  log_step "Downloading and verifying ${asset_name}"
  work_dir="$(mktemp -d)"
  trap 'rm -rf "${work_dir}"' EXIT
  curl --fail --silent --show-error --location --output "${work_dir}/${asset_name}" "${bin_url}"
  curl --fail --silent --show-error --location --output "${work_dir}/${asset_name}.sha256" "${sha_url}"
  ( cd "${work_dir}" && shasum -a 256 -c "${asset_name}.sha256" ) \
    || die "Checksum verification failed for ${asset_name}. Do not install; re-download."
  chmod 0755 "${work_dir}/${asset_name}"

  log_step "Installing to ${install_path} (sudo required)"
  sudo install -m 0755 "${work_dir}/${asset_name}" "${install_path}"
  rm -rf "${work_dir}"
  trap - EXIT
  log_success "Installed ${resolved_version} to ${install_path}"
fi

log_step "Writing daemon bootstrap config"
mkdir -p "$(dirname "${bootstrap_path}")"
cat > "${bootstrap_path}" <<EOF
controller:
  address: https://127.0.0.1:8443
  caCertificatePath: ${controller_ca}
  heartbeatInterval: 30s
EOF
log_success "Wrote ${bootstrap_path}"

env_file_set DAEMON_BOOTSTRAP_PATH "${bootstrap_path}"
env_file_set AGENTDESKTOP_BIN "${install_path}"
env_file_set AGENTDESKTOP_VERSION "${resolved_version}"

cat <<EOF

Everything is staged. Enrollment itself is interactive (opens your browser
for Entra ID sign-in) and needs sudo, so run this yourself in a terminal you
can watch:

    sudo "${install_path}" daemon --config "${bootstrap_path}"

Sign in as your pilot user (check state/demo.env for PILOT_UPN). Leave that
terminal running - it's the live daemon process, not a one-shot command.

Once enrolled, in a separate terminal:
    ${install_path} status
    ${install_path} discover
    ${install_path}            # opens the desktop UI
EOF
