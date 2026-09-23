#!/usr/bin/env bash
# Renders a macOS bootstrap shell script and pushes it to Intune as a
# deviceShellScript assigned to the pilot group.
#
# Deliberate deviation from AgentDesktop's documented production path: the
# docs' Intune "Apps > macOS (PKG)" workflow requires a Developer-ID-signed,
# notarized package. We don't have one for a same-day pilot, so instead this
# script has Intune's *shell script* mechanism (no signing/notarization
# requirement - it just runs as root via the Intune Management Extension)
# install the raw released binary itself, register it as a LaunchDaemon
# (dev.agentdesktop.daemon, matching the label the docs assume the PKG would
# have created), and write the same bootstrap config/CA the PKG path would
# write. Functionally equivalent for a pilot; revisit for real production use.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

usage() {
  cat <<'EOF'
Usage: 41-intune-push.sh [--group-id ID] [--version vX.Y.Z] [--controller-address URL] [--dry-run]

Defaults come from state/demo.env (INTUNE_PILOT_GROUP_ID from
40-intune-groups.sh, device CA from 20-controller-up.sh).
EOF
}

group_id=""
version=""
controller_address="https://127.0.0.1:8443"
repo="agentdesktop-dev/agentdesktop"

while (( $# > 0 )); do
  case "$1" in
    --group-id) group_id="$2"; shift 2 ;;
    --version) version="$2"; shift 2 ;;
    --controller-address) controller_address="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) log_error "Unknown argument: $1"; usage >&2; exit 2 ;;
  esac
done

load_env_file
group_id="${group_id:-${INTUNE_PILOT_GROUP_ID:-}}"
[[ -n "${group_id}" ]] || die "No group id given and none found in state. Run 40-intune-groups.sh first, or pass --group-id."

device_ca="${STATE_DIR}/keys/device-ca.pem"
[[ -f "${device_ca}" ]] || die "Device CA not found at ${device_ca}. Run 20-controller-up.sh first."

log_step "Resolving release and per-architecture checksums"
if [[ -n "${version}" ]]; then
  release_url="https://api.github.com/repos/${repo}/releases/tags/${version}"
else
  release_url="https://api.github.com/repos/${repo}/releases/latest"
fi
release_json="$(curl --fail --silent --show-error "${release_url}")" \
  || die "Could not fetch release metadata from ${release_url}"
resolved_version="$(jq -r .tag_name <<<"${release_json}")"

fetch_hash() {
  local asset=$1 url
  url="$(jq -r --arg n "${asset}.sha256" '.assets[] | select(.name == $n) | .browser_download_url' <<<"${release_json}")"
  [[ -n "${url}" ]] || die "Could not find ${asset}.sha256 in release ${resolved_version}"
  curl --fail --silent --show-error "${url}" | awk '{print $1}'
}
sha_arm64="$(fetch_hash agentdesktop-darwin-arm64)"
sha_amd64="$(fetch_hash agentdesktop-darwin-amd64)"
log_success "Resolved ${resolved_version} (arm64 ${sha_arm64:0:12}..., amd64 ${sha_amd64:0:12}...)"

generated_dir="${STATE_DIR}/generated"
mkdir -p "${generated_dir}"
bootstrap_script="${generated_dir}/agentdesktop-intune-bootstrap.sh"

if [[ "${DRY_RUN}" == "true" ]]; then
  log_info "[dry-run] would render ${bootstrap_script} for controller ${controller_address}, version ${resolved_version}"
  bash "${FIELD_KIT_ROOT}/lib/upsert-intune-script.sh" /dev/null "${group_id}" --dry-run 2>/dev/null || true
  cat <<EOF
[dry-run] az rest POST/PATCH https://graph.microsoft.com/beta/deviceManagement/deviceShellScripts
[dry-run]   displayName: agentdesktop bootstrap
[dry-run]   assign to group: ${group_id}
EOF
  exit 0
fi

log_step "Rendering bootstrap script"
{
  cat <<SCRIPT_HEADER
#!/bin/sh
set -eu

REPO="${repo}"
VERSION="${resolved_version}"
CONTROLLER_ADDRESS="${controller_address}"
SHA_ARM64="${sha_arm64}"
SHA_AMD64="${sha_amd64}"
INSTALL_PATH=/usr/local/bin/agentdesktop
CONFIG_DIR=/etc/agentdesktop
CONFIG_PATH="\${CONFIG_DIR}/config.yaml"
CA_PATH="\${CONFIG_DIR}/controller-ca.pem"
PLIST_PATH=/Library/LaunchDaemons/dev.agentdesktop.daemon.plist
LABEL=dev.agentdesktop.daemon
changed=0

ARCH="\$(/usr/bin/uname -m)"
case "\${ARCH}" in
  arm64) BIN_ARCH=arm64; EXPECTED_SHA="\${SHA_ARM64}" ;;
  x86_64) BIN_ARCH=amd64; EXPECTED_SHA="\${SHA_AMD64}" ;;
  *) echo "Unsupported architecture: \${ARCH}" >&2; exit 1 ;;
esac
BIN_NAME="agentdesktop-darwin-\${BIN_ARCH}"
BIN_URL="https://github.com/\${REPO}/releases/download/\${VERSION}/\${BIN_NAME}"

