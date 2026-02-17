# AKS Langfuse deployment — estimated monthly cost

This is an **approximate** monthly cost for the resources created by `aks-create-resources.sh` and `aks-add-front-door.sh`, using **Azure list (pay-as-you-go) pricing** in **USD**. Actual bills depend on region, usage, and your agreement.

**Sources:** [AKS](https://azure.microsoft.com/en-us/pricing/details/kubernetes-service/) | [ACR](https://azure.microsoft.com/en-us/pricing/details/container-registry/) | [Front Door](https://azure.microsoft.com/en-us/pricing/details/frontdoor/) | [Storage](https://azure.microsoft.com/en-us/pricing/details/storage/blobs/) | [Load Balancer](https://azure.microsoft.com/en-us/pricing/details/load-balancer/) | [Virtual Machines](https://azure.microsoft.com/en-us/pricing/details/virtual-machines/linux/) (pricing pages, latest available).

---

## Resources in this deployment

| Resource | What we use | Pricing model |
|--------|-------------------------------|-------------------|
| **AKS** | Free tier control plane; 2 nodes × Standard_D4s_v5 (East US) | Free + VM compute |
| **ACR** | Basic SKU, 10 GB included | Per day + overage storage |
| **Azure Front Door** | Standard tier, 1 profile, 1 endpoint, 1 route | Base + requests + egress |
| **Storage account** | Standard LRS, Hot tier, Blob (Langfuse media/exports/events) | Storage GB + operations |
| **Load Balancer** | Standard, 1 public IP (langfuse-web) | Per hour (first 5 rules) + data processed |
| **Managed Identity** | User-assigned (id-langfuse-dev) | No charge |
| **In-cluster DBs** | PostgreSQL, Redis, ClickHouse, Zookeeper (Helm) | Run on AKS nodes → part of VM cost |
| **Managed disks (PVCs)** | 8 Gi × several (postgres, redis, clickhouse, zookeeper) | Per GB/month (Standard) |

---

## Monthly estimate (East US, light–moderate usage)

| Component | Assumption | Estimated USD/month |
|-----------|------------|---------------------|
| **AKS control plane** | Free tier (no SLA) | **$0** |
| **AKS nodes (compute)** | 2 × Standard_D4s_v5 (4 vCPU, 16 GB each), 730 h/month | **~$280** |
| **ACR** | Basic, 10 GB included | **~$5** |
| **Azure Front Door Standard** | $35 base + ~1–5M requests ($0.009/10k) + small egress | **~$36–40** |
| **Storage (Blob)** | ~10–20 GB Hot, LRS | **~$1–2** |
| **Load Balancer** | 1 × $0.025/h (first 5 rules) + small data processed | **~$18–20** |
| **Managed disks (PVCs)** | ~40–50 GB Standard SSD/LRS | **~$4–8** |
| **Bandwidth / egress** | First 5 GB out free; then ~$0.087/GB (North America) | **~$0–10** (usage-dependent) |

---

## Total (ballpark)

| Scenario | Approximate USD/month |
|----------|------------------------|
| **Low usage** (dev / light traffic) | **~$345–360** |
| **Moderate usage** (more traffic, some egress) | **~$360–380** |

So you can expect roughly **$350–380/month** for this setup on list pay-as-you-go pricing in East US, with the assumptions above.

---

## What changes the bill

- **AKS tier:** Standard tier control plane is **$73/month** (SLA). We assumed Free.
- **Node count/size:** More or larger nodes (e.g. 3× D4s_v5) add VM cost.
- **Front Door:** More requests and more egress increase the total; Premium is **$330/month** base.
- **Reservations / Savings Plan:** 1- or 3-year commit on VMs (and optionally Storage) can cut compute cost by a large percentage.
- **Region:** Prices differ by region; East US is often mid-range.
- **Blob storage:** Grows with traces/events/exports; first 50 TB tier is ~\$0.0184/GB/month (Hot, LRS).

---

## How to check your actual cost

- **Cost Management + Billing** in Azure Portal: view cost by resource group (e.g. `rg-langfuse-dev`).
- **Azure Pricing Calculator:** [calculator](https://azure.microsoft.com/en-us/pricing/calculator/) — add AKS, ACR, Front Door, Storage, VMs, Load Balancer for your region and usage.
- **Tags:** Tag the resource group or resources (e.g. `project=langfuse`) and filter in Cost Management.

---

## Reducing cost (if needed)

- Use **AKS Free tier** and keep **2 nodes** (already assumed).
- Use **smaller node size** (e.g. Standard_D2s_v5) if the workload fits; scale back up if needed.
- **Reserve** VM capacity (1 or 3 years) for a large discount on node compute.
- **Pause** when not needed: scale AKS to 0 nodes (and optionally tear down Front Door / LB) to avoid VM and LB hourly charges; ACR and Storage will still incur small charges.
