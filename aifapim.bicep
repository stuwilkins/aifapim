@description('The location into which regionally scoped resources should be deployed. Note that Front Door is a global resource.')
param location string = resourceGroup().location

@description('Tags to apply to all resources.')
param tags object = {
  'managed-by': 'bicep'
  project: 'aifapim'
  repository: 'NSLS2/aifapim'
}

@description('The SKU of the API Management instance.')
@allowed([
  'Premium'
  'Developer'
  'BasicV2'
  'StandardV2'
])
param apiManagementSku string = 'Developer'

@description('The IP address prefix (CIDR range) to use when deploying the API Management subnet within the virtual network.')
param apiManagementSubnetIPPrefix string

@description('API Management Subnet Name')
param apiManagementSubnetName string = 'apim'

@description('The name of the API publisher. This information is used by API Management.')
param apiManagementPublisherName string

@description('The email address of the API publisher. This information is used by API Management.')
param apiManagementPublisherEmail string

@description('Disable the APIM developer portal entirely.')
param disableDeveloperPortal bool = true

@description('Enable the verbose RequestResponse diagnostic category on each AI Foundry account (full request/response bodies). Off by default; bodies can contain PII and add ingest cost.')
param aifDiagnosticsEnableRequestResponse bool = false

@description('Enable the Trace diagnostic category on each AI Foundry account. Off by default.')
param aifDiagnosticsEnableTrace bool = false

@description('Display name for the alert email receiver.')
param alertEmailName string

@description('Email address for the alert action group.')
param alertEmailAddress string

@description('Custom gateway (proxy) hostname (e.g., api.example.com). Leave empty to skip.')
param apimGatewayHostName string = ''

@description('Key Vault secret name for the gateway TLS certificate.')
param gatewayKeyVaultSecretName string = ''

@description('Custom developer portal hostname (e.g., portal.example.com). Leave empty to skip.')
param apimPortalHostName string = ''

@description('Name of the Key Vault containing the TLS certificates for custom domains.')
param keyVaultName string = ''

@description('Resource group of the Key Vault. Defaults to the current resource group.')
param keyVaultResourceGroup string = ''

@description('Key Vault secret name for the developer portal TLS certificate.')
param portalKeyVaultSecretName string = ''

@description('PEM-encoded intermediate CA certificate to install in the APIM CertificateAuthority store. Leave empty to skip. Typically populated in the bicepparam file via loadTextContent(\'resources/<your-intermediate>.pem\').')
param intermediateCaCert string = ''

@description('PEM-encoded root CA certificate to install in the APIM Root store. Leave empty to skip. Typically populated in the bicepparam file via loadTextContent(\'resources/<your-root>.pem\').')
param rootCaCert string = ''

@description('Regions to deploy a virtual network and Azure OpenAI account into. Each entry must have a unique label and non-overlapping vnetAddressPrefix.')
param regions array

@description('Industry for Anthropic model provider data.')
param anthropicIndustry string

@description('Country code for Anthropic model provider data (ISO 3166-1 alpha-2).')
param anthropicCountryCode string

@description('Organization name for Anthropic model provider data.')
param anthropicOrganizationName string

@description('Model deployments to create on each Azure OpenAI account.')
param modelDeployments array

@description('Default TPM capacity for OpenAI (DataZoneStandard) deployments. Overridable per-entry with `capacity`.')
param openaiCapacity int

@description('Default TPM capacity for Anthropic (GlobalStandard) deployments. Overridable per-entry with `capacity`.')
param anthropicCapacity int

@description('Per-request backend forward-request timeout in seconds applied to all three LLM APIs. Capped at 240 (classic-tier APIM limit).')
@minValue(1)
@maxValue(240)
param backendTimeoutSeconds int = 240