current_hash=""
if [ -x "\${INSTALL_PATH}" ]; then
  current_hash=\$(/usr/bin/shasum -a 256 "\${INSTALL_PATH}" | /usr/bin/awk '{print \$1}')
fi

if [ "\${current_hash}" != "\${EXPECTED_SHA}" ]; then
  TMP_BIN=\$(/usr/bin/mktemp /tmp/agentdesktop.XXXXXX)
  /usr/bin/curl --fail --silent --show-error --location --output "\${TMP_BIN}" "\${BIN_URL}"
  DOWNLOADED_HASH=\$(/usr/bin/shasum -a 256 "\${TMP_BIN}" | /usr/bin/awk '{print \$1}')
  if [ "\${DOWNLOADED_HASH}" != "\${EXPECTED_SHA}" ]; then
    echo "Checksum mismatch for \${BIN_NAME}: expected \${EXPECTED_SHA}, got \${DOWNLOADED_HASH}" >&2
    rm -f "\${TMP_BIN}"
    exit 1
  fi
  /usr/sbin/chown root:wheel "\${TMP_BIN}"
  /bin/chmod 0755 "\${TMP_BIN}"
  /bin/mv -f "\${TMP_BIN}" "\${INSTALL_PATH}"
  changed=1
fi

if ! /usr/bin/dscl . -read /Groups/agentdesktop >/dev/null 2>&1; then
  /usr/sbin/dseditgroup -o create -r "AgentDesktop" agentdesktop
fi

/usr/bin/install -d -o root -g wheel -m 0755 "\${CONFIG_DIR}"

write_managed_file() {
  target="\$1"
  mode="\$2"
  tmp=\$(/usr/bin/mktemp "\${target}.XXXXXX")
  /bin/cat >"\${tmp}"
  if [ -f "\${target}" ] && /usr/bin/cmp -s "\${tmp}" "\${target}"; then
    /bin/rm -f "\${tmp}"
    /usr/sbin/chown root:wheel "\${target}"
    /bin/chmod "\${mode}" "\${target}"
    return
  fi
  /usr/sbin/chown root:wheel "\${tmp}"
  /bin/chmod "\${mode}" "\${tmp}"
  /bin/mv -f "\${tmp}" "\${target}"
  changed=1
}

write_managed_file "\${CONFIG_PATH}" 0600 <<YAML
controller:
  address: \${CONTROLLER_ADDRESS}
  caCertificatePath: /etc/agentdesktop/controller-ca.pem
  heartbeatInterval: 30s
YAML

write_managed_file "\${CA_PATH}" 0644 <<'PEM'
$(cat "${device_ca}")
PEM

write_managed_file "\${PLIST_PATH}" 0644 <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>\${LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>\${INSTALL_PATH}</string>
    <string>daemon</string>
    <string>--config</string>
    <string>\${CONFIG_PATH}</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>/var/log/agentdesktop-daemon.log</string>
  <key>StandardErrorPath</key>
  <string>/var/log/agentdesktop-daemon.log</string>
</dict>
</plist>
PLIST

if [ "\${changed}" -eq 1 ]; then
  /bin/launchctl bootout system "\${PLIST_PATH}" >/dev/null 2>&1 || true
  /bin/launchctl bootstrap system "\${PLIST_PATH}"
  /bin/launchctl kickstart -k "system/\${LABEL}"
fi

console_user=\$(/usr/bin/stat -f '%Su' /dev/console)
case "\${console_user}" in
  "" | root | loginwindow | _mbsetupuser) ;;
  *)
    if ! /usr/sbin/dseditgroup -o checkmember -m "\${console_user}" agentdesktop 2>/dev/null | /usr/bin/grep -q 'yes'; then
      /usr/sbin/dseditgroup -o edit -a "\${console_user}" -t user agentdesktop
    fi
    ;;
esac
SCRIPT_HEADER
} > "${bootstrap_script}"

chmod 0755 "${bootstrap_script}"
sh -n "${bootstrap_script}" || die "Rendered script failed sh -n syntax check: ${bootstrap_script}"
log_success "Rendered $(wc -c <"${bootstrap_script}" | tr -d ' ') bytes to ${bootstrap_script}"

log_step "Acquiring an app-only Graph token for the Intune API (az CLI's own app cannot hold this permission - see lib/get-graph-app-token.sh)"
GRAPH_BEARER_TOKEN="$(bash "${FIELD_KIT_ROOT}/lib/get-graph-app-token.sh")" || die "Could not acquire an app-only Graph token"
export GRAPH_BEARER_TOKEN
log_success "Token acquired"

log_step "Pushing to Intune via Microsoft Graph"
bash "${FIELD_KIT_ROOT}/lib/upsert-intune-script.sh" "${bootstrap_script}" "${group_id}" --display-name "agentdesktop bootstrap"
unset GRAPH_BEARER_TOKEN

echo
log_success "Intune shell script pushed and assigned to group ${group_id}."
log_warn "Sync is not instant. On the pilot Mac after Intune enrollment, you can force a check-in with: sudo profiles renew -type enrollment"
