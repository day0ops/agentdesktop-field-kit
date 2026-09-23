#!/usr/bin/env bash
# Guided, resumable wizard for the whole AgentDesktop + Entra ID + Intune
# demo setup. Wraps the numbered scripts in scripts/ with a gum-powered TUI:
# styled step panels, confirm gates before anything mutating runs, and
# persisted progress so re-running this picks up where you left off.
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
trap - ERR # each step reports its own outcome; the generic trap is too blunt here

SCRIPTS_DIR="${FIELD_KIT_ROOT}/scripts"
PROGRESS_FILE="${STATE_DIR}/wizard-progress"

usage() {
  cat <<'EOF'
Usage: run-demo.sh [--reset] [--from STEP_ID]

  --reset          Clear all progress and start from the beginning.
  --from STEP_ID   Jump straight to a step (see step ids in the source).
EOF
}

from_step=""
while (( $# > 0 )); do
  case "$1" in
    --reset) rm -f "${PROGRESS_FILE}"; shift ;;
    --from) from_step="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

command -v gum >/dev/null 2>&1 || die "gum is required. Install with: brew install gum"
touch "${PROGRESS_FILE}"

is_done()  { grep -qx "$1" "${PROGRESS_FILE}" 2>/dev/null; }
mark_done() { is_done "$1" || echo "$1" >> "${PROGRESS_FILE}"; }

banner() {
  gum style --border double --margin "1 0" --padding "1 3" --border-foreground 212 --bold \
    "AgentDesktop Field Kit" "Entra ID + Intune demo setup"
}

section() {
  local id=$1 title=$2
  echo
  if is_done "${id}"; then
    gum style --foreground 212 --bold "▸ ${title}  (already completed - can re-run)"
  else
    gum style --foreground 212 --bold "▸ ${title}"
  fi
}

# run_auto ID TITLE DESCRIPTION -- CMD...
run_auto() {
  local id=$1 title=$2 description=$3
  shift 3
  [[ "$1" == "--" ]] && shift
  section "${id}" "${title}"
  gum style --foreground 245 "${description}"

  if is_done "${id}"; then
    gum confirm "Re-run this step?" --default=false || return 0
  else
    gum confirm "Run this step now?" --default=true || { gum style --foreground 214 "Skipped for now."; return 0; }
  fi

  while true; do
    if "$@"; then
      mark_done "${id}"
      gum style --foreground 42 "✔ ${title} succeeded"
      return 0
    fi
    choice="$(gum choose "Retry" "Skip (mark done anyway)" "Abort wizard" --header "That step failed. What now?")"
    case "${choice}" in
      Retry) continue ;;
      "Skip (mark done anyway)") mark_done "${id}"; gum style --foreground 214 "Marked done despite failure."; return 0 ;;
      *) gum style --foreground 196 "Aborting."; exit 1 ;;
    esac
  done
}

# manual_step ID TITLE INSTRUCTIONS
manual_step() {
  local id=$1 title=$2 instructions=$3
  section "${id}" "${title}"
  gum style --border normal --padding "1 2" --foreground 250 "${instructions}"
  if is_done "${id}"; then
    gum confirm "Already marked done. Re-confirm?" --default=false && mark_done "${id}"
    return 0
  fi
  until gum confirm "Mark this step as done once you've completed it"; do
    gum style --foreground 214 "OK, take your time. Re-run this prompt when ready."
  done
  mark_done "${id}"
}

clear
banner

if [[ -n "${from_step}" ]]; then
  gum style --foreground 214 "Jumping to step: ${from_step} (steps before it are assumed done)"
fi
skip_until() {
  [[ -z "${from_step}" ]] && return 1
  [[ "$1" == "${from_step}" ]] && { from_step=""; return 1; }
  return 0
}

skip_until preflight || run_auto preflight "Preflight checks" \
  "Verifies docker/az/jq/openssl are installed, Docker is running, az is Graph-authenticated, and Intune is licensed." \
  -- "${SCRIPTS_DIR}/00-preflight.sh"

skip_until pilot-user || {
  section pilot-user "Dedicated pilot user"
  load_env_file
  if [[ -n "${PILOT_UPN:-}" ]]; then
    default_upn="${PILOT_UPN}"
  else
    default_domain="$(az rest --method GET \
      --url 'https://graph.microsoft.com/v1.0/organization?$select=verifiedDomains' \
      --output json 2>/dev/null | jq -r '.value[0].verifiedDomains[] | select(.isDefault==true) | .name' 2>/dev/null | head -1)"
    default_upn="agentdesktop.pilot@${default_domain:-example.onmicrosoft.com}"
  fi
  upn="$(gum input --value "${default_upn}" --prompt "Pilot UPN: ")"
  run_auto pilot-user "Dedicated pilot user" \
    "Creates (or reuses) a dedicated Entra ID user for this demo, licenses it for Intune. Password is generated at runtime and shown once - capture it." \
    -- "${SCRIPTS_DIR}/05-pilot-user.sh" --upn "${upn}"
}

