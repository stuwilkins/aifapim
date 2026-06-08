@description('Azure region for all resources.')
param location string

@description('Region label used in resource naming (e.g. eus, eus2).')
param regionLabel string

@description('Tags to apply to all resources.')
param tags object = {}

@description('Subnet resource ID where a private endpoint will be created. Leave empty to skip private endpoint creation.')
param subnetId string = ''

@description('Private DNS zone resource IDs to register the private endpoint into. Required when subnetId is provided. AI Services accounts need three zones: privatelink.openai.azure.com, privatelink.cognitiveservices.azure.com, privatelink.services.ai.azure.com.')
param privateDnsZoneIds array = []

@description('Model deployments to create on the Azure AI Foundry account.')
param modelDeployments array = []

@description('Default TPM capacity for OpenAI (DataZoneStandard) deployments. Overridable per-entry with `capacity`.')
param openaiCapacity int

@description('Default TPM capacity for Anthropic (GlobalStandard) deployments. Overridable per-entry with `capacity`.')
param anthropicCapacity int

@description('Industry for Anthropic model provider data.')
param anthropicIndustry string = ''

@description('Country code for Anthropic model provider data (ISO 3166-1 alpha-2).')
param anthropicCountryCode string = ''

@description('Organization name for Anthropic model provider data.')
param anthropicOrganizationName string = ''

@description('Unique suffix for resource naming, passed from the parent deployment.')
param uniqueSuffix string

@description('Resource ID of a Log Analytics workspace to which this AI Foundry account should send diagnostic logs. Leave empty to disable diagnostics.')
param logAnalyticsWorkspaceId string = ''

@description('Enable the verbose RequestResponse diagnostic category (full request/response bodies). Off by default; bodies can contain PII and add cost.')
param diagnosticsEnableRequestResponse bool = false

@description('Enable the Trace diagnostic category (internal traces). Off by default.')
param diagnosticsEnableTrace bool = false

var createPrivateEndpoint = !empty(subnetId)

// Azure AI Foundry (AI Services) resource
resource aif 'Microsoft.CognitiveServices/accounts@2024-10-01' = {
  name: 'aif-${regionLabel}-${uniqueSuffix}'
  location: location
  tags: tags
  kind: 'AIServices'
  sku: {
    name: 'S0'
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    customSubDomainName: 'aif-${regionLabel}-${uniqueSuffix}'
    publicNetworkAccess: createPrivateEndpoint ? 'Disabled' : 'Enabled'
    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'AzureServices'
    }
  }
}

// Private Endpoint into the VNet
resource privateEndpoint 'Microsoft.Network/privateEndpoints@2023-11-01' = if (createPrivateEndpoint) {
  name: 'pe-${aif.name}'
  location: location
  tags: tags
  properties: {
    subnet: {
      id: subnetId
    }
    privateLinkServiceConnections: [
      {
        name: 'plsc-${aif.name}'
        properties: {
          privateLinkServiceId: aif.id
          groupIds: [
            'account'
          ]
        }
      }
    ]
  }
}

// Register the private endpoint with all required private DNS zones.
resource privateDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-11-01' = if (createPrivateEndpoint && !empty(privateDnsZoneIds)) {
  parent: privateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [for (zid, idx) in privateDnsZoneIds: {
      name: 'config-${idx}'
      properties: {
        privateDnsZoneId: zid
      }
    }]
  }
}

// Model deployments on the Azure AI Foundry account.
// Done from a sub-module so the parent account deployment fully completes (avoids
// AccountProvisioningStateInvalid: account in state 'Accepted' race condition).
module aifDeployments 'aif-deployments.bicep' = {
  name: 'aif-deps-${regionLabel}-${uniqueSuffix}'
  params: {
    accountName: aif.name
    modelDeployments: modelDeployments
    openaiCapacity: openaiCapacity
    anthropicCapacity: anthropicCapacity
    anthropicIndustry: anthropicIndustry
    anthropicCountryCode: anthropicCountryCode
    anthropicOrganizationName: anthropicOrganizationName
  }
  dependsOn: [
    privateDnsZoneGroup
  ]
}

// Diagnostic settings on the AI Foundry account. Sends Audit and per-request
// AzureOpenAI usage logs (plus all metrics) to the shared Log Analytics
// workspace by default. RequestResponse (full bodies) and Trace are opt-in
// because of size, cost, and potential PII exposure.
// Categories per https://learn.microsoft.com/azure/azure-monitor/reference/supported-logs/microsoft-cognitiveservices-accounts-logs
resource aifDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = if (!empty(logAnalyticsWorkspaceId)) {
  name: 'aif-${regionLabel}-diagnostics'
  scope: aif
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logAnalyticsDestinationType: 'Dedicated'
    logs: [
      {
        category: 'Audit'
        enabled: true
      }
      {
        category: 'AzureOpenAIRequestUsage'
        enabled: true
      }
      {
        category: 'RequestResponse'
        enabled: diagnosticsEnableRequestResponse
      }
      {
        category: 'Trace'
        enabled: diagnosticsEnableTrace
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

output openAiName string = aif.name
output openAiEndpoint string = aif.properties.endpoint
output openAiId string = aif.id
output resourceGroupName string = resourceGroup().name
