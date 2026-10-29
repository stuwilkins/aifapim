@description('Unique suffix used in resource names.')
param uniqueSuffix string

param location string

param tags object = {}

@description('Name of the existing virtual network that holds the function subnet. Must be in the same resource group and region.')
param vnetName string

@description('Name of the subnet to create for the function app virtual network integration.')
param functionSubnetName string = 'reqlog'

@description('CIDR of the function subnet. Flex Consumption needs at least a /27.')
param functionSubnetPrefix string

@description('Subnet resource ID for the private endpoints of the function host storage account.')
param privateEndpointSubnetId string

@description('Resource IDs of the privatelink.blob, privatelink.queue and privatelink.table private DNS zones.')
param blobPrivateDnsZoneId string
param queuePrivateDnsZoneId string
param tablePrivateDnsZoneId string

@description('Name of the storage account that holds the function host files, deployment package and the event queue.')
param hostStorageAccountName string

@description('Name of the data storage account that holds the request bodies (read-only for the function).')
param dataStorageAccountName string

@description('Name of the container on the data storage account that holds the request bodies.')
param dataContainerName string

@description('Logs Ingestion endpoint of the data collection endpoint.')
param dceLogsIngestionEndpoint string

@description('Name of the data collection rule. The function identity gets Monitoring Metrics Publisher on it.')
param dcrName string

@description('Immutable ID of the data collection rule.')
param dcrImmutableId string

@description('Name of the data collection rule input stream.')
param streamName string

@description('Name of the existing Application Insights component, and its connection string, used for the function logs.')
param applicationInsightsName string
param applicationInsightsConnectionString string

@description('Maximum number of function instances. Bounds the load on the ingestion endpoint.')
@minValue(1)
@maxValue(100)
param maximumInstanceCount int = 4

@description('Python version of the function app.')
param pythonVersion string = '3.13'

var azureRoles = loadJsonContent('../azure_roles.json')
var queueName = 'llm-request-events'
var deployContainerName = 'app-package'
var functionAppName = 'func-llmreq-${uniqueSuffix}'

resource vnet 'Microsoft.Network/virtualNetworks@2023-11-01' existing = {
  name: vnetName
}

resource nsg 'Microsoft.Network/networkSecurityGroups@2023-11-01' = {
  name: 'nsg-${functionSubnetName}-${uniqueSuffix}'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'Allow_Outbound_To_Private_Endpoints'
        properties: {
          description: 'Outbound HTTPS to the storage and Azure Monitor private endpoints in the VNet.'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '443'
          sourceAddressPrefix: 'VirtualNetwork'
          destinationAddressPrefix: 'VirtualNetwork'
          access: 'Allow'
          priority: 300
          direction: 'Outbound'
        }
      }
      {
        name: 'Deny_Lateral_Outbound_VirtualNetwork'
        properties: {
          description: 'Deny other outbound traffic to the VNet (Azure.NSG.LateralTraversal).'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: 'VirtualNetwork'
          destinationAddressPrefix: 'VirtualNetwork'
          access: 'Deny'
          priority: 4096
          direction: 'Outbound'
        }
      }
    ]
  }
}

// The subnet is private (no default outbound access) and has no route to the
// internet: BNL policy denies public IP addresses, so there is no NAT gateway.
// The function reaches Azure Monitor through the private link scope
// (request-log-ampls.bicep) and storage through private endpoints.
resource functionSubnet 'Microsoft.Network/virtualNetworks/subnets@2023-11-01' = {
  parent: vnet
  name: functionSubnetName
  properties: {
    addressPrefix: functionSubnetPrefix
    networkSecurityGroup: {
      id: nsg.id
    }
    delegations: [
      {
        name: 'Microsoft.App.environments'
        properties: {
          serviceName: 'Microsoft.App/environments'
        }
      }
    ]
    defaultOutboundAccess: false
  }
}

