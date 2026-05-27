# Oracle APEX CI/CD Pipeline (OCI Native)

End-to-end CI/CD pipeline for Oracle APEX applications using only Oracle Cloud Infrastructure DevOps services. No Terraform, no external CI, no third-party artifact stores — everything runs inside one OCI DevOps project.

## Services used

| OCI Service | Role |
|-------------|------|
| DevOps Code Repository | Source control (this repo) |
| DevOps Build Pipeline | Lints SQL, validates APEX export, packages artifact |
| DevOps Artifact (Generic) | Versioned deployment bundle |
| DevOps Deployment Pipeline | Stage and Prod deployments |
| DevOps Environment | Targets the Stage and Prod runners |
| Autonomous Database | Stage and Prod APEX hosts |
| Vault | DB wallets and credentials |
| Object Storage | Pre-deploy backups, static assets |
| Notifications (ONS) | Pipeline events to email or Slack |
| Logging | Build and deploy logs |

## Flow

```
git push → Code Repo → Build Pipeline → Artifact Registry
                                              │
                                              ├──► Stage Deploy Pipeline (auto)
                                              │      └─ Liquibase + APEX import + tests
                                              │
                                              └──► Prod Deploy Pipeline (manual approval)
                                                     └─ backup + blue-green deploy
```

## Repository layout

| Path | Purpose |
|------|---------|
| `apex/f100/` | APEX application export (SQLcl APEXExport output) |
| `apex/workspace/` | Workspace creation scripts |
| `db/changelog/` | Liquibase changelogs for tables, packages, seed data |
| `db/rollback/` | Manual rollback scripts |
| `tests/utplsql/` | utPLSQL regression tests |
| `tests/smoke/` | Post-deploy HTTP smoke checks |
| `pipeline/` | `build_spec.yaml` plus deploy scripts |
| `docs/` | Console setup walkthrough, runbook, APEX notes |

## Getting started

1. Read `docs/OCI-CONSOLE-SETUP.md` and create the resources by clicking through the OCI Console (~30 minutes)
2. Push this repo to the OCI Code Repository created in step 1
3. The push fires the Build Pipeline automatically
4. On build success the Stage Deployment Pipeline runs and reports test results
5. When you're happy with Stage, approve the Prod Deployment Pipeline in the console

See `docs/RUNBOOK.md` for day-2 operations and `docs/APEX-NOTES.md` for APEX-specific deployment gotchas.

## Prerequisites

- OCI tenancy with the DevOps service enabled in your home region
- Two Autonomous Databases (Stage + Prod) with APEX provisioned
- A Vault containing DB wallets and credentials as secrets
- A Dynamic Group + Policy granting the DevOps service permission to read Vault secrets, write to Object Storage, and connect to the ADBs
