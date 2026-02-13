#!/usr/bin/env bash
set -euo pipefail

# Export audit device configurations.
#
# Usage:
#   ./export-audit.sh --config <config.env> [--output-dir <dir>] [--dry-run]
#
# Output structure:
#   <output-dir>/audit/
#     _audit_devices.json    # full audit device listing

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

parse_export_args "$@"
load_config "${CONFIG_FILE}"
require_tools vault jq
setup_export_dir

AUDIT_DIR="${OUTPUT_DIR}/audit"
mkdir -p "${AUDIT_DIR}"

main() {
  info "Exporting audit devices to: ${AUDIT_DIR}"

  local audit_json
  if ! audit_json=$(vault audit list -format=json 2>/dev/null); then
    warn "Failed to list audit devices (may require sudo/root policy)."
    print_summary "Audit export"
    return 0
  fi

  # Check if any audit devices are enabled
  local count
  count=$(echo "$audit_json" | jq 'length')
  if [[ "$count" -eq 0 || "$audit_json" == "{}" ]]; then
    info "No audit devices enabled."
    print_summary "Audit export"
    return 0
  fi

  echo "$audit_json" | jq '.' > "${AUDIT_DIR}/_audit_devices.json"
  info "Exported ${count} audit device(s)"
  EXPORT_COUNT=$((EXPORT_COUNT + count))

  # Also save individual device configs for clarity
  echo "$audit_json" | jq -r 'keys[]' | while read -r device; do
    local clean="${device%/}"
    local safe_name="${clean//\//_}"
    echo "$audit_json" | jq --arg d "$device" '.[$d]' \
      > "${AUDIT_DIR}/${safe_name}.json"
    info "  Device: ${clean} (type: $(echo "$audit_json" | jq -r --arg d "$device" '.[$d].type'))"
  done

  print_summary "Audit export"
}

main