@description('Inbound IP allow-list applied to all three APIM APIs. Each entry is either a single IPv4 address (e.g., "192.0.2.1") or a CIDR range (e.g., "10.0.0.0/16"). CIDR entries are expanded via parseCidr().firstUsable/lastUsable, so the network and broadcast addresses are excluded from the allow-list.')
@minLength(1)
param allowedClientIps array

@description('APIM product name (and App Insights custom-metric namespace). All three APIs are grouped under this product, and the <llm-emit-token-metric> / <emit-metric> policies emit under this namespace. Must be a valid APIM resource name (lowercase alphanumerics + hyphens).')
param apimProductName string = 'aifapim'

@description('Display name for the APIM product (shown in the APIM portal and developer portal).')
param apimProductDisplayName string = 'AIFAPIM'

@description('Description for the APIM product.')
param apimProductDescription string = 'AI Foundry APIM product. Groups the Azure OpenAI, Azure OpenAI v1 Messages, and Anthropic APIs.'

@description('Curated model catalog JSON array (id/name/provider/context/output per chat-LLM model). Populated in the bicepparam file via loadTextContent(\'./model-catalog.json\'). Baked into the GET /catalog return-response policy at deploy time.')
param catalogJson string

// Render the IP allow-list entries as APIM ip-filter child elements. CIDR
// entries become <address-range from=... to=.../> using parseCidr's
// firstUsable/lastUsable; bare addresses become <address>...</address>.
var allowedIpsXml = join(map(allowedClientIps, ip => contains(ip, '/')
  ? '<address-range from="${parseCidr(ip).firstUsable}" to="${parseCidr(ip).lastUsable}" />'
  : '<address>${ip}</address>'
), '\n              ')

// The APIM AOAI policy is always the multi-region variant.
// Policies and API definition are loaded from the local repository so deployments do not depend on external URLs.
// Substitutions applied to each policy XML:
//   __BACKEND_TIMEOUT__    -> backendTimeoutSeconds (forward-request timeout)
//   __ALLOWED_CLIENT_IPS__ -> allowedIpsXml (ip-filter allow-list built from allowedClientIps)
//   __METRIC_NAMESPACE__   -> apimProductName (App Insights custom-metric namespace)
var openApiXml = replace(replace(replace(loadTextContent('apim_policies/AOAI_Policy-Managed_Identity_with_Retry_MultiRegion.xml'), '__BACKEND_TIMEOUT__', string(backendTimeoutSeconds)), '__ALLOWED_CLIENT_IPS__', allowedIpsXml), '__METRIC_NAMESPACE__', apimProductName)

// Anthropic API policy (multi-region retry variant).
var anthropicApiXml = replace(replace(replace(loadTextContent('apim_policies/Anthropic_Policy-Managed_Identity_with_Retry_MultiRegion.xml'), '__BACKEND_TIMEOUT__', string(backendTimeoutSeconds)), '__ALLOWED_CLIENT_IPS__', allowedIpsXml), '__METRIC_NAMESPACE__', apimProductName)

// OpenAI v1 Messages API policy (multi-region retry variant).
var openaiV1MessagesApiXml = replace(replace(replace(loadTextContent('apim_policies/OpenAIv1Messages_Policy-Managed_Identity_with_Retry_MultiRegion.xml'), '__BACKEND_TIMEOUT__', string(backendTimeoutSeconds)), '__ALLOWED_CLIENT_IPS__', allowedIpsXml), '__METRIC_NAMESPACE__', apimProductName)

// Catalog API policy: static return-response, no backend.
// Sentinels replaced: __ALLOWED_CLIENT_IPS__ (IP filter) and __CATALOG_JSON__ (model list body).
var catalogApiXml = replace(replace(loadTextContent('apim_policies/Catalog_Policy.xml'), '__ALLOWED_CLIENT_IPS__', allowedIpsXml), '__CATALOG_JSON__', catalogJson)

