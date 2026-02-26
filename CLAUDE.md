# Vault Migration Tool

## Purpose

A set of Bash scripts to **export** HashiCorp Vault configurations and secrets from a source cluster and **import** them into a destination cluster. Uses [medusa](https://github.com/jonasvinther/medusa) for bulk KV secret data transfer.

---

## Project Structure

```
vault-migration-tool/
├── CLAUDE.md                        # This file — project plan & dev conventions
├── config/
│   ├── source.env.example           # Source cluster config template
│   └── destination.env.example      # Destination cluster config template
├── lib/
│   └── common.sh                    # Shared functions (logging, vault helpers, config)
├── export/
│   ├── export-all.sh                # Orchestrator: runs all export scripts in order
│   ├── export-auth.sh               # Export auth methods, roles, groups, users
│   ├── export-policies.sh           # Export ACL policies (+ EGP/RGP for Enterprise)
│   ├── export-secrets-engines.sh    # Export secrets engine mounts & config (not data)
│   ├── export-secrets.sh            # Export KV secret data via medusa
│   └── export-audit.sh             # Export audit device configurations
├── import/
│   ├── import-all.sh                # Orchestrator: runs all import scripts in order
│   ├── import-auth.sh               # Import auth methods, roles, groups, users
│   ├── import-policies.sh           # Import ACL policies (+ EGP/RGP for Enterprise)
│   ├── import-secrets-engines.sh    # Import/enable secrets engines with config
│   ├── import-secrets.sh            # Import KV secret data via medusa
│   └── import-audit.sh             # Import audit device configurations
└── data/                            # Default export output (gitignored)
    └── <cluster-name>/              # Named per source cluster CLUSTER_NAME
```

---

## Configuration

Each cluster (source and destination) has its own `.env` config file sourced by the scripts.

```bash
# config/source.env
VAULT_ADDR="https://source-vault.example.com:8200"
VAULT_TOKEN="hvs.xxxxx"              # Can also be inherited from environment
VAULT_NAMESPACE=""                    # Enterprise namespace (optional)
VAULT_SKIP_VERIFY="false"            # Set "true" to skip TLS verification
VAULT_CACERT=""                       # Path to custom CA cert (optional)
CLUSTER_NAME="source-prod"           # Used for export directory naming
MEDUSA_ADDR=""                        # Override for medusa (defaults to VAULT_ADDR)
MEDUSA_INSECURE="false"              # Set "true" for medusa --insecure
```

Config files with real credentials (`config/*.env`) are gitignored. Only `.example` templates are committed.

---

## Export Data Layout

All exported data lands under `data/<CLUSTER_NAME>/`:

```
data/<cluster-name>/
├── auth/
│   ├── _auth_list.json              # Full raw auth mount listing
│   └── <mount-path>/                # e.g., oidc/, approle/, ldap/
│       ├── _mount.json              # Mount definition (type, accessor, options)
│       ├── tune.json                # Mount tune (TTLs, audit settings)
│       ├── config.json              # Auth method config endpoint
│       └── roles/ | users/ | groups/ | certs/ | ...
│           └── <name>.json          # Individual resource
├── policies/
│   ├── acl/
│   │   └── <policy-name>.hcl       # ACL policies in HCL format
│   └── egp/                         # Enterprise only: EGP sentinel policies
│       └── <policy-name>.json
├── secrets-engines/
│   ├── _mounts_list.json            # Full raw secrets mount listing
│   └── <mount-path>/
│       ├── _mount.json
│       ├── tune.json
│       └── config.json
├── secrets/                          # Medusa KV data exports
│   └── <mount-path>.json            # One file per KV engine
└── audit/
    └── _audit_devices.json          # All audit device configs
```

---

## Script Conventions

### Boilerplate

Every script MUST follow this exact pattern:

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
```

### Argument Interface

All scripts accept these flags:

| Flag             | Description                                      | Default                   |
|------------------|--------------------------------------------------|---------------------------|
| `--config`       | Path to cluster `.env` file **(required)**       | —                         |
| `--output-dir`   | Export output directory (export scripts)          | `data/<CLUSTER_NAME>`     |
| `--input-dir`    | Import input directory (import scripts)           | `data/<CLUSTER_NAME>`     |
| `--dry-run`      | Log operations without making changes             | off                       |
| `--yes`          | Skip interactive confirmation (import scripts)    | off (prompts by default)  |

### Logging

Use the shared logging functions from `lib/common.sh`:

- `info "message"`    — blue `[i]` informational
- `warn "message"`    — yellow `[!]` warning
- `error "message"`   — red `[x]` error (to stderr)
- `success "message"` — green `[+]` success

All log messages include timestamps.

### Naming

- **Functions**: `snake_case`. Prefix internal/private helpers with `_` (e.g., `_parse_mount_type`).
- **Variables**: `UPPER_CASE` for exported/config/env vars. `lower_case` for local variables.
- **Files**: `kebab-case` for scripts (e.g., `export-auth.sh`).

### Vault CLI Wrappers

All vault CLI calls go through safe wrappers defined in `lib/common.sh`:

- `safe_list <path>` — `vault list` with error handling, returns items or exit 1
- `safe_read_to_file <path> <file>` — `vault read` + write JSON to file
- `read_tune_to_file <mount> <file>` — read mount tune with version fallback
- `export_collection_by_list <base_path> <collection> <out_dir>` — list + read each item
- `export_map_collection <base_path> <collection> <out_dir>` — same for map-like resources

### DRY_RUN Support

When `--dry-run` is set, the global `DRY_RUN=true` variable is set. Import scripts must check this before any write operation:

```bash
if [[ "${DRY_RUN}" == "true" ]]; then
  info "[DRY-RUN] Would enable auth method: ${method} at ${path}"
else
  vault auth enable -path="${path}" "${method}"
fi
```

### Quality

- All scripts must be **shellcheck clean** (no warnings).
- No hardcoded paths — everything relative to config values or CLI arguments.
- Idempotent imports where possible (check if resource exists before creating).

---

## Medusa Integration

[Medusa](https://github.com/jonasvinther/medusa) handles bulk KV secret export/import.

**Export:**
```bash
medusa export <mount-path> \
  --format json \
  --output "data/<cluster>/secrets/<mount>.json" \
  --address "$VAULT_ADDR" \
  --token "$VAULT_TOKEN"
```

**Import:**
```bash
medusa import <mount-path> \
  "data/<cluster>/secrets/<mount>.json" \
  --address "$VAULT_ADDR" \
  --token "$VAULT_TOKEN"
```

- Scripts auto-discover KV v1/v2 mounts from `vault secrets list`
- Each KV mount gets its own export file
- Medusa handles both KV v1 and KV v2

---

## Import Order

Import scripts **must** run in this order (import-all.sh enforces this):

```
1. policies        — ACL policies needed by auth roles
2. auth            — Auth methods reference policies
3. secrets-engines — Engine mounts (config only, no data)
4. secrets         — KV data via medusa (engines must exist first)
5. audit           — Audit devices (independent, run last)
```

---

## Dependencies

Required tools on the machine running the scripts:

| Tool      | Purpose                          |
|-----------|----------------------------------|
| `vault`   | HashiCorp Vault CLI              |
| `jq`      | JSON processing                  |
| `medusa`  | Bulk KV secret export/import     |
| `bash` 4+ | Script runtime                   |

The `require_tools` function in `common.sh` validates these at startup.

---

## Implementation Phases

### Phase 1 — Foundation
1. `lib/common.sh` — shared library (extract from existing prototype + new helpers)
2. `config/*.env.example` — documented config templates
3. Update `.gitignore` for `data/`, `config/*.env`

### Phase 2 — Export Scripts
4. `export/export-auth.sh` — refactored from existing `export-vault-auth.sh`
5. `export/export-policies.sh`
6. `export/export-secrets-engines.sh`
7. `export/export-secrets.sh` (medusa)
8. `export/export-audit.sh`
9. `export/export-all.sh` — orchestrator

### Phase 3 — Import Scripts
10. `import/import-policies.sh`
11. `import/import-auth.sh`
12. `import/import-secrets-engines.sh`
13. `import/import-secrets.sh` (medusa)
14. `import/import-audit.sh`
15. `import/import-all.sh` — orchestrator

### Phase 4 — Cleanup
16. Remove old `export-vault-auth.sh` from root
17. Final `.gitignore` update
18. Consistency review across all scripts

## Checks

- Confirm it passes pre-commit rules
- Always ensure the documenation is up to date
