# Vault Migration Tool

Migrate [HashiCorp Vault](https://www.vaultproject.io/) configurations and secrets between clusters.

Exports auth methods, policies, secrets engine configs, KV secret data, and audit devices from a **source** Vault cluster, then imports them into a **destination** cluster. Secret data transfer is powered by [medusa](https://github.com/jonasvinther/medusa).

---

## Prerequisites

Install the following tools before running any scripts:

| Tool | Version | Install |
|------|---------|---------|
| [vault](https://developer.hashicorp.com/vault/install) | any | `brew install vault` |
| [jq](https://jqlang.github.io/jq/) | any | `brew install jq` |
| [medusa](https://github.com/jonasvinther/medusa) | any | `brew install jonasvinther/tap/medusa` |
| bash | 4.0+ | Included on most systems |

> **Note:** On macOS the default `/bin/bash` is version 3. If needed, install a newer version via `brew install bash`.

---

## Quick Start

### 1. Set up configuration

Create config files for your source and destination clusters:

```bash
cp config/source.env.example config/source.env
cp config/destination.env.example config/destination.env
```

Edit each file with the correct Vault address, token, and cluster name:

```bash
# config/source.env
VAULT_ADDR="https://vault-source.example.com:8200"
VAULT_TOKEN="hvs.your-source-token"
CLUSTER_NAME="source-prod"
```

```bash
# config/destination.env
VAULT_ADDR="https://vault-destination.example.com:8200"
VAULT_TOKEN="hvs.your-destination-token"
CLUSTER_NAME="destination-prod"
```

### 2. Export from source

Export everything at once:

```bash
./export/export-all.sh --config config/source.env
```

Or run individual export scripts:

```bash
./export/export-policies.sh --config config/source.env
./export/export-auth.sh --config config/source.env
./export/export-secrets-engines.sh --config config/source.env
./export/export-secrets.sh --config config/source.env
./export/export-audit.sh --config config/source.env
```

Exported data is saved to `data/<CLUSTER_NAME>/` by default.

### 3. Review the export

Check the exported data before importing:

```bash
ls data/source-prod/
# auth/  policies/  secrets-engines/  secrets/  audit/
```

### 4. Import to destination

Preview what will happen with a dry run:

```bash
./import/import-all.sh --config config/destination.env --dry-run
```

When ready, run the actual import:

```bash
./import/import-all.sh --config config/destination.env
```

You will be prompted for confirmation before any changes are made.

---

## Command Reference

### Export scripts

| Script | What it exports |
|--------|----------------|
| `export/export-all.sh` | Runs all export scripts in order |
| `export/export-auth.sh` | Auth methods, roles, users, groups, certs |
| `export/export-policies.sh` | ACL policies, EGP/RGP sentinel policies (Enterprise) |
| `export/export-secrets-engines.sh` | Secrets engine mounts, tune settings, config |
| `export/export-secrets.sh` | KV secret data via medusa |
| `export/export-audit.sh` | Audit device configurations |

### Import scripts

| Script | What it imports |
|--------|----------------|
| `import/import-all.sh` | Runs all import scripts in the correct order |
| `import/import-policies.sh` | ACL policies, EGP/RGP sentinel policies |
| `import/import-auth.sh` | Auth methods, roles, users, groups, certs |
| `import/import-secrets-engines.sh` | Secrets engine mounts, tune settings, config |
| `import/import-secrets.sh` | KV secret data via medusa |
| `import/import-audit.sh` | Audit device configurations |

### Flags

All scripts accept the following flags:

```
--config <path>       Path to cluster .env config file (required)
--output-dir <path>   Export output directory (default: data/<CLUSTER_NAME>)
--input-dir <path>    Import input directory (default: data/<CLUSTER_NAME>)
--dry-run             Log what would happen without making changes
--yes                 Skip interactive confirmation (import scripts only)
```

### Examples

```bash
# Export only auth methods to a custom directory
./export/export-auth.sh --config config/source.env --output-dir /tmp/vault-backup

# Dry-run import of policies
./import/import-policies.sh --config config/destination.env --dry-run

# Non-interactive import (for CI/CD pipelines)
./import/import-all.sh --config config/destination.env --yes
```

---

## Import Order

When running scripts individually, import them in this order:

```
1. policies           ACL policies (referenced by auth roles)
2. auth               Auth methods (depend on policies)
3. secrets-engines    Engine mounts and config (no data)
4. secrets            KV data via medusa (engines must exist)
5. audit              Audit devices (independent)
```

The `import-all.sh` orchestrator enforces this order automatically.

---

## Configuration Reference

| Variable | Required | Description |
|----------|----------|-------------|
| `VAULT_ADDR` | Yes | Vault cluster URL (e.g., `https://vault.example.com:8200`) |
| `VAULT_TOKEN` | Yes | Authentication token with sufficient permissions |
| `CLUSTER_NAME` | Yes | Identifier used for the export directory name |
| `VAULT_NAMESPACE` | No | Enterprise namespace (leave empty for OSS) |
| `VAULT_SKIP_VERIFY` | No | Set `"true"` to skip TLS certificate verification |
| `VAULT_CACERT` | No | Path to a custom CA certificate file |
| `MEDUSA_ADDR` | No | Override Vault address for medusa (defaults to `VAULT_ADDR`) |
| `MEDUSA_INSECURE` | No | Set `"true"` to pass `--insecure` to medusa |

---

## Export Data Layout

```
data/<cluster-name>/
├── auth/
│   ├── _auth_list.json                 # Raw auth mount listing
│   └── <mount>/                        # e.g., oidc/, approle/, ldap/
│       ├── _mount.json                 # Mount definition
│       ├── tune.json                   # TTLs, audit settings
│       ├── config.json                 # Method-specific config
│       └── roles/ users/ groups/ ...   # Sub-resources
├── policies/
│   ├── acl/
│   │   └── <name>.hcl                  # ACL policies
│   ├── egp/                            # Enterprise EGP policies
│   └── rgp/                            # Enterprise RGP policies
├── secrets-engines/
│   ├── _mounts_list.json               # Raw secrets mount listing
│   └── <mount>/
│       ├── _mount.json
│       ├── tune.json
│       └── config.json
├── secrets/
│   └── <mount>.json                    # Medusa KV export (one per engine)
└── audit/
    └── _audit_devices.json             # Audit device configs
```

---

## Safety Features

- **Confirmation prompts** — All import scripts ask for confirmation before writing. Use `--yes` to skip (e.g., in CI).
- **Dry-run mode** — Pass `--dry-run` to see exactly what would happen without making any changes.
- **Idempotent imports** — Scripts check if resources already exist before creating them (auth mounts, secrets engines, audit devices).
- **No secrets in git** — `data/` and `config/*.env` are gitignored by default.
- **Tool validation** — Scripts check for required tools (`vault`, `jq`, `medusa`) at startup and fail fast with a clear message.

---

## Supported Auth Methods

The export/import scripts handle sub-resources for these auth methods:

| Method | Exported sub-resources |
|--------|----------------------|
| OIDC / JWT | roles, providers, keys, config |
| AppRole | roles, config |
| LDAP | users, groups, config, legacy map/* |
| Userpass | users |
| GitHub | teams, users, config |
| AWS | roles, config, config/client |
| GCP | roles, config |
| Azure | roles, config, config/client |
| Kubernetes | roles, config |
| TLS Certificate | certs, config |

The scripts use a forgiving probe strategy — they try all known sub-resource paths for each mount and silently skip any that don't exist.

---

## Supported Secrets Engines

Engine mount definitions and configs are exported for all types. Additional sub-resources are captured for:

| Engine | Exported sub-resources |
|--------|----------------------|
| KV v1 / v2 | Secret data via medusa |
| PKI | roles, issuers, keys, config/urls, config/crl |
| Transit | keys |
| SSH | roles |
| Database | roles, static-roles, config |
| AWS / GCP | roles, config/root, config/lease |

System mounts (`sys/`, `identity/`, `cubbyhole/`) are automatically skipped.

---

## Troubleshooting

**"Missing required tools" error**

Install the missing tool listed in the error message. See [Prerequisites](#prerequisites).

**"Failed to list auth methods"**

Check that `VAULT_ADDR` and `VAULT_TOKEN` in your config file are correct and that the token has sufficient permissions (`sudo` access to `sys/` endpoints is required for full export).

**"No KV secrets engines found"**

The export-secrets script only exports KV (key-value) engine data. Other engine types are handled by export-secrets-engines (config only).

**Permission denied on scripts**

Make the scripts executable:

```bash
chmod +x export/*.sh import/*.sh lib/common.sh
```

---

## License

See [LICENSE](LICENSE) for details.
