# Langfuse on AKS — Client Deployment Guide (SPN‑Only, Workload Identity, Azure AD SSO)

**Audience:** Enterprise client platform teams

This guide provides a complete, client‑facing deployment and upgrade reference for running **Langfuse on Azure Kubernetes Service (AKS)** using **Service Principal / Workload Identity only** (no Azure storage account keys) and **Azure AD SSO**. It is aligned with the implementation and scripts in this repo.

---

## 0) Prerequisites

Install the following on the machine that will run the deployment:

| Tool                 | Minimum Version | Install                                                                   |
| -------------------- | --------------- | ------------------------------------------------------------------------- |
| **Azure CLI (`az`)** | 2.60+           | `curl -sL https://aka.ms/InstallAzureCLIDeb \| sudo bash`                 |
| **kubectl**          | 1.28+           | `az aks install-cli`                                                      |
| **Helm**             | 3.14+           | [helm.sh/docs/intro/install](https://helm.sh/docs/intro/install/)         |
| **Docker**           | 24+             | [docs.docker.com/engine/install](https://docs.docker.com/engine/install/) |

Log in to Azure and set your subscription:

```bash
az login
az account set --subscription "<SUBSCRIPTION_NAME_OR_ID>"
```

---

## 1) Hard Constraints (Must‑Follow)

- **No Azure storage account keys** anywhere (no `accessKeyId` / `secretAccessKey`).
- **Workload Identity only** for Blob access.
- **Official Helm chart only** (`langfuse/langfuse-k8s`) — **do not fork** the chart.
- **In‑cluster** PostgreSQL + Redis + ClickHouse.
- **Azure AD SSO** required for all users.

---

## 2) Required Azure Resources (Client‑Provisioned)

### Resource Group

- Example: `rg-<client>-langfuse-<env>`

### AKS Cluster

- OIDC issuer enabled
- Workload Identity enabled
- ACR attached (AcrPull at node identity level)
- Suggested node size: **Standard_D4s_v5** (use larger for production)

### Azure Container Registry (ACR)

- Used for `langfuse-web` and `langfuse-worker` images

### Storage Account (Blob)

- StorageV2, Standard_LRS
- Blob container name (e.g. `langfuse`)

### User‑Assigned Managed Identity

- Used by Langfuse pods for Blob access via Workload Identity

### RBAC (Mandatory)

Assign both roles on the Storage Account **to the managed identity**:

- `Storage Blob Data Contributor`
- `Storage Blob Delegator` (required for presigned URLs)

---

## 3) Workload Identity Wiring

Create a **federated credential** for the managed identity:

- **Issuer:** AKS OIDC issuer URL
- **Subject:** `system:serviceaccount:langfuse:langfuse`
- **Audience:** `api://AzureADTokenExchange`

> **Important:** Do NOT set `AZURE_CLIENT_ID`, `AZURE_CLIENT_SECRET`, or `AZURE_TENANT_ID` in pod env. `DefaultAzureCredential` will prefer env vars and bypass Workload Identity, which breaks this design.

---

## 4) Azure AD SSO (Entra ID)

### App Registration

- **Single tenant**
- Redirect URI: `https://<LANGFUSE_PUBLIC_URL>/api/auth/callback/azure-ad`
- Add **email** optional claim to ID token

Capture:

- **Application (client) ID**
- **Directory (tenant) ID**
- **Client secret Value** (not the secret ID)

---

## 5) Kubernetes Namespace & Secrets

### Create the namespace

```bash
kubectl create namespace langfuse
```

### App Secrets

Generate strong random values and create the secret:

```bash
kubectl create secret generic langfuse-secrets -n langfuse \
  --from-literal=nextauth-secret="$(openssl rand -hex 32)" \
  --from-literal=salt="$(openssl rand -hex 32)" \
  --from-literal=encryption-key="$(openssl rand -hex 32)"
```

### SSO Secrets

Use the **Application (client) ID** and **Client secret Value** from your Azure AD App Registration (§4):

```bash
kubectl create secret generic langfuse-sso -n langfuse \
  --from-literal=client-id="<AUTH_AZURE_AD_CLIENT_ID>" \
  --from-literal=client-secret="<AUTH_AZURE_AD_CLIENT_SECRET>"
```

---

## 6) Build & Publish Images (From Your Fork)

**Tagging requirement:** use **git SHA** tags for traceability.

From the root of the Langfuse repo:

```bash
# Set image tag to current git SHA
export GIT_SHA=$(git rev-parse --short HEAD)

# Point kubectl at the cluster
az aks get-credentials --resource-group <RESOURCE_GROUP> --name <AKS_CLUSTER_NAME>

# Log in to ACR
az acr login --name <ACR_NAME>

# Build images
docker build -t <ACR_NAME>.azurecr.io/langfuse-web:$GIT_SHA -f web/Dockerfile .
docker build -t <ACR_NAME>.azurecr.io/langfuse-worker:$GIT_SHA -f worker/Dockerfile .

# Push images
docker push <ACR_NAME>.azurecr.io/langfuse-web:$GIT_SHA
docker push <ACR_NAME>.azurecr.io/langfuse-worker:$GIT_SHA
```

> **Tip:** If `az acr login` fails with a credential-helper error on WSL/Linux, check `~/.docker/config.json` and remove `"credsStore": "desktop"` if present.

---

## 7) Helm Deployment (Official Chart)

```bash
# Add the Langfuse Helm repo (first time only)
helm repo add langfuse https://langfuse.github.io/langfuse-k8s
helm repo update

# Install (namespace must already exist from §5)
helm install langfuse langfuse/langfuse -n langfuse -f values.yaml
```

> **Important:** The chart assumes release name **`langfuse`**. If you change it, you must override the Redis host.

---

## 8) Reference `values.yaml` (Client‑Facing)

Replace all `<...>` placeholders.

```yaml
langfuse:
  serviceAccount:
    create: true
    annotations:
      azure.workload.identity/client-id: "<IDENTITY_CLIENT_ID>"

  pod:
    labels:
      azure.workload.identity/use: "true"

  nextauth:
    url: "https://<LANGFUSE_PUBLIC_URL>" # Must match Azure AD redirect URI base
    secret:
      secretKeyRef:
        name: langfuse-secrets
        key: nextauth-secret

  salt:
    secretKeyRef:
      name: langfuse-secrets
      key: salt

  encryptionKey:
    secretKeyRef:
      name: langfuse-secrets
      key: encryption-key

  web:
    image:
      repository: "<ACR_NAME>.azurecr.io/langfuse-web"
      tag: "<GIT_SHA>" # Use git SHA tag
    # If using Front Door / App Gateway, enable LoadBalancer:
    # service:
    #   type: LoadBalancer

  worker:
    image:
      repository: "<ACR_NAME>.azurecr.io/langfuse-worker"
      tag: "<GIT_SHA>"

  additionalEnv:
    # --- Azure AD SSO ---
    - name: AUTH_AZURE_AD_CLIENT_ID
      valueFrom:
        secretKeyRef:
          name: langfuse-sso
          key: client-id
    - name: AUTH_AZURE_AD_CLIENT_SECRET
      valueFrom:
        secretKeyRef:
          name: langfuse-sso
          key: client-secret
    - name: AUTH_AZURE_AD_TENANT_ID
      value: "<TENANT_ID>"
    - name: AUTH_DISABLE_USERNAME_PASSWORD
      value: "true"
    - name: AUTH_AZURE_AD_ALLOW_ACCOUNT_LINKING
      value: "true"

  ingress:
    enabled: false

# In‑cluster data stores
postgresql:
  deploy: true
  auth:
    username: postgres
    password: "<DB_PASSWORD>"
    database: langfuse

redis:
  deploy: true
  auth:
    password: "<REDIS_PASSWORD>"

clickhouse:
  deploy: true
  auth:
    password: "<CH_PASSWORD>"
  replicaCount: 1
  # Sizing:
  # - Test run (<=2 projects, low traffic): use "large".
  # - Production: use "2xlarge" or larger; ClickHouse is the first bottleneck for dashboards/observations.
  resourcesPreset: "large" # change to "2xlarge" or larger for production
  # Avoid "Trace not found" / worker dropping records: default Bitnami persistence is 8Gi and fills up.
  # Test: 50Gi is usually fine; Production: start at 100Gi+.
  persistence:
    size: 50Gi # increase as needed; use project data retention to limit growth

# Azure Blob (Workload Identity, no keys)
s3:
  deploy: false
  storageProvider: "azure"
  bucket: "<BLOB_CONTAINER>"
  endpoint: "https://<STORAGE_ACCOUNT>.blob.core.windows.net"
  # Do NOT set accessKeyId/secretAccessKey
  eventUpload:
    prefix: "events/"
  batchExport:
    enabled: true
    prefix: "exports/"
  mediaUpload:
    enabled: true
    prefix: "media/"
```

---

## 9) Validation Checklist (Mandatory)

- **Pods running:** `kubectl get pods -n langfuse`
- **SSO login:** open `https://<LANGFUSE_PUBLIC_URL>` → Azure AD login
- **Blob access:** send a trace and verify objects under `events/` in Blob
- **Presigned URLs:** upload/download media files (no 403s)

---

## 10) Known Failure Modes (and Fixes)

| Symptom                                                    | Likely Cause                               | Fix                                                                                                                             |
| ---------------------------------------------------------- | ------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------- |
| Presigned URL 403                                          | Missing **Storage Blob Delegator** role    | Assign role to managed identity                                                                                                 |
| “State cookie missing”                                     | `nextauth.url` mismatch                    | Align `nextauth.url` + Azure AD redirect URI                                                                                    |
| Image pull errors                                          | ACR not attached / no AcrPull              | Attach ACR to AKS or add imagePullSecret                                                                                        |
| CrashLoopBackOff                                           | DB/ClickHouse not ready                    | Check DB pods, then web/worker logs                                                                                             |
| "Trace not found" / worker "dropped N traces/observations" | **ClickHouse disk full** (default PVC 8Gi) | Resize the existing PVC with kubectl (Helm cannot change StatefulSet volumeClaimTemplates). See **ClickHouse disk full** below. |

### ClickHouse disk full (worker drops traces, "Trace not found")

StatefulSet spec is immutable for `volumeClaimTemplates`, so **do not** use `helm upgrade --set clickhouse.persistence.size=30Gi` on an existing release—it will fail. Resize the existing PVC in place (requires a storage class that supports volume expansion, e.g. many Azure Disk classes):

```bash
# List ClickHouse PVC(s) (typically data-langfuse-clickhouse-shard0-0)
kubectl get pvc -n langfuse

# Resize to 50Gi (use the PVC name from above)
kubectl patch pvc data-langfuse-clickhouse-shard0-0 -n langfuse -p '{"spec":{"resources":{"requests":{"storage":"50Gi"}}}}'

# Restart ClickHouse so it sees the resized volume
kubectl delete pod -n langfuse -l app.kubernetes.io/name=clickhouse
```

If your storage class does not support expansion, you must backup data, delete the StatefulSet and PVCs, set `clickhouse.persistence.size` in values and reinstall, then restore.

---

## 11) Upgrade Procedure (Client‑Safe)

Run these commands from the root of the Langfuse repo:

```bash
# 1. Set the new image tag
export GIT_SHA=$(git rev-parse --short HEAD)

# 2. Build and push new images (same as §6)
az acr login --name <ACR_NAME>
docker build -t <ACR_NAME>.azurecr.io/langfuse-web:$GIT_SHA -f web/Dockerfile .
docker build -t <ACR_NAME>.azurecr.io/langfuse-worker:$GIT_SHA -f worker/Dockerfile .
docker push <ACR_NAME>.azurecr.io/langfuse-web:$GIT_SHA
docker push <ACR_NAME>.azurecr.io/langfuse-worker:$GIT_SHA

# 3. Upgrade the Helm release (keeps all existing config, only changes image tags)
helm upgrade langfuse langfuse/langfuse -n langfuse --reuse-values \
  --set langfuse.web.image.tag=$GIT_SHA \
  --set langfuse.worker.image.tag=$GIT_SHA

# 4. Wait for rollouts to complete
kubectl rollout status deployment/langfuse-web -n langfuse
kubectl rollout status deployment/langfuse-worker -n langfuse
```

> **Note:** If you maintain a `values.yaml` file, update `langfuse.web.image.tag` and `langfuse.worker.image.tag` in that file and use `helm upgrade langfuse langfuse/langfuse -n langfuse -f values.yaml` instead of `--reuse-values --set`.

---

## 12) Rollback Procedure

```
helm history langfuse -n langfuse
helm rollback langfuse <REVISION> -n langfuse
```

If Blob auth fails, emergency fallback is to **temporarily** add storage keys in Helm values (not recommended for enterprise policies).

---

## 13) Reference Links

- Helm chart repo: https://github.com/langfuse/langfuse-k8s
- Kubernetes deployment docs: https://langfuse.com/self-hosting/deployment/kubernetes-helm
- Azure AD SSO docs: https://langfuse.com/self-hosting/security/authentication-and-sso#azure-adentra-id
- Workload Identity overview: https://learn.microsoft.com/en-us/azure/aks/workload-identity-overview
- Storage Blob Delegator role: https://learn.microsoft.com/en-us/azure/role-based-access-control/built-in-roles/storage#storage-blob-delegator