// Azure OpenAI data-plane inference spec is pinned locally so deployments are
// deterministic and do not depend on github.com being reachable at deploy time.
// Source: https://github.com/Azure/azure-rest-api-specs/blob/main/specification/cognitiveservices/data-plane/AzureOpenAI/inference/stable/2024-10-21/inference.yaml
// Local copy is augmented with /models and /models/{model_id} listing operations.
var openApiSpec = loadTextContent('api_definitions/AzureOpenAI_inference_2024-10-21.yaml')

var apiNetwork = 'External'

var apiManagementSkuCount = 1

var openaiApiName = 'azure-openai-service-api'
var openaiApiPath = ''
var openaiApiDisplayName = 'Azure OpenAI Service API'

var openaiV1MessagesApiName = 'azure-openai-v1-messages-api'
var openaiV1MessagesApiPath = 'openai'
var openaiV1MessagesApiDisplayName = 'Azure OpenAI v1 Messages API'

var anthropicApiName = 'anthropic-service-api'
var anthropicApiPath = 'anthropic'
var anthropicApiDisplayName = 'Anthropic Service API'

var catalogApiName = 'catalog-api'
var catalogApiPath = 'catalog'
var catalogApiDisplayName = 'AIFAPIM Model Catalog API'
var catalogProductName = 'aifapim-catalog'
var catalogProductDisplayName = 'AIFAPIM Catalog'
var catalogProductDescription = 'Read-only product scoped to GET /catalog only. Used by the ansible catalog poller to discover models and token windows. Keys issued under this product cannot call inference endpoints.'

var unique = uniqueString(resourceGroup().id, subscription().id)
var apiManagementServiceName = 'apim-${unique}'
var logAnalyticsName = 'law-${unique}'
var eventHubName = 'eh-${unique}'
var eventHubNamespaceName = 'ehn-${unique}'
var applicationInsightsName = 'appIn-${unique}'

var azureRoles = loadJsonContent('azure_roles.json')

// Virtual Network (one per region)

module vnet 'modules/vnet.bicep' = [for region in regions: {
  name: 'net-${region.label}-${unique}'
  params: {
    location: region.name
    name: 'net-${region.label}-${unique}'
    addressPrefixes: [
      region.vnetAddressPrefix
    ]
    subnets: [
      {
        name: 'openai'
        addressPrefix: region.openAiSubnetPrefix
      }
    ]
    tags: tags
  }
}]

// Bidirectional VNet peering between the two regional vnets (global peering).
resource peering0to1 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2023-11-01' = {
  name: '${vnet[0].name}/peer-${regions[0].label}-to-${regions[1].label}'
  properties: {
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: false
    allowGatewayTransit: false
    useRemoteGateways: false
    remoteVirtualNetwork: {
      id: vnet[1].outputs.vnetId
    }
  }
}

resource peering1to0 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2023-11-01' = {
  name: '${vnet[1].name}/peer-${regions[1].label}-to-${regions[0].label}'
  properties: {
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: false
    allowGatewayTransit: false
    useRemoteGateways: false
    remoteVirtualNetwork: {
      id: vnet[0].outputs.vnetId
    }
  }
}

// Shared private DNS zones for Azure AI Services / OpenAI private endpoints (global).
// AI Services accounts (kind=AIServices) expose three FQDNs and need all three zones,
// each linked to every vnet that needs to resolve them.
var aiPrivateDnsZoneNames = [
  'privatelink.openai.azure.com'
  'privatelink.cognitiveservices.azure.com'
  'privatelink.services.ai.azure.com'
]

module aiPrivateDnsZones 'modules/private-dns-zone.bicep' = [for zoneName in aiPrivateDnsZoneNames: {
  name: replace(zoneName, '.', '-')
  params: {
    zoneName: zoneName
    vnetId: vnet[0].outputs.vnetId
    tags: tags
  }
}]

// Additional vnet links for the remaining regions (skip index 0; already linked by the zone module).
resource aiPrivateDnsZoneRefs 'Microsoft.Network/privateDnsZones@2020-06-01' existing = [for zoneName in aiPrivateDnsZoneNames: {
  name: zoneName
}]

