#!/usr/bin/env bash
set -euo pipefail

# Export all enabled auth methods with configurations and sub-resources.
#
# Usage:
#   ./export-auth.sh --config <config.env> [--output-dir <dir>] [--dry-run]
#
# Output structure:
#   <output-dir>/auth/
#     _auth_list.json
#     <mount-path>/
#       _mount.json          # mount definition (type, accessor, options)
#       tune.json            # mount tune (TTLs, audit settings)
#       config.json          # generic auth config (if endpoint exists)
#       config_client.json   # AWS/GCP/Azure client config (if exists)
#       <collection>/        # roles/, users/, groups/, certs/, ...
#         <item>.json

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

parse_export_args "$@"
load_config "${CONFIG_FILE}"
require_tools vault jq
setup_export_dir

AUTH_DIR="${OUTPUT_DIR}/auth"
mkdir -p "${AUTH_DIR}"

main() {
  info "Exporting auth mounts to: ${AUTH_DIR}"

  local auth_json
  if ! auth_json=$(vault auth list -format=json); then
    error "Failed to list auth methods. Check VAULT_ADDR/VAULT_TOKEN and permissions."
    exit 1
  fi

  # Save the full raw listing for reference
  echo "$auth_json" | jq '.' > "${AUTH_DIR}/_auth_list.json"

  local mount_count=0

  echo "$auth_json" | jq -r 'keys[]' | while read -r mount; do
    local local_mount="${mount%/}/"

    # Skip the built-in token/ auth mount (not migrated)
    if [[ "$local_mount" == "token/" ]]; then
      warn "Skipping built-in token/ auth mount"
      SKIP_COUNT=$((SKIP_COUNT + 1))
      continue
    fi

    local mount_dir="${AUTH_DIR}/${local_mount}"
    mkdir -p "$mount_dir"

    # Mount definition (type, accessor, etc.)
    echo "$auth_json" \
      | jq --arg m "$local_mount" '.[$m]' > "${mount_dir}/_mount.json"
    info "Auth mount: ${local_mount}"

    # Tune (TTLs, audit_non_hmac_request_keys, etc.)
    read_tune_to_file "$local_mount" "${mount_dir}/tune.json" "auth" \
      || warn "  No tune info for ${local_mount}"

    # Generic config (many auth methods support /config)
    safe_read_to_file "auth/${local_mount}config" "${mount_dir}/config.json" \
      || true

    # ── Probe common sub-resources per auth method type ──────────────────
    # We intentionally try multiple collection names. Only matching ones
    # will succeed; the rest silently fail. This is forgiving across
    # Vault versions and auth method types.

    # Roles (oidc/jwt/aws/gcp/azure/approle/kubernetes/github)
    # Try both plural and singular endpoints — some auth methods use "roles",
    # others use "role". Export whichever succeeds (or both if they differ).
    export_collection "auth/${local_mount%/}" "roles" "$mount_dir" || true
    export_collection "auth/${local_mount%/}" "role" "$mount_dir" || true

    # AppRole: export role_id for each role so it can be preserved on import.
    # The role_id lives at a separate endpoint and is not included in the role config.
    local mount_type
    mount_type=$(echo "$auth_json" | jq -r --arg m "$local_mount" '.[$m].type')
    if [[ "$mount_type" == "approle" ]]; then
      local roles_dir
      for roles_dir in "${mount_dir}/roles" "${mount_dir}/role"; do
        [[ -d "$roles_dir" ]] || continue
        local role_file
        for role_file in "${roles_dir}/"*.json; do
          [[ -f "$role_file" ]] || continue
          local role_name
          role_name=$(basename "$role_file" .json)
          safe_read_to_file "auth/${local_mount%/}/role/${role_name}/role-id" \
            "${roles_dir}/${role_name}.role_id.json" \
            || warn "  Could not read role_id for AppRole role: ${role_name}"
        done
      done
    fi

    # Users (userpass, github)
    export_collection "auth/${local_mount%/}" "users" "$mount_dir" \
      || true

    # Groups (ldap)
    export_collection "auth/${local_mount%/}" "groups" "$mount_dir" \
      || true

    # Cert auth: certs
    export_collection "auth/${local_mount%/}" "certs" "$mount_dir" \
      || true

    # LDAP legacy map/* endpoints
    export_collection "auth/${local_mount%/}/map" "users" "$mount_dir" \
      || true
    export_collection "auth/${local_mount%/}/map" "groups" "$mount_dir" \
      || true
    export_collection "auth/${local_mount%/}/map" "roles" "$mount_dir" \
      || true

    # GitHub: teams
    export_collection "auth/${local_mount%/}" "teams" "$mount_dir" \
      || true

    # OIDC/JWT: providers, keys
    export_collection "auth/${local_mount%/}" "providers" "$mount_dir" \
      || true
    export_collection "auth/${local_mount%/}" "keys" "$mount_dir" \
      || true

    # AWS/GCP/Azure: client config (separate from generic /config)
    safe_read_to_file "auth/${local_mount%/}/config/client" "${mount_dir}/config_client.json" \
      || true

    mount_count=$((mount_count + 1))
  done

  print_summary "Auth export"
}

main
