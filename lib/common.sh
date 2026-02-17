#!/usr/bin/env bash
# shellcheck disable=SC2034  # Variables used by sourcing scripts
# Shared library for vault-migration-tool scripts.
# Source this file; do not execute directly.
#
# Provides:
#   Logging:     info, warn, error, success
#   Vault:       safe_list, safe_read_to_file, read_tune_to_file, export_collection, vault_retry
#   Config:      load_config, require_tools
#   Args:        parse_export_args, parse_import_args
#   Safety:      confirm_action
#   Globals:     DRY_RUN, CONFIG_FILE, OUTPUT_DIR, INPUT_DIR, AUTO_YES

# Guard against double-sourcing
[[ -n "${_COMMON_SH_LOADED:-}" ]] && return 0
_COMMON_SH_LOADED=1

# ── Globals ──────────────────────────────────────────────────────────────────
DRY_RUN="${DRY_RUN:-false}"
AUTO_YES="${AUTO_YES:-false}"
CONFIG_FILE=""
OUTPUT_DIR=""
INPUT_DIR=""
CLUSTER_NAME="${CLUSTER_NAME:-}"

# Counters (scripts can increment these, then call print_summary)
EXPORT_COUNT=0
IMPORT_COUNT=0
SKIP_COUNT=0
WARN_COUNT=0
ERROR_LOG=""

# ── Logging ──────────────────────────────────────────────────────────────────
_ts() { date +%H:%M:%S; }

info()    { echo -e "\033[1;34m[i]\033[0m $(_ts) $*"; }
warn()    { echo -e "\033[1;33m[!]\033[0m $(_ts) $*"; WARN_COUNT=$((WARN_COUNT + 1)); }
error()   { echo -e "\033[1;31m[x]\033[0m $(_ts) $*" >&2; }
success() { echo -e "\033[1;32m[+]\033[0m $(_ts) $*"; }

# ── Error log ─────────────────────────────────────────────────────────────────
# Initialise an error log file under INPUT_DIR. Call after setup_import_dir.
setup_error_log() {
  ERROR_LOG="${INPUT_DIR}/import-errors.log"
  touch "$ERROR_LOG"   # create if missing, preserve existing content
}

# Append an error entry to the log file.
# Usage: log_error "resource path" "vault error message"
log_error() {
  local resource="$1"
  local message="$2"
  [[ -z "$ERROR_LOG" ]] && return 0
  printf "[%s] FAILED %s — %s\n" "$(date +%H:%M:%S)" "$resource" "$message" >> "$ERROR_LOG"
}

# Print error log location in the summary if there were errors.
_print_error_log_summary() {
  if [[ -n "$ERROR_LOG" && -s "$ERROR_LOG" ]]; then
    local count
    count=$(wc -l < "$ERROR_LOG" | tr -d ' ')
    warn "  Errors:            ${count} (see ${ERROR_LOG})"
  fi
}

# ── Tool checks ──────────────────────────────────────────────────────────────
require_tools() {
  local missing=()
  for tool in "$@"; do
    if ! command -v "$tool" &>/dev/null; then
      missing+=("$tool")
    fi
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    error "Missing required tools: ${missing[*]}"
    error "Install them before running this script."
    exit 1
  fi
}

# ── Config loading ───────────────────────────────────────────────────────────
# Sources a .env file and exports key vault variables.
load_config() {
  local config_file="$1"
  if [[ ! -f "$config_file" ]]; then
    error "Config file not found: ${config_file}"
    exit 1
  fi
  # shellcheck disable=SC1090
  source "$config_file"

  # Export vault environment variables
  export VAULT_ADDR="${VAULT_ADDR:?VAULT_ADDR is required in config}"
  export VAULT_TOKEN="${VAULT_TOKEN:?VAULT_TOKEN is required in config}"

  # Optional vars — export if set
  [[ -n "${VAULT_NAMESPACE:-}" ]]    && export VAULT_NAMESPACE
  [[ -n "${VAULT_CACERT:-}" ]]       && export VAULT_CACERT
  [[ -n "${VAULT_SKIP_VERIFY:-}" ]]  && export VAULT_SKIP_VERIFY

  CLUSTER_NAME="${CLUSTER_NAME:?CLUSTER_NAME is required in config}"

  info "Loaded config: ${config_file} (cluster: ${CLUSTER_NAME})"
  info "Vault address: ${VAULT_ADDR}"
}

