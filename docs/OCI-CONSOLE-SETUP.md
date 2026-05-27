# OCI Console Setup Walkthrough

Step-by-step guide to building the CI/CD pipeline by clicking through the OCI Console. Takes about 30-45 minutes the first time. All work happens in your home region.

## Phase 1 — Foundational resources (10 min)

### 1.1 Compartment

Pick or create a compartment for these resources. Suggested name: `apex-cicd`.

### 1.2 IAM Dynamic Group

Identity & Security → Domains → Default → Dynamic Groups → Create.

- Name: `apex-devops-dg`
- Matching rule:
  ```
  ALL {resource.type = 'devopsdeploypipeline', resource.compartment.id = '<compartment_ocid>'}
  ANY {resource.type = 'devopsbuildpipeline', resource.compartment.id = '<compartment_ocid>'}
  ```

### 1.3 IAM Policy

Identity & Security → Policies → Create.

- Name: `apex-devops-policy`, attached to root compartment
- Statements:
  ```
  Allow dynamic-group apex-devops-dg to manage devops-family in compartment apex-cicd
  Allow dynamic-group apex-devops-dg to read secret-family in compartment apex-cicd
  Allow dynamic-group apex-devops-dg to manage objects in compartment apex-cicd
  Allow dynamic-group apex-devops-dg to read autonomous-databases in compartment apex-cicd
  Allow dynamic-group apex-devops-dg to use ons-topics in compartment apex-cicd
  Allow dynamic-group apex-devops-dg to read repos in compartment apex-cicd
  ```

### 1.4 Vault and secrets

Identity & Security → Vault → Create Vault: `apex-cicd-vault`.

Inside the vault, create a Master Encryption Key (AES, 256 bits), then create these secrets:

| Secret name | Contents |
|-------------|----------|
| `stage-db-wallet` | Base64-encoded `Wallet_StageADB.zip` |
| `stage-db-password` | Stage DB user password |
| `prod-db-wallet` | Base64-encoded `Wallet_ProdADB.zip` |
| `prod-db-password` | Prod DB user password |

To encode the wallet: `base64 -w 0 Wallet_StageADB.zip | pbcopy` (Mac) or `base64 -w 0 Wallet_StageADB.zip > stage.b64` (Linux). Paste into the secret's content field.

Note the OCID of each secret — you'll reference them later.

### 1.5 Object Storage buckets

Storage → Object Storage → Create Bucket. Create three buckets in your compartment:

- `apex-stage-rollback` — rollback snapshots from Stage deploys
- `apex-prod-backups` — pre-deploy backups from Prod deploys
- `apex-static-prod` and `apex-static-stage` — only if you serve static assets from Object Storage

### 1.6 Notifications topic

Application Integration → Notifications → Create Topic: `apex-deploy-events`.

Add a subscription (email, Slack via webhook, or PagerDuty). Confirm the subscription from your inbox. Note the topic OCID.

## Phase 2 — DevOps project and repo (5 min)

### 2.1 DevOps Project

Developer Services → DevOps → Projects → Create Project.

- Name: `apex-cicd`
- Notifications topic: select `apex-deploy-events`

### 2.2 Code Repository

Inside the project → Code Repositories → Create Repository.

- Name: `apex-app`
- Type: Hosted
- Default branch: `main`

You'll get an HTTPS clone URL. Generate an Auth Token under your user profile to push.

### 2.3 Artifact

Inside the project → Artifacts → Add Artifact.

- Name: `apex-bundle`
- Type: Generic Artifact
- Artifact source: Inline
- Path: `apex-app`
- Version: `${BUILD_VERSION}` (the build pipeline will substitute this)
- Replace existing artifact: Yes

## Phase 3 — Build pipeline (10 min)

### 3.1 Create the Build Pipeline

Inside the project → Build Pipelines → Create.

- Name: `apex-build`

### 3.2 Add the Managed Build stage

Open the pipeline → Add Stage → Managed Build.

- Stage name: `build-and-package`
- Build spec file path: `pipeline/build_spec.yaml`
- Image: `OL7_X86_64_STANDARD_10`
- Primary code repository: select `apex-app`, branch `main`
- Timeout: 60 minutes

### 3.3 Add the Deliver Artifacts stage

Add Stage → Deliver Artifacts (after the build stage).

- Stage name: `publish-artifact`
- Build config / Result artifact name (from build_spec): `apex_bundle`
- DevOps artifact: `apex-bundle`

### 3.4 Add a trigger for pushes to main

Inside the project → Triggers → Create Trigger.

- Name: `main-push`
- Source: DevOps Code Repository → `apex-app`
- Events: Push
- Filter: `refs/heads/main`
- Action: Run Build Pipeline → `apex-build`

## Phase 4 — Environments (5 min)

You need a place where the deploy scripts actually execute. Options:

- **Container Instance** (recommended) — provisioned per deploy, no standing infra
- **OKE cluster** — overkill for this use case
- **Compute instance group** — works but requires patching/maintaining VMs

The deploy stages use Container Instance shell deployment, so you don't need to create persistent environments. The deployment stage configuration itself defines the container shape, network, and image.

If you do prefer a persistent runner (e.g. for IP allow-listing to the ADB), create a Compute VM in a private subnet with VCN routing to the ADB's service gateway, install SQLcl and OCI CLI on it, then create a DevOps Environment of type "Compute instance group" pointing at it.

## Phase 5 — Stage deployment pipeline (10 min)

### 5.1 Create the Deployment Pipeline