// One vnet link per (zone, extra-region) pair using a flattened index.
var extraRegionCount = length(regions) - 1
var zoneCount = length(aiPrivateDnsZoneNames)
var zoneVnetLinkPairs = [for i in range(0, zoneCount * extraRegionCount): {
  zoneIndex: i / extraRegionCount
  regionIndex: (i % extraRegionCount) + 1
}]

resource zoneExtraVnetLinks 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = [for pair in zoneVnetLinkPairs: {
  parent: aiPrivateDnsZoneRefs[pair.zoneIndex]
  name: 'vnet-link-${regions[pair.regionIndex].label}'
  location: 'global'
  tags: tags
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: vnet[pair.regionIndex].outputs.vnetId
    }
  }
  dependsOn: [
    aiPrivateDnsZones
  ]
}]

// AI Foundry (one per region)

module aif 'modules/aif.bicep' = [for (region, i) in regions: {
  name: 'openai-${region.label}'
  params: {
    location: region.name
    regionLabel: region.label
    uniqueSuffix: unique
    tags: tags
    subnetId: vnet[i].outputs.subnetIds.openai
    privateDnsZoneIds: [for z in range(0, length(aiPrivateDnsZoneNames)): aiPrivateDnsZones[z].outputs.zoneId]
    modelDeployments: modelDeployments[i]
    openaiCapacity: openaiCapacity
    anthropicCapacity: anthropicCapacity
    anthropicIndustry: anthropicIndustry
    anthropicCountryCode: anthropicCountryCode
    anthropicOrganizationName: anthropicOrganizationName
    logAnalyticsWorkspaceId: logAnalyticsWorkspace.outputs.id
    diagnosticsEnableRequestResponse: aifDiagnosticsEnableRequestResponse
    diagnosticsEnableTrace: aifDiagnosticsEnableTrace
  }
}]

// Having now stood up the AI Foundry, now set parameters for the gateway

// Primary backend region: regions[1] (eastus2). Retry/failover policies in
// apim_policies/* fall back to regions[0] (eastus) on errors.
var apiServiceNamePrimary string = aif[1].outputs.openAiName
var apiServiceNameSecondary string = aif[0].outputs.openAiName
var apiServiceUrlPrimary = 'https://${apiServiceNamePrimary}.openai.azure.com/openai'
var apiServiceUrlSecondary = 'https://${apiServiceNameSecondary}.openai.azure.com/openai'
var anthropicServiceUrlPrimary = 'https://${apiServiceNamePrimary}.services.ai.azure.com/anthropic'
var anthropicServiceUrlSecondary = 'https://${apiServiceNameSecondary}.services.ai.azure.com/anthropic'

module logAnalyticsWorkspace 'modules/log-analytics-workspace.bicep' = {
  name: 'log-analytics-workspace'
  params: {
    location: location
    logAnalyticsName: logAnalyticsName
    tags: tags
  }
}

module eventHub 'modules/event-hub.bicep' = {
  name: 'event-hub'
  params: {
    location: location
    eventHubNamespaceName: eventHubNamespaceName
    eventHubName: eventHubName
    tags: tags
  }
}

module applicationInsights 'modules/app-insights.bicep' = {
  name: 'application-insights'
  params: {
    location: location
    workspaceName: logAnalyticsName
    applicationInsightsName: applicationInsightsName
    uniqueSuffix: unique
    alertEmailName: alertEmailName
    alertEmailAddress: alertEmailAddress
    tags: tags
  }
  dependsOn: [
    logAnalyticsWorkspace
  ]
}

