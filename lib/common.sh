#!/usr/bin/env bash
# Shared helpers sourced by every script in scripts/. Not meant to be run directly.

if [[ -n "${AGENTDESKTOP_FIELD_KIT_COMMON_LOADED:-}" ]]; then
  # shellcheck disable=SC2317 # reached when sourced a second time; exit only fires when run directly
  return 0 2>/dev/null || exit 0
fi
AGENTDESKTOP_FIELD_KIT_COMMON_LOADED=1

set -euo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIELD_KIT_ROOT="$(cd "${LIB_DIR}/.." && pwd)"
STATE_DIR="${FIELD_KIT_ROOT}/state"
ENV_FILE="${STATE_DIR}/demo.env"

mkdir -p "${STATE_DIR}"
chmod 700 "${STATE_DIR}"

# --- logging -----------------------------------------------------------

if [[ -t 2 ]]; then
  readonly _C_RED=$'\033[31m' _C_YELLOW=$'\033[33m' _C_GREEN=$'\033[32m' _C_BLUE=$'\033[34m' _C_RESET=$'\033[0m'
else
  readonly _C_RED='' _C_YELLOW='' _C_GREEN='' _C_BLUE='' _C_RESET=''
fi

log_info()    { printf '%s[INFO]%s  %s\n'  "${_C_BLUE}"   "${_C_RESET}" "$*" >&2; }
log_warn()    { printf '%s[WARN]%s  %s\n'  "${_C_YELLOW}" "${_C_RESET}" "$*" >&2; }
log_error()   { printf '%s[ERROR]%s %s\n'  "${_C_RED}"    "${_C_RESET}" "$*" >&2; }
log_success() { printf '%s[OK]%s    %s\n'  "${_C_GREEN}"  "${_C_RESET}" "$*" >&2; }
log_step()    { printf '\n%s==> %s%s\n' "${_C_BLUE}" "$*" "${_C_RESET}" >&2; }

die() {
  log_error "$*"
  exit 1
}

on_err() {
  local exit_code=$1 line=$2
  log_error "Failed in ${0##*/} at line ${line} (exit ${exit_code})."
}
trap 'on_err $? $LINENO' ERR

# --- environment / prerequisite checks ----------------------------------

require_macos() {
  [[ "$(uname -s)" == "Darwin" ]] || die "This script is written for macOS only (found $(uname -s))."
}

require_cmd() {
  local cmd=$1 hint=${2:-}
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    if [[ -n "${hint}" ]]; then
      die "Required command '${cmd}' not found. Install it with: ${hint}"
    else
      die "Required command '${cmd}' not found on PATH."
    fi
  fi
}

mac_arch() {
  case "$(uname -m)" in
    arm64)  printf 'arm64\n' ;;
    x86_64) printf 'amd64\n' ;;
    *) die "Unsupported architecture: $(uname -m)" ;;
  esac
}

docker_running() {
  docker info >/dev/null 2>&1
}

# Returns 0 and prints the current tenant ID if az has a usable Microsoft
# Graph token; returns 1 with no output otherwise. Never throws even though
# the rest of this file runs under `set -e`.
az_graph_tenant_id() {
  local tenant_id
  if ! tenant_id="$(az account show --query tenantId --output tsv 2>/dev/null)"; then
    return 1
  fi
  if ! az ad app list --all --output tsv --query '[0].appId' >/dev/null 2>&1; then
    return 1
  fi
  printf '%s\n' "${tenant_id}"
}

# --- dry-run / confirmation helpers -------------------------------------
# DRY_RUN is a global consumed by every script that sources this file, not
# read within common.sh itself - shellcheck can't see that cross-file usage.

# shellcheck disable=SC2034
DRY_RUN=false

# Strips --dry-run out of the positional args and sets the global DRY_RUN.
# Must NOT be called via process/command substitution ($(...) or <(...)) -
# that would run it in a subshell and the DRY_RUN=true assignment would be
# lost when the subshell exits. Call directly and re-set "$@" from the
# array it fills in, e.g.:
#   strip_dry_run_flag "$@"; set -- "${STRIPPED_ARGS[@]}"
STRIPPED_ARGS=()
strip_dry_run_flag() {
  STRIPPED_ARGS=()
  for arg in "$@"; do
    if [[ "${arg}" == "--dry-run" ]]; then
      # shellcheck disable=SC2034 # consumed by the sourcing script, not here
      DRY_RUN=true
    else
      STRIPPED_ARGS+=("${arg}")
    fi
  done
}

confirm() {
  local prompt=${1:-"Are you sure?"}
  if [[ "${ASSUME_YES:-false}" == "true" ]]; then
    return 0
  fi
  local reply
  read -r -p "${prompt} [y/N] " reply
  [[ "${reply}" =~ ^[Yy]$ ]]
}

# --- state file (non-secret operational values only) --------------------
# Never write passwords, API keys, or private key material into ENV_FILE.

env_file_set() {
  local key=$1 value=$2
  touch "${ENV_FILE}"
  chmod 600 "${ENV_FILE}"
  if grep -q "^${key}=" "${ENV_FILE}" 2>/dev/null; then
    local tmp
    tmp="$(mktemp "${ENV_FILE}.XXXXXX")"
    awk -F'=' -v k="${key}" -v v="${value}" 'BEGIN{OFS="="} $1==k{$0=k"="v} {print}' "${ENV_FILE}" > "${tmp}"
    mv "${tmp}" "${ENV_FILE}"
  else
    printf '%s=%s\n' "${key}" "${value}" >> "${ENV_FILE}"
  fi
}

env_file_get() {
  local key=$1
  [[ -f "${ENV_FILE}" ]] || return 1
  awk -F'=' -v k="${key}" '$1==k{print substr($0, length(k)+2); found=1} END{exit !found}' "${ENV_FILE}"
}

load_env_file() {
  if [[ -f "${ENV_FILE}" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "${ENV_FILE}"
    set +a
  fi
}
