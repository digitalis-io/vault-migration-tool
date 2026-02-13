#!/usr/bin/env bash
set -euo pipefail

# Export KV secret data using medusa.
# Discovers all KV v1/v2 mounts and exports each to a separate JSON file.
#
# Usage:
#   ./export-secrets.sh --config <config.env> [--output-dir <dir>] [--dry-run]
#
# Output structure:
#   <output-dir>/secrets/
#     <mount-path>.json      # medusa export per KV engine

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

parse_export_args "$@"
load_config "${CONFIG_FILE}"
require_tools vault jq medusa
setup_export_dir

SECRETS_DIR="${OUTPUT_DIR}/secrets"
mkdir -p "${SECRETS_DIR}"

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
  info "Exporting KV secrets via medusa to: ${SECRETS_DIR}"

  local mounts_json
  if ! mounts_json=$(vault secrets list -format=json); then
    error "Failed to list secrets engines."
    exit 1
  fi

  # Filter to KV v1 and KV v2 mounts only
  local kv_mounts
  kv_mounts=$(echo "$mounts_json" | jq -r '
    to_entries[]
    | select(.value.type == "kv" or .value.type == "generic")
    | .key
  ')

  if [[ -z "$kv_mounts" ]]; then
    warn "No KV secrets engines found."
    print_summary "Secrets export"
    return 0
  fi

  while read -r mount; do
    local local_mount="${mount%/}"
    # Sanitise mount path for filename (replace / with _)
    local safe_name="${local_mount//\//_}"
    local output_file="${SECRETS_DIR}/${safe_name}.json"

    info "Exporting KV mount: ${local_mount}"

    if [[ "${DRY_RUN}" == "true" ]]; then
      info "  [DRY-RUN] Would run: medusa export ${local_mount}"
      SKIP_COUNT=$((SKIP_COUNT + 1))
      continue
    fi

    # shellcheck disable=SC2046
    if medusa export "$local_mount" \
        --format json \
        --output "$output_file" \
        $(_medusa_flags) 2>/dev/null; then
      info "  Exported to: ${output_file}"
      EXPORT_COUNT=$((EXPORT_COUNT + 1))
    else
      warn "  Failed to export KV mount: ${local_mount}"
    fi
  done <<< "$kv_mounts"

  print_summary "Secrets export (medusa)"
}

main
