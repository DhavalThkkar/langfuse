#!/usr/bin/env bash
# ============================================================================
# Langfuse AKS SPN-Only Deployment — Complete Setup Script
# ============================================================================
# Covers: Task 3 (Azure resources), Task 4 (Workload Identity), Task 5 (SSO),
#         Task 6 (Docker build + push), Task 7 (K8s secrets), Task 8 (Helm deploy),
#         Task 9 (Verification).
#
# Prerequisites:
#   - Azure CLI (az), logged in (az login), with Contributor + User Access Administrator
#   - Docker (running), kubectl, helm, openssl
#   - You have cloned/forked the Langfuse repo at $LANGFUSE_REPO_ROOT
#
# Usage:
#   export LANGFUSE_REPO_ROOT=/path/to/langfuse   # required
#   bash docs/tasks/aks-create-resources.sh        # run in subshell (recommended)
#
# Optional — public URL for nextauth.url (default: http://localhost:3000 for port-forward):
#   export LANGFUSE_PUBLIC_URL="https://your-profile.azurefd.net"   # Front Door
#   export LANGFUSE_PUBLIC_URL="https://langfuse.enterprise.com"   # enterprise-allocated domain
# Omit to keep port-forward only. See docs/tasks/aks-friendly-hostname.md.
#
# Resume after 7.3 (skip to Helm deploy):
#   export RESUME_FROM=8
#   export LANGFUSE_REPO_ROOT=... ACR_NAME=... STORAGE_ACCOUNT=...
#   bash docs/tasks/aks-create-resources.sh
#
# Do NOT use "source" — the script uses set -e, so any failure would exit your
# current shell and close the terminal. Use "bash" so only the script process exits.
# ============================================================================

set -euo pipefail
# When sourced, re-run in a subshell so set -e doesn't close the user's terminal on failure
if [ -n "${BASH_SOURCE[0]:-}" ] && [ "${BASH_SOURCE[0]}" != "${0}" ]; then
  echo "Running in subshell (sourced); failures will not close your terminal."
  ( exec bash "${BASH_SOURCE[0]}" "$@" )
  return $? 2>/dev/null || exit $?
fi

# ============================================================================
# 0. VARIABLES — Concrete defaults; override via env vars before running.
# ============================================================================
# Naming convention: langfuse-<component>-<env>
# All names are deterministic (no random suffixes) so re-runs are idempotent.

export RESOURCE_GROUP="${RESOURCE_GROUP:-rg-langfuse-dev}"
export LOCATION="${LOCATION:-eastus}"
export AKS_NAME="${AKS_NAME:-aks-langfuse-dev}"
export ACR_NAME="${ACR_NAME:-acrlangfusedev}"              # ACR: alphanumeric only, globally unique
export STORAGE_ACCOUNT="${STORAGE_ACCOUNT:-stlangfusedev}"  # Storage: alphanumeric, 3-24 chars, globally unique
export IDENTITY_NAME="${IDENTITY_NAME:-id-langfuse-dev}"
export BLOB_CONTAINER="${BLOB_CONTAINER:-langfuse}"
export K8S_NAMESPACE="${K8S_NAMESPACE:-langfuse}"
export IMAGE_TAG="${IMAGE_TAG:-v1}"
# Public URL for nextauth.url — editable; default port-forward. Set for Front Door or enterprise-allocated domain.
export LANGFUSE_PUBLIC_URL="${LANGFUSE_PUBLIC_URL:-http://localhost:3000}"

# Repo root: from env, or auto-detect from script location (script lives in repo/docs/tasks/)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
if [ -z "${LANGFUSE_REPO_ROOT:-}" ] || [ "$LANGFUSE_REPO_ROOT" = "/path/to/langfuse" ] || [ ! -d "${LANGFUSE_REPO_ROOT:-}/docs/tasks" ]; then
  export LANGFUSE_REPO_ROOT="$DEFAULT_REPO_ROOT"
fi
if [ ! -f "$LANGFUSE_REPO_ROOT/docs/tasks/aks-helm-values.example.yaml" ]; then
  echo "ERROR: LANGFUSE_REPO_ROOT ($LANGFUSE_REPO_ROOT) has no docs/tasks/aks-helm-values.example.yaml. Set LANGFUSE_REPO_ROOT to your Langfuse repo root."
  exit 1
fi

# Derived
export YOUR_TENANT_ID="${YOUR_TENANT_ID:-$(az account show --query tenantId -o tsv)}"