// Host storage: function host files, the deployment package and the queue the
// Event Grid events land in. Reached through private endpoints; the firewall
// default is Deny and only trusted Azure services (Event Grid delivering to
// the queue with its managed identity) bypass it.
resource hostStorage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: hostStorageAccountName
  location: location
  tags: tags
  kind: 'StorageV2'
  sku: {
    name: 'Standard_LRS'
  }
  properties: {
    accessTier: 'Hot'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    defaultToOAuthAuthentication: true
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'AzureServices'
    }
  }
}

resource hostBlobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: hostStorage
  name: 'default'
  properties: {
    deleteRetentionPolicy: {
      enabled: true
      days: 7
    }
    containerDeleteRetentionPolicy: {
      enabled: true
      days: 7
    }
  }
}

resource deployContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: hostBlobService
  name: deployContainerName
  properties: {
    publicAccess: 'None'
  }
}

resource hostQueueService 'Microsoft.Storage/storageAccounts/queueServices@2023-05-01' = {
  parent: hostStorage
  name: 'default'
}

resource eventQueue 'Microsoft.Storage/storageAccounts/queueServices/queues@2023-05-01' = {
  parent: hostQueueService
  name: queueName
}

module blobEndpoint 'storage-private-endpoint.bicep' = {
  name: 'pe-${hostStorageAccountName}-blob'
  params: {
    name: 'pe-${hostStorageAccountName}-blob'
    location: location
    tags: tags
    storageAccountId: hostStorage.id
    groupId: 'blob'
    subnetId: privateEndpointSubnetId
    privateDnsZoneId: blobPrivateDnsZoneId
  }
}

module queueEndpoint 'storage-private-endpoint.bicep' = {
  name: 'pe-${hostStorageAccountName}-queue'
  params: {
    name: 'pe-${hostStorageAccountName}-queue'
    location: location
    tags: tags
    storageAccountId: hostStorage.id
    groupId: 'queue'
    subnetId: privateEndpointSubnetId
    privateDnsZoneId: queuePrivateDnsZoneId
  }
  dependsOn: [
    blobEndpoint
  ]
}

module tableEndpoint 'storage-private-endpoint.bicep' = {
  name: 'pe-${hostStorageAccountName}-table'
  params: {
    name: 'pe-${hostStorageAccountName}-table'
    location: location
    tags: tags
    storageAccountId: hostStorage.id
    groupId: 'table'
    subnetId: privateEndpointSubnetId
    privateDnsZoneId: tablePrivateDnsZoneId
  }
  dependsOn: [
    queueEndpoint
  ]
}

resource plan 'Microsoft.Web/serverfarms@2024-04-01' = {
  name: 'asp-llmreq-${uniqueSuffix}'
  location: location
  tags: tags
  kind: 'functionapp'
  sku: {
    name: 'FC1'
    tier: 'FlexConsumption'
  }
  properties: {
    reserved: true
  }
}

resource functionApp 'Microsoft.Web/sites@2024-04-01' = {
  name: functionAppName
  location: location
  tags: tags
  kind: 'functionapp,linux'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    virtualNetworkSubnetId: functionSubnet.id
    functionAppConfig: {
      deployment: {
        storage: {
          type: 'blobContainer'
          value: '${hostStorage.properties.primaryEndpoints.blob}${deployContainerName}'
          authentication: {
            type: 'SystemAssignedIdentity'
          }
        }
      }
      scaleAndConcurrency: {
        maximumInstanceCount: maximumInstanceCount
        instanceMemoryMB: 2048
      }
      runtime: {
        name: 'python'
        version: pythonVersion
      }
    }
    siteConfig: {
      appSettings: [
        { name: 'AzureWebJobsStorage__credential', value: 'managedidentity' }
        { name: 'AzureWebJobsStorage__blobServiceUri', value: hostStorage.properties.primaryEndpoints.blob }
        { name: 'AzureWebJobsStorage__queueServiceUri', value: hostStorage.properties.primaryEndpoints.queue }
        { name: 'AzureWebJobsStorage__tableServiceUri', value: hostStorage.properties.primaryEndpoints.table }
        { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: applicationInsightsConnectionString }
        { name: 'APPLICATIONINSIGHTS_AUTHENTICATION_STRING', value: 'Authorization=AAD' }
        { name: 'EVENT_QUEUE_NAME', value: queueName }
        { name: 'DATA_STORAGE_ACCOUNT', value: dataStorageAccountName }
        { name: 'DATA_CONTAINER', value: dataContainerName }
        { name: 'DCE_LOGS_INGESTION_ENDPOINT', value: dceLogsIngestionEndpoint }
        { name: 'DCR_IMMUTABLE_ID', value: dcrImmutableId }
        { name: 'DCR_STREAM_NAME', value: streamName }
      ]
    }
  }
  dependsOn: [
    tableEndpoint
    deployContainer
    eventQueue
  ]
}

