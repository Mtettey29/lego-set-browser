@description('Location for all resources')
param location string = 'francecentral'
param accountName string = 'cosmos-lego-sets'
param databaseName string = 'LegoDatabase'
param containerName string = 'legoSets'

/*
  Creates a Cosmos DB account (SQL API), a database, and a container.
  - Default throughput set to 400 RU for the database
  - Partition key: /id
  - Adjust names and throughput before deployment as needed
*/

resource cosmos 'Microsoft.DocumentDB/databaseAccounts@2024-05-15' = {
  name: accountName
  location: location
  kind: 'GlobalDocumentDB'
  properties: {
    databaseAccountOfferType: 'Standard'
    // Enforce Entra ID (AAD) auth only — disable key-based local auth. The app reads Cosmos via managed identity.
    disableLocalAuth: true
    locations: [
      {
        locationName: location
      }
    ]
    consistencyPolicy: {
      defaultConsistencyLevel: 'Session'
    }
  }
}

resource sqlDatabase 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases@2024-05-15' = {
  name: '${cosmos.name}/${databaseName}'
  properties: {
    resource: {
      id: databaseName
    }
    options: {
      throughput: 400
    }
  }
}

resource sqlContainer 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers@2024-05-15' = {
  name: '${cosmos.name}/${databaseName}/${containerName}'
  properties: {
    resource: {
      id: containerName
      partitionKey: {
        paths: [ '/id' ]
        kind: 'Hash'
      }
    }
    options: {}
  }
}

output cosmosAccountName string = cosmos.name
output cosmosEndpoint string = 'https://${cosmos.name}.documents.azure.com:443/'
output databaseNameOut string = databaseName
output containerNameOut string = containerName