// LLM-aware latency alerts (scheduled-query rules on ApiManagementGatewayLogs).
// Replaces the prior noisy metricAlert on App Insights requests/duration.
module llmLatencyAlerts 'modules/llm-latency-alerts.bicep' = {
  name: 'llm-latency-alerts'
  params: {
    location: location
    workspaceResourceId: logAnalyticsWorkspace.outputs.id
    actionGroupId: applicationInsights.outputs.actionGroupId
    uniqueSuffix: unique
    tags: tags
  }
}

module network 'modules/network.bicep' = {
  name: 'network'
  params: {
    vnetName: 'net-${regions[0].label}-${unique}'
    uniqueSuffix: unique
    location: location
    apiManagementSubnetName: apiManagementSubnetName
    apiManagementSubnetIPPrefix: apiManagementSubnetIPPrefix
    tags: tags
  }
}

// User-assigned managed identity for APIM to access Key Vault at creation time
resource apimIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = if (!empty(keyVaultName)) {
  name: 'id-${apiManagementServiceName}'
  location: location
  tags: tags
}

// Grant the user-assigned identity Key Vault Secrets User role BEFORE APIM deployment
module kvAccess 'modules/keyvault-role.bicep' = if (!empty(keyVaultName)) {
  name: 'kvSecretUserForApim'
  scope: resourceGroup(keyVaultResourceGroup)
  params: {
    keyVaultName: keyVaultName
    roleName: guid(subscription().id, keyVaultName, apiManagementServiceName, 'KeyVaultSecretUser', 'vault-scope')
    principalId: apimIdentity!.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: resourceId('Microsoft.Authorization/roleDefinitions', '4633458b-17de-408a-b874-0445c86b69e6') // Key Vault Secrets User
  }
}


module apiManagement 'modules/api-management-private.bicep' = {
  name: 'api-management'
  params: {
    location: location
    serviceName: apiManagementServiceName
    publisherName: apiManagementPublisherName
    publisherEmail: apiManagementPublisherEmail
    skuName: apiManagementSku
    skuCount: apiManagementSkuCount
    subnetResourceId: network.outputs.apiManagementSubnetResourceId
    virtualNetworkType: apiNetwork
    aiName: applicationInsightsName
    gatewayHostName: apimGatewayHostName
    portalHostName: apimPortalHostName
    keyVaultName: keyVaultName
    keyVaultResourceGroup: keyVaultResourceGroup
    gatewayKeyVaultSecretName: gatewayKeyVaultSecretName
    portalKeyVaultSecretName: portalKeyVaultSecretName
    intermediateCaCert: intermediateCaCert
    rootCaCert: rootCaCert
    userAssignedIdentityId: !empty(keyVaultName) ? apimIdentity!.id : ''
    userAssignedIdentityClientId: !empty(keyVaultName) ? apimIdentity!.properties.clientId : ''
    disableDeveloperPortal: disableDeveloperPortal
    logAnalyticsWorkspaceId: logAnalyticsWorkspace.outputs.id
    tags: tags
  }
  dependsOn: [
    applicationInsights
    eventHub
    kvAccess
  ]
}

