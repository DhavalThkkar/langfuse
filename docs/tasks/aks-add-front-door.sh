#!/usr/bin/env bash
# ============================================================================
# Add Azure Front Door in front of existing Langfuse on AKS
# ============================================================================
# Prerequisites: Langfuse already deployed (helm release "langfuse" in namespace).
#   az, kubectl, helm must be in PATH; you must be logged in (az login, kubectl context set).
#
# What this script does:
#   1. Enable LoadBalancer on langfuse-web and wait for EXTERNAL-IP
#   2. Create Azure Front Door profile + endpoint (or use existing)
#   3. Create origin group + origin (backend = EXTERNAL-IP:3000) + route
#   4. Set nextauth.url to https://<endpoint-hostname> and upgrade Helm, restart web
#
# Usage:
#   export RESOURCE_GROUP=rg-langfuse-dev   # default
#   export AFD_PROFILE_NAME=langfuse-aks   # default
#   bash docs/tasks/aks-add-front-door.sh
# ============================================================================

set -euo pipefail

export RESOURCE_GROUP="${RESOURCE_GROUP:-rg-langfuse-dev}"
export K8S_NAMESPACE="${K8S_NAMESPACE:-langfuse}"
export AFD_PROFILE_NAME="${AFD_PROFILE_NAME:-langfuse-aks}"
export AFD_ENDPOINT_NAME="${AFD_ENDPOINT_NAME:-default}"
export AFD_ORIGIN_GROUP_NAME="${AFD_ORIGIN_GROUP_NAME:-langfuse-origin-group}"
export AFD_ORIGIN_NAME="${AFD_ORIGIN_NAME:-langfuse-origin}"
export AFD_ROUTE_NAME="${AFD_ROUTE_NAME:-langfuse-route}"
export HELM_VALUES_FILE="${HELM_VALUES_FILE:-/tmp/langfuse-values-frontdoor.yaml}"

# Ensure Helm repo
helm repo add langfuse https://langfuse.github.io/langfuse-k8s 2>/dev/null || true
helm repo update

# Use current Helm values if file missing (e.g. from another machine)
if [ ! -f "$HELM_VALUES_FILE" ] || [ ! -s "$HELM_VALUES_FILE" ]; then
  echo ">>> Fetching current Helm values from release into $HELM_VALUES_FILE"
  helm get values langfuse -n "$K8S_NAMESPACE" -o yaml > "$HELM_VALUES_FILE"
fi

echo ">>> Step 1: Enable LoadBalancer on langfuse-web"
helm upgrade langfuse langfuse/langfuse -n "$K8S_NAMESPACE" -f "$HELM_VALUES_FILE" \
  --set langfuse.web.service.type=LoadBalancer

