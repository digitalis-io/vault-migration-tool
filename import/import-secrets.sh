#!/usr/bin/env bash
set -euo pipefail

# Import KV secret data using medusa.
# Reads medusa JSON export files and imports into corresponding KV mounts.
#
# Usage:
#   ./import-secrets.sh --config <config.env> [--input-dir <dir>] [--dry-run] [--yes]
#
# Reads from:
#   <input-dir>/secrets/
#     <mount-path>.json      # medusa export per KV engine

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

parse_import_args "$@"
load_config "${CONFIG_FILE}"
require_tools vault jq medusa
setup_import_dir

SECRETS_DIR="${INPUT_DIR}/secrets"

# Build medusa flags from config
_medusa_flags() {
  local flags=()
  local addr="${MEDUSA_ADDR:-${VAULT_ADDR}}"
  flags+=(--address "$addr")
  flags+=(--token "$VAULT_TOKEN")
  if [[ "${MEDUSA_INSECURE:-false}" == "true" ]]; then
    flags+=(--insecure)
  fi
  echo "${flags[@]}"
}

main() {
  if [[ ! -d "$SECRETS_DIR" ]]; then
    warn "Secrets export directory not found: ${SECRETS_DIR}"
    print_summary "Secrets import"
    return 0
  fi

  info "Importing KV secrets via medusa to: ${VAULT_ADDR}"

  if ! confirm_action "Import secrets to ${VAULT_ADDR}? This will overwrite existing secret values."; then
    info "Aborted by user."
    exit 0
  fi

  local file
  for file in "${SECRETS_DIR}"/*.json; do
    [[ -f "$file" ]] || continue

    local filename
    filename=$(basename "$file" .json)
    # Reverse the filename sanitisation (underscores back to slashes)
    local mount_path="${filename//_//}"

    # Skip mounts that don't match the --mount filter
    if [[ -n "$FILTER_MOUNT" ]]; then
      local filter_clean="${FILTER_MOUNT%/}"
      if [[ "$mount_path" != "$filter_clean" ]]; then
        SKIP_COUNT=$((SKIP_COUNT + 1))
        continue
      fi
    fi

    info "Importing KV mount: ${mount_path}"

    if [[ "${DRY_RUN}" == "true" ]]; then
      info "  [DRY-RUN] Would run: medusa import ${mount_path} ${file}"
      SKIP_COUNT=$((SKIP_COUNT + 1))
      continue
    fi

    # shellcheck disable=SC2046
    if medusa import "$mount_path" "$file" \
        $(_medusa_flags) 2>/dev/null; then
      info "  Imported: ${mount_path}"
      IMPORT_COUNT=$((IMPORT_COUNT + 1))
    else
      warn "  Failed to import KV mount: ${mount_path}"
    fi
  done

  print_summary "Secrets import (medusa)"
}

main
