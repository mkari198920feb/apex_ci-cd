# APEX Deployment Notes

APEX deployments differ from typical app pipelines in important ways. This document captures the gotchas.

## Application IDs and offsets

APEX uses internal numeric IDs for pages, regions, items, and shared components. When you import an app, these IDs can collide with existing objects in the target workspace.

**Always call `apex_application_install.generate_offset` before importing.** This makes APEX rewrite all internal IDs into a safe range. Without it, your Prod import can silently corrupt an existing application sharing the same ID range.

## Workspace consistency

The workspace name must exist in both Stage and Prod ADBs with the same internal workspace ID, or session state and shared components break.

- Create workspaces via the script in `apex/workspace/create_workspace.sql`, not manually in the console
- Hard-code the workspace ID (we use 100100) so it matches across environments
- Version-control the workspace creation script

## Static files and supporting objects

If your app references static files uploaded through the APEX builder, they're embedded in the export.

For non-trivial apps, use OCI Object Storage for static assets. The deploy script syncs `apex/static/` to the bucket using the OCI CLI. The APEX instance must be configured to serve static files from that bucket.

## Session timeouts during deploy

APEX imports lock the application briefly. For high-traffic Prod, use blue-green: import to a new app ID (100 → 101), test, then swap the alias via `apex_application_admin.set_application_alias`. Set `DEPLOY_MODE=blue-green` in the deployment pipeline parameters.

## Wallet rotation

ADB wallets in OCI Vault can be rotated independently of the DB. If you rotate the DB password in ADB without re-uploading the wallet to Vault, the next deploy will fail with ORA-01017. Bake a quarterly wallet refresh into your runbook.

## APEX export format

Use the split export format from SQLcl 23+:

```
sqlcl <user>/<pwd>@<service>
SQL> apex export -applicationid 100 -dir apex/f100 -split
```

Split format produces one file per page, shared component, and metadata object. This gives meaningful diffs in PR reviews instead of a single 50,000-line file.

## Liquibase + APEX

Liquibase manages DB objects (tables, packages, views). It does NOT manage APEX application metadata. Treat them as two separate deployment streams:

1. Liquibase runs first to bring DB schema up to date
2. APEX import runs second, using the updated schema

Never put APEX metadata changes inside Liquibase changesets. The APEX import script handles all of that.

## Rollback strategy

APEX exports are atomic snapshots. The deploy scripts export the current app before each import, store it in Object Storage, and use that as the rollback artifact. Combined with Liquibase rollback tags for the DB side, you can revert both halves of a bad release in under 5 minutes.
