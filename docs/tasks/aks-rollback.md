# AKS Langfuse deployment – rollback procedures

Use these when reverting or fixing issues after deploying Langfuse on AKS with SPN-only auth.

**Default naming** (from `aks-create-resources.sh`):
- Namespace: `langfuse`
- Resource Group: `rg-langfuse-dev`
- Helm Release: `langfuse`

---

## Troubleshooting: BackOff / CrashLoopBackOff

When pods show **BackOff** or **CrashLoopBackOff**, the container is exiting; the event does not show the reason. Use these to see the real error:

```bash
# Last logs from the failing container (run for web and worker)
kubectl logs -l app.kubernetes.io/name=langfuse-web -n langfuse --tail=100 --previous
kubectl logs -l app.kubernetes.io/name=langfuse-worker -n langfuse --tail=100 --previous

# If --previous fails (no previous run yet), use without it
kubectl logs -l app.kubernetes.io/name=langfuse-web -n langfuse --tail=100
kubectl logs -l app.kubernetes.io/name=langfuse-worker -n langfuse --tail=100

# Container exit reason (e.g. ExitCode, OOMKilled)
kubectl describe pod -l app.kubernetes.io/name=langfuse-web -n langfuse | grep -A 20 "Last State"
kubectl describe pod -l app.kubernetes.io/name=langfuse-worker -n langfuse | grep -A 20 "Last State"
```

**Common causes:**

| Symptom in logs | Likely cause | Fix |
|-----------------|--------------|-----|
| `ECONNREFUSED` / `connection refused` to postgres, redis, or clickhouse | DBs not ready or wrong host/port | Wait for postgresql/redis/clickhouse pods to be Running; check chart values for service names. |
| `DATABASE_URL` / `NEXTAUTH` / env not set | Missing or wrong secret/env | Check `langfuse-secrets` and `langfuse-sso` exist; check Helm values `additionalEnv` and secretKeyRef. |
| Azure Blob / `DefaultAzureCredential` / 403 | Workload Identity or RBAC | Ensure pod has label `azure.workload.identity/use: "true"` and SA annotation `azure.workload.identity/client-id`; ensure identity has Storage Blob Data Contributor + Storage Blob Delegator. |
| Exit code 1 or 137 | App error or OOM | Read the log line before exit; increase memory if OOMKilled. |
| Prisma P1013 / invalid port in database URL | DB password has special chars (`:`, `@`, `+`) | Use hex-only password for postgres (script now uses `openssl rand -hex 16` for DB_PASSWORD). Redeploy or fix values and upgrade. |
| ENCRYPTION_KEY must be 64 hex chars (256 bits) | Secret had 32 hex chars | Script now uses `openssl rand -hex 32`. Update secret: `kubectl create secret generic langfuse-secrets ... --from-literal=encryption-key=$(openssl rand -hex 32) ... -n langfuse --dry-run=client -o yaml \| kubectl apply -f -` then delete pods to restart. |
| Worker: `relation "models" does not exist` / `table "public.background_migrations" does not exist` | Worker started before web ran Prisma migrations (e.g. after Postgres re-init) | Ensure web is 1/1 Running and has applied migrations, then restart worker: `kubectl rollout restart deployment langfuse-worker -n langfuse`. |

---

## Troubleshooting: OAuth callback — "State cookie was missing"

If web logs show:

```text
[next-auth][error][OAUTH_CALLBACK_ERROR] State cookie was missing.
```

the OAuth state cookie set when you started sign-in was not sent on the callback. This happens when **the URL you open in the browser is different from `NEXTAUTH_URL`** (and from the redirect URI in Azure AD).