echo ">>> Waiting for langfuse-web EXTERNAL-IP (up to 3 min)"
for i in $(seq 1 36); do
  EXTERNAL_IP=$(kubectl get svc langfuse-web -n "$K8S_NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
  if [ -n "${EXTERNAL_IP:-}" ]; then break; fi
  sleep 5
done
if [ -z "${EXTERNAL_IP:-}" ]; then
  echo "ERROR: langfuse-web did not get an EXTERNAL-IP. Check: kubectl get svc langfuse-web -n $K8S_NAMESPACE"
  exit 1
fi
echo ">>> langfuse-web EXTERNAL-IP: $EXTERNAL_IP"
# Re-fetch values so step 8 keeps LoadBalancer
helm get values langfuse -n "$K8S_NAMESPACE" -o yaml > "$HELM_VALUES_FILE"

echo ">>> Step 2: Create Azure Front Door profile (if not exists)"
if ! az afd profile show --profile-name "$AFD_PROFILE_NAME" --resource-group "$RESOURCE_GROUP" &>/dev/null; then
  az afd profile create --profile-name "$AFD_PROFILE_NAME" --resource-group "$RESOURCE_GROUP" --sku Standard_AzureFrontDoor
else
  echo ">>> Profile $AFD_PROFILE_NAME already exists."
fi

echo ">>> Step 3: Create Front Door endpoint (if not exists)"
if ! az afd endpoint show --profile-name "$AFD_PROFILE_NAME" --endpoint-name "$AFD_ENDPOINT_NAME" --resource-group "$RESOURCE_GROUP" &>/dev/null; then
  az afd endpoint create --profile-name "$AFD_PROFILE_NAME" --endpoint-name "$AFD_ENDPOINT_NAME" --resource-group "$RESOURCE_GROUP" --enabled-state Enabled
else
  echo ">>> Endpoint $AFD_ENDPOINT_NAME already exists."
fi

echo ">>> Step 4: Create origin group (if not exists)"
if ! az afd origin-group show --profile-name "$AFD_PROFILE_NAME" --origin-group-name "$AFD_ORIGIN_GROUP_NAME" --resource-group "$RESOURCE_GROUP" &>/dev/null; then
  az afd origin-group create --profile-name "$AFD_PROFILE_NAME" --origin-group-name "$AFD_ORIGIN_GROUP_NAME" --resource-group "$RESOURCE_GROUP" \
    --sample-size 4 --successful-samples-required 2 --additional-latency-in-milliseconds 50 \
    --probe-path "/api/public/health" --probe-protocol Http --probe-request-type GET --probe-interval-in-seconds 30
else
  echo ">>> Origin group $AFD_ORIGIN_GROUP_NAME already exists."
fi

echo ">>> Step 5: Create or update origin (backend $EXTERNAL_IP:3000)"
# Origin host header must match the Front Door hostname so the backend receives the same Host as the client (avoids 404).
AFD_HOSTNAME_FOR_ORIGIN=$(az afd endpoint show --profile-name "$AFD_PROFILE_NAME" --endpoint-name "$AFD_ENDPOINT_NAME" --resource-group "$RESOURCE_GROUP" --query hostName -o tsv 2>/dev/null || true)
if [ -z "${AFD_HOSTNAME_FOR_ORIGIN:-}" ]; then
  echo "WARNING: Could not get Front Door hostname for origin-host-header; using EXTERNAL_IP. If you get 404, update origin to set origin-host-header to your Front Door hostname."
  AFD_HOSTNAME_FOR_ORIGIN="$EXTERNAL_IP"
fi
if az afd origin show --profile-name "$AFD_PROFILE_NAME" --origin-group-name "$AFD_ORIGIN_GROUP_NAME" --origin-name "$AFD_ORIGIN_NAME" --resource-group "$RESOURCE_GROUP" &>/dev/null; then
  az afd origin update --profile-name "$AFD_PROFILE_NAME" --origin-group-name "$AFD_ORIGIN_GROUP_NAME" --origin-name "$AFD_ORIGIN_NAME" --resource-group "$RESOURCE_GROUP" \
    --host-name "$EXTERNAL_IP" --http-port 3000 --origin-host-header "$AFD_HOSTNAME_FOR_ORIGIN" --enabled-state Enabled --priority 1 --weight 1000 --enforce-certificate-name-check false
else
  az afd origin create --profile-name "$AFD_PROFILE_NAME" --origin-group-name "$AFD_ORIGIN_GROUP_NAME" --origin-name "$AFD_ORIGIN_NAME" --resource-group "$RESOURCE_GROUP" \
    --host-name "$EXTERNAL_IP" --http-port 3000 --origin-host-header "$AFD_HOSTNAME_FOR_ORIGIN" --enabled-state Enabled --priority 1 --weight 1000 --enforce-certificate-name-check false
fi

echo ">>> Step 6: Create route (if not exists)"
if ! az afd route show --profile-name "$AFD_PROFILE_NAME" --endpoint-name "$AFD_ENDPOINT_NAME" --route-name "$AFD_ROUTE_NAME" --resource-group "$RESOURCE_GROUP" &>/dev/null; then
  az afd route create --profile-name "$AFD_PROFILE_NAME" --endpoint-name "$AFD_ENDPOINT_NAME" --route-name "$AFD_ROUTE_NAME" --resource-group "$RESOURCE_GROUP" \
    --origin-group "$AFD_ORIGIN_GROUP_NAME" --forwarding-protocol HttpOnly --enabled-state Enabled --link-to-default-domain Enabled
else
  echo ">>> Route $AFD_ROUTE_NAME already exists."
fi

echo ">>> Step 7: Get Front Door hostname"
AFD_HOSTNAME=$(az afd endpoint show --profile-name "$AFD_PROFILE_NAME" --endpoint-name "$AFD_ENDPOINT_NAME" --resource-group "$RESOURCE_GROUP" --query hostName -o tsv 2>/dev/null || true)
if [ -z "${AFD_HOSTNAME:-}" ]; then
  echo "ERROR: Could not get Front Door endpoint hostname."
  exit 1
fi
FRONT_DOOR_URL="https://${AFD_HOSTNAME}"
echo ">>> Front Door URL: $FRONT_DOOR_URL"

echo ">>> Step 8: Set nextauth.url to Front Door URL and upgrade Helm"
helm upgrade langfuse langfuse/langfuse -n "$K8S_NAMESPACE" -f "$HELM_VALUES_FILE" \
  --set langfuse.nextauth.url="$FRONT_DOOR_URL" \
  --reuse-values

echo ">>> Step 9: Restart web deployment to pick up new nextauth.url"
kubectl rollout restart deployment langfuse-web -n "$K8S_NAMESPACE"
kubectl rollout status deployment langfuse-web -n "$K8S_NAMESPACE" --timeout=120s

echo ""
echo "=========================================="
echo "FRONT DOOR SETUP COMPLETE"
echo "=========================================="
echo "  Front Door URL:  $FRONT_DOOR_URL"
echo "  Add this redirect URI in Azure AD App Registration (Authentication):"
echo "    $FRONT_DOOR_URL/api/auth/callback/azure-ad"
echo ""
echo "  Then open $FRONT_DOOR_URL in the browser and sign in with Azure AD."
echo ""
echo "  If you see 'page not found' (404): Azure Front Door config can take 30–90 min to propagate."
echo "  Check: az afd endpoint show -g $RESOURCE_GROUP --profile-name $AFD_PROFILE_NAME --endpoint-name $AFD_ENDPOINT_NAME --query deploymentStatus -o tsv"
echo "  When deploymentStatus is 'InProgress' or 'Succeeded', the URL should work."
echo "=========================================="