Inside the project → Deployment Pipelines → Create.

- Name: `deploy-stage`

### 5.2 Add pipeline parameters

Open the pipeline → Parameters tab → Add the following:

| Name | Default value | Notes |
|------|---------------|-------|
| `APP_ID` | `100` | |
| `WORKSPACE` | `MY_WORKSPACE` | |
| `STAGE_DB_SERVICE` | `stagedb_high` | |
| `STAGE_APEX_URL` | `https://<adb-host>/ords/r/MY_WORKSPACE/app` | |
| `STAGE_WALLET_OCID` | (OCID of `stage-db-wallet` secret) | |
| `DB_USER` | `MY_WORKSPACE` | |

For `DB_PASSWORD`, use a Vault Secret reference rather than a plain parameter. The OCI deployment pipeline supports `Vault Secret` parameter type — point it at the `stage-db-password` secret you created.

### 5.3 Add the Shell stage

Add Stage → Shell.

- Stage name: `run-stage-deploy`
- Container instance configuration:
  - Shape: `CI.Standard.E4.Flex`, 1 OCPU, 4 GB RAM
  - Network: select a subnet with egress to the ADB
  - Image: an Oracle Linux image with SQLcl pre-installed, or pull `container-registry.oracle.com/database/sqlcl:latest` at runtime
- Artifact: select `apex-bundle`
- Command: see below

Command field:
```bash
tar -xzf /workspace/${ARTIFACT_NAME}-${BUILD_VERSION}.tar.gz -C /workspace
cd /workspace/${ARTIFACT_NAME}-${BUILD_VERSION}
chmod +x pipeline/deploy_stage.sh
bash pipeline/deploy_stage.sh
```

Mark all parameters from 5.2 as Environment Variables on this stage.

### 5.4 Wire the Build pipeline to trigger this on success

Go back to the Build pipeline `apex-build` → Add Stage (after `publish-artifact`) → Trigger Deployment.

- Stage name: `trigger-stage-deploy`
- Deployment pipeline: `deploy-stage`
- Pass parameters: enable "Pass all parameters from build to deployment"

Now: push to main → build runs → on build success the Stage deployment pipeline fires automatically.

## Phase 6 — Prod deployment pipeline (10 min)

### 6.1 Create the pipeline

Inside the project → Deployment Pipelines → Create.

- Name: `deploy-prod`

### 6.2 Add parameters

Same as Stage, but with prod values: `PROD_DB_SERVICE`, `PROD_APEX_URL`, `PROD_WALLET_OCID`, prod DB credentials. Add:

- `DEPLOY_MODE` = `blue-green`
- `NOTIFICATION_TOPIC_OCID` = OCID of `apex-deploy-events`

### 6.3 Add a Manual Approval stage

Open the pipeline → Add Stage → Manual Approval.

- Stage name: `approve-prod-release`
- Approval policy: Count-based
- Required approvers: 1 (or 2 for stricter change control)
- Approver groups: a group containing the people authorized to approve prod

### 6.4 Add the Shell stage for the actual deployment

Add Stage → Shell (after the approval gate).

- Stage name: `run-prod-deploy`
- Container instance config: same as Stage
- Artifact: `apex-bundle`
- Command:
  ```bash
  tar -xzf /workspace/${ARTIFACT_NAME}-${BUILD_VERSION}.tar.gz -C /workspace
  cd /workspace/${ARTIFACT_NAME}-${BUILD_VERSION}
  chmod +x pipeline/deploy_prod.sh
  bash pipeline/deploy_prod.sh
  ```

### 6.5 Triggering Prod

Prod is gated on human approval, so don't auto-trigger it from the Build pipeline. Instead, from the OCI Console:

1. Open the Prod deployment pipeline
2. Click "Run Pipeline"
3. Confirm parameters (including the `BUILD_VERSION` of the artifact you want to promote)
4. The Manual Approval stage pauses
5. An approver clicks "Approve" — the Shell stage runs

Optionally, you can wire the Stage deployment pipeline's success to *initiate* (but not bypass approval of) the Prod pipeline. From the Stage pipeline, add a Trigger Deployment stage targeting `deploy-prod`. The approval gate still blocks until a human approves.

## Phase 7 — First end-to-end run

1. Clone the new Code Repository locally.
2. Copy in the contents of this repo and commit on `main`.
3. Push.
4. Watch the Build Pipeline run in the console — fix any errors in `build_spec.yaml`.
5. On success, watch the Stage deployment run.
6. Verify the app in the Stage APEX URL.
7. From the Prod pipeline, click Run, approve, and watch it deploy.

## Common setup issues

**Build fails with "wallet not found" during validation** — the build pipeline doesn't connect to the DB. Wallet handling is only in the deployment stage scripts. Make sure your `build_spec.yaml` is the one in this repo (no DB connections during build).

**Deploy stage fails with "401 NotAuthenticated" from OCI CLI** — the Dynamic Group rule isn't matching the deployment pipeline's resource ID, or the Policy is in the wrong compartment. Verify with: Logging → Search → filter by `deploypipeline` to see the actual principal in the failed call.

**Deploy stage fails with ORA-12506** — the wallet was extracted but `TNS_ADMIN` isn't being respected. Make sure the `unzip` step extracts to a writable directory and that the deployment shell stage script does `export TNS_ADMIN=...` before invoking `sqlcl`.

**Container Instance can't reach the ADB** — your subnet doesn't have a route to the ADB. Either use a Service Gateway in the same VCN, or move to a public subnet (less secure but simpler for first deploy).
