#!/bin/bash
# Stage deployment script. Executed by the OCI DevOps Deployment Pipeline
# inside a managed container instance. The artifact bundle is extracted to
# the working directory before this script runs.
#
# Pipeline injects these env vars via parameters or Vault references:
#   DB_USER, DB_PASSWORD, STAGE_DB_SERVICE, STAGE_APEX_URL
#   STAGE_WALLET_OCID  (Vault secret OCID containing base64-encoded wallet.zip)

set -euo pipefail

ENV="STAGE"
WALLET_DIR="/tmp/wallet_stage"
APP_ID="${APP_ID:-100}"
WORKSPACE="${WORKSPACE:-MY_WORKSPACE}"

echo "==> Deploying to ${ENV} (app ${APP_ID}, workspace ${WORKSPACE})"

# ----- 1. Fetch wallet from OCI Vault using instance principal auth -----
echo "==> Fetching DB wallet from Vault"
WALLET_B64=$(oci secrets secret-bundle get \
  --auth instance_principal \
  --secret-id "${STAGE_WALLET_OCID}" \
  --query 'data."secret-bundle-content".content' \
  --raw-output)

echo "${WALLET_B64}" | base64 -d > /tmp/wallet.zip
mkdir -p "${WALLET_DIR}"
unzip -o /tmp/wallet.zip -d "${WALLET_DIR}" >/dev/null
export TNS_ADMIN="${WALLET_DIR}"
chmod 600 "${WALLET_DIR}"/*

# ----- 2. Pre-deploy snapshot of APEX app for rollback -----
echo "==> Exporting current APEX app for rollback"
mkdir -p /tmp/rollback
sqlcl -S "${DB_USER}/${DB_PASSWORD}@${STAGE_DB_SERVICE}" <<EOF
apex export -applicationid ${APP_ID} -dir /tmp/rollback
exit
EOF

# Stash rollback artifact in Object Storage
oci os object put \
  --auth instance_principal \
  --bucket-name "apex-stage-rollback" \
  --file "/tmp/rollback/f${APP_ID}.sql" \
  --name "pre-deploy-${BUILD_VERSION:-manual}.sql" \
  --force

# ----- 3. Apply DB changes via Liquibase -----
echo "==> Applying Liquibase changelog"
sqlcl -S "${DB_USER}/${DB_PASSWORD}@${STAGE_DB_SERVICE}" <<EOF
liquibase update -changelog-file=db/changelog/master.xml
exit
EOF

# ----- 4. Import APEX application with ID offset -----
echo "==> Importing APEX application"
sqlcl -S "${DB_USER}/${DB_PASSWORD}@${STAGE_DB_SERVICE}" <<EOF
ALTER SESSION SET CURRENT_SCHEMA = ${WORKSPACE};
BEGIN
  apex_application_install.set_workspace('${WORKSPACE}');
  apex_application_install.set_application_id(${APP_ID});
  apex_application_install.generate_offset;
  apex_application_install.set_schema('${WORKSPACE}');
END;
/
@apex/f${APP_ID}/install.sql
exit
EOF

# ----- 5. Sync static assets to Object Storage (optional) -----
if [ -d "apex/static" ]; then
  echo "==> Syncing static assets"
  oci os object bulk-upload \
    --auth instance_principal \
    --bucket-name "apex-static-stage" \
    --src-dir apex/static \
    --overwrite
fi

# ----- 6. Smoke tests -----
echo "==> Running smoke tests"
bash tests/smoke/smoke_check.sh "${STAGE_APEX_URL}"

# ----- 7. utPLSQL regression suite -----
echo "==> Running utPLSQL regression suite"
sqlcl -S "${DB_USER}/${DB_PASSWORD}@${STAGE_DB_SERVICE}" <<EOF
SET SERVEROUTPUT ON
exec ut.run('${WORKSPACE}', a_color_console => false);
exit
EOF

echo "==> Stage deployment complete"
