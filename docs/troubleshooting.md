# LAB501 Troubleshooting — `rg-lego-set-browser-dev`

Practical troubleshooting for the LEGO Set Browser deployment in **France Central**. For topology, identities, and observability wiring, see [architecture.md](architecture.md).

**Status (Jun 2026):** Scenarios 1–4 complete; web tier healthy on ingress port **8000**.

---

## Quick Reference — Lab Topics vs. Your Deployment

| # | Lab topic | Applies? | Your status / note |
|---|-----------|----------|-------------------|
| 1 | Cosmos fails locally | Yes (local dev) | `az login` + `COSMOS_ENDPOINT` in `.env`; account uses `disableLocalAuth: true` — user needs **Data Contributor** |
| 2 | ACR name has hyphens | No | Registry `acrlegosetsabcd` is alphanumeric |
| 3 | AZD wrong subscription | Maybe | Align with `azd env set AZURE_SUBSCRIPTION_ID $(az account show --query id -o tsv)` |
| 4 | Container App → Cosmos | Already fixed | Env vars set; system MI has **Data Reader** on `cosmos-lego-sets` |
| 5 | `ingress update` hangs | Yes | Normal 2+ min wait for revision — do not Ctrl+C (Scenario 3) |
| 6 | First request slow | Yes | Wait ~15s after deploy despite `minReplicas: 1` |
| 7 | KQL returns no results | Yes + twist | Wait 5 min for ingestion; **`ContainerAppSystemLogs_CL` not in `law-lego`** — use HTTP logs / App Insights |
| 8 | `scheduled-query` not found | Fixed | `az extension add --name scheduled-query --yes` |
| 9 | Docker build fails | No | Deploy succeeded; start Docker Desktop if rebuilding |
| 10 | Python deps fail | Maybe (local) | Python 3.13+ locally; Function runs 3.12 in Azure |
| 11 | PowerShell KQL escaping | Yes | Use `has "ProbeFailed"` instead of `== "ProbeFailed"` |
| 12 | Gunicorn port mismatch → 503 | Already fixed | Ingress **8000** ↔ `gunicorn --bind 0.0.0.0:8000` |

---

## Session-Specific Issues You Hit

| Issue | Status | What to do |
|-------|--------|------------|
| **Region policy blocks** | Worked around | `westus3` / `westus2` denied on student subscription; **France Central** succeeded |
| **Placeholder image not swapped** | Fixed | Bicep provisions `mcr.microsoft.com/azuredocs/containerapps-helloworld:latest`; real app is `acrlegosetsabcd.azurecr.io/ca-web-lego:latest` after deploy. Confirm with `az containerapp revision list` |
| **Cosmos RBAC missing** | Fixed | Web system MI → **Data Reader**; Function UAMI `uaid-fa-lego-sets` → **Data Contributor** |
| **Function platform 503** | Fixed | Old `fa-lego-sets` (Consumption) removed; live host is **`fa-lego-flex`** on Flex Consumption FC1 |
| **Broken set images** | Fixed | Repo has no bundled images — cards use `image_url` from Cosmos via `/image-proxy` |
| **Image-proxy whitelist** | By design | Route `/image-proxy` only allows **`cdn.rebrickable.com`**. Brickset or other hosts return 403 even if URL is valid |
| **System logs not in LAW** | Known gap | `aca-env-lego` has no app-logs LA destination; `ContainerAppSystemLogs_CL` absent. Use `ContainerAppHTTPLogs`, `appi-lego`, and `alert-lego-5xx` |

---

## Quick Diagnostic Cheat Sheet

Run from PowerShell with `az` logged into the student subscription.

```powershell
# 1. Web tier — is it serving?
curl.exe -s -o NUL -w "HTTP %{http_code}`n" `
  "https://ca-web-lego-abcd.calmrock-4a13cc87.francecentral.azurecontainerapps.io/"

# 2. Ingress port — must be 8000 (Scenario 3 regression check)
az containerapp show -n ca-web-lego-abcd -g rg-lego-set-browser-dev `
  --query "properties.configuration.ingress.targetPort" -o tsv

# 3. Recent platform logs (live — not in LAW system-log table)
az containerapp logs show -n ca-web-lego-abcd -g rg-lego-set-browser-dev --type system --tail 30

# 4. HTTP telemetry in Log Analytics (works in your workspace)
$cid = az monitor log-analytics workspace show -g rg-lego-set-browser-dev -n law-lego --query customerId -o tsv
az monitor log-analytics query -w $cid --analytics-query `
  "ContainerAppHTTPLogs | where TimeGenerated > ago(1h) | where ContainerAppName == 'ca-web-lego-abcd' | summarize count() by StatusCode" -o table

# 5. Cosmos RBAC — web read path + Function write path
az cosmosdb sql role assignment list --account-name cosmos-lego-sets -g rg-lego-set-browser-dev -o table

# 6. Function host — running state and hostname
az functionapp show -n fa-lego-flex -g rg-lego-set-browser-dev `
  --query "{state:state, host:defaultHostName}" -o json
```

---

## Decision Tree

```
503 on web URL?
  ├─ targetPort ≠ 8000?  → az containerapp ingress update … --target-port 8000; wait for revision
  ├─ targetPort = 8000?  → az containerapp logs show --type system; check probe/readiness failures
  └─ See scenario-4-incident-report.md for KQL port-mismatch proof

App loads but no sets / DB errors?
  ├─ Check Cosmos RBAC (cheat sheet #5) and env vars on ca-web-lego-abcd
  └─ Local dev? az login + COSMOS_ENDPOINT in .env

Images broken but catalog data loads?
  └─ /image-proxy whitelist — only cdn.rebrickable.com; re-seed lego_seed.json with verified URLs

Function ingest fails?
  ├─ fa-lego-flex state (cheat sheet #6); retry after cold start
  └─ Confirm UAMI Data Contributor on cosmos-lego-sets

Scenario 4 KQL empty?
  ├─ Wait 5 min after generating traffic
  ├─ Query ContainerAppHTTPLogs (not ContainerAppSystemLogs_CL)
  └─ alert-lego-probefailed won't fire until system logs ingest
```

---

## Common Fixes (One-Liners)

**Restore ingress after port break:**

```powershell
az containerapp ingress update -g rg-lego-set-browser-dev -n ca-web-lego-abcd --target-port 8000
```

**Re-seed Cosmos after fixing image URLs:**

```powershell
python seed_cosmos.py
```

**List active alerts:**

```powershell
az monitor scheduled-query list -g rg-lego-set-browser-dev -o table
```

---

## Bottom Line

The stack is healthy after Scenario 3's port fix. The two issues most likely to recur are **ingress port drift** (check `targetPort` before blaming Cosmos) and **Cosmos MI RBAC** after identity redeploy. For observability, lean on **`alert-lego-5xx`**, **`appi-lego`**, and **`ContainerAppHTTPLogs`** — not `ContainerAppSystemLogs_CL`, which is not ingested in `law-lego`.

**Related:** [architecture.md](architecture.md) · [scenario-4-incident-report.md](scenario-4-incident-report.md)