# ── Argument parsing ─────────────────────────────────────────────────────────
# Usage: parse_export_args "$@"
# Sets: CONFIG_FILE, OUTPUT_DIR, DRY_RUN
parse_export_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --config)
        CONFIG_FILE="$2"; shift 2 ;;
      --output-dir)
        OUTPUT_DIR="$2"; shift 2 ;;
      --dry-run)
        DRY_RUN=true; shift ;;
      --help|-h)
        _print_export_usage; exit 0 ;;
      *)
        error "Unknown argument: $1"
        _print_export_usage; exit 1 ;;
    esac
  done
  if [[ -z "$CONFIG_FILE" ]]; then
    error "--config <path> is required"
    _print_export_usage
    exit 1
  fi
}

_print_export_usage() {
  cat <<'USAGE'
Usage: <script> --config <config.env> [--output-dir <dir>] [--dry-run]

  --config <path>      Path to cluster .env config file (required)
  --output-dir <path>  Export output directory (default: data/<CLUSTER_NAME>)
  --dry-run            Log operations without making changes
USAGE
}

# Usage: parse_import_args "$@"
# Sets: CONFIG_FILE, INPUT_DIR, DRY_RUN, AUTO_YES
parse_import_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --config)
        CONFIG_FILE="$2"; shift 2 ;;
      --input-dir)
        INPUT_DIR="$2"; shift 2 ;;
      --dry-run)
        DRY_RUN=true; shift ;;
      --yes|-y)
        AUTO_YES=true; shift ;;
      --help|-h)
        _print_import_usage; exit 0 ;;
      *)
        error "Unknown argument: $1"
        _print_import_usage; exit 1 ;;
    esac
  done
  if [[ -z "$CONFIG_FILE" ]]; then
    error "--config <path> is required"
    _print_import_usage
    exit 1
  fi
}

_print_import_usage() {
  cat <<'USAGE'
Usage: <script> --config <config.env> [--input-dir <dir>] [--dry-run] [--yes]

  --config <path>      Path to cluster .env config file (required)
  --input-dir <path>   Import input directory (default: data/<CLUSTER_NAME>)
  --dry-run            Log operations without making changes
  --yes                Skip interactive confirmation prompts
USAGE
}

# ── Setup helpers ────────────────────────────────────────────────────────────
# Call after parse_export_args + load_config. Sets OUTPUT_DIR default.
setup_export_dir() {
  local script_root
  script_root="$(cd "$(dirname "${BASH_SOURCE[1]}")/.." && pwd)"
  OUTPUT_DIR="${OUTPUT_DIR:-${script_root}/data/${CLUSTER_NAME}}"
  mkdir -p "$OUTPUT_DIR"
  info "Export directory: ${OUTPUT_DIR}"
}

# Call after parse_import_args + load_config. Sets INPUT_DIR default.
setup_import_dir() {
  local script_root
  script_root="$(cd "$(dirname "${BASH_SOURCE[1]}")/.." && pwd)"
  INPUT_DIR="${INPUT_DIR:-${script_root}/data/${CLUSTER_NAME}}"
  if [[ ! -d "$INPUT_DIR" ]]; then
    error "Import directory not found: ${INPUT_DIR}"
    exit 1
  fi
  info "Import directory: ${INPUT_DIR}"
}

# ── Safety ───────────────────────────────────────────────────────────────────
# Interactive confirmation. Returns 0 if confirmed, 1 if denied.
# Skipped when AUTO_YES=true or DRY_RUN=true.
confirm_action() {
  local message="${1:-Proceed?}"
  if [[ "$DRY_RUN" == "true" || "$AUTO_YES" == "true" ]]; then
    return 0
  fi
  echo -n -e "\033[1;33m[?]\033[0m ${message} [y/N] "
  read -r answer
  case "$answer" in
    [yY]|[yY][eE][sS]) return 0 ;;
    *) return 1 ;;
  esac
}

# ── Retry logic ──────────────────────────────────────────────────────────────
VAULT_MAX_RETRIES="${VAULT_MAX_RETRIES:-5}"
VAULT_RETRY_BASE_DELAY="${VAULT_RETRY_BASE_DELAY:-2}"  # seconds

