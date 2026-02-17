# AKS Langfuse — Friendly hostname (no raw IP)

By default, exposing the web service as `LoadBalancer` gives a **public IP** (e.g. `http://20.123.45.67:3000`). To get a **hostname instead of numbers**, use an Azure service in front of AKS.

---

## Redeploy with Azure Front Door (step-by-step)

Use this when Langfuse is already deployed and you want to put **Azure Front Door** in front and use the **`*.azurefd.net`** hostname.

**Automated option:** Run the script (enables LoadBalancer, creates Front Door profile/endpoint/origin/route, sets nextauth.url, restarts web):

```bash
bash docs/tasks/aks-add-front-door.sh
```

Then add the printed redirect URI in Azure AD and open the Front Door URL. Manual steps below are an alternative.

### 1. Expose Langfuse web with a Load Balancer (backend for Front Door)

Edit your Helm values (e.g. `/tmp/langfuse-values.yaml` or your `values.yaml`). Under `langfuse.web`, **enable** the service as LoadBalancer:

```yaml
langfuse:
  web:
    image: { ... }
    service:
      type: LoadBalancer
```

Upgrade the release:

```bash
helm upgrade langfuse langfuse/langfuse -n langfuse -f /tmp/langfuse-values.yaml
```

Wait for the external IP (1–2 minutes), then note it:

```bash
kubectl get svc langfuse-web -n langfuse
# Use the EXTERNAL-IP value (e.g. 20.123.45.67)
```

### 2. Create Azure Front Door and get the hostname

Create a Front Door Standard profile (and endpoint) in the same resource group as AKS:

```bash
# Same resource group as your AKS (e.g. rg-langfuse-dev)
az afd profile create \
  --profile-name langfuse-aks \
  --resource-group rg-langfuse-dev \
  --sku Standard_AzureFrontDoor
```

Create an endpoint (if your setup doesn’t create one by default). In the Azure Portal: **Front Door profile → Endpoints → + Add**. The default hostname will be **`langfuse-aks.azurefd.net`** (or `{endpoint}.{profile}.azurefd.net`). Note this URL — you’ll use **`https://langfuse-aks.azurefd.net`** (no port).

### 3. Configure Front Door: origin and route

In Azure Portal (**Front Door profile → Origin groups → + Add**):

- **Origin group:** e.g. `langfuse-origin-group`.
- **Origin:** Add origin:
  - **Origin host:** the **EXTERNAL-IP** from step 1 (e.g. `20.123.45.67`).
  - **Host header:** same IP or leave default.
  - **HTTP port:** `3000` (Langfuse listens on 3000).
  - **Origin priority:** 1.
  - **Weight:** 1000.

Then **Routes → + Add**:

- **Name:** e.g. `langfuse-route`.
- **Accepted protocols:** HTTPS only (or HTTPS and HTTP).
- **Patterns to match:** `/*`.
- **Origin group:** `langfuse-origin-group`.
- **Forwarding protocol:** HTTP only (Front Door terminates HTTPS; backend is HTTP).

Save. Front Door will use the default hostname (e.g. `https://langfuse-aks.azurefd.net`) for this route.

### 4. Set nextauth.url to the Front Door URL and upgrade Helm

Edit your Helm values file and set `langfuse.nextauth.url` to your Front Door URL (HTTPS, no port):

```yaml
langfuse:
  nextauth:
    url: "https://langfuse-aks.azurefd.net"
```

Then upgrade and restart web so pods pick up the new URL:

```bash
helm upgrade langfuse langfuse/langfuse -n langfuse -f /tmp/langfuse-values.yaml
kubectl rollout restart deployment langfuse-web -n langfuse
```

(If you prefer to use the script’s placeholder: set `export LANGFUSE_PUBLIC_URL="https://langfuse-aks.azurefd.net"`, then regenerate values from the example with the same sed block as in the script so `<LANGFUSE_PUBLIC_URL>` is replaced, and run the same `helm upgrade`.)

### 5. Add redirect URI in Azure AD

In **Azure Portal → Microsoft Entra ID → App registrations → your Langfuse SSO app**:

- **Authentication → Add a platform → Web** (if not already).
- **Redirect URIs:** add  
  **`https://langfuse-aks.azurefd.net/api/auth/callback/azure-ad`**  
  (replace with your Front Door hostname if different).
- Save.

### 6. Verify

- Open **`https://langfuse-aks.azurefd.net`** in the browser (use your actual hostname).
- Sign in with Azure AD; you should land on the Langfuse dashboard without “State cookie was missing.”

**If you see "page not found" (404):** Azure Front Door config can take 30–90 minutes to propagate. Check: `az afd endpoint show -g rg-langfuse-dev --profile-name langfuse-aks --endpoint-name default --query deploymentStatus -o tsv`. When status is InProgress or Succeeded, the URL should work. Until then, use port-forward and http://localhost:3000 if needed.

**Optional:** For future runs of `aks-create-resources.sh`, set `LANGFUSE_PUBLIC_URL` before the script so the initial deploy already uses the Front Door URL:

```bash
export LANGFUSE_PUBLIC_URL="https://langfuse-aks.azurefd.net"
# Then run the script as usual; ensure langfuse.web.service.type is LoadBalancer in values if using Front Door.
```