// --- Role assignments for the function identity ---

resource hostBlobOwner 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: hostStorage
  name: guid(hostStorage.id, functionApp.id, azureRoles.StorageBlobDataOwner)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', azureRoles.StorageBlobDataOwner)
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource hostQueueContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: hostStorage
  name: guid(hostStorage.id, functionApp.id, azureRoles.StorageQueueDataContributor)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', azureRoles.StorageQueueDataContributor)
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource hostTableContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: hostStorage
  name: guid(hostStorage.id, functionApp.id, azureRoles.StorageTableDataContributor)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', azureRoles.StorageTableDataContributor)
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource dataStorage 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: dataStorageAccountName
}

resource dataReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: dataStorage
  name: guid(dataStorage.id, functionApp.id, azureRoles.StorageBlobDataReader)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', azureRoles.StorageBlobDataReader)
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
    description: 'Read request bodies to load them into Log Analytics'
  }
}

resource dcr 'Microsoft.Insights/dataCollectionRules@2022-06-01' existing = {
  name: dcrName
}

resource dcrPublisher 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: dcr
  name: guid(dcr.id, functionApp.id, azureRoles.MonitoringMetricsPublisher)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', azureRoles.MonitoringMetricsPublisher)
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
    description: 'Send request body rows to the data collection rule'
  }
}

resource applicationInsights 'Microsoft.Insights/components@2020-02-02' existing = {
  name: applicationInsightsName
}

resource aiPublisher 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: applicationInsights
  name: guid(applicationInsights.id, functionApp.id, azureRoles.MonitoringMetricsPublisher)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', azureRoles.MonitoringMetricsPublisher)
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
    description: 'Function logs to Application Insights (Entra auth only)'
  }
}

// --- Event Grid: BlobCreated on the data account -> queue on the host account ---

resource dataTopic 'Microsoft.EventGrid/systemTopics@2022-06-15' = {
  name: 'evgt-llmreq-${uniqueSuffix}'
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    source: dataStorage.id
    topicType: 'Microsoft.Storage.StorageAccounts'
  }
}

resource topicQueueSender 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: hostStorage
  name: guid(hostStorage.id, dataTopic.id, azureRoles.StorageQueueDataMessageSender)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', azureRoles.StorageQueueDataMessageSender)
    principalId: dataTopic.identity.principalId
    principalType: 'ServicePrincipal'
    description: 'Event Grid delivers BlobCreated events to the loader queue'
  }
}

resource blobCreatedSubscription 'Microsoft.EventGrid/systemTopics/eventSubscriptions@2022-06-15' = {
  parent: dataTopic
  name: 'blob-created-to-queue'
  properties: {
    eventDeliverySchema: 'EventGridSchema'
    deliveryWithResourceIdentity: {
      identity: {
        type: 'SystemAssigned'
      }
      destination: {
        endpointType: 'StorageQueue'
        properties: {
          resourceId: hostStorage.id
          queueName: eventQueue.name
          queueMessageTimeToLiveInSeconds: 604800
        }
      }
    }
    filter: {
      includedEventTypes: [
        'Microsoft.Storage.BlobCreated'
      ]
      subjectBeginsWith: '/blobServices/default/containers/${dataContainerName}/'
    }
    retryPolicy: {
      maxDeliveryAttempts: 30
      eventTimeToLiveInMinutes: 1440
    }
  }
  dependsOn: [
    topicQueueSender
  ]
}

output functionAppName string = functionApp.name
output functionPrincipalId string = functionApp.identity.principalId
output hostStorageName string = hostStorage.name
