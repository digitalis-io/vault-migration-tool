#!/usr/bin/env bash
set -euo pipefail

# Import secrets engine mounts: enable engines, apply tune/config, create roles.
# Does NOT import secret data (use import-secrets.sh with medusa for that).
#
# Usage:
#   ./import-secrets-engines.sh --config <config.env> [--input-dir <dir>] [--dry-run] [--yes]
#
# Reads from:
#   <input-dir>/secrets-engines/
#     _mounts_list.json
#     <mount-path>/
#       _mount.json
#       tune.json
#       config.json
#       config_*.json
#       roles/, keys/, issuers/, static-roles/

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

parse_import_args "$@"
load_config "${CONFIG_FILE}"
require_tools vault jq
setup_import_dir

setup_error_log
ENGINES_DIR="${INPUT_DIR}/secrets-engines"

# System mounts to skip
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

# ── Import a collection of resources (roles, keys, etc.) ────────────────────
_import_collection() {
  local engine_path="$1"   # e.g., pki
  local collection="$2"    # e.g., roles
  local col_dir="$3"       # e.g., /path/to/secrets-engines/pki/roles

  [[ -d "$col_dir" ]] || return 0

  local file
  for file in "${col_dir}"/*.json; do
    [[ -f "$file" ]] || continue
    local name
    name=$(basename "$file" .json)
    local write_path="${engine_path}/${collection}/${name}"

    local payload
    payload=$(jq '.data // .' "$file")

    if [[ "${DRY_RUN}" == "true" ]]; then
      info "  [DRY-RUN] Would write: ${write_path}"
      SKIP_COUNT=$((SKIP_COUNT + 1))
      continue
    fi

    local vault_err
    if vault_err=$(echo "$payload" | vault_retry vault write "${write_path}" - 2>&1 >/dev/null); then
      info "  Imported: ${write_path}"
      IMPORT_COUNT=$((IMPORT_COUNT + 1))
    else
      warn "  Failed to write: ${write_path}"
      log_error "${write_path}" "${vault_err}"
    fi
  done
}

# ── Apply tune to a secrets engine mount ─────────────────────────────────────
_apply_tune() {
  local mount_path="$1"
  local tune_file="$2"

  [[ -f "$tune_file" ]] || return 0

  # vault secrets tune uses -flag=value syntax with dashes
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
    info "  [DRY-RUN] Would tune secrets engine: ${mount_path} (${args[*]})"
    return 0
  fi

  local vault_err
  if vault_err=$(vault_retry vault secrets tune "${args[@]}" "${mount_path}" 2>&1 >/dev/null); then
    info "  Applied tune to: ${mount_path}"
  else
    warn "  Failed to tune: ${mount_path}"
    log_error "secrets tune ${mount_path}" "${vault_err}"
  fi
}

# ── Write a config file to an engine endpoint ────────────────────────────────
_apply_config_file() {
  local write_path="$1"
  local config_file="$2"

  [[ -f "$config_file" ]] || return 0

  local payload
  payload=$(jq '.data // .' "$config_file")

  if [[ "${DRY_RUN}" == "true" ]]; then
    info "  [DRY-RUN] Would write config: ${write_path}"
    return 0
  fi

  local vault_err
  if vault_err=$(echo "$payload" | vault_retry vault write "${write_path}" - 2>&1 >/dev/null); then
    info "  Applied config: ${write_path}"
  else
    warn "  Failed to write config: ${write_path}"
    log_error "${write_path}" "${vault_err}"
  fi
}

# ── Main ─────────────────────────────────────────────────────────────────────
main() {
  if [[ ! -d "$ENGINES_DIR" ]]; then
    warn "Secrets engines export directory not found: ${ENGINES_DIR}"
    exit 1
  fi

  info "Importing secrets engines to: ${VAULT_ADDR}"

  if ! confirm_action "Import secrets engines to ${VAULT_ADDR}?"; then
    info "Aborted by user."
    exit 0
  fi

  # Get existing secrets mounts to avoid re-enabling
  local existing_mounts
  existing_mounts=$(vault secrets list -format=json 2>/dev/null | jq -r 'keys[]' || echo "")

  local mount_dir
  for mount_dir in "${ENGINES_DIR}"/*/; do
    [[ -d "$mount_dir" ]] || continue
    local mount_name
    mount_name=$(basename "$mount_dir")

    [[ "$mount_name" == _* ]] && continue

    # Skip mounts that don't match the --mount filter
    if [[ -n "$FILTER_MOUNT" ]]; then
      local filter_clean="${FILTER_MOUNT%/}"
      if [[ "$mount_name" != "$filter_clean" ]]; then
        SKIP_COUNT=$((SKIP_COUNT + 1))
        continue
      fi
    fi

    local mount_path="${mount_name}/"

    if _should_skip "$mount_path"; then
      info "Skipping system mount: ${mount_path}"
      SKIP_COUNT=$((SKIP_COUNT + 1))
      continue
    fi

    local mount_file="${mount_dir}/_mount.json"
    if [[ ! -f "$mount_file" ]]; then
      warn "No _mount.json for ${mount_path}, skipping."
      continue
    fi

    local engine_type options
    engine_type=$(jq -r '.type' "$mount_file")
    options=$(jq -r '.options // {} | to_entries | map("-options=\(.key)=\(.value)") | .[]' "$mount_file" 2>/dev/null || true)

    info "Secrets engine: ${mount_path} (type: ${engine_type})"

    # Enable the engine if it doesn't already exist
    if echo "$existing_mounts" | grep -qx "${mount_path}"; then
      info "  Mount already exists, skipping enable."
    else
      if [[ "${DRY_RUN}" == "true" ]]; then
        info "  [DRY-RUN] Would enable secrets engine: ${engine_type} at ${mount_path}"
      else
        local enable_args=(-path="${mount_name}")
        if [[ -n "$options" ]]; then
          while IFS= read -r opt; do
            enable_args+=("$opt")
          done <<< "$options"
        fi

        local vault_err
        if vault_err=$(vault_retry vault secrets enable "${enable_args[@]}" "${engine_type}" 2>&1 >/dev/null); then
          info "  Enabled secrets engine: ${mount_path}"
          IMPORT_COUNT=$((IMPORT_COUNT + 1))
        else
          error "  Failed to enable secrets engine: ${mount_path}"
          log_error "secrets enable ${mount_path}" "${vault_err}"
          continue
        fi
      fi
    fi

    # Apply tune
    _apply_tune "$mount_path" "${mount_dir}/tune.json"

    # Apply config files — generic config for all engines
    _apply_config_file "${mount_name}/config" "${mount_dir}/config.json"

    # Engine-specific config endpoints
    case "$engine_type" in
      pki)
        _apply_config_file "${mount_name}/config/urls" "${mount_dir}/config_urls.json"
        _apply_config_file "${mount_name}/config/crl" "${mount_dir}/config_crl.json"
        ;;
      aws|gcp)
        _apply_config_file "${mount_name}/config/root" "${mount_dir}/config_root.json"
        _apply_config_file "${mount_name}/config/lease" "${mount_dir}/config_lease.json"
        ;;
    esac

    # Import collections
    for collection in roles keys issuers static-roles; do
      _import_collection "${mount_name}" "$collection" "${mount_dir}/${collection}"
    done

  done

  print_summary "Secrets engine import"
}

main
