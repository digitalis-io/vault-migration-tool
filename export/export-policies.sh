#!/usr/bin/env bash
set -euo pipefail

# Export all Vault ACL policies (and EGP/RGP sentinel policies for Enterprise).
#
# Usage:
#   ./export-policies.sh --config <config.env> [--output-dir <dir>] [--dry-run]
#
# Output structure:
#   <output-dir>/policies/
#     acl/
#       <policy-name>.hcl
#     egp/                    # Enterprise only
#       <policy-name>.json
#     rgp/                    # Enterprise only
#       <policy-name>.json

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

parse_export_args "$@"
load_config "${CONFIG_FILE}"
require_tools vault jq
setup_export_dir

POLICIES_DIR="${OUTPUT_DIR}/policies"

# ── ACL Policies ─────────────────────────────────────────────────────────────
export_acl_policies() {
  local acl_dir="${POLICIES_DIR}/acl"
  mkdir -p "$acl_dir"

  info "Exporting ACL policies..."

  local policies
  if ! policies=$(vault policy list -format=json 2>/dev/null); then
    error "Failed to list ACL policies."
    return 1
  fi

  local name
  echo "$policies" | jq -r '.[]' | while read -r name; do
    # Skip the built-in default and root policies
    if [[ "$name" == "default" || "$name" == "root" ]]; then
      info "  Skipping built-in policy: ${name}"
      SKIP_COUNT=$((SKIP_COUNT + 1))
      continue
    fi

    # Sanitise slashes in policy names for safe filenames
    local safe_name="${name//\//%2F}"
    local file="${acl_dir}/${safe_name}.hcl"
    if vault policy read "$name" > "$file" 2>/dev/null; then
      info "  Exported ACL policy: ${name}"
      EXPORT_COUNT=$((EXPORT_COUNT + 1))
    else
      warn "  Could not read ACL policy: ${name}"
    fi
  done
}

# ── EGP Sentinel Policies (Enterprise) ──────────────────────────────────────
export_egp_policies() {
  local egp_dir="${POLICIES_DIR}/egp"

  local policies
  if ! policies=$(vault list -format=json sys/policies/egp 2>/dev/null); then
    info "No EGP sentinel policies (or not Enterprise)."
    return 0
  fi

  mkdir -p "$egp_dir"
  info "Exporting EGP sentinel policies..."

  local name
  echo "$policies" | jq -r '.[]' | while read -r name; do
    local clean_name="${name%/}"
    local safe_name="${clean_name//\//%2F}"
    local file="${egp_dir}/${safe_name}.json"
    if safe_read_to_file "sys/policies/egp/${clean_name}" "$file"; then
      info "  Exported EGP policy: ${clean_name}"
      EXPORT_COUNT=$((EXPORT_COUNT + 1))
    else
      warn "  Could not read EGP policy: ${clean_name}"
    fi
  done
}

# ── RGP Sentinel Policies (Enterprise) ──────────────────────────────────────
export_rgp_policies() {
  local rgp_dir="${POLICIES_DIR}/rgp"

  local policies
  if ! policies=$(vault list -format=json sys/policies/rgp 2>/dev/null); then
    info "No RGP sentinel policies (or not Enterprise)."
    return 0
  fi

  mkdir -p "$rgp_dir"
  info "Exporting RGP sentinel policies..."

  local name
  echo "$policies" | jq -r '.[]' | while read -r name; do
    local clean_name="${name%/}"
    local safe_name="${clean_name//\//%2F}"
    local file="${rgp_dir}/${safe_name}.json"
    if safe_read_to_file "sys/policies/rgp/${clean_name}" "$file"; then
      info "  Exported RGP policy: ${clean_name}"
      EXPORT_COUNT=$((EXPORT_COUNT + 1))
    else
      warn "  Could not read RGP policy: ${clean_name}"
    fi
  done
}

# ── Main ─────────────────────────────────────────────────────────────────────
main() {
  info "Exporting policies to: ${POLICIES_DIR}"
  export_acl_policies
  export_egp_policies
  export_rgp_policies
  print_summary "Policy export"
}

main
