# Task: Deploy Langfuse on AKS with SPN-Only Authentication

**Status:** Ready for deployment — All deliverables (code, script, docs) are complete. Run [aks-create-resources.sh](./aks-create-resources.sh) with `LANGFUSE_REPO_ROOT` set, then verify per Task 9.
**Priority:** High
**Estimated effort:** 3-5 days (for an engineer familiar with Azure + Node.js)
**Master checklist:** [aks-deployment-todo.md](./aks-deployment-todo.md)
**Helm values template:** [aks-helm-values.example.yaml](./aks-helm-values.example.yaml)
**Rollback procedures:** [aks-rollback.md](./aks-rollback.md)

---

## Table of Contents

1. [Background and Constraints](#1-background-and-constraints)
2. [Architecture Overview](#2-architecture-overview)
3. [Prerequisites](#3-prerequisites)
4. [Task 1: Fork the Langfuse Repository](#task-1-fork-the-langfuse-repository)
5. [Task 2: Modify StorageService for Azure AD Auth](#task-2-modify-storageservice-for-azure-ad-auth)
6. [Task 3: Create Azure Resources](#task-3-create-azure-resources)
7. [Task 4: Configure AKS Workload Identity](#task-4-configure-aks-workload-identity)
8. [Task 5: Configure Azure AD SSO (App Registration)](#task-5-configure-azure-ad-sso-app-registration)
9. [Task 6: Build and Push Container Images](#task-6-build-and-push-container-images)
10. [Task 7: Create Kubernetes Secrets](#task-7-create-kubernetes-secrets)
11. [Task 8: Prepare Helm Values and Deploy](#task-8-prepare-helm-values-and-deploy)
12. [Task 9: Verification and Testing](#task-9-verification-and-testing)
13. [Task 10: Document Rollback Procedures](#task-10-document-rollback-procedures)
14. [Reference Links](#reference-links)
15. [Decision Log](#decision-log)

---

## 1. Background and Constraints

### What we are doing

Deploying the open-source Langfuse LLM engineering platform on Azure Kubernetes Service (AKS) using the official Helm chart, with the following hard constraints:

- **SPN-only:** No Azure Storage Account access keys, no Azure Redis access keys, no Azure-generated primary keys of any kind. All Azure resource data-plane access must use Service Principals (SPN), Managed Identity, or Workload Identity.
- **Helm only:** Deployment must use the official Langfuse Kubernetes Helm chart from `langfuse/langfuse-k8s`.
- **SSO:** Users must authenticate via Azure AD (Entra ID) single sign-on using their corporate accounts.
- **In-cluster data stores:** PostgreSQL, Redis, and ClickHouse run inside AKS (deployed by the Helm chart) to avoid Azure-managed service access keys.
- **External Blob only:** Azure Blob Storage is the only external Azure data-plane resource, accessed via Workload Identity (no storage account keys).

### What requires a code change

Only **one file** in the Langfuse application requires modification:

**File:** `packages/shared/src/server/services/StorageService.ts`

**Why:** The `AzureBlobStorageService` class currently uses `StorageSharedKeyCredential` (account name + account key) exclusively. It has no Azure AD / SPN authentication path. The `getSignedUrl` and `getSignedUploadUrl` methods use `blockBlobClient.generateSasUrl()` which only works with key-based credentials.

**What to change:** Add support for `DefaultAzureCredential` (from `@azure/identity`) and implement **user delegation SAS** for presigned URLs.

### What does NOT require code changes

- Azure AD SSO (already supported via environment variables)
- ACR image pull (AKS managed identity handles this)
- Helm chart deployment on AKS (officially supported)
- PostgreSQL/Redis/ClickHouse configuration (connection strings via Helm values)

---

## 2. Architecture Overview

```
Internet
    |
[Azure Application Gateway / NGINX Ingress]
    |
[AKS Cluster]
    |-- langfuse-web (Next.js, port 3000)
    |-- langfuse-worker (Express.js, port 3030)
    |-- postgresql (Bitnami subchart, in-cluster)
    |-- redis/valkey (Bitnami subchart, in-cluster)
    |-- clickhouse + zookeeper (Bitnami subchart, in-cluster)
    |
    |-- [Workload Identity] --> Azure Blob Storage (no keys)
    |
[Azure AD / Entra ID] <-- SSO (OAuth2)
[ACR] <-- images pulled via AKS managed identity
```

**Key point:** PostgreSQL, Redis, and ClickHouse are INSIDE the cluster. Only Blob Storage is an external Azure resource. This eliminates all Azure-generated access keys.

---

## 3. Prerequisites

### Tools (install on your local machine)

- **Azure CLI** >= 2.47.0 — [Install docs](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli)
- **kubectl** — [Install docs](https://kubernetes.io/docs/tasks/tools/)
- **Helm** >= 3.x — [Install docs](https://helm.sh/docs/intro/install/)
- **Docker** (for building images) — [Install docs](https://docs.docker.com/get-docker/)
- **Node.js 24** + **pnpm 9.5.0** (for local development/testing of the code change)
- **Git**

### Azure subscription

- An active Azure subscription where you can create resources
- Permissions: at minimum, Contributor + User Access Administrator on the subscription (or a dedicated resource group)
- Azure CLI logged in: `az login`

### Accounts

- GitHub account (to fork the repo)
- Access to the Azure AD tenant where SSO will be configured

---

## Task 1: Fork the Langfuse Repository

### 1.1 Fork the application repo

1. Go to https://github.com/langfuse/langfuse
2. Click "Fork" to create a copy in your GitHub org/account
3. Clone your fork locally:

```bash
git clone https://github.com/<YOUR_ORG>/langfuse.git
cd langfuse
git remote add upstream https://github.com/langfuse/langfuse.git
```

### 1.2 Understand the repo structure

Read the following files to understand the codebase:

- `CLAUDE.md` — full project overview, build commands, architecture
- `AGENTS.md` — linting and test commands
- `packages/shared/src/server/services/StorageService.ts` — **the file you will modify**
- `packages/shared/src/env.ts` — environment variable definitions (lines 112-139)
- `web/src/env.mjs` — web-side environment variable definitions (lines 119-124 for Azure AD SSO)
- `web/Dockerfile` — web container build
- `worker/Dockerfile` — worker container build
- `web/entrypoint.sh` — startup script, shows how DATABASE_URL is constructed

### 1.3 Do NOT fork the Helm chart repo

We will use the official Helm chart from `langfuse/langfuse-k8s` as-is and configure everything via `values.yaml` and `additionalEnv`. No Helm chart fork is needed.

**Reference:** https://github.com/langfuse/langfuse-k8s

---

## Task 2: Modify StorageService for Azure AD Auth

This is the only code change required. All modifications are in the `packages/shared` package.

### 2.1 Add the `@azure/identity` dependency

**File:** `packages/shared/package.json`

The package already has `@azure/storage-blob` (line 74). Add `@azure/identity` as a dependency.

**Reference:** https://www.npmjs.com/package/@azure/identity

Run from the repo root:

```bash
cd packages/shared
pnpm add @azure/identity
```

### 2.2 Modify `AzureBlobStorageService` in `StorageService.ts`

**File:** `packages/shared/src/server/services/StorageService.ts`

**Current behavior (lines 145-178):**

- Constructor requires `accessKeyId` (account name) and `secretAccessKey` (account key)
- Creates `StorageSharedKeyCredential` and `BlobServiceClient` from it
- Throws if either is missing

**Required change:**

Modify the constructor to support two auth paths:

1. **If `accessKeyId` AND `secretAccessKey` are provided:** Use existing `StorageSharedKeyCredential` path (backward compatible, no change).
2. **If either is missing (or a new env flag indicates AD auth):** Use `DefaultAzureCredential` from `@azure/identity` to create the `BlobServiceClient`.

**Instructions:**

- Import `DefaultAzureCredential` from `@azure/identity`
- Import `generateBlobSASQueryParameters`, `BlobSASSignatureValues`, `SASProtocol` from `@azure/storage-blob` (for user delegation SAS)
- Store a reference to the `BlobServiceClient` instance as a private field (currently only `ContainerClient` is stored). You need `BlobServiceClient` for `getUserDelegationKey()`.
- Add a private field `private useAdAuth: boolean` to track which auth path is active.
- In the constructor:
  - If key + secret provided → existing path
  - Else if endpoint provided → create `BlobServiceClient` with `new DefaultAzureCredential()`
  - Else → throw error
- No changes needed to: `uploadFile`, `uploadJson`, `download`, `listFiles`, `deleteFiles`, `createContainerIfNotExists` — these all use `this.client` (ContainerClient) which works the same regardless of credential type.

### 2.3 Modify `getSignedUrl` and `getSignedUploadUrl`

**Current behavior (lines 358-423):**

Both methods call `blockBlobClient.generateSasUrl(...)`. This method ONLY works with `StorageSharedKeyCredential`. With `DefaultAzureCredential`, it will throw an error.

**Required change:**

When using AD auth, implement **user delegation SAS**:

1. Call `this.blobServiceClient.getUserDelegationKey(startsOn, expiresOn)` — this returns a delegation key signed by Azure AD.
2. Use `generateBlobSASQueryParameters(...)` with the delegation key to produce SAS query params.
3. Construct the full URL: `blockBlobClient.url + "?" + sasQueryParams.toString()`

**Important details:**

- `getUserDelegationKey` requires the identity to have the **"Storage Blob Delegator"** RBAC role. Without it, this call returns a 403.
- The delegation key has a max lifetime of 7 days. The SAS token built from it can be shorter.
- For performance, consider caching the delegation key for 30 minutes (not longer — if permissions are revoked, a cached key still works until expiry).
- **Clock skew:** When building the SAS, set `startsOn` to at least **15 minutes in the past** (e.g., `new Date(Date.now() - 15 * 60 * 1000)`), or omit it entirely. Azure Storage servers and your pod may have slightly different clocks; if `startsOn` is set to "now," intermittent "not yet valid" 403 errors will occur at scale. This is documented by Microsoft: *"Set the start time to be at least 15 minutes in the past. Or, don't set it at all."* See: https://stackoverflow.com/questions/66191800 and http://www.allenconway.net/2023/11/dealing-with-time-skew-and-sas-azure.html
- Preserve the `externalEndpoint` URL replacement logic that already exists in both methods.

**Reference documentation:**
- User delegation SAS in Node.js: https://learn.microsoft.com/en-us/azure/storage/blobs/storage-blob-create-user-delegation-sas-javascript
- `generateBlobSASQueryParameters` API: https://learn.microsoft.com/en-us/javascript/api/@azure/storage-blob/generateblobsasqueryparameters
- `getUserDelegationKey` API: https://learn.microsoft.com/en-us/javascript/api/@azure/storage-blob/blobserviceclient#@azure-storage-blob-blobserviceclient-getuserdelegationkey

### 2.4 Optionally add new env vars

**File:** `packages/shared/src/env.ts` (around line 135)

The existing `LANGFUSE_USE_AZURE_BLOB` flag already exists. The simplest approach is: when `LANGFUSE_USE_AZURE_BLOB=true` and no `ACCESS_KEY_ID`/`SECRET_ACCESS_KEY` are provided for a given storage context, automatically use `DefaultAzureCredential`. This requires no new env var.

If you prefer an explicit flag, add:

```typescript
LANGFUSE_AZURE_BLOB_USE_AD_AUTH: z.enum(["true", "false"]).default("false"),
```

### 2.5 Verify backward compatibility

The following callers all pass `accessKeyId` and `secretAccessKey` from env vars. When these env vars are set, the existing key-based path should run unchanged:

- `web/src/features/media/server/getMediaStorageClient.ts` (line 13)
- `worker/src/features/evaluation/s3StorageClient.ts` (line 22)
- `worker/src/features/batchExport/handleBatchExportJob.ts` (line 237)
- `worker/src/queues/coreDataS3ExportQueue.ts` (line 14)
- `worker/src/queues/projectDelete.ts` (line 24)
- `worker/src/features/traces/processClickhouseTraceDelete.ts` (line 20)
- `worker/src/features/blobstorage/handleBlobStorageIntegrationProjectJob.ts` (line 167)

When `accessKeyId`/`secretAccessKey` are `undefined` (not set in env), the new AD auth path should activate.

### 2.6 Testing the code change

**Local test with Azurite (key-based, backward compat):**

```bash
# From repo root
pnpm install
pnpm run dev  # or pnpm run dx for full setup
# Existing tests that use MinIO/Azurite should still pass
```

**Test with real Azure Blob + Workload Identity:**

This can only be fully tested after Task 3 and Task 4 (Azure resources + Workload Identity). On a local machine, you can test with `DefaultAzureCredential` by setting:

```bash
export AZURE_TENANT_ID=<your-tenant-id>
export AZURE_CLIENT_ID=<your-spn-client-id>
export AZURE_CLIENT_SECRET=<your-spn-client-secret>
```

`DefaultAzureCredential` will pick these up. See: https://learn.microsoft.com/en-us/javascript/api/@azure/identity/defaultazurecredential

**WARNING — DefaultAzureCredential precedence:** `DefaultAzureCredential` tries credentials in this order: (1) Environment variables (`AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_CLIENT_SECRET`), (2) Workload Identity (injected by AKS webhook), (3) Managed Identity, (4) Azure CLI, etc. This means if `AZURE_CLIENT_ID`/`AZURE_CLIENT_SECRET` are set in the pod's environment for any reason (e.g., leftover from another tool, accidentally set in `additionalEnv`), they will take priority over Workload Identity and may cause unexpected auth failures. In production, do NOT set these env vars — let Workload Identity handle authentication. For local dev, use them intentionally. See: https://learn.microsoft.com/en-us/azure/developer/javascript/sdk/authentication/best-practices

---

## Task 3: Create Azure Resources

### 3.0 Automated script

**All of Tasks 3 through 9 are automated in [aks-create-resources.sh](./aks-create-resources.sh).** You can run it end-to-end or section-by-section. The instructions below explain what the script does, for understanding and troubleshooting.

```bash
export LANGFUSE_REPO_ROOT=/path/to/your/langfuse-fork
source docs/tasks/aks-create-resources.sh
```

### 3.1 Set variables

These are the **default concrete names** used by the script. Override via env vars before running.

```bash
export RESOURCE_GROUP="rg-langfuse-dev"
export LOCATION="eastus"
export AKS_NAME="aks-langfuse-dev"
export ACR_NAME="acrlangfusedev"          # must be globally unique; change if taken
export STORAGE_ACCOUNT="stlangfusedev"    # must be globally unique; change if taken
export IDENTITY_NAME="id-langfuse-dev"
export BLOB_CONTAINER="langfuse"
export K8S_NAMESPACE="langfuse"
export IMAGE_TAG="v1"
```

**Naming convention:** `<component>-langfuse-<env>` (e.g., `rg-langfuse-dev`, `aks-langfuse-dev`). For ACR and Storage Account, Azure requires alphanumeric-only names.

### 3.2 Resource Group

```bash
az group create --name $RESOURCE_GROUP --location $LOCATION
```

### 3.3 Azure Container Registry

```bash
az acr create --name $ACR_NAME --resource-group $RESOURCE_GROUP --sku Basic
```

**Reference:** https://learn.microsoft.com/en-us/azure/container-registry/container-registry-get-started-azure-cli

### 3.4 AKS Cluster

```bash
az aks create \
  --resource-group $RESOURCE_GROUP \
  --name $AKS_NAME \
  --enable-oidc-issuer \
  --enable-workload-identity \
  --attach-acr $ACR_NAME \
  --node-count 3 \
  --node-vm-size Standard_D4s_v5 \
  --generate-ssh-keys
```

**Key flags explained:**

- `--enable-oidc-issuer` — enables OpenID Connect issuer on the cluster (required for Workload Identity)
- `--enable-workload-identity` — enables Microsoft Entra Workload Identity
- `--attach-acr` — grants AKS the AcrPull role on ACR automatically (no image pull secret needed). **Important:** This works at the **node/kubelet level** (AKS cluster managed identity), NOT via Workload Identity. Workload Identity is pod-level and does NOT handle image pulls. If `--attach-acr` is not used, you must create an `imagePullSecret` separately. See: https://learn.microsoft.com/en-us/azure/aks/cluster-container-registry-integration
- `--node-vm-size Standard_D4s_v5` — 4 vCPU, 16 GB RAM per node. ClickHouse needs memory. Adjust for budget.

**Reference:** https://learn.microsoft.com/en-us/azure/aks/workload-identity-deploy-cluster

### 3.5 Azure Storage Account + Container

```bash
az storage account create \
  --name $STORAGE_ACCOUNT \
  --resource-group $RESOURCE_GROUP \
  --sku Standard_LRS \
  --kind StorageV2

az storage container create \
  --name $BLOB_CONTAINER \
  --account-name $STORAGE_ACCOUNT \
  --auth-mode login
```

**Note:** `--auth-mode login` uses your Azure CLI credential (SPN), not a storage key.

### 3.6 User-Assigned Managed Identity

```bash
az identity create \
  --name $IDENTITY_NAME \
  --resource-group $RESOURCE_GROUP \
  --location $LOCATION
```

Save the client ID and principal ID:

```bash
export IDENTITY_CLIENT_ID=$(az identity show \
  --name $IDENTITY_NAME \
  --resource-group $RESOURCE_GROUP \
  --query clientId -o tsv)

export IDENTITY_PRINCIPAL_ID=$(az identity show \
  --name $IDENTITY_NAME \
  --resource-group $RESOURCE_GROUP \
  --query principalId -o tsv)
```

### 3.7 RBAC: Assign roles on Storage Account

```bash
STORAGE_ID=$(az storage account show \
  --name $STORAGE_ACCOUNT \
  --resource-group $RESOURCE_GROUP \
  --query id -o tsv)

# Data plane: read/write/delete blobs, create containers
az role assignment create \
  --assignee-object-id $IDENTITY_PRINCIPAL_ID \
  --role "Storage Blob Data Contributor" \
  --scope $STORAGE_ID \
  --assignee-principal-type ServicePrincipal

# Required for user delegation SAS (presigned URLs)
az role assignment create \
  --assignee-object-id $IDENTITY_PRINCIPAL_ID \
  --role "Storage Blob Delegator" \
  --scope $STORAGE_ID \
  --assignee-principal-type ServicePrincipal
```

**CRITICAL:** Both roles are required. Without "Storage Blob Delegator", the `getUserDelegationKey()` call fails with 403 and presigned URLs will not work.

**Reference:** https://learn.microsoft.com/en-us/azure/storage/blobs/storage-blob-create-user-delegation-sas-javascript#assign-azure-roles-for-access-to-data

---

## Task 4: Configure AKS Workload Identity

### 4.1 Get the OIDC issuer URL

```bash
export AKS_OIDC_ISSUER=$(az aks show \
  --name $AKS_NAME \
  --resource-group $RESOURCE_GROUP \
  --query oidcIssuerProfile.issuerUrl -o tsv)
```

### 4.2 Create the federated identity credential

This links the managed identity to a Kubernetes service account. The Langfuse Helm chart creates a service account named `langfuse` in the `langfuse` namespace.

```bash
az identity federated-credential create \
  --name fed-langfuse \
  --identity-name $IDENTITY_NAME \
  --resource-group $RESOURCE_GROUP \
  --issuer $AKS_OIDC_ISSUER \
  --subject system:serviceaccount:langfuse:langfuse \
  --audience api://AzureADTokenExchange
```

**Important:** The `--subject` format is `system:serviceaccount:<namespace>:<service-account-name>`. The Helm chart creates a SA named `langfuse` when `langfuse.serviceAccount.create: true`.

**Reference:** https://learn.microsoft.com/en-us/azure/aks/workload-identity-deploy-cluster#create-the-federated-identity-credential

### 4.3 Get AKS credentials

```bash
az aks get-credentials --name $AKS_NAME --resource-group $RESOURCE_GROUP
kubectl create namespace langfuse
```

---

## Task 5: Configure Azure AD SSO (App Registration)

> **Note:** The [aks-create-resources.sh](./aks-create-resources.sh) script automates Task 5 using `az ad app create`. The manual steps below are for reference or if you prefer using the Azure Portal.

### 5.1 Create App Registration in Azure Portal

1. Go to **Azure Portal** > **Microsoft Entra ID** > **App registrations** > **New registration**
2. **Name:** `Langfuse SSO (rg-langfuse-dev)` (include your resource group for clarity)
3. **Supported account types:** "Accounts in this organizational directory only" (single tenant)
4. **Redirect URI:** Platform = Web, URI = `http://localhost:3000/api/auth/callback/azure-ad`
   - For production with ingress: `https://langfuse.yourdomain.com/api/auth/callback/azure-ad`
   - **CRITICAL:** This must exactly match `NEXTAUTH_URL` + `/api/auth/callback/azure-ad`. A mismatch will cause SSO to fail silently (redirect_uri_mismatch error).
5. Click **Register**

### 5.2 Configure token claims

1. Go to the App Registration > **Token configuration**
2. Click **Add optional claim** > **ID** > check **email** > **Add**
3. If prompted to add Microsoft Graph email permission, accept

**Reference (Langfuse-specific note):** https://langfuse.com/self-hosting/security/authentication-and-sso#azure-adentra-id

> "Langfuse uses email to identify users. You need to add the email claim in the token configuration and all users must have an Email in their user profile."

### 5.3 Generate client secret

1. Go to **Certificates & secrets** > **New client secret**
2. Set a description (e.g., "Langfuse SSO") and expiry
3. **Copy the `Value` immediately** (not the `Secret ID`). You cannot retrieve it later.

### 5.4 Record the values

Save these — you'll need them for Kubernetes Secrets:

- **Application (client) ID** — from the Overview page
- **Directory (tenant) ID** — from the Overview page
- **Client secret Value** — from step 5.3

### 5.5 Langfuse environment variables for SSO

These are the env vars Langfuse reads (verified in `web/src/env.mjs` lines 119-124 and `web/src/server/auth.ts` lines 342-358):

```
AUTH_AZURE_AD_CLIENT_ID=<Application (client) ID>
AUTH_AZURE_AD_CLIENT_SECRET=<Client secret Value>
AUTH_AZURE_AD_TENANT_ID=<Directory (tenant) ID>
AUTH_DISABLE_USERNAME_PASSWORD=true
AUTH_AZURE_AD_ALLOW_ACCOUNT_LINKING=true
NEXTAUTH_URL=https://<YOUR_LANGFUSE_DOMAIN>
```

**Reference:** https://langfuse.com/self-hosting/security/authentication-and-sso#azure-adentra-id

---

## Task 6: Build and Push Container Images

### 6.1 Log in to ACR

```bash
az acr login --name $ACR_NAME
```

### 6.2 Build images

From the root of your forked Langfuse repo (with the StorageService change):

```bash
# Web image
docker build -f web/Dockerfile \
  -t $ACR_NAME.azurecr.io/langfuse-web:v1 .

# Worker image
docker build -f worker/Dockerfile \
  -t $ACR_NAME.azurecr.io/langfuse-worker:v1 .
```

**Notes:**
- Both Dockerfiles use Node.js 24 Alpine base images (`web/Dockerfile` line 2, `worker/Dockerfile` line 2)
- The build uses `turbo prune` to create an isolated workspace, then `pnpm install --frozen-lockfile`, then `turbo run build`
- The web Dockerfile removes `middleware.ts` (line 77) — this is intentional for self-hosted
- Build can take 5-15 minutes depending on your machine

### 6.3 Push images

```bash
docker push $ACR_NAME.azurecr.io/langfuse-web:v1
docker push $ACR_NAME.azurecr.io/langfuse-worker:v1
```

---

## Task 7: Create Kubernetes Secrets

### 7.1 Generate app secrets

```bash
export NEXTAUTH_SECRET=$(openssl rand -hex 32)
export SALT=$(openssl rand -base64 32)
export ENCRYPTION_KEY=$(openssl rand -hex 32)
```

### 7.2 Create secrets in the cluster

```bash
# App secrets
kubectl create secret generic langfuse-secrets -n langfuse \
  --from-literal=nextauth-secret=$NEXTAUTH_SECRET \
  --from-literal=salt=$SALT \
  --from-literal=encryption-key=$ENCRYPTION_KEY

# SSO secrets
kubectl create secret generic langfuse-sso -n langfuse \
  --from-literal=client-id=<AUTH_AZURE_AD_CLIENT_ID> \
  --from-literal=client-secret=<AUTH_AZURE_AD_CLIENT_SECRET_VALUE>
```

Replace the `<...>` placeholders with values from Task 5.

---

## Task 8: Prepare Helm Values and Deploy

### 8.1 Add the Langfuse Helm repo

```bash
helm repo add langfuse https://langfuse.github.io/langfuse-k8s
helm repo update
```

**Reference:** https://github.com/langfuse/langfuse-k8s

### 8.2 Create `values.yaml`

Use the template at [aks-helm-values.example.yaml](./aks-helm-values.example.yaml). The script generates this automatically using `sed` to substitute placeholders. If you're doing it manually:

```bash
cp docs/tasks/aks-helm-values.example.yaml values.yaml
# Then replace all <PLACEHOLDER> values — see the instructions in the file header.
```

**Key configuration points:**

- `langfuse.nextauth.url` — MUST match the redirect URI base in your Azure AD App Registration. Use `http://localhost:3000` for port-forward testing.
- `langfuse.additionalEnv` — Contains SSO vars and `LANGFUSE_USE_AZURE_BLOB=true`. Do NOT duplicate the blob endpoint/bucket env vars here — the `s3:` section handles those.
- `s3:` section — Maps to `LANGFUSE_S3_*` env vars in the pod. Do NOT set `accessKeyId` or `secretAccessKey` — Workload Identity handles auth.
- **WARNING:** Do NOT set `AZURE_CLIENT_ID` / `AZURE_CLIENT_SECRET` / `AZURE_TENANT_ID` in `additionalEnv`. This would override Workload Identity (see `DefaultAzureCredential` precedence in Task 2.6).

See the file itself for the full annotated structure.

### 8.3 Deploy

```bash
helm install langfuse langfuse/langfuse -n langfuse -f values.yaml
```

**Important:** The Helm chart assumes the release name is `langfuse`. If you use a different name, the internal Redis hostname changes and you must override `redis.host`.

**Reference:** https://langfuse.com/self-hosting/deployment/kubernetes-helm

### 8.4 Monitor deployment

```bash
kubectl get pods -n langfuse -w
```

Expect:
- `langfuse-web-*` and `langfuse-worker-*` pods may restart a few times while databases initialize
- All pods should be `Running` within 5 minutes
- Check logs if a pod is in CrashLoopBackOff: `kubectl logs <pod-name> -n langfuse`

---

## Task 9: Verification and Testing

### 9.1 Basic smoke test

```bash
# Port forward to access the UI
kubectl port-forward svc/langfuse-web 3000:3000 -n langfuse

# Open http://localhost:3000 in your browser
```

**Expected:** You should see the Langfuse login page with an "Azure AD" button (no username/password fields if `AUTH_DISABLE_USERNAME_PASSWORD=true`).

### 9.2 SSO test

1. Click "Azure AD" on the login page
2. Authenticate with your corporate account
3. You should land on the Langfuse dashboard
4. Create an organization and a project

### 9.3 Blob Storage test (Workload Identity)

1. In Langfuse, create a project
2. Use the Langfuse Python or JS SDK to send a trace:

```python
# pip install langfuse
from langfuse import Langfuse
langfuse = Langfuse(
    public_key="<project-public-key>",
    secret_key="<project-secret-key>",
    host="http://localhost:3000"
)
trace = langfuse.trace(name="test-trace", input={"test": "hello"})
langfuse.flush()
```

3. Check the web pod logs for any storage errors:

```bash
kubectl logs -l app=web -n langfuse | grep -i "azure\|blob\|storage\|error"
```

4. Check if events are stored in Azure Blob:

```bash
az storage blob list \
  --container-name $BLOB_CONTAINER \
  --account-name $STORAGE_ACCOUNT \
  --auth-mode login \
  --prefix events/ \
  --output table
```

### 9.4 Failure modes to check

| Test | What to check | Expected if broken |
|---|---|---|
| Blob upload | Send a trace via SDK | Pod logs: "Failed to upload" or 403 error |
| Presigned URL (download) | View a trace in the UI | Pod logs: "Failed to generate presigned URL" or `getUserDelegationKey` 403 |
| Presigned URL (upload) | Upload media via SDK | Same as above |
| Missing Delegator role | Remove "Storage Blob Delegator" role and test presigned URLs | 403 on `getUserDelegationKey` — uploads/downloads still work, but presigned URLs fail |

---

## Task 10: Document Rollback Procedures

### Rollback: code change

If the StorageService change causes issues, revert to key-based auth by setting the storage account access key in the Helm values:

```yaml
s3:
  accessKeyId:
    value: "<storage-account-name>"
  secretAccessKey:
    value: "<storage-account-key>"
```

This activates the existing key-based path without any code change. Use this as an emergency fallback only.

### Rollback: Helm deployment

```bash
# Roll back to previous Helm release
helm rollback langfuse -n langfuse

# Or uninstall entirely
helm uninstall langfuse -n langfuse
```

### Rollback: SSO

If SSO is misconfigured, temporarily re-enable username/password login:

```yaml
additionalEnv:
  - name: AUTH_DISABLE_USERNAME_PASSWORD
    value: "false"
```

Then `helm upgrade langfuse langfuse/langfuse -n langfuse -f values.yaml`.

---

## Reference Links

### Langfuse

| Resource | URL |
|---|---|
| Langfuse GitHub (app) | https://github.com/langfuse/langfuse |
| Langfuse Helm chart repo | https://github.com/langfuse/langfuse-k8s |
| Helm chart on Artifact Hub | https://artifacthub.io/packages/helm/langfuse-k8s/langfuse |
| Kubernetes deployment docs | https://langfuse.com/self-hosting/deployment/kubernetes-helm |
| Azure Blob Storage docs | https://langfuse.com/self-hosting/deployment/infrastructure/blobstorage |
| SSO / Azure AD docs | https://langfuse.com/self-hosting/security/authentication-and-sso#azure-adentra-id |
| Environment variables | https://langfuse.com/self-hosting/configuration |

### Azure

| Resource | URL |
|---|---|
| AKS Workload Identity overview | https://learn.microsoft.com/en-us/azure/aks/workload-identity-overview |
| Deploy Workload Identity on AKS | https://learn.microsoft.com/en-us/azure/aks/workload-identity-deploy-cluster |
| Create user delegation SAS (JS) | https://learn.microsoft.com/en-us/azure/storage/blobs/storage-blob-create-user-delegation-sas-javascript |
| `@azure/identity` npm | https://www.npmjs.com/package/@azure/identity |
| `DefaultAzureCredential` docs | https://learn.microsoft.com/en-us/javascript/api/@azure/identity/defaultazurecredential |
| `@azure/storage-blob` npm | https://www.npmjs.com/package/@azure/storage-blob |
| Storage Blob Data Contributor role | https://learn.microsoft.com/en-us/azure/role-based-access-control/built-in-roles/storage#storage-blob-data-contributor |
| Storage Blob Delegator role | https://learn.microsoft.com/en-us/azure/role-based-access-control/built-in-roles/storage#storage-blob-delegator |
| CloudNativePG on AKS (future) | https://learn.microsoft.com/en-us/azure/aks/deploy-postgresql-ha |
| CloudNativePG Azure Blob backup | https://cloudnative-pg.io/plugin-barman-cloud/docs/object_stores/#azure-blob-storage |

### Codebase files (this repo)

| File | What it contains |
|---|---|
| `packages/shared/src/server/services/StorageService.ts` | **Primary file to modify.** Azure Blob auth + SAS generation. |
| `packages/shared/src/env.ts` (lines 112-139) | Env var definitions for S3/Blob/Azure. |
| `packages/shared/package.json` (line 74) | `@azure/storage-blob` dependency. Add `@azure/identity` here. |
| `web/src/env.mjs` (lines 119-124) | Azure AD SSO env vars. |
| `web/src/server/auth.ts` (lines 342-358) | Azure AD SSO provider setup in NextAuth. |
| `web/Dockerfile` | Web container build. |
| `worker/Dockerfile` | Worker container build. |
| `web/entrypoint.sh` | Startup: constructs DATABASE_URL, runs Prisma migrations. |
| `web/src/features/media/server/getMediaStorageClient.ts` | Caller of StorageServiceFactory (media uploads). |
| `worker/src/features/evaluation/s3StorageClient.ts` | Caller of StorageServiceFactory (event uploads). |
| `worker/src/features/batchExport/handleBatchExportJob.ts` | Caller of StorageServiceFactory (batch exports). |

---

## Decision Log

| # | Decision | Rationale |
|---|---|---|
| 1 | Run PostgreSQL, Redis, ClickHouse in-cluster | Avoids Azure-generated access keys. Security team policy. |
| 2 | Use Azure Blob externally with Workload Identity | Only external Azure data-plane resource. Workload Identity = no keys. |
| 3 | Use `DefaultAzureCredential` (not `ClientSecretCredential`) | Supports Workload Identity (zero secrets in cluster) and falls back to env vars for local dev. |
| 4 | Implement user delegation SAS for presigned URLs | `generateSasUrl()` requires account key. User delegation SAS works with any Azure AD credential. |
| 5 | Do NOT fork the Helm chart | Use `additionalEnv`, `pod.labels`, and `serviceAccount.annotations` to configure everything. Less maintenance. |
| 6 | Use Bitnami subcharts for data stores (test) | Simple, works out of the box. For enterprise, swap to CloudNativePG (PostgreSQL) — it's a Helm values change, not a code change. |
| 7 | SSO via env vars, not code | Langfuse already supports Azure AD SSO. Just set `AUTH_AZURE_AD_*` env vars. |
| 8 | Both RBAC roles on storage account | "Storage Blob Data Contributor" + "Storage Blob Delegator". Missing Delegator = presigned URLs fail. |

---

## Checklist

**Deliverables (done in repo):**

- [x] Fork created and cloned (user clones their fork; repo is ready)
- [x] `@azure/identity` added to `packages/shared/package.json`
- [x] `StorageService.ts` modified: DefaultAzureCredential path + user delegation SAS
- [x] Backward compatibility: key-based path unchanged when `accessKeyId`/`secretAccessKey` are set
- [x] Azure Resource Group, ACR, AKS, Storage, Identity, RBAC — script: [aks-create-resources.sh](./aks-create-resources.sh) (Task 3)
- [x] Federated credential (identity ↔ K8s SA) — same script (Task 4)
- [x] App Registration (SSO) with email claim + client secret — same script (Task 5)
- [x] Docker images built and pushed to ACR — same script (Task 6)
- [x] K8s namespace and secrets created — same script (Task 7)
- [x] `values.yaml` prepared from [aks-helm-values.example.yaml](./aks-helm-values.example.yaml) — same script (Task 8)
- [x] Helm install — same script (Task 8)
- [x] Rollback procedures documented — [aks-rollback.md](./aks-rollback.md) (Task 10)

**After you run the script (user verification):**

- [ ] All pods running (`kubectl get pods -n langfuse`)
- [ ] SSO login works (port-forward, then sign in with Azure AD)
- [ ] Trace ingestion works (events in Azure Blob)
- [ ] Presigned URLs work (media download/upload)
- [ ] Rollback steps tested (optional)
