@description('Name of the existing Azure AI Foundry (AI Services) account.')
param accountName string

@description('Model deployments to create on the account.')
param modelDeployments array

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

resource account 'Microsoft.CognitiveServices/accounts@2025-10-01-preview' existing = {
  name: accountName
}

@batchSize(1)
resource deployments 'Microsoft.CognitiveServices/accounts/deployments@2025-10-01-preview' = [for deployment in modelDeployments: {
  parent: account
  name: deployment.name
  sku: {
    name: deployment.skuName
    // Formats other than OpenAI and Anthropic (for example 'Black Forest Labs')
    // have no default: their quota is counted in different units, so the entry
    // must set `capacity` itself and the deployment fails if it does not.
    capacity: deployment.?capacity ?? ((deployment.?format ?? 'OpenAI') == 'Anthropic' ? anthropicCapacity : ((deployment.?format ?? 'OpenAI') == 'OpenAI' ? openaiCapacity : deployment.capacity))
  }
  properties: union(
    {
      model: {
        format: deployment.?format ?? 'OpenAI'
        name: deployment.model
        version: deployment.version
      }
      versionUpgradeOption: deployment.?versionUpgradeOption ?? 'OnceNewDefaultVersionAvailable'
    },
    (contains(deployment, 'format') && deployment.format == 'Anthropic') ? {
      modelProviderData: {
        industry: anthropicIndustry
        countryCode: anthropicCountryCode
        organizationName: anthropicOrganizationName
      }
    } : {},
    (startsWith(deployment.model, 'gpt-') && contains(deployment, 'raiPolicyName')) ? {
      raiPolicyName: deployment.raiPolicyName
    } : {}
  )
}]
