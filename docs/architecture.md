# LEGO Set Browser — Deployed Architecture (`rg-lego-set-browser-dev`)

This document captures the **actual deployed topology** of the LEGO Set Browser solution as
discovered live (read-only) in the **"Azure for Students"** subscription
(`6a4d2bbf-e536-448d-a119-f06b51ffd744`), resource group **`rg-lego-set-browser-dev`**
in **France Central**. It reflects the **post-cleanup state (Jun 2026)**: the legacy
Consumption Function App `fa-lego-sets` and its plan `FranceCentralLinuxDynamicPlan` have
been removed; ingest now runs on **`fa-lego-flex`** (Flex Consumption). The Container Apps
environment has **no Log Analytics app-logs destination**, **no classic diagnostic settings**
are configured, and the Function emits telemetry to **its own App Insights wired to a default
workspace outside this resource group**.

> **Cleanup note (refreshed Jun 2026):** `fa-lego-sets`, `FranceCentralLinuxDynamicPlan`, and
> the orphaned `fa-lego-sets-plan` / duplicate storage account `falegosetssa` are **gone**.
> The live Function host store is `falegosetsa`; the API tier is `fa-lego-flex` on plan
> `ASP-rglegosetbrowserdev-4842` (Flex Consumption FC1).

The web tier is healthy and serving traffic. The read path (Container App → Cosmos via the
system-assigned managed identity with **Data Reader**) and the write/ingest path (Function App
→ Cosmos via the user-assigned identity with **Data Contributor**) are both operational.

## Architecture diagram

```mermaid
graph TB
    user["User / Browser"]
    deployer["Deployer / Human principal<br/>fbecc709"]

    subgraph WEB["Web Tier"]
        acr["ACR<br/>acrlegosetsabcd<br/>Basic SKU<br/>admin disabled"]
        acaenv["Container Apps Env<br/>aca-env-lego<br/>no app-logs LA destination"]
        ca["Container App<br/>ca-web-lego-abcd<br/>external ingress, targetPort 8000, HTTPS only<br/>image ca-web-lego:latest<br/>scale 1 to 3, http rule 50 concurrent<br/>liveness + readiness probes<br/>STATUS: Running"]
        casi["System-assigned MI<br/>ca-web-lego-abcd<br/>principal bf05cbef"]
    end

    subgraph API["API Tier"]
        plan["App Service Plan<br/>ASP-rglegosetbrowserdev-4842<br/>Flex Consumption FC1, Linux<br/>hosts the Function"]
        fa["Function App<br/>fa-lego-flex<br/>Python 3.12, Flex Consumption<br/>User assigned identity<br/>STATUS: Running"]
        uami["User-assigned MI<br/>uaid-fa-lego-sets<br/>client 7589fea6 / principal 80219cab"]
    end

    subgraph STG["Backing Storage"]
        sa["Storage Account<br/>falegosetsa<br/>StorageV2 Standard_LRS<br/>shared-key + public access disabled<br/>Function host: AzureWebJobs + content share"]
    end

    subgraph OBS["Observability"]
        appi["App Insights<br/>appi-lego<br/>workspace-based<br/>used by Container App"]
        faai["App Insights<br/>fa-lego-flex<br/>workspace-based<br/>used by Function App"]
        law["Log Analytics<br/>law-lego<br/>PerGB2018, 30 day retention"]
        deflaw["Default LA workspace<br/>DefaultWorkspace-...-PAR<br/>OUTSIDE this resource group"]
        alert["Scheduled query rule<br/>alert-lego-5xx<br/>Container App HTTP 5xx<br/>enabled"]
    end

    subgraph DATA["Data"]
        cosmos["Cosmos DB account<br/>cosmos-lego-sets<br/>SQL API, Session<br/>disableLocalAuth: TRUE - key auth off<br/>public network: Enabled"]
        cdb["SQL Database<br/>LegoDatabase"]
        ccol["Container<br/>legoSets<br/>partition key /id"]
    end

    %% Web request path
    user -->|HTTPS 443| ca
    acaenv -->|hosts| ca
    acr -->|image pull via system MI, AcrPull| ca
    ca -. system-assigned MI .-> casi

    %% Read path (Container App -> Cosmos, Data Reader)
    casi ==>|Cosmos SQL Data Reader| cosmos
    ca -->|read items, SQL via SDK| cdb

    %% API / write path
    plan -->|hosts| fa
    fa -. user-assigned MI .-> uami
    fa -->|host metadata + content share| sa
    uami ==>|Cosmos SQL Data Contributor| cosmos
    fa -->|upsert items, SQL via SDK| cdb
    deployer ==>|Cosmos SQL Data Contributor| cosmos

    %% Data hierarchy
    cosmos --> cdb --> ccol

    %% Observability (via connection strings; no diagnostic settings exist)
    ca -->|telemetry, connection string| appi
    fa -->|telemetry, connection string| faai
    appi -->|workspace-based| law
    faai -->|workspace-based| deflaw
    appi -->|5xx query source| alert

    classDef identity fill:#fff3cd,stroke:#d39e00,stroke-width:1px,color:#664d03;
    classDef data fill:#cfe2ff,stroke:#0a58ca,stroke-width:1px,color:#084298;

    class casi,uami,deployer identity;
    class cosmos,cdb,ccol data;
```

