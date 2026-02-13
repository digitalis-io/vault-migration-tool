#!/usr/bin/env bash
set -euo pipefail

# Import ACL policies (and EGP/RGP sentinel policies for Enterprise).
#
# Usage:
#   ./import-policies.sh --config <config.env> [--input-dir <dir>] [--dry-run] [--yes]
#
# Reads from:
#   <input-dir>/policies/
#     acl/<policy-name>.hcl
#     egp/<policy-name>.json
#     rgp/<policy-name>.json

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

parse_import_args "$@"
load_config "${CONFIG_FILE}"
require_tools vault jq
setup_import_dir

POLICIES_DIR="${INPUT_DIR}/policies"

# ── ACL Policies ─────────────────────────────────────────────────────────────
import_acl_policies() {
  local acl_dir="${POLICIES_DIR}/acl"
  if [[ ! -d "$acl_dir" ]]; then
    info "No ACL policies directory found, skipping."
    return 0
  fi

  info "Importing ACL policies from: ${acl_dir}"

  local file
  for file in "${acl_dir}"/*.hcl; do
    [[ -f "$file" ]] || continue
    local name
    name=$(basename "$file" .hcl)

    if [[ "${DRY_RUN}" == "true" ]]; then
      info "  [DRY-RUN] Would write ACL policy: ${name}"
      SKIP_COUNT=$((SKIP_COUNT + 1))
      continue
    fi

    if vault policy write "$name" "$file" >/dev/null 2>&1; then
      info "  Imported ACL policy: ${name}"
      IMPORT_COUNT=$((IMPORT_COUNT + 1))
    else
      warn "  Failed to write ACL policy: ${name}"
    fi
  done
}

# ── EGP Sentinel Policies (Enterprise) ──────────────────────────────────────
import_egp_policies() {
  local egp_dir="${POLICIES_DIR}/egp"
  if [[ ! -d "$egp_dir" ]]; then
    return 0
  fi

  info "Importing EGP sentinel policies from: ${egp_dir}"

  local file
  for file in "${egp_dir}"/*.json; do
    [[ -f "$file" ]] || continue
    local name
    name=$(basename "$file" .json)

    # Extract fields from exported JSON
    local enforcement_level paths policy_b64
    enforcement_level=$(jq -r '.data.enforcement_level // "soft-mandatory"' "$file")
    paths=$(jq -r '.data.paths | join(",")' "$file" 2>/dev/null || echo "*")
    policy_b64=$(jq -r '.data.policy' "$file")

    if [[ "${DRY_RUN}" == "true" ]]; then
      info "  [DRY-RUN] Would write EGP policy: ${name}"
      SKIP_COUNT=$((SKIP_COUNT + 1))
      continue
    fi

    if vault write "sys/policies/egp/${name}" \
        policy="${policy_b64}" \
        paths="${paths}" \
        enforcement_level="${enforcement_level}" >/dev/null 2>&1; then
      info "  Imported EGP policy: ${name}"
      IMPORT_COUNT=$((IMPORT_COUNT + 1))
    else
      warn "  Failed to write EGP policy: ${name}"
    fi
  done
}

# ── RGP Sentinel Policies (Enterprise) ──────────────────────────────────────
import_rgp_policies() {
  local rgp_dir="${POLICIES_DIR}/rgp"
  if [[ ! -d "$rgp_dir" ]]; then
    return 0
  fi

  info "Importing RGP sentinel policies from: ${rgp_dir}"

  local file
  for file in "${rgp_dir}"/*.json; do
    [[ -f "$file" ]] || continue
    local name
    name=$(basename "$file" .json)

    local enforcement_level policy_b64
    enforcement_level=$(jq -r '.data.enforcement_level // "soft-mandatory"' "$file")
    policy_b64=$(jq -r '.data.policy' "$file")

    if [[ "${DRY_RUN}" == "true" ]]; then
      info "  [DRY-RUN] Would write RGP policy: ${name}"
      SKIP_COUNT=$((SKIP_COUNT + 1))
      continue
    fi

    if vault write "sys/policies/rgp/${name}" \
        policy="${policy_b64}" \
        enforcement_level="${enforcement_level}" >/dev/null 2>&1; then
      info "  Imported RGP policy: ${name}"
      IMPORT_COUNT=$((IMPORT_COUNT + 1))
    else
      warn "  Failed to write RGP policy: ${name}"
    fi
  done
}

# ── Main ─────────────────────────────────────────────────────────────────────
main() {
  info "Importing policies to: ${VAULT_ADDR}"

  if ! confirm_action "Import policies to ${VAULT_ADDR}?"; then
    info "Aborted by user."
    exit 0
  fi

  import_acl_policies
  import_egp_policies
  import_rgp_policies
  print_summary "Policy import"
}

main
