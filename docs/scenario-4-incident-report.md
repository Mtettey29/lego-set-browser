# Scenario 4 Incident Report — Container App Port Mismatch

**Lab:** Build 2026 LAB501 — Investigate & Operationalize  
**Analysis date:** June 2026  
**Incident window:** 2026-06-24 (UTC)

---

## Environment Summary

| Item | Value |
|------|-------|
| Resource group | `rg-lego-set-browser-dev` (France Central) |
| Container App | `ca-web-lego-abcd` |
| Log Analytics | `law-lego` |
| App Insights | `appi-lego` (workspace-based → `law-lego`) |
| Cosmos DB | `cosmos-lego-sets` / `LegoDatabase` / `legoSets` |
| Managed environment | `aca-env-lego` |

See [architecture.md](architecture.md) for the full deployed topology.

---

## Part A — Log Analytics Table Availability

**Checkpoint:** Partial — HTTP logs prove the incident; system logs table is absent.

| Table | Available | Notes |
|-------|-----------|-------|
| `ContainerAppHTTPLogs` | Yes | Only ACA application log table ingested (~54 rows in 7d window) |
| `ContainerAppSystemLogs_CL` | **No** | SEM0100 — table does not exist in workspace |
| `AzureDiagnostics` | Yes | Platform diagnostics (~205K rows / 7d) |
| `AzureMetrics` | Yes | Container App metrics present |

**Why system logs are missing:** ACA environment `aca-env-lego` was created with `appLogsConfiguration.destination = null` (not linked to Log Analytics at creation). Diagnostic setting `diag-law` sends `allLogs` to `law-lego`, but only HTTP ingress logs land. Platform events such as `ProbeFailed` and `ReplicaUnhealthy` are visible via `az containerapp logs show --type system` but not queryable in KQL post-mortems.

**Lab-intended queries on `ContainerAppSystemLogs_CL` fail as expected:**

```text
'where' operator: Failed to resolve table or column expression named 'ContainerAppSystemLogs_CL'
```

---

## Incident Summary

**Root cause:** Scenario 3 break set ingress `targetPort` to **9999** while gunicorn binds **8000** (`Dockerfile`: `gunicorn --bind 0.0.0.0:8000`).

| Metric | Value |
|--------|-------|
| HTTP 503 responses | **7** (all routed to upstream `:9999`, `Connection_refused`) |
| HTTP 200 responses | **31** (all routed to upstream `:8000`, `via_upstream`) |
| First 503 | `2026-06-24T19:46:25Z` |
| Last 503 | `2026-06-24T23:43:03Z` |
| Recovery (first 200 after last 503) | **`2026-06-24T23:44:36Z`** on `:8000` |

**Symptom:** `503 Service Unavailable` with body `upstream connect error … Connection refused`.

**Evidence chain:**

1. Live config showed `targetPort: 9999` while console logs confirmed gunicorn listening on `:8000`.
2. Every 503 in `ContainerAppHTTPLogs` targeted `UpstreamHost` ending in `:9999` with `ResponseFlags = URX,UF` and `ResponseCodeDetails` containing `Connection_refused`.
3. Every 200 targeted `:8000`. No mixed-port outcomes for a given status code.
4. Active revision throughout: `ca-web-lego-abcd--0000003`.

**Timeline (503 bursts, 5-minute bins):**

| Time (UTC) | 503 count | Notes |
|------------|-----------|-------|
| 19:45 | 1 | First probe after port change |
| 23:20 | 1 | Failure resumes |
| 23:35 | 3 | All requests in bin failed |
| 23:40 | 2 | Last failures before restore |

**Fix:** Restore ingress to port 8000:

```powershell
az containerapp ingress update -g rg-lego-set-browser-dev -n ca-web-lego-abcd --target-port 8000
```

---

## Key KQL Queries (HTTP Fallbacks)

Look up workspace ID once:

```powershell
$cid = az monitor log-analytics workspace show -g rg-lego-set-browser-dev -n law-lego --query customerId -o tsv
```

**503 timeline (5-minute bins):**

```kql
ContainerAppHTTPLogs
| where TimeGenerated > ago(7d)
| where ContainerAppName == 'ca-web-lego-abcd'
| where StatusCode == 503
| summarize count() by bin(TimeGenerated, 5m)
| order by TimeGenerated asc
```

**Port mismatch proof:**

```kql
ContainerAppHTTPLogs
| where TimeGenerated > ago(7d)
| where ContainerAppName == 'ca-web-lego-abcd'
| extend UpstreamPort = extract(':([0-9]+)$', 1, UpstreamHost)
| summarize Requests = count() by UpstreamPort, StatusCode
| order by UpstreamPort, StatusCode
```

