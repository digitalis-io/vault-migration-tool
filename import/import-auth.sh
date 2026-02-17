#!/usr/bin/env bash
set -euo pipefail

# Import auth methods: enable mounts, apply tune/config, create roles/users/groups.
#
# Usage:
#   ./import-auth.sh --config <config.env> [--input-dir <dir>] [--dry-run] [--yes]
#
# Reads from:
#   <input-dir>/auth/
#     _auth_list.json
#     <mount-path>/
#       _mount.json
#       tune.json
#       config.json
#       roles/ | users/ | groups/ | certs/ | ...

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

parse_import_args "$@"
load_config "${CONFIG_FILE}"
require_tools vault jq
setup_import_dir

setup_error_log
AUTH_DIR="${INPUT_DIR}/auth"
USERPASS_TEMP_PASSWORD="${USERPASS_TEMP_PASSWORD:-TEMPORARY-CHANGE-ME}"

# ── Import a single collection (roles, users, groups, etc.) ─────────────────
_import_collection() {
  local auth_path="$1"    # e.g., auth/oidc
  local collection="$2"   # e.g., roles
  local col_dir="$3"      # e.g., /path/to/auth/oidc/roles
  local auth_type="${4:-}"  # optional: auth method type (e.g., userpass)

  [[ -d "$col_dir" ]] || return 0

  local file
  for file in "${col_dir}"/*.json; do
    [[ -f "$file" ]] || continue
    local name
    name=$(basename "$file" .json)
    local write_path="${auth_path}/${collection}/${name}"

    # Extract .data from the exported JSON (vault read wraps in .data)
    local payload
    payload=$(jq '.data // .' "$file")

    # Special handling for userpass users: Vault requires a password when creating
    # users, but passwords are not exported (Vault never exposes them).
    # We set a temporary password and warn the user to reset it.
    if [[ "$auth_type" == "userpass" && "$collection" == "users" ]]; then
      payload=$(echo "$payload" | jq --arg pw "$USERPASS_TEMP_PASSWORD" '. + {password: $pw}')
    fi

    # AppRole roles: strip read-only fields that Vault rejects on write.
    # local_secret_ids can only be set at role creation time and is not
    # accepted as a parameter on the write endpoint.
    if [[ "$auth_type" == "approle" && ( "$collection" == "roles" || "$collection" == "role" ) ]]; then
      payload=$(echo "$payload" | jq 'del(.local_secret_ids)')
    fi

    # Kubernetes roles: strip alias_name_source if empty/invalid.
    # Vault exports this field with an empty string but rejects it on write
    # (must be "serviceaccount_uid" or "serviceaccount_name").
    if [[ "$auth_type" == "kubernetes" && ( "$collection" == "roles" || "$collection" == "role" ) ]]; then
      payload=$(echo "$payload" | jq 'if .alias_name_source == "" or .alias_name_source == null then del(.alias_name_source) else . end')
    fi

    if [[ "${DRY_RUN}" == "true" ]]; then
      info "  [DRY-RUN] Would write: ${write_path}"
      SKIP_COUNT=$((SKIP_COUNT + 1))
      continue
    fi

    local vault_err
    if vault_err=$(echo "$payload" | vault write "${write_path}" - 2>&1 >/dev/null); then
      info "  Imported: ${write_path}"
      IMPORT_COUNT=$((IMPORT_COUNT + 1))
      # Warn about temporary password for userpass users
      if [[ "$auth_type" == "userpass" && "$collection" == "users" ]]; then
        warn "  User '${name}' imported with temporary password - MUST be reset!"
      fi
    else
      warn "  Failed to write: ${write_path}"
      log_error "${write_path}" "${vault_err}"
    fi
  done
}

# ── Restore AppRole role_ids ────────────────────────────────────────────────
# After creating AppRole roles, restore the original role_id so that
# applications using them continue to work without changes.
_restore_approle_role_ids() {
  local auth_path="$1"    # e.g., auth/approle-test
  local roles_dir="$2"    # e.g., /path/to/auth/approle-test/roles

  [[ -d "$roles_dir" ]] || return 0

  local role_id_file
  for role_id_file in "${roles_dir}"/*.role_id.json; do
    [[ -f "$role_id_file" ]] || continue
    local role_name
    role_name=$(basename "$role_id_file" .role_id.json)
    local original_role_id
    original_role_id=$(jq -r '.data.role_id // .role_id // empty' "$role_id_file")

    if [[ -z "$original_role_id" ]]; then
      warn "  No role_id found in ${role_id_file}, skipping"
      continue
    fi

    if [[ "${DRY_RUN}" == "true" ]]; then
      info "  [DRY-RUN] Would restore role_id for ${role_name}"
      continue
    fi

    local vault_err
    if vault_err=$(vault write "${auth_path}/role/${role_name}/role-id" role_id="${original_role_id}" 2>&1 >/dev/null); then
      info "  Restored role_id for AppRole role: ${role_name}"
    else
      warn "  Failed to restore role_id for: ${role_name}"
      log_error "${auth_path}/role/${role_name}/role-id" "${vault_err}"
    fi
  done
}

# ── Apply tune settings ─────────────────────────────────────────────────────
_apply_tune() {
  local mount_path="$1"   # e.g., oidc/
  local tune_file="$2"

  [[ -f "$tune_file" ]] || return 0

  # Extract tunable fields from the exported tune JSON
  # vault auth tune uses -flag=value syntax with dashes
  local args=()
  local val

  val=$(jq -r '.data.default_lease_ttl // .default_lease_ttl // empty' "$tune_file" 2>/dev/null)
  [[ -n "$val" && "$val" != "0" ]] && args+=("-default-lease-ttl=${val}")

  val=$(jq -r '.data.max_lease_ttl // .max_lease_ttl // empty' "$tune_file" 2>/dev/null)
  [[ -n "$val" && "$val" != "0" ]] && args+=("-max-lease-ttl=${val}")

  val=$(jq -r '.data.description // .description // empty' "$tune_file" 2>/dev/null)
  [[ -n "$val" ]] && args+=("-description=${val}")

  if [[ ${#args[@]} -eq 0 ]]; then
    return 0
  fi

  if [[ "${DRY_RUN}" == "true" ]]; then
    info "  [DRY-RUN] Would tune auth mount: ${mount_path} (${args[*]})"
    return 0
  fi

  local vault_err
  if vault_err=$(vault auth tune "${args[@]}" "${mount_path}" 2>&1 >/dev/null); then
    info "  Applied tune to: ${mount_path}"
  else
    warn "  Failed to tune: ${mount_path}"
    log_error "auth tune ${mount_path}" "${vault_err}"
  fi
}

# ── Apply config ─────────────────────────────────────────────────────────────
_apply_config() {
  local auth_path="$1"    # e.g., auth/oidc
  local config_file="$2"

  [[ -f "$config_file" ]] || return 0

  local payload
  payload=$(jq '.data // .' "$config_file")

  if [[ "${DRY_RUN}" == "true" ]]; then
    info "  [DRY-RUN] Would write config: ${auth_path}/config"
    return 0
  fi

  local vault_err
  if vault_err=$(echo "$payload" | vault write "${auth_path}/config" - 2>&1 >/dev/null); then
    info "  Applied config to: ${auth_path}/config"
  else
    warn "  Failed to write config: ${auth_path}/config"
    log_error "${auth_path}/config" "${vault_err}"
  fi
}

# ── Main ─────────────────────────────────────────────────────────────────────
main() {
  if [[ ! -d "$AUTH_DIR" ]]; then
    warn "Auth export directory not found: ${AUTH_DIR}"
    exit 1
  fi

  info "Importing auth methods to: ${VAULT_ADDR}"

  if ! confirm_action "Import auth methods to ${VAULT_ADDR}?"; then
    info "Aborted by user."
    exit 0
  fi

  # Get existing auth mounts to avoid re-enabling
  local existing_mounts
  existing_mounts=$(vault auth list -format=json 2>/dev/null | jq -r 'keys[]' || echo "")

  # Iterate over exported mount directories
  local mount_dir
  for mount_dir in "${AUTH_DIR}"/*/; do
    [[ -d "$mount_dir" ]] || continue
    local mount_name
    mount_name=$(basename "$mount_dir")

    # Skip underscore-prefixed files (like _auth_list.json directory wouldn't exist, but guard)
    [[ "$mount_name" == _* ]] && continue

    local mount_path="${mount_name}/"
    local mount_file="${mount_dir}/_mount.json"

    if [[ ! -f "$mount_file" ]]; then
      warn "No _mount.json for ${mount_path}, skipping."
      continue
    fi

    local auth_type
    auth_type=$(jq -r '.type' "$mount_file")
    info "Auth mount: ${mount_path} (type: ${auth_type})"

    # Enable the auth mount if it doesn't already exist
    if echo "$existing_mounts" | grep -qx "${mount_path}"; then
      info "  Mount already exists, skipping enable."
    else
      if [[ "${DRY_RUN}" == "true" ]]; then
        info "  [DRY-RUN] Would enable auth: ${auth_type} at ${mount_path}"
      else
        local vault_err
        if vault_err=$(vault auth enable -path="${mount_name}" "${auth_type}" 2>&1 >/dev/null); then
          info "  Enabled auth mount: ${mount_path}"
          IMPORT_COUNT=$((IMPORT_COUNT + 1))
        else
          error "  Failed to enable auth mount: ${mount_path}"
          log_error "auth enable ${mount_path}" "${vault_err}"
          continue
        fi
      fi
    fi

    # Apply tune
    _apply_tune "$mount_path" "${mount_dir}/tune.json"

    # Apply config
    _apply_config "auth/${mount_name}" "${mount_dir}/config.json"

    # Apply client config (AWS/GCP/Azure)
    if [[ -f "${mount_dir}/config_client.json" ]]; then
      local payload
      payload=$(jq '.data // .' "${mount_dir}/config_client.json")
      if [[ "${DRY_RUN}" == "true" ]]; then
        info "  [DRY-RUN] Would write: auth/${mount_name}/config/client"
      else
        local vault_err
        if ! vault_err=$(echo "$payload" | vault write "auth/${mount_name}/config/client" - 2>&1 >/dev/null); then
          warn "  Failed to write config/client for ${mount_path}"
          log_error "auth/${mount_name}/config/client" "${vault_err}"
        fi
      fi
    fi

    # Import collections (roles, users, groups, certs, teams, providers, keys)
    for collection in roles role users groups certs teams providers keys; do
      _import_collection "auth/${mount_name}" "$collection" "${mount_dir}/${collection}" "$auth_type"
    done

    # AppRole: restore original role_ids so applications keep working
    if [[ "$auth_type" == "approle" ]]; then
      _restore_approle_role_ids "auth/${mount_name}" "${mount_dir}/roles"
      _restore_approle_role_ids "auth/${mount_name}" "${mount_dir}/role"
    fi

    # LDAP legacy map/* collections
    for collection in users groups roles; do
      if [[ -d "${mount_dir}/map/${collection}" ]]; then
        _import_collection "auth/${mount_name}/map" "$collection" "${mount_dir}/map/${collection}" "$auth_type"
      fi
    done

  done

  print_summary "Auth import"
}

main
