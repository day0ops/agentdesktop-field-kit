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
Usage: run-demo.sh [--role controller|gateway] [--reset] [--from STEP_ID]

  --role controller  Only the steps needed on the machine running the
                      Docker-based controller: preflight, cloud/Entra/Intune
                      admin steps, controller-up, validate.
  --role gateway      Only the steps needed on the machine running
                      agentgateway + the enrolled daemon: preflight,
                      cloud/Entra/Intune admin steps, agentgateway-up,
                      daemon-prepare/enroll, intune-groups/push/enroll,
                      validate.
  (no --role)         Run everything - the original single-machine flow.
  --reset             Clear all progress and start from the beginning.
  --from STEP_ID      Jump straight to a step (see step ids in the source).
EOF
}

from_step=""
role=""
while (( $# > 0 )); do
  case "$1" in
    --role)
      role="$2"
      case "${role}" in
        controller|gateway) ;;
        *) echo "--role must be 'controller' or 'gateway', got: ${role}" >&2; exit 2 ;;
      esac
      shift 2
      ;;
    --reset) rm -f "${PROGRESS_FILE}"; shift ;;
    --from) from_step="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

command -v gum >/dev/null 2>&1 || die "gum is required. Install with: brew install gum"
touch "${PROGRESS_FILE}"

# role_skip STEP_ROLE - same calling convention as skip_until: returns 0
# (skip) when this step's role tag doesn't match --role, 1 (run) otherwise.
# STEP_ROLE "both" always runs; with no --role set, everything runs
# (preserves the original single-machine flow).
role_skip() {
  local step_role=$1
  [[ -z "${role}" || "${step_role}" == "both" || "${step_role}" == "${role}" ]] && return 1
  return 0
}

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
if [[ -n "${role}" ]]; then
  gum style --foreground 212 "Role: ${role} (steps for the other machine are skipped automatically)"
fi

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

if [[ -n "${role}" ]]; then
  skip_until controller-address || {
    section controller-address "Controller address"
    load_env_file
    if [[ -z "${CONTROLLER_PUBLIC_ADDRESS:-}" ]]; then
      if [[ "${role}" == "controller" ]]; then
        prompt_text="Enter the address the OTHER (agentgateway/daemon) machine uses to reach THIS one (LAN IP, Tailscale hostname, etc.)."
      else
        prompt_text="Enter the address this machine uses to reach the CONTROLLER machine (LAN IP, Tailscale hostname, etc.)."
      fi
      gum style --foreground 245 "${prompt_text} Loopback (127.0.0.1) only works when everything's on one machine."
      addr="$(gum input --placeholder "e.g. kasuns-macbook-pro.tail537a5d.ts.net")"
      [[ -n "${addr}" ]] && env_file_set CONTROLLER_PUBLIC_ADDRESS "${addr}"
    fi
    mark_done controller-address
  }
fi

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