# Resume from Task 8 (after 7.3): set RESUME_FROM=8 and required env vars (see docs/tasks/aks-resume.md)
RESUME_FROM="${RESUME_FROM:-}"
if [ -n "$RESUME_FROM" ] && [ "$RESUME_FROM" -ge 8 ]; then
  echo ">>> Resuming from Task 8 (skipping Tasks 3–7)."
  export IDENTITY_CLIENT_ID="${IDENTITY_CLIENT_ID:-$(az identity show --name "$IDENTITY_NAME" --resource-group "$RESOURCE_GROUP" --query clientId -o tsv 2>/dev/null)}"
  if [ -z "${IDENTITY_CLIENT_ID:-}" ]; then
    echo "ERROR: IDENTITY_CLIENT_ID not set and could not get from Azure. Set IDENTITY_CLIENT_ID or ensure identity $IDENTITY_NAME exists in $RESOURCE_GROUP."
    exit 1
  fi
  az aks get-credentials --name "$AKS_NAME" --resource-group "$RESOURCE_GROUP" --overwrite-existing
  kubectl create namespace "$K8S_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - 2>/dev/null || true
fi

echo "=========================================="
echo "Resource Group:   $RESOURCE_GROUP"
echo "Location:         $LOCATION"
echo "AKS Cluster:      $AKS_NAME"
echo "ACR:              $ACR_NAME"
echo "Storage Account:  $STORAGE_ACCOUNT"
echo "Managed Identity: $IDENTITY_NAME"
echo "Blob Container:   $BLOB_CONTAINER"
echo "K8s Namespace:    $K8S_NAMESPACE"
echo "Image Tag:        $IMAGE_TAG"
echo "Tenant ID:        $YOUR_TENANT_ID"
echo "Repo Root:        $LANGFUSE_REPO_ROOT"
echo "Public URL:       $LANGFUSE_PUBLIC_URL (nextauth.url; set LANGFUSE_PUBLIC_URL to override)"
echo "=========================================="

# Prerequisites: az, kubectl, helm, openssl; docker only when not resuming from 8
check_cmd() { command -v "$1" &>/dev/null || { echo "ERROR: $1 is not installed or not in PATH. Install it and re-run."; exit 1; }; }
check_cmd az
check_cmd kubectl
check_cmd helm
check_cmd openssl
if [ -z "${RESUME_FROM:-}" ] || [ "${RESUME_FROM:-0}" -lt 8 ]; then
  check_cmd docker
fi

# ============================================================================
# TASK 3: Create Azure Resources
# ============================================================================
if [ -z "${RESUME_FROM:-}" ] || [ "${RESUME_FROM:-0}" -lt 8 ]; then

echo ">>> Task 3.1: Resource Group"
az group create --name "$RESOURCE_GROUP" --location "$LOCATION"

echo ">>> Task 3.2: Azure Container Registry"
if az acr show --name "$ACR_NAME" --resource-group "$RESOURCE_GROUP" &>/dev/null; then
  echo "ACR $ACR_NAME already exists; skipping create."
else
  az acr create --name "$ACR_NAME" --resource-group "$RESOURCE_GROUP" --sku Basic
fi

echo ">>> Task 3.3: AKS Cluster (OIDC + Workload Identity + attach ACR)"
# --attach-acr grants AcrPull to the AKS node/kubelet managed identity (NOT pod-level).
# This means no imagePullSecret is needed.
# Node count 2 is sufficient for dev/test; use 3+ for production.
if az aks show --resource-group "$RESOURCE_GROUP" --name "$AKS_NAME" &>/dev/null; then
  echo "AKS cluster $AKS_NAME already exists; attaching ACR and continuing."
  az aks update --resource-group "$RESOURCE_GROUP" --name "$AKS_NAME" --attach-acr "$ACR_NAME"
else
  az aks create \
    --resource-group "$RESOURCE_GROUP" \
    --name "$AKS_NAME" \
    --enable-oidc-issuer \
    --enable-workload-identity \
    --attach-acr "$ACR_NAME" \
    --node-count 2 \
    --node-vm-size Standard_D4s_v5 \
    --generate-ssh-keys
fi

echo ">>> Task 3.4: Storage Account + Blob Container"
if az storage account show --name "$STORAGE_ACCOUNT" --resource-group "$RESOURCE_GROUP" &>/dev/null; then
  echo "Storage account $STORAGE_ACCOUNT already exists; skipping create."
else
  az storage account create \
    --name "$STORAGE_ACCOUNT" \
    --resource-group "$RESOURCE_GROUP" \
    --sku Standard_LRS \
    --kind StorageV2
