@description('Name of the Log Analytics workspace that holds the searchable copy of the request bodies.')
param workspaceName string

@description('Unique suffix used in the names of the collection endpoint and rule.')
param uniqueSuffix string

param location string

param tags object = {}

@description('Days the table keeps data available for fast interactive queries.')
@minValue(4)
@maxValue(730)
param interactiveRetentionDays int = 90

@description('Total days the table keeps data (interactive plus long-term retention). 4383 days (12 years) is the Log Analytics maximum.')
@minValue(4)
@maxValue(4383)
param totalRetentionDays int = 4383

@description('Object ID of the Entra group that may query the workspace (Log Analytics Reader). Leave empty to skip the assignment.')
param readerGroupObjectId string = ''

var tableName = 'LlmRequestBody_CL'
var streamName = 'Custom-${tableName}'
var logAnalyticsReaderRoleId = '73c42c96-874c-492b-b04d-ab87d138a893'

// One row per chunk of one request body. A chunk is at most 60,000 bytes of
// UTF-8 because the ingestion API truncates field values at 64 KB.
var columns = [
  { name: 'TimeGenerated', type: 'datetime' }
  { name: 'RowId', type: 'string' }
  { name: 'CorrelationId', type: 'string' }
  { name: 'Seq', type: 'int' }
  { name: 'SeqCount', type: 'int' }
  { name: 'SubscriptionName', type: 'string' }
  { name: 'Api', type: 'string' }
  { name: 'Model', type: 'string' }
  { name: 'IsStream', type: 'string' }
  { name: 'ContentType', type: 'string' }
  { name: 'RequestBytes', type: 'long' }
  { name: 'BlobPath', type: 'string' }
  { name: 'Truncated', type: 'boolean' }
  { name: 'Chunk', type: 'string' }
]

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: workspaceName
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: interactiveRetentionDays
    features: {
      disableLocalAuth: true
      enableLogAccessUsingOnlyResourcePermissions: true
    }
  }
}

resource table 'Microsoft.OperationalInsights/workspaces/tables@2022-10-01' = {
  parent: workspace
  name: tableName
  properties: {
    plan: 'Analytics'
    retentionInDays: interactiveRetentionDays
    totalRetentionInDays: totalRetentionDays
    schema: {
      name: tableName
      columns: columns
    }
  }
}

resource dce 'Microsoft.Insights/dataCollectionEndpoints@2022-06-01' = {
  name: 'dce-llmreq-${uniqueSuffix}'
  location: location
  tags: tags
  properties: {
    networkAcls: {
      publicNetworkAccess: 'Enabled'
    }
  }
}

resource dcr 'Microsoft.Insights/dataCollectionRules@2022-06-01' = {
  name: 'dcr-llmreq-${uniqueSuffix}'
  location: location
  tags: tags
  properties: {
    dataCollectionEndpointId: dce.id
    streamDeclarations: {
      '${streamName}': {
        columns: columns
      }
    }
    destinations: {
      logAnalytics: [
        {
          name: 'la-dest'
          workspaceResourceId: workspace.id
        }
      ]
    }
    dataFlows: [
      {
        streams: [
          streamName
        ]
        destinations: [
          'la-dest'
        ]
        transformKql: 'source'
        outputStream: streamName
      }
    ]
  }
  dependsOn: [
    table
  ]
}

resource readerAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(readerGroupObjectId)) {
  scope: workspace
  name: guid(workspace.id, readerGroupObjectId, logAnalyticsReaderRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', logAnalyticsReaderRoleId)
    principalId: readerGroupObjectId
    principalType: 'Group'
    description: 'Query access to the stored LLM request bodies'
  }
}

output workspaceId string = workspace.id
output workspaceName string = workspace.name
output dceId string = dce.id
output dceName string = dce.name
output dceLogsIngestionEndpoint string = dce.properties.logsIngestion.endpoint
output dcrName string = dcr.name
output dcrImmutableId string = dcr.properties.immutableId
output streamName string = streamName