skip_until managed-programs || {
  section managed-programs "Managed programs"
  load_env_file
  gum style --foreground 245 "Choose which AI coding tools this demo manages through the controller, agentgateway, and daemon."

  program_choices=()
  default_selected=()
  if [[ "${CLAUDE_CODE_PRESENT:-true}" == "true" ]]; then
    program_choices+=("Claude Code")
    if [[ -z "${MANAGED_PROGRAMS:-}" || ",${MANAGED_PROGRAMS}," == *,claude,* ]]; then
      default_selected+=("Claude Code")
    fi
  fi
  if [[ "${CODEX_PRESENT:-true}" == "true" ]]; then
    program_choices+=("Codex")
    if [[ -z "${MANAGED_PROGRAMS:-}" || ",${MANAGED_PROGRAMS}," == *,codex,* ]]; then
      default_selected+=("Codex")
    fi
  fi
  if (( ${#program_choices[@]} == 0 )); then
    program_choices=("Claude Code" "Codex")
    default_selected=("Claude Code" "Codex")
  fi

  selected=""
  until [[ -n "${selected}" ]]; do
    selected="$(gum choose --no-limit --selected "$(IFS=,; echo "${default_selected[*]}")" \
      --header "Manage which program(s) in this demo?" "${program_choices[@]}")"
    [[ -n "${selected}" ]] || gum style --foreground 214 "Pick at least one program."
  done

  programs=""
  [[ "${selected}" == *"Claude Code"* ]] && programs="claude"
  [[ "${selected}" == *"Codex"* ]] && programs="${programs:+${programs},}codex"

  managed_programs_args=(--programs "${programs}")

  if [[ ",${programs}," == *,claude,* ]]; then
    if gum confirm "Use a real Claude Team/Enterprise seat instead of an API key?" --default=true; then
      managed_programs_args+=(--claude-auth-mode subscription)
    else
      managed_programs_args+=(--claude-auth-mode api-key)
      if [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then
        ANTHROPIC_API_KEY="$(gum input --password --placeholder "sk-ant-...")"
        export ANTHROPIC_API_KEY
      fi
    fi
  fi

  if [[ ",${programs}," == *,codex,* ]]; then
    if gum confirm "Use a real ChatGPT account instead of an API key?" --default=true; then
      managed_programs_args+=(--codex-auth-mode subscription)
    else
      managed_programs_args+=(--codex-auth-mode api-key)
      if [[ -z "${OPENAI_API_KEY:-}" ]]; then
        OPENAI_API_KEY="$(gum input --password --placeholder "sk-...")"
        export OPENAI_API_KEY
      fi
    fi
  fi

  run_auto managed-programs "Managed programs" \
    "Resolves which of Claude Code / Codex this demo manages and each one's auth mode (subscription seat vs. API key), persists the decision to state/demo.env." \
    -- "${SCRIPTS_DIR}/15-managed-programs.sh" "${managed_programs_args[@]}"
}

skip_until controller-up || role_skip controller || run_auto controller-up "Controller (Docker, local, Entra-backed)" \
  "Generates dev TLS/CA/JWT keys, renders controller.yaml with real Entra ID as OIDC issuer, runs the controller via docker run (no Kubernetes/Postgres)." \
  -- "${SCRIPTS_DIR}/20-controller-up.sh"

skip_until agentgateway-up || role_skip gateway || {
  section agentgateway-up "agentgateway (live Claude Code traffic)"
  load_env_file
  # Auth mode/keys are normally already resolved and exported by the
  # managed-programs step above. This only re-prompts when that's not true -
  # e.g. jumping straight here with --from, where the key was never exported
  # in this process. Gate each *_AUTH_MODE read on MANAGED_PROGRAMS
  # membership first: 15-managed-programs.sh never clears a stale
  # *_AUTH_MODE left over from an earlier run where that program was
  # selected but no longer is.
  claude_needs_key=false
  codex_needs_key=false
  if [[ ",${MANAGED_PROGRAMS:-}," == *,claude,* && "${CLAUDE_AUTH_MODE:-}" == "api-key" && -z "${ANTHROPIC_API_KEY:-}" ]]; then
    claude_needs_key=true
  fi
  if [[ ",${MANAGED_PROGRAMS:-}," == *,codex,* && "${CODEX_AUTH_MODE:-}" == "api-key" && -z "${OPENAI_API_KEY:-}" ]]; then
    codex_needs_key=true
  fi

  proceed=true
  if [[ "${claude_needs_key}" == "true" || "${codex_needs_key}" == "true" ]]; then
    gum confirm "Include live Claude Code traffic through agentgateway?" --default=true || proceed=false
  fi

  if [[ "${proceed}" == "true" ]]; then
    if [[ "${claude_needs_key}" == "true" ]]; then
      ANTHROPIC_API_KEY="$(gum input --password --placeholder "sk-ant-...")"
      export ANTHROPIC_API_KEY
    fi
    if [[ "${codex_needs_key}" == "true" ]]; then
      OPENAI_API_KEY="$(gum input --password --placeholder "sk-...")"
      export OPENAI_API_KEY
    fi
    run_auto agentgateway-up "agentgateway" \
      "Starts agentgateway, validating controller-issued JWTs and forwarding to the configured provider(s)." \
      -- "${SCRIPTS_DIR}/21-agentgateway-up.sh"
  else
    gum style --foreground 214 "Skipping agentgateway - enrollment/management story only."
    mark_done agentgateway-up
  fi
}

skip_until daemon-prepare || role_skip gateway || run_auto daemon-prepare "Prepare local daemon binary" \
  "Downloads and checksum-verifies the released agentdesktop binary, writes the local bootstrap config." \
  -- "${SCRIPTS_DIR}/30-daemon-enroll.sh"

load_env_file
# Which program(s), if any, need an interactive browser sign-in once the
# daemon is up - only subscription mode does (api-key mode has no session).
# Gated on MANAGED_PROGRAMS membership first: a stale *_AUTH_MODE can be
# left over from an earlier run where that program was selected but no
# longer is (15-managed-programs.sh never clears it).
subscription_signin=""
if [[ ",${MANAGED_PROGRAMS:-}," == *,claude,* && "${CLAUDE_AUTH_MODE:-}" == "subscription" ]]; then
  subscription_signin="Claude.ai"
fi
if [[ ",${MANAGED_PROGRAMS:-}," == *,codex,* && "${CODEX_AUTH_MODE:-}" == "subscription" ]]; then
  subscription_signin="${subscription_signin:+${subscription_signin} and }ChatGPT"
fi
daemon_enroll_instructions="Enrollment opens your browser for Entra ID sign-in, so run it yourself in a
terminal you can watch (leave it running - it's the live daemon, not one-shot):

    ${AGENTDESKTOP_BIN:-/usr/local/bin/agentdesktop} daemon --user --config ${DAEMON_BOOTSTRAP_PATH:-${STATE_DIR}/config/daemon-bootstrap.yaml}

Sign in as your pilot user (${PILOT_UPN:-check state/demo.env}). This is the quick manual
sanity-check path - 41-intune-push.sh below is the path that actually demonstrates
Intune management."
if [[ -n "${subscription_signin}" ]]; then
  daemon_enroll_instructions+="

Once the daemon is running and enrolled, sign into ${subscription_signin} in a browser
when agentdesktop's checklist/UI prompts for it - subscription auth needs that live
sign-in, same as the Entra ID sign-in above."
fi
skip_until daemon-enroll || role_skip gateway || manual_step daemon-enroll "Enroll this Mac directly (manual, interactive)" \
"${daemon_enroll_instructions}"

skip_until intune-groups || role_skip gateway || run_auto intune-groups "Intune pilot group" \
  "Creates the AgentDesktop-Pilot-macOS security group and adds the pilot user." \
  -- "${SCRIPTS_DIR}/40-intune-groups.sh"

skip_until intune-push || role_skip gateway || run_auto intune-push "Push Intune bootstrap script" \
  "Renders a shell script that installs the daemon as a LaunchDaemon and writes its bootstrap config, pushes it to Intune, assigns the pilot group." \
  -- "${SCRIPTS_DIR}/41-intune-push.sh"

skip_until intune-enroll || role_skip gateway || manual_step intune-enroll "Enroll the Mac in Intune (manual, interactive)" \
"1. Install Company Portal from the Mac App Store (or https://go.microsoft.com/fwlink/?linkid=853070).
2. Open Company Portal, sign in as the pilot user, and enroll this Mac (approve the
   management profile in System Settings > Privacy & Security when prompted).
3. Sync is not instant. This is user/Company-Portal enrollment, not DEP, so
   'profiles renew -type enrollment' does not apply here (it'll error with
   'No Device Enrollment configuration found' - expected, harmless, ignore
   it). Our payload is a shell script, delivered via the Intune Management
   Extension agent, not the base MDM profile channel, so force a combined
   MDM + agent check-in instead:
     sudo killall IntuneMdmAgent
   Or from the GUI: Company Portal app -> this Mac -> the \"...\" menu -> Check Status.
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
  "Two-machine setup? Run this with --role controller on one machine and --role gateway on the other." \
  "Rehearse the whole flow once tonight before the live demo - Intune sync timing is the main risk."
