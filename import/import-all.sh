#!/usr/bin/env bash
set -euo pipefail

# Orchestrator: run all import scripts in the correct order.
#
# Import order (dependencies flow top-down):
#   1. policies        — ACL policies needed by auth roles
#   2. auth            — Auth methods reference policies
#   3. secrets-engines — Engine mounts (config only, no data)
#   4. secrets         — KV data via medusa (engines must exist first)
#   5. audit           — Audit devices (independent, run last)
#
# Usage:
#   ./import-all.sh --config <config.env> [--input-dir <dir>] [--dry-run] [--yes]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

# Pass all arguments through to each sub-script
ARGS=("$@")

# Validate args early
parse_import_args "$@"
load_config "${CONFIG_FILE}"
setup_import_dir

SCRIPTS=(
  "${SCRIPT_DIR}/import-policies.sh"
  "${SCRIPT_DIR}/import-auth.sh"
  "${SCRIPT_DIR}/import-secrets-engines.sh"
  "${SCRIPT_DIR}/import-secrets.sh"
  "${SCRIPT_DIR}/import-audit.sh"
)

main() {
  info "═══════════════════════════════════════════════"
  info "  Vault Full Import — target: ${VAULT_ADDR}"
  info "  Input: ${INPUT_DIR}"
  if [[ "${DRY_RUN}" == "true" ]]; then
    warn "  DRY RUN mode enabled"
  fi
  info "═══════════════════════════════════════════════"
  echo ""

  if ! confirm_action "Proceed with full import to ${VAULT_ADDR}?"; then
    info "Aborted by user."
    exit 0
  fi

  # Add --yes to sub-scripts since we already confirmed at the orchestrator level
  local sub_args=("${ARGS[@]}" "--yes")

  local failed=0

  for script in "${SCRIPTS[@]}"; do
    local name
    name=$(basename "$script" .sh)
    info "── Running: ${name} ──────────────────────────"

    if bash "$script" "${sub_args[@]}"; then
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
    success "All imports completed successfully."
  else
    error "${failed} import script(s) failed."
    exit 1
  fi
  info "═══════════════════════════════════════════════"
}

main