- **Cause:** You open the app at URL A (e.g. `http://localhost:3000` via port-forward), but `nextauth.url` in Helm is set to URL B (e.g. the Load Balancer URL). The state cookie is set for URL A; Azure redirects back to URL B, so the browser does not send that cookie → "State cookie was missing".
- **Fix:** Use one consistent base URL for both access and OAuth:
  1. **Port-forward testing:** Set `nextauth.url: "http://localhost:3000"` in values, add redirect URI `http://localhost:3000/api/auth/callback/azure-ad` in Azure AD, and always open **http://localhost:3000** in the browser (do not open the Load Balancer URL).
  2. **Production / Load Balancer:** Set `nextauth.url` to the public URL (e.g. `https://langfuse.example.com`), add that callback path in Azure AD, and always open that URL in the browser.

Then run `helm upgrade langfuse langfuse/langfuse -n langfuse -f values.yaml` and retry sign-in.

---

## Rollback: Helm release (fastest)

```bash
# List revisions to see history
helm history langfuse -n langfuse

# Roll back to the previous working revision
helm rollback langfuse -n langfuse

# Or roll back to a specific revision number
helm rollback langfuse <REVISION> -n langfuse
```

---

## Rollback: StorageService (Azure AD auth → key-based)

If the StorageService AD-auth change causes issues (e.g., 403 on presigned URLs even with correct RBAC), revert to **key-based** auth without code change:

1. In Azure Portal, get the Storage Account **key** (Settings → Access keys).
2. In Helm `values.yaml`, add S3/Blob credentials so the existing key-based path is used:

```yaml
s3:
  accessKeyId:
    value: "<storage-account-name>"
  secretAccessKey:
    value: "<storage-account-key>"
```

3. Upgrade release:
   ```bash
   helm upgrade langfuse langfuse/langfuse -n langfuse -f values.yaml
   ```

**Note:** Use only as an emergency fallback; storage account keys are less secure than Workload Identity and violate the SPN-only policy.

### Common causes to check before reverting
- **Missing Storage Blob Delegator role** — `getUserDelegationKey()` returns 403 without it.
- **RBAC propagation delay** — Can take up to 5 minutes after role assignment.
- **Clock skew** — If `startsOn` is too close to "now", intermittent 403 errors occur. The code uses 15-minute skew by default.

---

## Rollback: SSO (Azure AD)

If SSO is misconfigured (redirect URI mismatch, wrong tenant, etc.), temporarily re-enable username/password login:

In `values.yaml` under `langfuse.additionalEnv`:

```yaml
- name: AUTH_DISABLE_USERNAME_PASSWORD
  value: "false"
```

Then:
```bash
helm upgrade langfuse langfuse/langfuse -n langfuse -f values.yaml
```

### Common SSO issues
- **Redirect URI mismatch:** `NEXTAUTH_URL` in `values.yaml` must match the base of the redirect URI in Azure AD App Registration (e.g., `http://localhost:3000` → redirect URI `http://localhost:3000/api/auth/callback/azure-ad`).
- **Missing email claim:** Ensure the App Registration has `email` configured as an optional ID token claim.
- **Wrong tenant:** `AUTH_AZURE_AD_TENANT_ID` must match the tenant of the users who will sign in.

---

## Rollback: Container images

If a new image version causes issues:

```bash
# In values.yaml, change the image tag back to the previous working version:
#   tag: "v1"   (or whatever the previous tag was)
helm upgrade langfuse langfuse/langfuse -n langfuse -f values.yaml
```

---

## Full teardown: All Azure resources

To destroy everything in one command:

```bash
# This deletes the resource group and ALL resources inside it (AKS, ACR, Storage, Identity)
az group delete --name rg-langfuse-dev --yes --no-wait
```

Also clean up the App Registration (not inside the resource group):
```bash
# Find and delete the SSO App Registration
az ad app delete --id "$SSO_APP_ID"
```

And remove the kubectl context:
```bash
kubectl config delete-context aks-langfuse-dev
```

Ensure `RESOURCE_GROUP` matches what was used in `docs/tasks/aks-create-resources.sh` (default: `rg-langfuse-dev`).