**503 detail — upstream host and failure reason:**

```kql
ContainerAppHTTPLogs
| where TimeGenerated > ago(7d)
| where ContainerAppName == 'ca-web-lego-abcd'
| where StatusCode == 503
| project TimeGenerated, RequestMethod, RequestUri, UpstreamHost,
          ResponseCodeDetails, ResponseFlags, RevisionName
| order by TimeGenerated asc
```

**Incident window and recovery:**

```kql
ContainerAppHTTPLogs
| where TimeGenerated > ago(7d)
| where ContainerAppName == 'ca-web-lego-abcd'
| summarize
    First503 = minif(StatusCode == 503, TimeGenerated),
    Last503  = maxif(StatusCode == 503, TimeGenerated),
    First200AfterFix = minif(StatusCode == 200 and TimeGenerated > datetime(2026-06-24T23:43:03Z), TimeGenerated),
    Total503 = countif(StatusCode == 503),
    Total200 = countif(StatusCode == 200)
```

**HTTP status breakdown:**

```kql
ContainerAppHTTPLogs
| where TimeGenerated > ago(24h)
| where ContainerAppName == 'ca-web-lego-abcd'
| summarize Requests = count() by StatusCode, ResponseFlags
| order by StatusCode asc
```

Example invocation:

```powershell
az monitor log-analytics query -w $cid --analytics-query "<KQL here>" -o table
```

**PowerShell tip:** Prefer single-quoted KQL strings (`'ca-web-lego-abcd'`) inside double-quoted `--analytics-query` to avoid hyphen/subtraction parsing issues.

---

## Alerts

| Alert | Status | Query target |
|-------|--------|--------------|
| `alert-lego-5xx` | **Works today** | `ContainerAppHTTPLogs` where `StatusCode >= 500` |
| `alert-lego-probefailed` | **Created, won't fire yet** | `ContainerAppSystemLogs_CL` where `Reason_s has 'ProbeFailed'` — table not ingested |

`alert-lego-5xx` KQL:

```kql
ContainerAppHTTPLogs
| where ContainerAppName == 'ca-web-lego-abcd'
| where StatusCode >= 500
```

Until system logs ingest, use HTTP 5xx alerting plus live `az containerapp logs show --type system` for probe events.

---

## Production Alert Recommendations

| # | Alert | Signal | Priority | Pattern |
|---|-------|--------|----------|---------|
| 1 | HTTP 5xx spike | Log (KQL) | High | Exists as `alert-lego-5xx` |
| 2 | ProbeFailed / replica unhealthy | Log (KQL) | High | Needs `ContainerAppSystemLogs_CL` ingestion |
| 3 | Replica restart loop | Log (KQL) | High | System logs — restarts > 3 per 15m |
| 4 | High request latency (P95) | Metric | High | `ResponseTime > 2000ms` on Container App |
| 5 | CPU saturation | Metric | Med | `CpuPercentage > 80` |
| 6 | Memory pressure | Metric | Med | `MemoryPercentage > 85` |
| 7 | Cosmos 429 throttling | Metric | High | `TotalRequests where StatusCode=429 > 10` on `cosmos-lego-sets` |
| 8 | Function App failures | Log (KQL) | High | `AppExceptions` where `AppRoleName == 'fa-lego-flex'` |

Metric alert example (Cosmos throttling):

```powershell
az monitor metrics alert create `
  -g rg-lego-set-browser-dev `
  -n alert-cosmos-throttling `
  --scopes "/subscriptions/<sub-id>/resourceGroups/rg-lego-set-browser-dev/providers/Microsoft.DocumentDB/databaseAccounts/cosmos-lego-sets" `
  --condition "total TotalRequests where StatusCode includes 429 > 10" `
  --window-size 5m --evaluation-frequency 1m `
  --severity 1
```

---

## Lab Takeaway

Scenario 4 closes the loop from "incident fixed" to "incident understood and monitored." Even when the ideal telemetry table (`ContainerAppSystemLogs_CL`) is missing, HTTP ingress logs tell the same story: every 503 routed to upstream port **9999** with `Connection_refused`, while healthy traffic used **8000**. KQL post-mortems answer *how long* and *when recovery happened*; scheduled-query alerts (`alert-lego-5xx` works today; `alert-lego-probefailed` awaits system log ingestion) turn investigation into proactive paging. Production readiness means layering metric alerts (latency, CPU, memory, Cosmos RU/throttling) alongside log alerts and knowing which signal covers which failure mode.

**Related:** [architecture.md](architecture.md) · [troubleshooting.md](troubleshooting.md)
