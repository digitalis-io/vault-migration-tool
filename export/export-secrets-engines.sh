#!/usr/bin/env bash
set -euo pipefail

# Export secrets engine mount definitions, tune, and per-engine configuration.
# Does NOT export secret data (use export-secrets.sh with medusa for that).
#
# Usage:
#   ./export-secrets-engines.sh --config <config.env> [--output-dir <dir>] [--dry-run]
#
# Output structure:
#   <output-dir>/secrets-engines/
#     _mounts_list.json
#     <mount-path>/
#       _mount.json
#       tune.json
#       config.json          # engine-specific config (if exists)
#       roles/               # for PKI, transit, SSH, etc.
#         <role>.json

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

parse_export_args "$@"
load_config "${CONFIG_FILE}"
require_tools vault jq
setup_export_dir

ENGINES_DIR="${OUTPUT_DIR}/secrets-engines"
mkdir -p "${ENGINES_DIR}"

# System mounts to skip (not user-configurable, not migrated)
SKIP_MOUNTS="sys/ identity/ cubbyhole/"

_should_skip() {
  local mount="$1"
  for skip in $SKIP_MOUNTS; do
    if [[ "$mount" == "$skip" ]]; then
      return 0
    fi
  done
  return 1
}

main() {
  info "Exporting secrets engine mounts to: ${ENGINES_DIR}"

  local mounts_json
  if ! mounts_json=$(vault secrets list -format=json); then
    error "Failed to list secrets engines. Check VAULT_ADDR/VAULT_TOKEN and permissions."
    exit 1
  fi

  # Save raw listing
  echo "$mounts_json" | jq '.' > "${ENGINES_DIR}/_mounts_list.json"

  echo "$mounts_json" | jq -r 'keys[]' | while read -r mount; do
    local local_mount="${mount%/}/"

    if _should_skip "$local_mount"; then
      info "Skipping system mount: ${local_mount}"
      SKIP_COUNT=$((SKIP_COUNT + 1))
      continue
    fi

    # Skip mounts that don't match the --mount filter
    if [[ -n "$FILTER_MOUNT" ]]; then
      local filter_clean="${FILTER_MOUNT%/}/"
      if [[ "$local_mount" != "$filter_clean" ]]; then
        SKIP_COUNT=$((SKIP_COUNT + 1))
        continue
      fi
    fi

    local mount_dir="${ENGINES_DIR}/${local_mount}"
    mkdir -p "$mount_dir"

    # Mount definition
    echo "$mounts_json" \
      | jq --arg m "$local_mount" '.[$m]' > "${mount_dir}/_mount.json"
    info "Secrets engine: ${local_mount}"
    EXPORT_COUNT=$((EXPORT_COUNT + 1))

    # Tune
    read_tune_to_file "$local_mount" "${mount_dir}/tune.json" "mounts" \
      || warn "  No tune info for ${local_mount}"

    # Generic config endpoint (PKI, SSH, transit, database, etc.)
    safe_read_to_file "${local_mount%/}/config" "${mount_dir}/config.json" \
      || true

    # PKI-specific: URLs, CRL, issuers, roles, keys
    safe_read_to_file "${local_mount%/}/config/urls" "${mount_dir}/config_urls.json" \
      || true
    safe_read_to_file "${local_mount%/}/config/crl" "${mount_dir}/config_crl.json" \
      || true
    export_collection "${local_mount%/}" "roles" "$mount_dir" \
      || true
    export_collection "${local_mount%/}" "issuers" "$mount_dir" \
      || true
    export_collection "${local_mount%/}" "keys" "$mount_dir" \
      || true

    # Transit: keys
    export_collection "${local_mount%/}" "keys" "$mount_dir" \
      || true

    # SSH: roles
    export_collection "${local_mount%/}" "roles" "$mount_dir" \
      || true

    # Database: config, roles, static-roles
    export_collection "${local_mount%/}/config" "" "$mount_dir" \
      || true
    export_collection "${local_mount%/}" "roles" "$mount_dir" \
      || true
    export_collection "${local_mount%/}" "static-roles" "$mount_dir" \
      || true

    # AWS/GCP secrets: roles, rolesets, config
    safe_read_to_file "${local_mount%/}/config/root" "${mount_dir}/config_root.json" \
      || true
    safe_read_to_file "${local_mount%/}/config/lease" "${mount_dir}/config_lease.json" \
      || true
    export_collection "${local_mount%/}" "roles" "$mount_dir" \
      || true
    export_collection "${local_mount%/}" "rolesets" "$mount_dir" \
      || true

  done

  print_summary "Secrets engine export"
}

main
