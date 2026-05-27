# Operational Runbook

## Daily operations

### Promoting a release
1. Merge PR to `main`. Push triggers the Build Pipeline automatically.
2. Build runs: SQL lint → Liquibase validate → APEX export check → package as tarball → publish to Artifact Registry as `apex-app-<sha>-<timestamp>`.
3. Stage Deployment Pipeline fires on build success. Watch it in the OCI Console under DevOps → Project → Deployments.
4. After Stage tests pass, open the Prod Deployment Pipeline and click Run. Confirm the artifact version.
5. The Manual Approval stage pauses. The approver(s) listed in the stage configuration receive a notification.
6. After approval, the Shell stage runs the prod deploy script with backup + Liquibase + blue-green APEX import.

### Rolling back

**APEX application** — re-import the pre-deploy snapshot from `apex-prod-backups`:
```bash
oci os object get --auth instance_principal \
  --bucket-name apex-prod-backups \
  --name pre-deploy-<version>-<timestamp>.sql \
  --file /tmp/rollback.sql

sqlcl <user>/<pwd>@<service> @/tmp/rollback.sql
```

**Database changes** — Liquibase rollback to the previous tag:
```bash
sqlcl <user>/<pwd>@<service>
SQL> liquibase rollback -tag=<previous-release-tag> -changelog-file=db/changelog/master.xml
```

**Blue-green rollback** — swap the alias back to the previous app ID. No re-import needed:
```sql
BEGIN
  apex_application_admin.set_application_alias(
    p_application_id => <previous_app_id>,
    p_alias          => 'PROD_APP'
  );
END;
/
```
This is the fastest rollback path — typically under 30 seconds.

## Monitoring

### Where to look when something breaks

- **Build failures** — DevOps → Project → Build Pipelines → click the failed build → Logs tab. Each step's stdout/stderr is captured.
- **Deploy failures** — Deployment Pipelines → click the failed run → Stage logs. Container instance logs are also forwarded to OCI Logging.
- **APEX errors at runtime** — APEX Workspace → Monitor → Debug Messages. Or query `apex_workspace_log_summary`.
- **DB-level errors** — Autonomous Database → Performance Hub → SQL Monitoring.

### Useful Log Search queries

In OCI Logging, search for:
```
data.principalId = '<deployment_pipeline_ocid>' and data.outcome = 'Failure'
```
to see every failed call the deploy made against OCI services.

## Common issues

### Build fails on "Validate APEX export integrity"
The `apex/f100/install.sql` placeholder hasn't been replaced with a real export. From SQLcl against your dev workspace:
```
sqlcl <user>/<pwd>@<service>
SQL> apex export -applicationid 100 -dir apex/f100 -split
```
Commit the new files.

### Deploy fails with ORA-01017 (invalid credentials)
The Vault secret holding the DB password is stale or was rotated. Update the secret in Vault → the deployment pipeline picks up the new value on its next run.

### Deploy fails with ORA-12506 (TNS:listener rejected connection)
Wallet extraction issue or `TNS_ADMIN` not pointing at the unzipped wallet directory. Check the Shell stage script set `export TNS_ADMIN=` before invoking `sqlcl`.

### Stage smoke check passes but prod shows a blank page
Static asset sync didn't run, or the bucket has different CORS/visibility settings between stage and prod. Compare bucket policies and rerun `oci os object bulk-upload` for prod static assets.

### Approval notification didn't reach approvers
Notifications → Topics → `apex-deploy-events` → Subscriptions tab. Confirm each subscription is in "Active" status, not "Pending Confirmation".

## Quarterly tasks

- Rotate wallet files in Vault when ADB rotates them (ADB wallets auto-rotate every 90 days; manual upload still required to keep the Vault secret in sync)
- Review IAM policies — confirm least privilege still holds
- Prune old artifacts in the Artifact Registry (keep last 30 builds)
- Test the rollback path against a non-prod environment to confirm backups are readable and Liquibase rollback tags still resolve
- Validate that Object Storage backup objects are inside their retention policy