skip_until entra-app || run_auto entra-app "Entra app registration" \
  "Creates the 'agentdesktop enrollment' public-client app registration (no secret, PKCE, loopback redirect)." \
  -- "${SCRIPTS_DIR}/10-entra-app.sh"

skip_until entra-consent || run_auto entra-consent "Admin consent + assignment" \
  "Grants tenant-wide admin consent and assigns the pilot user to the Enterprise Application." \
  -- "${SCRIPTS_DIR}/11-entra-consent.sh"

skip_until intune-licensing || manual_step intune-licensing "Intune licensing (manual)" \
"1. Go to https://admin.microsoft.com -> Billing -> Purchase services -> 'Microsoft Intune Plan 1' -> start the Managed (user-based) trial - only if not already licensed.
2. Visit https://intune.microsoft.com once and confirm Tenant administration -> Tenant status shows MDM Authority: Microsoft Intune and a non-zero license count."

skip_until controller-up || run_auto controller-up "Controller (Docker, local, Entra-backed)" \
  "Generates dev TLS/CA/JWT keys, renders controller.yaml with real Entra ID as OIDC issuer, runs the controller via docker run (no Kubernetes/Postgres)." \
  -- "${SCRIPTS_DIR}/20-controller-up.sh"

skip_until agentgateway-up || {
  section agentgateway-up "agentgateway (live Claude Code traffic)"
  if gum confirm "Include live Claude Code traffic through agentgateway?" --default=true; then
    if [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then
      ANTHROPIC_API_KEY="$(gum input --password --placeholder "sk-ant-...")"
      export ANTHROPIC_API_KEY
    fi
    run_auto agentgateway-up "agentgateway" \
      "Starts agentgateway, validating controller-issued JWTs and forwarding to Anthropic." \
      -- "${SCRIPTS_DIR}/21-agentgateway-up.sh"
  else
    gum style --foreground 214 "Skipping agentgateway - enrollment/management story only."
    mark_done agentgateway-up
  fi
}

skip_until daemon-prepare || run_auto daemon-prepare "Prepare local daemon binary" \
  "Downloads and checksum-verifies the released agentdesktop binary, writes the local bootstrap config." \
  -- "${SCRIPTS_DIR}/30-daemon-enroll.sh"

load_env_file
skip_until daemon-enroll || manual_step daemon-enroll "Enroll this Mac directly (manual, interactive)" \
"Enrollment needs sudo and opens your browser for Entra ID sign-in, so run it yourself in a
terminal you can watch (leave it running - it's the live daemon, not one-shot):

    sudo ${AGENTDESKTOP_BIN:-/usr/local/bin/agentdesktop} daemon --config ${DAEMON_BOOTSTRAP_PATH:-${STATE_DIR}/config/daemon-bootstrap.yaml}

Sign in as your pilot user (${PILOT_UPN:-check state/demo.env}). This is the quick manual
sanity-check path - 41-intune-push.sh below is the path that actually demonstrates
Intune management."

skip_until intune-groups || run_auto intune-groups "Intune pilot group" \
  "Creates the AgentDesktop-Pilot-macOS security group and adds the pilot user." \
  -- "${SCRIPTS_DIR}/40-intune-groups.sh"

skip_until intune-push || run_auto intune-push "Push Intune bootstrap script" \
  "Renders a shell script that installs the daemon as a LaunchDaemon and writes its bootstrap config, pushes it to Intune, assigns the pilot group." \
  -- "${SCRIPTS_DIR}/41-intune-push.sh"

skip_until intune-enroll || manual_step intune-enroll "Enroll the Mac in Intune (manual, interactive)" \
"1. Install Company Portal from the Mac App Store (or https://go.microsoft.com/fwlink/?linkid=853070).
2. Open Company Portal, sign in as the pilot user, and enroll this Mac (approve the
   management profile in System Settings > Privacy & Security when prompted).
3. Sync is not instant. To force a check-in after enrolling:
     sudo profiles renew -type enrollment
4. Confirm the push landed:
     sudo launchctl print system/dev.agentdesktop.daemon
     sudo cat /etc/agentdesktop/config.yaml"

skip_until validate || run_auto validate "Validate" \
  "Runs through connectivity/config checks and reports a pass/fail/skip summary. Non-fatal - just diagnostic." \
  -- "${SCRIPTS_DIR}/50-validate.sh"

echo
gum style --border double --margin "1 0" --padding "1 3" --border-foreground 42 --bold \
  "Setup walkthrough complete." \
  "Re-run any step anytime with: ./run-demo.sh --from STEP_ID" \
  "Rehearse the whole flow once tonight before the live demo - Intune sync timing is the main risk."
