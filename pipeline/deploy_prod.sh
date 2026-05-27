#!/bin/bash
# Production deployment script. Runs only after the manual approval gate
# in the OCI DevOps Deployment Pipeline is passed.
#
# Pipeline injects these env vars:
#   DB_USER, DB_PASSWORD, PROD_DB_SERVICE, PROD_APEX_URL
#   PROD_WALLET_OCID  (Vault secret OCID containing base64-encoded wallet.zip)
#   DEPLOY_MODE       (in-place | blue-green, default blue-green)

set -euo pipefail

ENV="PROD"
WALLET_DIR="/tmp/wallet_prod"
APP_ID="${APP_ID:-100}"
WORKSPACE="${WORKSPACE:-MY_WORKSPACE}"
DEPLOY_MODE="${DEPLOY_MODE:-blue-green}"

echo "==> Deploying to ${ENV} (mode: ${DEPLOY_MODE}, app ${APP_ID})"

# ----- 1. Fetch wallet from Vault -----
WALLET_B64=$(oci secrets secret-bundle get \
  --auth instance_principal \
  --secret-id "${PROD_WALLET_OCID}" \
  --query 'data."secret-bundle-content".content' \
  --raw-output)

echo "${WALLET_B64}" | base64 -d > /tmp/wallet.zip
mkdir -p "${WALLET_DIR}"
unzip -o /tmp/wallet.zip -d "${WALLET_DIR}" >/dev/null
export TNS_ADMIN="${WALLET_DIR}"
chmod 600 "${WALLET_DIR}"/*

# ----- 2. Pre-deploy backup -----
echo "==> Creating pre-deploy backup"
BACKUP_TS=$(date +%Y%m%d%H%M%S)
mkdir -p "/tmp/backup_${BACKUP_TS}"

sqlcl -S "${DB_USER}/${DB_PASSWORD}@${PROD_DB_SERVICE}" <<EOF
apex export -applicationid ${APP_ID} -dir /tmp/backup_${BACKUP_TS}
exit
EOF

oci os object put \
  --auth instance_principal \
  --bucket-name "apex-prod-backups" \
  --file "/tmp/backup_${BACKUP_TS}/f${APP_ID}.sql" \
  --name "pre-deploy-${BUILD_VERSION:-manual}-${BACKUP_TS}.sql" \
  --force

# ----- 3. Apply DB changes -----
echo "==> Applying Liquibase changelog"
sqlcl -S "${DB_USER}/${DB_PASSWORD}@${PROD_DB_SERVICE}" <<EOF
liquibase update -changelog-file=db/changelog/master.xml
exit
EOF

# ----- 4. APEX import - in-place or blue-green -----
if [ "${DEPLOY_MODE}" = "blue-green" ]; then
  NEW_APP_ID=$((APP_ID + 1))
  echo "==> Blue-green: importing as new app ID ${NEW_APP_ID}"
  sqlcl -S "${DB_USER}/${DB_PASSWORD}@${PROD_DB_SERVICE}" <<EOF
ALTER SESSION SET CURRENT_SCHEMA = ${WORKSPACE};
BEGIN
  apex_application_install.set_workspace('${WORKSPACE}');
  apex_application_install.set_application_id(${NEW_APP_ID});
  apex_application_install.generate_offset;
  apex_application_install.set_schema('${WORKSPACE}');
END;
/
@apex/f${APP_ID}/install.sql
exit
EOF

  echo "==> Blue-green: validating new app before alias swap"
  bash tests/smoke/smoke_check.sh "${PROD_APEX_URL}?p=${NEW_APP_ID}"

  echo "==> Blue-green: swapping alias"
  sqlcl -S "${DB_USER}/${DB_PASSWORD}@${PROD_DB_SERVICE}" <<EOF
BEGIN
  apex_application_admin.set_application_alias(
    p_application_id => ${NEW_APP_ID},
    p_alias          => 'PROD_APP'
  );
END;
/
exit
EOF
else
  echo "==> In-place import to app ${APP_ID}"
  sqlcl -S "${DB_USER}/${DB_PASSWORD}@${PROD_DB_SERVICE}" <<EOF
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
fi

# ----- 5. Sync static assets -----
if [ -d "apex/static" ]; then
  oci os object bulk-upload \
    --auth instance_principal \
    --bucket-name "apex-static-prod" \
    --src-dir apex/static \
    --overwrite
fi

# ----- 6. Post-deploy verification -----
echo "==> Post-deploy smoke check"
bash tests/smoke/smoke_check.sh "${PROD_APEX_URL}"

# ----- 7. Publish deployment event to ONS topic -----
if [ -n "${NOTIFICATION_TOPIC_OCID:-}" ]; then
  oci ons message publish \
    --auth instance_principal \
    --topic-id "${NOTIFICATION_TOPIC_OCID}" \
    --title "APEX Prod deploy ${BUILD_VERSION}" \
    --body "Production deployment of ${BUILD_VERSION} completed successfully."
fi

echo "==> Production deployment complete"