## Resource inventory

| Resource | Type | Notes |
|----------|------|-------|
| `cosmos-lego-sets` | Cosmos DB account (`Microsoft.DocumentDB/databaseAccounts`) | SQL API (GlobalDocumentDB), Session consistency, **`disableLocalAuth: true`** (key auth off), public network **Enabled**, periodic geo backup, automatic failover. |
| `LegoDatabase` | Cosmos SQL database | Child of `cosmos-lego-sets`. |
| `legoSets` | Cosmos SQL container | Partition key `/id`, consistent indexing. |
| `ca-web-lego-abcd` | Container App (`Microsoft.App/containerApps`) | External ingress, target port **8000**, `allowInsecure: false`, image `acrlegosetsabcd.azurecr.io/ca-web-lego:latest`, scale **1→3** (HTTP rule, 50 concurrent), liveness + readiness probes, **Running**. System-assigned MI principal `bf05cbef`. Pulls image using system identity. |
| `aca-env-lego` | Container Apps managed environment (`Microsoft.App/managedEnvironments`) | Default domain `calmrock-4a13cc87.francecentral.azurecontainerapps.io`. **No app-logs Log Analytics destination configured.** |
| `acrlegosetsabcd` | Container Registry (`Microsoft.ContainerRegistry/registries`) | **Basic** SKU, **admin user disabled**, anonymous pull disabled, public network enabled. |
| `fa-lego-flex` | Function App (`Microsoft.Web/sites`, `functionapp,linux`) | **Python 3.12** on **Flex Consumption** (`ASP-rglegosetbrowserdev-4842`, FC1). User-assigned identity only (`uaid-fa-lego-sets`). **Running.** Uses `AZURE_CLIENT_ID` of the UAMI for Cosmos. |
| `ASP-rglegosetbrowserdev-4842` | App Service Plan (`Microsoft.Web/serverFarms`) | **Flex Consumption FC1**, Linux (`kind: functionapp`), **1 site** (hosts `fa-lego-flex`). |
| `uaid-fa-lego-sets` | User-assigned managed identity (`Microsoft.ManagedIdentity/userAssignedIdentities`) | Client `7589fea6`, principal `80219cab`. Holds Cosmos **Data Contributor** (write path). |
| `falegosetsa` | Storage Account (`Microsoft.Storage/storageAccounts`) | StorageV2 `Standard_LRS`, shared-key access and blob public access disabled. **Function host storage** (AzureWebJobsStorage + content share). |
| `law-lego` | Log Analytics workspace (`Microsoft.OperationalInsights/workspaces`) | `PerGB2018`, 30-day retention. Workspace for `appi-lego`. |
| `appi-lego` | Application Insights (`Microsoft.Insights/components`) | Workspace-based → `law-lego`. Instrumentation key `49225d18` matches the **Container App** connection string. |
| `fa-lego-flex` (Insights) | Application Insights (`Microsoft.Insights/components`) | Separate component for the Function App, **workspace-based but linked to `DefaultWorkspace-...-PAR` (outside this resource group)**. |
| `alert-lego-5xx` | Scheduled query rule (`Microsoft.Insights/scheduledqueryrules`) | **Enabled.** Fires when the Container App returns HTTP 5xx (e.g. 503 from ingress / readiness probe failure). |
| `Application Insights Smart Detection` | Action group (`microsoft.insights/actiongroups`) | Auto-created with App Insights for smart-detection alerts. |

### Cosmos DB SQL role assignments (data plane)

| Principal | Identity | Role |
|-----------|----------|------|
| `bf05cbef-d78c-40e8-b888-51e7804e8297` | Container App system-assigned MI | **Cosmos DB Built-in Data Reader** (read path) |
| `80219cab-ecfb-4c55-8edb-a1d576ca0de0` | `uaid-fa-lego-sets` user-assigned MI | **Cosmos DB Built-in Data Contributor** (write path) |
| `fbecc709-7aa7-41a0-aac0-1b360f129771` | Deployer / human principal | **Cosmos DB Built-in Data Contributor** |

### Reality vs. idealized lab topology

- **Function App migrated to Flex Consumption** — `fa-lego-flex` on `ASP-rglegosetbrowserdev-4842` (FC1) replaces the removed `fa-lego-sets` / `FranceCentralLinuxDynamicPlan` pair.
- **No diagnostic settings** exist on the Container App, ACA environment, or Cosmos account; telemetry reaches App Insights only via the `APPLICATIONINSIGHTS_CONNECTION_STRING` app settings.
- **ACA environment has no Log Analytics app-logs destination** configured.
- **Two App Insights components**: the Container App reports to `appi-lego` (→ `law-lego`), while the Function reports to `fa-lego-flex` wired to a **default workspace outside this resource group**.
- **5xx alerting** via `alert-lego-5xx` monitors Container App HTTP failures against `appi-lego` telemetry.
- **Security hardening confirmed**: Cosmos `disableLocalAuth: true`, ACR admin disabled, the storage account has shared-key and public blob access disabled, Container App ingress is HTTPS-only.