fi
az storage container create \
  --name "$BLOB_CONTAINER" \
  --account-name "$STORAGE_ACCOUNT" \
  --auth-mode login \
  2>/dev/null || true

echo ">>> Task 3.5: User-Assigned Managed Identity"
if az identity show --name "$IDENTITY_NAME" --resource-group "$RESOURCE_GROUP" &>/dev/null; then
  echo "Managed identity $IDENTITY_NAME already exists; skipping create."
else
  az identity create \
    --name "$IDENTITY_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --location "$LOCATION"
fi

export IDENTITY_CLIENT_ID=$(az identity show \
  --name "$IDENTITY_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --query clientId -o tsv)

export IDENTITY_PRINCIPAL_ID=$(az identity show \
  --name "$IDENTITY_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --query principalId -o tsv)

echo ">>> Task 3.6: RBAC — Storage Blob Data Contributor + Storage Blob Delegator"
# BOTH roles are required:
#   - Storage Blob Data Contributor: read/write/delete blobs
#   - Storage Blob Delegator: call getUserDelegationKey() for user delegation SAS
# Without Delegator, presigned URL generation will fail with 403.
STORAGE_ID=$(az storage account show \
  --name "$STORAGE_ACCOUNT" \
  --resource-group "$RESOURCE_GROUP" \
  --query id -o tsv)

az role assignment create \
  --assignee-object-id "$IDENTITY_PRINCIPAL_ID" \
  --role "Storage Blob Data Contributor" \
  --scope "$STORAGE_ID" \
  --assignee-principal-type ServicePrincipal

az role assignment create \
  --assignee-object-id "$IDENTITY_PRINCIPAL_ID" \
  --role "Storage Blob Delegator" \
  --scope "$STORAGE_ID" \
  --assignee-principal-type ServicePrincipal

echo ">>> Task 3 complete."

fi
# ============================================================================
# TASK 4: Configure AKS Workload Identity
# ============================================================================
if [ -z "${RESUME_FROM:-}" ] || [ "${RESUME_FROM:-0}" -lt 8 ]; then


echo ">>> Task 4.1: Get AKS OIDC issuer"
export AKS_OIDC_ISSUER=$(az aks show \
  --name "$AKS_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --query oidcIssuerProfile.issuerUrl -o tsv)

echo ">>> Task 4.2: Create federated credential"
# The subject must match: system:serviceaccount:<namespace>:<service-account-name>
# The Helm chart creates a service account named "langfuse" in the namespace.
az identity federated-credential create \
  --name fed-langfuse \
  --identity-name "$IDENTITY_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --issuer "$AKS_OIDC_ISSUER" \
  --subject "system:serviceaccount:${K8S_NAMESPACE}:langfuse" \
  --audience api://AzureADTokenExchange

echo ">>> Task 4.3: Get kubectl credentials + create namespace"
az aks get-credentials --name "$AKS_NAME" --resource-group "$RESOURCE_GROUP" --overwrite-existing
kubectl create namespace "$K8S_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

echo ">>> Task 4 complete."

fi
# ============================================================================
# TASK 5: Azure AD SSO — App Registration
# ============================================================================
if [ -z "${RESUME_FROM:-}" ] || [ "${RESUME_FROM:-0}" -lt 8 ]; then

# This creates the App Registration for Langfuse Azure AD SSO login.
# For testing with port-forward, NEXTAUTH_URL = http://localhost:3000.
# Redirect URI = <NEXTAUTH_URL>/api/auth/callback/azure-ad

export NEXTAUTH_URL="${NEXTAUTH_URL:-http://localhost:3000}"
REDIRECT_URI="${NEXTAUTH_URL}/api/auth/callback/azure-ad"

echo ">>> Task 5.1: Create App Registration for SSO"
SSO_APP_ID=$(az ad app create \
  --display-name "Langfuse SSO (${RESOURCE_GROUP})" \
  --web-redirect-uris "$REDIRECT_URI" \
  --sign-in-audience "AzureADMyOrg" \
  --query appId -o tsv)
export SSO_APP_ID

echo ">>> Task 5.2: Create client secret (valid 2 years)"
SSO_CLIENT_SECRET=$(az ad app credential reset \
  --id "$SSO_APP_ID" \
  --append \
  --display-name "langfuse-sso-secret" \
  --years 2 \
  --query password -o tsv)
export SSO_CLIENT_SECRET

echo ">>> Task 5.3: Configure optional claim — email in ID token"
# The Azure AD provider in Langfuse needs the 'email' claim.
# This configures it on the App Registration.
az ad app update --id "$SSO_APP_ID" \
  --optional-claims '{
    "idToken": [{"name": "email", "source": null, "essential": false}]
  }'

echo ">>> Task 5 complete."
echo "SSO_APP_ID (AUTH_AZURE_AD_CLIENT_ID): $SSO_APP_ID"
echo "SSO_CLIENT_SECRET (AUTH_AZURE_AD_CLIENT_SECRET): [stored in \$SSO_CLIENT_SECRET]"
echo "YOUR_TENANT_ID (AUTH_AZURE_AD_TENANT_ID): $YOUR_TENANT_ID"
echo "Redirect URI: $REDIRECT_URI"

fi
# ============================================================================
# TASK 6: Build and Push Container Images to ACR
# ============================================================================
if [ -z "${RESUME_FROM:-}" ] || [ "${RESUME_FROM:-0}" -lt 8 ]; then


echo ">>> Task 6.1: Login to ACR"
az acr login --name "$ACR_NAME"

echo ">>> Task 6.2: Build Langfuse web image"
# Build from repo root; the Dockerfiles use turbo prune for efficient builds.
docker build \
  -f "$LANGFUSE_REPO_ROOT/web/Dockerfile" \
  -t "${ACR_NAME}.azurecr.io/langfuse-web:${IMAGE_TAG}" \
  "$LANGFUSE_REPO_ROOT"

echo ">>> Task 6.3: Build Langfuse worker image"
docker build \
  -f "$LANGFUSE_REPO_ROOT/worker/Dockerfile" \
  -t "${ACR_NAME}.azurecr.io/langfuse-worker:${IMAGE_TAG}" \
  "$LANGFUSE_REPO_ROOT"

echo ">>> Task 6.4: Push images"
docker push "${ACR_NAME}.azurecr.io/langfuse-web:${IMAGE_TAG}"
docker push "${ACR_NAME}.azurecr.io/langfuse-worker:${IMAGE_TAG}"

echo ">>> Task 6 complete."

fi
# ============================================================================
# TASK 7: Create Kubernetes Secrets
# ============================================================================
if [ -z "${RESUME_FROM:-}" ] || [ "${RESUME_FROM:-0}" -lt 8 ]; then


echo ">>> Task 7.1: Generate secret values"
NEXTAUTH_SECRET=$(openssl rand -base64 32)
SALT=$(openssl rand -base64 16)
ENCRYPTION_KEY=$(openssl rand -hex 32)  # 64-char hex = 256 bits (required by Langfuse env)

echo ">>> Task 7.2: Create langfuse-secrets"
kubectl create secret generic langfuse-secrets \
  --namespace "$K8S_NAMESPACE" \
  --from-literal=nextauth-secret="$NEXTAUTH_SECRET" \
  --from-literal=salt="$SALT" \
  --from-literal=encryption-key="$ENCRYPTION_KEY" \
  --dry-run=client -o yaml | kubectl apply -f -

echo ">>> Task 7.3: Create langfuse-sso secret"
kubectl create secret generic langfuse-sso \
  --namespace "$K8S_NAMESPACE" \
  --from-literal=client-id="$SSO_APP_ID" \
  --from-literal=client-secret="$SSO_CLIENT_SECRET" \
  --dry-run=client -o yaml | kubectl apply -f -

echo ">>> Task 7 complete."

fi
# ============================================================================
# TASK 8: Prepare Helm Values and Deploy
# ============================================================================

echo ">>> Task 8.1: Add Langfuse Helm repo"
helm repo add langfuse https://langfuse.github.io/langfuse-k8s
helm repo update

echo ">>> Task 8.2: Generate values.yaml from template"
cp "$LANGFUSE_REPO_ROOT/docs/tasks/aks-helm-values.example.yaml" /tmp/langfuse-values.yaml

# Generate passwords for in-cluster data stores (hex-only to avoid URL special chars in DATABASE_URL)
DB_PASSWORD=$(openssl rand -hex 16)
REDIS_PASSWORD=$(openssl rand -hex 16)
CH_PASSWORD=$(openssl rand -hex 16)

echo ">>> Public URL (nextauth.url): $LANGFUSE_PUBLIC_URL (set LANGFUSE_PUBLIC_URL to override; edit values.yaml for enterprise-allocated domain)"
sed -i \
  -e "s|<IDENTITY_CLIENT_ID>|$IDENTITY_CLIENT_ID|g" \
  -e "s|<ACR_NAME>|$ACR_NAME|g" \
  -e "s|<STORAGE_ACCOUNT>|$STORAGE_ACCOUNT|g" \
  -e "s|<BLOB_CONTAINER>|$BLOB_CONTAINER|g" \
  -e "s|<YOUR_TENANT_ID>|$YOUR_TENANT_ID|g" \
  -e "s|<DB_PASSWORD>|$DB_PASSWORD|g" \
  -e "s|<REDIS_PASSWORD>|$REDIS_PASSWORD|g" \
  -e "s|<CH_PASSWORD>|$CH_PASSWORD|g" \
  -e "s|<LANGFUSE_PUBLIC_URL>|$LANGFUSE_PUBLIC_URL|g" \
  /tmp/langfuse-values.yaml

echo ">>> Task 8.3: Install Langfuse via Helm"
helm install langfuse langfuse/langfuse \
  --namespace "$K8S_NAMESPACE" \
  -f /tmp/langfuse-values.yaml \
  --wait \
  --timeout 10m

echo ">>> Task 8.4: Verify pods"
kubectl get pods -n "$K8S_NAMESPACE"

echo ">>> Task 8 complete."

# ============================================================================
# TASK 9: Verification and Testing
# ============================================================================

echo ">>> Task 9: Verification"
echo ""
echo "Run the following commands to verify the deployment:"
echo ""
echo "1. Port-forward the web service:"
echo "   kubectl port-forward svc/langfuse-web 3000:3000 -n $K8S_NAMESPACE"
echo ""
echo "2. Open http://localhost:3000 in your browser."
echo "   - Click 'Sign in with Azure AD'."
echo "   - Authenticate with your Azure AD credentials."
echo "   - You should land on the Langfuse dashboard."
echo ""
echo "3. Create a new project in Langfuse, get the API keys, then test tracing:"
echo "   pip install langfuse"
echo "   python3 -c \""
echo "   from langfuse import Langfuse"
echo "   lf = Langfuse("
echo "     public_key='<your-langfuse-public-key>',"
echo "     secret_key='<your-langfuse-secret-key>',"
echo "     host='http://localhost:3000'"
echo "   )"
echo "   trace = lf.trace(name='test-aks-deployment')"
echo "   trace.generation(name='test-gen', input='hello', output='world')"
echo "   lf.flush()"
echo "   print('Trace sent successfully!')"
echo "   \""
echo ""
echo "4. Verify Blob Storage (presigned URLs):"
echo "   - In Langfuse, go to a project > upload a media file (or trigger batch export)."
echo "   - Check Azure Portal > Storage Account > $STORAGE_ACCOUNT > $BLOB_CONTAINER for blobs."
echo "   - If presigned URLs fail with 403, check:"
echo "     a) The managed identity has BOTH 'Storage Blob Data Contributor' AND 'Storage Blob Delegator' roles."
echo "     b) RBAC role propagation can take up to 5 minutes after assignment."
echo ""
echo "5. Check pod logs for errors:"
echo "   kubectl logs -l app.kubernetes.io/name=langfuse-web -n $K8S_NAMESPACE --tail=50"
echo "   kubectl logs -l app.kubernetes.io/name=langfuse-worker -n $K8S_NAMESPACE --tail=50"
echo ""

echo "=========================================="
echo "DEPLOYMENT COMPLETE"
echo "=========================================="
echo ""
echo "Summary of created resources:"
echo "  Resource Group:      $RESOURCE_GROUP"
echo "  AKS Cluster:         $AKS_NAME"
echo "  ACR:                 $ACR_NAME.azurecr.io"
echo "  Storage Account:     $STORAGE_ACCOUNT"
echo "  Blob Container:      $BLOB_CONTAINER"
echo "  Managed Identity:    $IDENTITY_NAME (Client ID: $IDENTITY_CLIENT_ID)"
echo "  SSO App Registration: $SSO_APP_ID"
echo "  K8s Namespace:       $K8S_NAMESPACE"
echo "  Public URL (nextauth): $LANGFUSE_PUBLIC_URL (edit in values or set LANGFUSE_PUBLIC_URL and re-run)"
echo "  Helm Values:         /tmp/langfuse-values.yaml"
echo ""
echo "To tear down everything:"
echo "  helm uninstall langfuse -n $K8S_NAMESPACE"
echo "  az group delete --name $RESOURCE_GROUP --yes --no-wait"
echo ""
echo "For rollback procedures, see: docs/tasks/aks-rollback.md"
