#!/usr/bin/env bash
set -euo pipefail

# Orchestrator: run all export scripts in order.
#
# Usage:
#   ./export-all.sh --config <config.env> [--output-dir <dir>] [--dry-run]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

# Pass all arguments through to each sub-script
ARGS=("$@")

# Validate args early (will be re-parsed by each script, but catch errors here)
parse_export_args "$@"
load_config "${CONFIG_FILE}"
setup_export_dir

SCRIPTS=(
  "${SCRIPT_DIR}/export-policies.sh"
  "${SCRIPT_DIR}/export-auth.sh"
  "${SCRIPT_DIR}/export-secrets-engines.sh"
  "${SCRIPT_DIR}/export-secrets.sh"
  "${SCRIPT_DIR}/export-audit.sh"
)

main() {
  info "═══════════════════════════════════════════════"
  info "  Vault Full Export — cluster: ${CLUSTER_NAME}"
  info "  Output: ${OUTPUT_DIR}"
  if [[ "${DRY_RUN}" == "true" ]]; then
    warn "  DRY RUN mode enabled"
  fi
  info "═══════════════════════════════════════════════"
  echo ""

  local failed=0

  for script in "${SCRIPTS[@]}"; do
    local name
    name=$(basename "$script" .sh)
    info "── Running: ${name} ──────────────────────────"

    if bash "$script" "${ARGS[@]}"; then
      success "  ${name} completed."
    else
      error "  ${name} FAILED (exit code: $?)."
      failed=$((failed + 1))
    fi
    echo ""
  done

  echo ""
  info "═══════════════════════════════════════════════"
  if [[ $failed -eq 0 ]]; then
    success "All exports completed successfully."
  else
    error "${failed} export script(s) failed."
    exit 1
  fi
  info "═══════════════════════════════════════════════"
}

main
