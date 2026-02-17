# AKS deployment — resume

**Last run got to:** Task 6 (Docker build). Web image build finished (~6 min) but the run **timed out** during image export, so the script was killed before push/Helm.

**Already created (safe to skip on re-run):**
- Resource group: `rg-langfuse-dev`
- ACR: `acrlangfusedev4fbb5a`
- AKS: `aks-langfuse-dev` (ACR attached)
- Storage account: `stlangfusedev383140`
- Blob container: `langfuse`
- Managed identity, RBAC, federated credential, SSO app, K8s secrets (if script got that far)
- Script is **idempotent**: existing resources are skipped.

**To resume from Task 8 (after 7.3)** — skip Tasks 3–7 and run only Helm deploy + verification.

**Prerequisites:** `az`, `kubectl`, **`helm`**, `openssl` must be installed and in PATH. Install Helm: https://helm.sh/docs/intro/install/ (e.g. `curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash` or your package manager).

```bash
export RESUME_FROM=8
export LANGFUSE_REPO_ROOT=/path/to/langfuse
export ACR_NAME="acrlangfusedev4fbb5a"
export STORAGE_ACCOUNT="stlangfusedev383140"
# IDENTITY_CLIENT_ID is fetched from Azure if not set (identity id-langfuse-dev in rg-langfuse-dev)
bash docs/tasks/aks-create-resources.sh
```

**To run from the start** (same env vars; use a longer timeout for Docker build):

```bash
export LANGFUSE_REPO_ROOT=/path/to/langfuse
export ACR_NAME="acrlangfusedev4fbb5a"
export STORAGE_ACCOUNT="stlangfusedev383140"
bash docs/tasks/aks-create-resources.sh
```

Run from a terminal (not a short-timeout runner) or in the background so Task 6 (build + push) and Task 8 (Helm) can finish. After it completes, do the verification steps from Task 9 (port-forward, SSO login, trace test).
