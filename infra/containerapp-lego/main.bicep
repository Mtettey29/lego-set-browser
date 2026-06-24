@description('Container Apps environment + container app for Flask web app')
param location string = 'francecentral'
param environmentName string = 'aca-env-lego'
param containerAppNamePrefix string = 'ca-web-lego-'
param suffix string = 'XXXX' // replace or parameterize when deploying (auto-generate recommended)
var containerAppName string = '${containerAppNamePrefix}${suffix}'
param containerImage string = 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest' // placeholder image per provisioning rules
param cosmosEndpoint string = ''
param cosmosDatabase string = 'LegoDatabase'
param cosmosContainer string = 'legoSets'

@description('Name of the Azure Container Registry the container app pulls from (pull via system-assigned identity).')
param acrLoginServer string = 'acrlegosetsabcd.azurecr.io'

@description('Name of the existing Cosmos DB account to grant the container app data-plane read access to.')
param cosmosAccountName string = 'cosmos-lego-sets'

@description('Name of the existing workspace-based Application Insights component. Referenced (not hardcoded) so the connection string is never stored in source.')
param appInsightsName string = 'appi-lego'

/*
  Notes:
  - Creates a Container Apps managed environment and a container app pulling from ACR via system-assigned identity.
  - System-assigned managed identity is enabled on the container app; a Cosmos DB Built-in Data Reader
    data-plane role assignment is created below so the app can read Cosmos with DefaultAzureCredential (no keys).
  - Health probes (Liveness/Readiness) and an HTTP scale rule (min 1 / max 3) are configured.
*/

resource containerEnv 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: environmentName
  location: location
  properties: {}
}

// Reference the existing Application Insights component to source its connection string without hardcoding secrets.
resource appInsights 'Microsoft.Insights/components@2020-02-02' existing = {
  name: appInsightsName
}

resource containerApp 'Microsoft.App/containerApps@2024-03-01' = {
  name: containerAppName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    managedEnvironmentId: containerEnv.id
    configuration: {
      registries: [
        {
          server: acrLoginServer
          identity: 'system'
        }
      ]
      ingress: {
        external: true
        targetPort: 8000
        allowInsecure: false
      }
    }
    template: {
      containers: [
        {
          name: 'web'
          image: containerImage
          resources: {
            cpu: 1
            memory: '2Gi'
          }
          env: [
            {
              name: 'COSMOS_ENDPOINT'
              value: cosmosEndpoint
            }
            {
              name: 'COSMOS_DATABASE'
              value: cosmosDatabase
            }
            {
              name: 'COSMOS_CONTAINER'
              value: cosmosContainer
            }
            {
              name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
              value: appInsights.properties.ConnectionString
            }
          ]
          probes: [
            {
              type: 'Liveness'
              httpGet: {
                path: '/'
                port: 8000
              }
              initialDelaySeconds: 10
              periodSeconds: 30
            }
            {
              type: 'Readiness'
              httpGet: {
                path: '/'
                port: 8000
              }
              initialDelaySeconds: 5
              periodSeconds: 10
            }
          ]
        }
      ]
      scale: {
        minReplicas: 1
        maxReplicas: 3
        rules: [
          {
            name: 'http-scale'
            http: {
              metadata: {
                concurrentRequests: '50'
              }
            }
          }
        ]
      }
    }
  }
}

// Existing Cosmos DB account (created by the cosmos module) used to scope the data-plane role assignment.
resource cosmosAccount 'Microsoft.DocumentDB/databaseAccounts@2024-05-15' existing = {
  name: cosmosAccountName
}

// Cosmos DB Built-in Data Reader (data-plane) role definition id.
var cosmosDataReaderRoleId string = '00000000-0000-0000-0000-000000000001'

// Grant the container app's system-assigned identity read access to Cosmos data plane.
resource cosmosDataReaderAssignment 'Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments@2024-05-15' = {
  parent: cosmosAccount
  name: guid(cosmosAccount.id, containerApp.id, cosmosDataReaderRoleId)
  properties: {
    roleDefinitionId: '${cosmosAccount.id}/sqlRoleDefinitions/${cosmosDataReaderRoleId}'
    principalId: containerApp.identity.principalId
    scope: cosmosAccount.id
  }
}

output containerAppName string = containerApp.name