module api 'modules/api.bicep' = {
  name: 'api'
  params: {
    apimName: apiManagementServiceName
    apiName: openaiApiName
    apiPath: openaiApiPath
    openaiApiDisplayName: openaiApiDisplayName
    openApiSpec: openApiSpec
    openApiXml : openApiXml
    openaiV1MessagesApiXml: openaiV1MessagesApiXml
    openaiV1MessagesApiName: openaiV1MessagesApiName
    openaiV1MessagesApiPath: openaiV1MessagesApiPath
    openaiV1MessagesApiDisplayName: openaiV1MessagesApiDisplayName
    openaiV1MessagesOpenApiSpec: loadTextContent('api_definitions/AzureOpenAI_v1_Messages_OpenAPI.json')
    anthropicApiXml: anthropicApiXml
    anthropicApiName: anthropicApiName
    anthropicApiPath: anthropicApiPath
    anthropicApiDisplayName: anthropicApiDisplayName
    anthropicOpenApiSpec: loadTextContent('api_definitions/AzureAnthropic_OpenAPI.json')
    serviceUrlPrimary : apiServiceUrlPrimary
    serviceUrlSecondary: apiServiceUrlSecondary
    anthropicServiceUrlPrimary: anthropicServiceUrlPrimary
    anthropicServiceUrlSecondary: anthropicServiceUrlSecondary
    aiLoggerId: apiManagement.outputs.aiLoggerId
    apimProductName: apimProductName
    apimProductDisplayName: apimProductDisplayName
    apimProductDescription: apimProductDescription
    catalogApiName: catalogApiName
    catalogApiPath: catalogApiPath
    catalogApiDisplayName: catalogApiDisplayName
    catalogApiXml: catalogApiXml
    catalogOpenApiSpec: loadTextContent('api_definitions/Catalog_OpenAPI.json')
    catalogProductName: catalogProductName
    catalogProductDisplayName: catalogProductDisplayName
    catalogProductDescription: catalogProductDescription
  }
}

resource eventHubNamespaceParent 'Microsoft.EventHub/namespaces@2021-01-01-preview' existing = {
  name: eventHubNamespaceName
}

resource azureEventHubsDataSender 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(subscription().id, resourceGroup().id, eventHubNamespaceName)
  scope: eventHubNamespaceParent
  properties: {
    principalId: apiManagement.outputs.apiManagementIdentityPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: resourceId('Microsoft.Authorization/roleDefinitions', azureRoles.AzureEventHubsDataSender)
  }
}

// Grant APIM system-assigned identity Monitoring Metrics Publisher on App Insights
// so that azure-openai-emit-token-metric custom metrics appear in Application Insights.
resource apimMetricsPublisher 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(subscription().id, resourceGroup().id, applicationInsightsName, 'MonitoringMetricsPublisher')
  scope: appInsightsRef
  properties: {
    principalId: apiManagement.outputs.apiManagementIdentityPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: resourceId('Microsoft.Authorization/roleDefinitions', azureRoles.MonitoringMetricsPublisher)
  }
}

resource appInsightsRef 'Microsoft.Insights/components@2020-02-02' existing = {
  name: applicationInsightsName
}

// Grant APIM system-assigned identity Cognitive Services OpenAI User on each AI Foundry account
module openAiRoles 'modules/cognitive-services-role.bicep' = [for (region, i) in regions: {
  name: 'openai-roles-${region.label}'
  params: {
    accountName: aif[i].outputs.openAiName
    principalId: apiManagement.outputs.apiManagementIdentityPrincipalId
    roleDefinitionId: resourceId('Microsoft.Authorization/roleDefinitions', azureRoles.CognitiveServicesOpenAIUser)
  }
}]

// Grant APIM system-assigned identity Azure AI User on each AI Foundry account.
// Required for non-OpenAI providers exposed via AI Services (e.g., Anthropic /anthropic/*),
// which need the Microsoft.CognitiveServices/accounts/AIServices/providers/action data action.
module aiUserRoles 'modules/cognitive-services-role.bicep' = [for (region, i) in regions: {
  name: 'ai-user-roles-${region.label}'
  params: {
    accountName: aif[i].outputs.openAiName
    principalId: apiManagement.outputs.apiManagementIdentityPrincipalId
    roleDefinitionId: resourceId('Microsoft.Authorization/roleDefinitions', azureRoles.AzureAIUser)
  }
}]

output apiManagementProxyHostName string = apiManagement.outputs.apiManagementProxyHostName
output apiManagementPortalHostName string = apiManagement.outputs.apiManagementDeveloperPortalHostName
output vnetNames array = [for (region, i) in regions: vnet[i].outputs.vnetName]
output openAiNames array = [for (region, i) in regions: aif[i].outputs.openAiName]
output openAiEndpoints array = [for (region, i) in regions: aif[i].outputs.openAiEndpoint]
