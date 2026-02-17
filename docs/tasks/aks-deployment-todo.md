# AKS SPN-only deployment – master checklist

Deploy Langfuse on AKS with **SPN-only** auth (no storage/Redis keys), **Workload Identity** for Azure Blob, and **Azure AD SSO**. Full details: [aks-spn-deployment-task-template.md](./aks-spn-deployment-task-template.md).

---

## Default resource names

| Resource | Default Name | Notes |
|----------|-------------|-------|
| Resource Group | `rg-langfuse-dev` | Contains all Azure resources |
| AKS Cluster | `aks-langfuse-dev` | 2 nodes, Standard_D4s_v5 |
| ACR | `acrlangfusedev` | Must be globally unique; change if taken |
| Storage Account | `stlangfusedev` | Must be globally unique; change if taken |
| Managed Identity | `id-langfuse-dev` | For Workload Identity |
| Blob Container | `langfuse` | Inside the storage account |
| K8s Namespace | `langfuse` | All pods and secrets live here |
| Helm Release | `langfuse` | `helm install langfuse ...` |
| SSO App Registration | `Langfuse SSO (rg-langfuse-dev)` | In Azure AD |

---

## Quick reference

| Task | Description | Artifacts | Status |
|------|-------------|-----------|--------|
| 1 | Fork/understand repo | Repo present; see CLAUDE.md, AGENTS.md | Manual |
| 2 | **Modify StorageService for Azure AD auth** | `packages/shared`: `@azure/identity`, `StorageService.ts` | **Done in repo** |
| 3 | Create Azure resources | [aks-create-resources.sh](./aks-create-resources.sh) | **Scripted** |
| 4 | Configure AKS Workload Identity | Same script (Task 3+4) | **Scripted** |
| 5 | Configure Azure AD SSO (App Registration) | Same script (Task 5) | **Scripted** |
| 6 | Build and push container images | Same script (Task 6) | **Scripted** |
| 7 | Create Kubernetes secrets | Same script (Task 7) | **Scripted** |
| 8 | Prepare Helm values and deploy | Same script (Task 8) + [aks-helm-values.example.yaml](./aks-helm-values.example.yaml) | **Scripted** |
| 9 | Verification and testing | Same script prints instructions (Task 9) | Semi-manual |
| 10 | Document rollback procedures | [aks-rollback.md](./aks-rollback.md) | **Done** |

---

## How to run

```bash
# 1. Ensure prerequisites: az (logged in), docker (running), kubectl, helm, openssl
# 2. Set the repo root (required):
export LANGFUSE_REPO_ROOT=/path/to/your/langfuse-fork

# 3. (Optional) Override any defaults:
# export RESOURCE_GROUP=rg-langfuse-staging
# export ACR_NAME=acrlangfusestaging
# export STORAGE_ACCOUNT=stlangfusestaging

# 4. Run the full script:
bash docs/tasks/aks-create-resources.sh
```

The script handles Tasks 3–9 end-to-end, including Azure AD App Registration, Docker image builds, K8s secrets, Helm install, and prints verification steps.

---

## Checklist (in order)

- [ ] **Task 1** – Repo forked/cloned; read CLAUDE.md, AGENTS.md, StorageService.ts, env files, Dockerfiles.
- [ ] **Task 2** – `@azure/identity` added; `AzureBlobStorageService` supports DefaultAzureCredential + user delegation SAS; backward compat verified. (**Already done in the repo.**)
- [ ] **Task 3** – Resource group, ACR, AKS (OIDC + Workload Identity + attach ACR), Storage Account + container, User-Assigned Managed Identity, RBAC (Storage Blob Data Contributor + **Storage Blob Delegator**).
- [ ] **Task 4** – OIDC issuer obtained; federated credential created (`system:serviceaccount:langfuse:langfuse`); `kubectl` credentials and `langfuse` namespace.
- [ ] **Task 5** – App Registration (`Langfuse SSO (rg-langfuse-dev)`); redirect URI `http://localhost:3000/api/auth/callback/azure-ad`; optional claim **email**; client secret saved; client ID, tenant ID, secret value recorded.
- [ ] **Task 6** – `az acr login`; Docker build web + worker from repo root; push to `acrlangfusedev.azurecr.io`.
- [ ] **Task 7** – `NEXTAUTH_SECRET`, `SALT`, `ENCRYPTION_KEY` generated; `langfuse-secrets` and `langfuse-sso` created in `langfuse` namespace.
- [ ] **Task 8** – Helm repo added; `values.yaml` from example with all placeholders replaced via `sed`; `helm install langfuse langfuse/langfuse -n langfuse -f values.yaml`; pods running.
- [ ] **Task 9** – Port-forward to web (`kubectl port-forward svc/langfuse-web 3000:3000 -n langfuse`); login via Azure AD; create project; send trace via SDK; confirm events in Blob; confirm presigned URLs (media upload/download).
- [ ] **Task 10** – Rollback steps read and tested if needed; see [aks-rollback.md](./aks-rollback.md).

---

## Critical points

- **Storage Blob Delegator** role is required on the managed identity for presigned URLs (user delegation SAS). Without it, `getUserDelegationKey()` returns 403.
- Do **not** set `AZURE_CLIENT_ID` / `AZURE_CLIENT_SECRET` / `AZURE_TENANT_ID` in pod env in production; let Workload Identity provide credentials via the projected service account token. `DefaultAzureCredential` checks env vars *before* Workload Identity.
- **ACR image pulls** use the AKS node/kubelet managed identity (via `--attach-acr`), NOT pod-level Workload Identity. If `--attach-acr` fails, create an `imagePullSecret` instead.
- **Clock skew**: SAS `startsOn` is set 15 minutes in the past to avoid intermittent "not yet valid" 403 errors.
- In-cluster: PostgreSQL, Redis, ClickHouse (Helm subcharts). External: only Azure Blob, accessed via Workload Identity.
- **Globally unique names**: ACR (`acrlangfusedev`) and Storage Account (`stlangfusedev`) must be globally unique across all of Azure. If taken, override with env vars before running the script.