---

**Editable public URL:** The public URL used for OAuth and Azure AD (`nextauth.url`) is configurable so your enterprise team can input or autogenerate a domain and have it applied consistently:

- **Script:** Set `LANGFUSE_PUBLIC_URL` before running `aks-create-resources.sh` (e.g. `export LANGFUSE_PUBLIC_URL="https://langfuse.team.com"`). Default if unset: `http://localhost:3000` (port-forward only).
- **Values:** In `aks-helm-values.example.yaml` the placeholder `<LANGFUSE_PUBLIC_URL>` is substituted by the script; for manual or CI use, replace it in `langfuse.nextauth.url` with your Front Door hostname or enterprise-allocated domain. The previous variant (port-forward / LoadBalancer IP) remains intact when you omit or leave the default.

## Option 1: Azure Front Door (recommended — default hostname, no custom domain)

**Azure Front Door** gives you a **default hostname** without buying a domain:  
**`{profile-name}.azurefd.net`**

- No custom domain or DNS setup required.
- Managed HTTPS (TLS) on the default hostname.
- Optional: WAF, global CDN, and (with Premium) Private Link to AKS.

### High-level steps

1. **Expose Langfuse web with a public IP**  
   In Helm values set `langfuse.web.service.type: LoadBalancer`, upgrade, then note the **EXTERNAL-IP** of `langfuse-web`:
   ```bash
   kubectl get svc langfuse-web -n langfuse
   ```

2. **Create an Azure Front Door (Standard or Premium) profile**  
   - [Create a Front Door profile (portal)](https://learn.microsoft.com/en-us/azure/frontdoor/create-front-door-portal)  
   - Or CLI: `az afd profile create --profile-name langfuse-aks --resource-group rg-langfuse-dev --sku Standard_AzureFrontDoor`  
   - Create an **endpoint** (e.g. default or named). The default hostname will be **`langfuse-aks.azurefd.net`** (or `{endpoint-name}.{profile-name}.azurefd.net` depending on config).

3. **Add an origin group and origin**  
   - **Origin host:** the AKS Load Balancer **public IP** from step 1.  
   - **Origin host header:** same IP or leave default.  
   - **HTTP port:** `3000` (Langfuse web listens on 3000).  
   - [Configure an origin](https://learn.microsoft.com/en-us/azure/frontdoor/how-to-configure-origin)

4. **Add a route**  
   - Path: `/*` (or `/`)  
   - Route to the origin group.  
   - Protocol: HTTPS (Front Door) → HTTP (backend port 3000) is typical.

5. **Use the Front Door URL for Langfuse and Azure AD**  
   - **App URL:** `https://langfuse-aks.azurefd.net` (no port; Front Door uses 443).  
   - In Helm: `nextauth.url: "https://langfuse-aks.azurefd.net"`  
   - In Azure AD App registration, redirect URI: `https://langfuse-aks.azurefd.net/api/auth/callback/azure-ad`  
   - Upgrade Helm and retry sign-in.

**Docs:**  
- [What is Azure Front Door?](https://learn.microsoft.com/en-us/azure/frontdoor/front-door-overview)  
- [Use Azure Front Door to secure AKS workloads](https://learn.microsoft.com/en-us/azure/architecture/example-scenario/aks-front-door/aks-front-door) (NGINX + Private Link; more advanced)  
- [Configure an origin](https://learn.microsoft.com/en-us/azure/frontdoor/how-to-configure-origin)

---

## Option 2: Custom domain (e.g. `langfuse.yourcompany.com`)

If you have a domain:

- **Front Door:** Add a [custom domain](https://learn.microsoft.com/en-us/azure/frontdoor/standard-premium/how-to-add-custom-domain) to the same Front Door profile; Front Door can manage TLS. Then use `https://langfuse.yourcompany.com` for `nextauth.url` and Azure AD.
- **Application Gateway:** Use [Application Gateway Ingress Controller (AGIC)](https://learn.microsoft.com/en-us/azure/application-gateway/ingress-controller-overview) with an AKS ingress and attach a custom hostname + certificate (e.g. from Key Vault or cert-manager).

---

## Option 3: Application Gateway in front of AKS

**Application Gateway** can expose AKS apps via an ingress resource and give a single public IP; you typically assign a **custom hostname** (and DNS record) to that IP for a friendly name. It does not provide a built-in `*.azure.net` style hostname like Front Door’s `*.azurefd.net`.  
See: [Expose an AKS service over HTTP/HTTPS using Application Gateway](https://learn.microsoft.com/en-us/azure/application-gateway/ingress-controller-expose-service-over-http-https).

---

## Summary

| Goal                         | Option              | Hostname / URL example                    |
|-----------------------------|---------------------|-------------------------------------------|
| Name instead of IP, no DNS | **Azure Front Door**| `https://langfuse-aks.azurefd.net`        |
| Your own domain            | Front Door + custom domain or Application Gateway + DNS | `https://langfuse.yourcompany.com` |

For a **name instead of numbers with no extra domain**, use **Azure Front Door** and the default **`*.azurefd.net`** hostname.
