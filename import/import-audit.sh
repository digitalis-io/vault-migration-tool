#!/usr/bin/env bash
set -euo pipefail

# Import audit device configurations.
#
# Usage:
#   ./import-audit.sh --config <config.env> [--input-dir <dir>] [--dry-run] [--yes]
#
# Reads from:
#   <input-dir>/audit/
#     _audit_devices.json

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

parse_import_args "$@"
load_config "${CONFIG_FILE}"
require_tools vault jq
setup_import_dir

setup_error_log
AUDIT_DIR="${INPUT_DIR}/audit"

main() {
  local devices_file="${AUDIT_DIR}/_audit_devices.json"
  if [[ ! -f "$devices_file" ]]; then
    info "No audit devices export found, skipping."
    print_summary "Audit import"
    return 0
  fi

  info "Importing audit devices to: ${VAULT_ADDR}"

  if ! confirm_action "Import audit devices to ${VAULT_ADDR}?"; then
    info "Aborted by user."
    exit 0
  fi

  # Get existing audit devices
  local existing
  existing=$(vault audit list -format=json 2>/dev/null | jq -r 'keys[]' || echo "")

  local devices
  devices=$(jq -r 'keys[]' "$devices_file")

  if [[ -z "$devices" ]]; then
    info "No audit devices to import."
    print_summary "Audit import"
    return 0
  fi

  while read -r device; do
    local clean="${device%/}"
    local device_type
    device_type=$(jq -r --arg d "$device" '.[$d].type' "$devices_file")

    # Check if already exists
    if echo "$existing" | grep -qx "${device}"; then
      info "  Audit device already exists: ${clean}, skipping."
      SKIP_COUNT=$((SKIP_COUNT + 1))
      continue
    fi

    # Build options from the exported config
    local options_json
    options_json=$(jq -r --arg d "$device" '.[$d].options // {}' "$devices_file")
    local options_args=()

    while IFS='=' read -r key val; do
      [[ -n "$key" ]] && options_args+=("${key}=${val}")
    done < <(echo "$options_json" | jq -r 'to_entries[] | "\(.key)=\(.value)"')

    if [[ "${DRY_RUN}" == "true" ]]; then
      info "  [DRY-RUN] Would enable audit device: ${clean} (type: ${device_type})"
      SKIP_COUNT=$((SKIP_COUNT + 1))
      continue
    fi

    local enable_args=(-path="${clean}" -type="${device_type}")
    for opt in "${options_args[@]}"; do
      enable_args+=("$opt")
    done

    local vault_err
    if vault_err=$(vault audit enable "${enable_args[@]}" 2>&1 >/dev/null); then
      info "  Enabled audit device: ${clean} (type: ${device_type})"
      IMPORT_COUNT=$((IMPORT_COUNT + 1))
    else
      warn "  Failed to enable audit device: ${clean}"
      log_error "audit enable ${clean}" "${vault_err}"
    fi
  done <<< "$devices"

  print_summary "Audit import"
}

main
