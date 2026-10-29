@description('Unique suffix used in resource names (same suffix as the rest of the stack).')
param uniqueSuffix string

param location string

param tags object = {}

@description('Name of the existing virtual network (in this resource group) that holds the function subnet and the private endpoints.')
param vnetName string

@description('Resource ID of that virtual network, for the private DNS zone links.')
param vnetId string

@description('Subnet resource ID for the private endpoints.')
param privateEndpointSubnetId string

@description('CIDR of the new function subnet (at least a /27).')
param functionSubnetPrefix string

@description('Name of the data storage account for the request bodies.')
param dataStorageAccountName string

@description('Name of the container for the request bodies.')
param containerName string

@description('Object ID of the Entra group that may read the request bodies. Leave empty to skip the assignments.')
param readerGroupObjectId string = ''

@description('Public IPv4 addresses or CIDR ranges allowed to read the blobs. Empty means private endpoint access only.')
param readerIps array = []

@description('Principal ID of the API Management system-assigned identity, which writes the request bodies.')
param apimPrincipalId string

@description('Resource ID of the main Log Analytics workspace that receives blob audit logs.')
param auditWorkspaceId string

@description('Name of the existing Application Insights component and its connection string, for the loader logs.')
param applicationInsightsName string
param applicationInsightsConnectionString string

@description('Maximum number of function instances.')
param maximumInstanceCount int = 4

param immutabilityPeriodDays int = 146000
param manageImmutabilityPolicy bool = true
param coldAfterDays int = 7
param archiveAfterDays int = 90

var azureRoles = loadJsonContent('../azure_roles.json')
var storageSuffix = environment().suffixes.storage

module blobZone 'private-dns-zone.bicep' = {
  name: 'privatelink-blob'
  params: {
    zoneName: 'privatelink.blob.${storageSuffix}'
    vnetId: vnetId
    tags: tags
  }
}

module queueZone 'private-dns-zone.bicep' = {
  name: 'privatelink-queue'
  params: {
    zoneName: 'privatelink.queue.${storageSuffix}'
    vnetId: vnetId
    tags: tags
  }
}

module tableZone 'private-dns-zone.bicep' = {
  name: 'privatelink-table'
  params: {
    zoneName: 'privatelink.table.${storageSuffix}'
    vnetId: vnetId
    tags: tags
  }
}

module workspace 'request-log-workspace.bicep' = {
  name: 'request-log-workspace'
  params: {
    workspaceName: 'law-prompts-${uniqueSuffix}'
    uniqueSuffix: uniqueSuffix
    location: location
    tags: tags
    readerGroupObjectId: readerGroupObjectId
  }
}

module storage 'request-log-storage.bicep' = {
  name: 'request-log-storage'
  params: {
    storageAccountName: dataStorageAccountName
    containerName: containerName
    location: location
    tags: tags
    subnetId: privateEndpointSubnetId
    blobPrivateDnsZoneId: blobZone.outputs.zoneId
    readerIps: readerIps
    immutabilityPeriodDays: immutabilityPeriodDays
    manageImmutabilityPolicy: manageImmutabilityPolicy
    coldAfterDays: coldAfterDays
    archiveAfterDays: archiveAfterDays
    auditWorkspaceId: auditWorkspaceId
  }
}

module loader 'request-log-function.bicep' = {
  name: 'request-log-function'
  params: {
    uniqueSuffix: uniqueSuffix
    location: location
    tags: tags
    vnetName: vnetName
    functionSubnetPrefix: functionSubnetPrefix
    privateEndpointSubnetId: privateEndpointSubnetId
    blobPrivateDnsZoneId: blobZone.outputs.zoneId
    queuePrivateDnsZoneId: queueZone.outputs.zoneId
    tablePrivateDnsZoneId: tableZone.outputs.zoneId
    hostStorageAccountName: 'stllmfn${uniqueSuffix}'
    dataStorageAccountName: storage.outputs.name
    dataContainerName: storage.outputs.containerName
    dceLogsIngestionEndpoint: workspace.outputs.dceLogsIngestionEndpoint
    dcrName: workspace.outputs.dcrName
    dcrImmutableId: workspace.outputs.dcrImmutableId
    streamName: workspace.outputs.streamName
    applicationInsightsName: applicationInsightsName
    applicationInsightsConnectionString: applicationInsightsConnectionString
    maximumInstanceCount: maximumInstanceCount
  }
}

resource dataStorage 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: dataStorageAccountName
  dependsOn: [
    storage
  ]
}

// The gateway writes one blob per request. The condition removes the read,
// delete and move data actions from the built-in role, so the gateway identity,
// which anyone who can edit an API Management policy can use, cannot read back
// or list stored prompts. WORM separately stops any change or delete once a blob
// is written. One gap remains: the role still carries the control-plane
// generateUserDelegationKey action, which a condition cannot restrict.
var writeOnlyCondition = '((!(ActionMatches{\'Microsoft.Storage/storageAccounts/blobServices/containers/blobs/read\'}) AND !(ActionMatches{\'Microsoft.Storage/storageAccounts/blobServices/containers/blobs/delete\'}) AND !(ActionMatches{\'Microsoft.Storage/storageAccounts/blobServices/containers/blobs/move/action\'})))'

resource apimBlobWriter 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: dataStorage
  name: guid(dataStorage.id, apimPrincipalId, azureRoles.StorageBlobDataContributor)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', azureRoles.StorageBlobDataContributor)
    principalId: apimPrincipalId
    principalType: 'ServicePrincipal'
    description: 'API Management writes request bodies (write only)'
    condition: writeOnlyCondition
    conditionVersion: '2.0'
  }
}

resource readerBlobAccess 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(readerGroupObjectId)) {
  scope: dataStorage
  name: guid(dataStorage.id, readerGroupObjectId, azureRoles.StorageBlobDataReader)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', azureRoles.StorageBlobDataReader)
    principalId: readerGroupObjectId
    principalType: 'Group'
    description: 'Read the stored LLM request bodies'
  }
}

output functionAppName string = loader.outputs.functionAppName
output functionPrincipalId string = loader.outputs.functionPrincipalId
output dataStorageAccountName string = storage.outputs.name
output containerName string = storage.outputs.containerName
output workspaceName string = workspace.outputs.workspaceName
output natPublicIp string = loader.outputs.natPublicIp
