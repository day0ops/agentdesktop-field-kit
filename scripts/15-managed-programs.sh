#!/usr/bin/env bash
# Resolves which of Claude Code / Codex are being demoed this run, and each
# selected program's auth mode (subscription vs. API key), then persists the
# decision to state/demo.env. Later scripts (controller/agentgateway config
# rendering, validation, the wizard) read that state instead of each
# re-deriving the same decision independently.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

usage() {
  cat <<'EOF'
Usage: 15-managed-programs.sh [--programs LIST] [--claude-auth-mode MODE]
                               [--codex-auth-mode MODE] [--dry-run]

LIST is a comma-separated subset of "claude,codex" (no spaces). Default:
both, filtered to whichever of CLAUDE_CODE_PRESENT/CODEX_PRESENT (written
by 00-preflight.sh) is "true". If one of those state keys was never
recorded (preflight wasn't run, or ran before this key existed), that
program defaults to included rather than silently dropped.

MODE is "subscription" or "api-key". Default per program: "api-key" if
that program's API key is set in the environment (ANTHROPIC_API_KEY for
claude, OPENAI_API_KEY for codex), else "subscription".

An auth-mode flag for a program that isn't in the resolved --programs set
is accepted but ignored (warned about, not rejected): it has nothing to
apply to.
EOF
}

programs_flag=""
claude_auth_mode_flag=""
codex_auth_mode_flag=""

while (( $# > 0 )); do
  case "$1" in
    --programs) programs_flag="$2"; shift 2 ;;
    --claude-auth-mode) claude_auth_mode_flag="$2"; shift 2 ;;
    --codex-auth-mode) codex_auth_mode_flag="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) log_error "Unknown argument: $1"; usage >&2; exit 2 ;;
  esac
done

is_valid_auth_mode() {
  [[ "$1" == "subscription" || "$1" == "api-key" ]]
}

[[ -z "${claude_auth_mode_flag}" ]] || is_valid_auth_mode "${claude_auth_mode_flag}" \
  || die "--claude-auth-mode must be 'subscription' or 'api-key', got: ${claude_auth_mode_flag}"
[[ -z "${codex_auth_mode_flag}" ]] || is_valid_auth_mode "${codex_auth_mode_flag}" \
  || die "--codex-auth-mode must be 'subscription' or 'api-key', got: ${codex_auth_mode_flag}"

load_env_file

# --- resolve selected programs -------------------------------------------

want_claude=false
want_codex=false

if [[ -n "${programs_flag}" ]]; then
  IFS=',' read -r -a requested_programs <<<"${programs_flag}"
  for p in "${requested_programs[@]}"; do
    case "${p}" in
      claude) want_claude=true ;;
      codex) want_codex=true ;;
      *) die "--programs must be a comma-separated subset of 'claude,codex', got: ${programs_flag}" ;;
    esac
  done
else
  # Per-program default: included unless preflight explicitly recorded it
  # as absent. An unset presence var defaults to included.
  if [[ "${CLAUDE_CODE_PRESENT:-true}" == "true" ]]; then want_claude=true; fi
  if [[ "${CODEX_PRESENT:-true}" == "true" ]]; then want_codex=true; fi
fi

managed_programs=""
if [[ "${want_claude}" == "true" ]]; then
  managed_programs="claude"
fi
if [[ "${want_codex}" == "true" ]]; then
  managed_programs="${managed_programs:+${managed_programs},}codex"
fi

# --- resolve auth modes ----------------------------------------------------

claude_auth_mode=""
if [[ "${want_claude}" == "true" ]]; then
  if [[ -n "${claude_auth_mode_flag}" ]]; then
    claude_auth_mode="${claude_auth_mode_flag}"
  elif [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
    claude_auth_mode="api-key"
  else
    claude_auth_mode="subscription"
  fi
elif [[ -n "${claude_auth_mode_flag}" ]]; then
  log_warn "--claude-auth-mode given but claude is not in the selected programs; ignoring it"
fi

codex_auth_mode=""
if [[ "${want_codex}" == "true" ]]; then
  if [[ -n "${codex_auth_mode_flag}" ]]; then
    codex_auth_mode="${codex_auth_mode_flag}"
  elif [[ -n "${OPENAI_API_KEY:-}" ]]; then
    codex_auth_mode="api-key"
  else
    codex_auth_mode="subscription"
  fi
elif [[ -n "${codex_auth_mode_flag}" ]]; then
  log_warn "--codex-auth-mode given but codex is not in the selected programs; ignoring it"
fi

# --- summary ---------------------------------------------------------------

describe_mode() {
  local program=$1 mode=$2
  if [[ "${mode}" == "api-key" ]]; then
    case "${program}" in
      claude) printf 'ANTHROPIC_API_KEY from environment' ;;
      codex) printf 'OPENAI_API_KEY from environment' ;;
    esac
  else
    case "${program}" in
      claude) printf 'sign in with a Claude Team/Enterprise seat' ;;
      codex) printf 'sign in with a ChatGPT account' ;;
    esac
  fi
}

print_summary() {
  if [[ "${want_claude}" == "true" ]]; then
    printf 'claude: %s (%s)\n' "${claude_auth_mode}" "$(describe_mode claude "${claude_auth_mode}")"
  fi
  if [[ "${want_codex}" == "true" ]]; then
    printf 'codex: %s (%s)\n' "${codex_auth_mode}" "$(describe_mode codex "${codex_auth_mode}")"
  fi
  if [[ "${want_claude}" != "true" && "${want_codex}" != "true" ]]; then
    printf 'No managed programs selected.\n'
  fi
}

if [[ "${DRY_RUN}" == "true" ]]; then
  log_step "Resolved managed-programs selection (dry-run, not persisted)"
  print_summary
  exit 0
fi

env_file_set MANAGED_PROGRAMS "${managed_programs}"
if [[ "${want_claude}" == "true" ]]; then
  env_file_set CLAUDE_AUTH_MODE "${claude_auth_mode}"
fi
if [[ "${want_codex}" == "true" ]]; then
  env_file_set CODEX_AUTH_MODE "${codex_auth_mode}"
fi

log_step "Resolved managed-programs selection"
print_summary