# Run a vault command with automatic retry on HTTP 429 (rate limit).
# Usage: vault_retry vault write "path" - <<< "$payload"
#        vault_retry vault auth enable -path="foo" "bar"
# Returns the command's exit code. Stdout/stderr pass through on the final attempt.
# On 429, retries up to VAULT_MAX_RETRIES times with exponential backoff.
vault_retry() {
  local attempt=0
  local exit_code=0
  local output=""

  # Buffer stdin so it can be replayed on retries (needed for piped vault write)
  local stdin_data=""
  if [[ ! -t 0 ]]; then
    stdin_data=$(cat)
  fi

  while true; do
    if [[ -n "$stdin_data" ]]; then
      output=$(echo "$stdin_data" | "$@" 2>&1) && exit_code=0 || exit_code=$?
    else
      output=$("$@" 2>&1) && exit_code=0 || exit_code=$?
    fi

    if [[ $exit_code -eq 0 ]]; then
      echo "$output"
      return 0
    fi

    # Check if the error is a 429 rate limit
    if echo "$output" | grep -qi "429" && [[ $attempt -lt $VAULT_MAX_RETRIES ]]; then
      attempt=$((attempt + 1))
      local delay=$(( VAULT_RETRY_BASE_DELAY * (2 ** (attempt - 1)) ))
      # Cap delay at 60 seconds
      [[ $delay -gt 60 ]] && delay=60
      warn "  Rate limited (429), retry ${attempt}/${VAULT_MAX_RETRIES} in ${delay}s..."
      sleep "$delay"
      continue
    fi

    # Not a 429 or retries exhausted — return the error
    echo "$output" >&2
    return $exit_code
  done
}

# ── Vault CLI wrappers ───────────────────────────────────────────────────────

# Run vault list, return items (one per line) or exit 1 if empty/missing.
safe_list() {
  local path="$1"
  local out
  if ! out=$(vault list -format=json "$path" 2>/dev/null); then
    return 1
  fi
  if [[ "$out" == "null" || -z "$out" ]]; then
    return 1
  fi
  echo "$out" | jq -r '.[]'
  return 0
}

# Run vault read; if path exists, write pretty JSON to file.
safe_read_to_file() {
  local path="$1"
  local file="$2"
  local out
  if out=$(vault read -format=json "$path" 2>/dev/null); then
    echo "$out" | jq '.' > "$file"
    return 0
  fi
  return 1
}

# Fetch mount tune. Tries `vault auth tune` first (Vault 1.12+),
# then falls back to sys/auth/<path>/tune for older versions.
# Also works for secrets engine tunes via sys/mounts/<path>/tune.
read_tune_to_file() {
  local mount_path="$1"
  local file="$2"
  local mount_type="${3:-auth}"  # "auth" or "mounts"
  local out

  if [[ "$mount_type" == "auth" ]]; then
    # Try vault auth tune first
    if out=$(vault auth tune -format=json "$mount_path" 2>/dev/null); then
      echo "$out" | jq '.' > "$file"
      return 0
    fi
  fi

  # Fallback: read from sys/<mount_type>/<path>/tune
  local clean="${mount_path%/}/"
  local sys_path="sys/${mount_type}/${clean}tune"
  if out=$(vault read -format=json "$sys_path" 2>/dev/null); then
    echo "$out" | jq '.' > "$file"
    return 0
  fi
  return 1
}

# ── Collection export ────────────────────────────────────────────────────────
# List items at <base_path>/<collection>, then read each to <out_dir>/<collection>/<name>.json.
# Works for roles, users, groups, certs, keys, teams, providers, etc.
export_collection() {
  local base_path="$1"
  local collection="$2"
  local out_dir="$3"
  local items

  local list_path="${base_path}/${collection}"
  if items=$(safe_list "$list_path"); then
    local col_dir="${out_dir}/${collection}"
    mkdir -p "$col_dir"
    while IFS= read -r name; do
      local clean_name="${name%/}"
      local read_path="${list_path}/${clean_name}"
      local file="${col_dir}/${clean_name}.json"
      if safe_read_to_file "$read_path" "$file"; then
        info "  Exported ${read_path}"
        EXPORT_COUNT=$((EXPORT_COUNT + 1))
      else
        warn "  Could not read ${read_path}"
      fi
    done <<< "$items"
    return 0
  fi
  return 1
}

# ── Summary ──────────────────────────────────────────────────────────────────
print_summary() {
  local label="${1:-Operation}"
  echo ""
  echo "─────────────────────────────────────────"
  success "${label} complete."
  info "  Exported/Imported: ${EXPORT_COUNT:-0}"
  info "  Skipped:           ${SKIP_COUNT:-0}"
  if [[ "${WARN_COUNT:-0}" -gt 0 ]]; then
    warn "  Warnings:          ${WARN_COUNT}"
  fi
  _print_error_log_summary
  if [[ "${DRY_RUN}" == "true" ]]; then
    warn "  (DRY RUN — no changes were made)"
  fi
  echo "─────────────────────────────────────────"
}
