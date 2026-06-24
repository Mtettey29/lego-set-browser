@description('Location for all resources')
param location string = 'francecentral'
param functionAppName string = 'fa-lego-sets'
var storageAccountName = toLower(concat(replace(functionAppName, '-', ''), 'sa'))
param userAssignedIdentityName string = 'uaid-fa-lego-sets'
@description('Name of the existing Cosmos DB account (assumed to live in this resource group) the Function identity reads/writes.')
param cosmosAccountName string = 'cosmos-lego-sets'
param cosmosDatabaseName string = 'LegoDatabase'
param cosmosContainerName string = 'legoSets'

/*
  Notes:
  - This template creates a user-assigned managed identity and a Function App (Linux).
  - It does NOT create a Cosmos DB account; it references the existing one named by `cosmosAccountName`
    (assumed to be in this resource group) and grants the Function identity the Cosmos DB Built-in
    Data Contributor data-plane role so it can read/write with managed identity (no keys).
*/

resource userIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2018-11-30' = {
  name: userAssignedIdentityName
  location: location
}

resource storageAccount 'Microsoft.Storage/storageAccounts@2021-09-01' = {
  name: storageAccountName
  location: location
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    allowBlobPublicAccess: false
    minimumTlsVersion: 'TLS1_2'
  }
}

resource appServicePlan 'Microsoft.Web/serverfarms@2021-02-01' = {
  name: '${functionAppName}-plan'
  location: location
  sku: {
    name: 'Y1' // Consumption plan (Y1) — adjust if validation requires a different SKU
    tier: 'Dynamic'
  }
  kind: 'functionapp'
}

resource functionApp 'Microsoft.Web/sites@2021-02-01' = {
  name: functionAppName
  location: location
  kind: 'functionapp'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${userIdentity.id}': {}
    }
  }
  properties: {
    serverFarmId: appServicePlan.id
    siteConfig: {
      linuxFxVersion: 'Python|3.9'
      alwaysOn: true
      appSettings: [
        {
          name: 'FUNCTIONS_WORKER_RUNTIME'
          value: 'python'
        }
        {
          name: 'WEBSITE_RUN_FROM_PACKAGE'
          value: '1'
        }
        {
          name: 'COSMOS_ENDPOINT'
          value: ''
        }
        {
          name: 'COSMOS_DATABASE'
          value: cosmosDatabaseName
        }
        {
          name: 'COSMOS_CONTAINER'
          value: cosmosContainerName
        }
      ]
    }
  }
  dependsOn: [ storageAccount ]
}

// Existing Cosmos DB account (created by the cosmos module) used to scope the data-plane role assignment.
resource cosmosAccount 'Microsoft.DocumentDB/databaseAccounts@2024-05-15' existing = {
  name: cosmosAccountName
}

// Cosmos DB Built-in Data Contributor (data-plane) role definition id.
var cosmosDataContributorRoleId string = '00000000-0000-0000-0000-000000000002'

// Grant the Function's user-assigned identity read/write access to the Cosmos data plane.
resource cosmosDataContributorAssignment 'Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments@2024-05-15' = {
  parent: cosmosAccount
  name: guid(cosmosAccount.id, userIdentity.id, cosmosDataContributorRoleId)
  properties: {
    roleDefinitionId: '${cosmosAccount.id}/sqlRoleDefinitions/${cosmosDataContributorRoleId}'
    principalId: userIdentity.properties.principalId
    scope: cosmosAccount.id
  }
}

output functionAppName string = functionApp.name
output userAssignedIdentityId string = userIdentity.id
