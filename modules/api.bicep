param apimName string
param apiName string
param apiPath string
param openaiApiDisplayName string
param aiLoggerId string
@description('Inline OpenAPI (YAML) spec for the Azure OpenAI data-plane inference API.')
param openApiSpec string
param openApiXml string
param openaiV1MessagesApiXml string
param serviceUrlPrimary string
param serviceUrlSecondary string
param anthropicServiceUrlPrimary string
param anthropicServiceUrlSecondary string

@description('Display name and id for the Azure OpenAI v1 Messages API.')
param openaiV1MessagesApiName string

@description('Display name for the Azure OpenAI v1 Messages API.')
param openaiV1MessagesApiDisplayName string

@description('Path suffix for the Azure OpenAI v1 Messages API.')
param openaiV1MessagesApiPath string

@description('Inline OpenAPI (JSON) spec defining the Azure OpenAI v1 Messages API operations.')
param openaiV1MessagesOpenApiSpec string

@description('Display name and id for the Anthropic API.')
param anthropicApiName string

@description('Display name for the Anthropic API.')
param anthropicApiDisplayName string

@description('Path suffix for the Anthropic API (under the gateway base URL).')
param anthropicApiPath string

@description('Inline policy XML for the Anthropic API.')
param anthropicApiXml string

@description('Inline OpenAPI (JSON) spec defining the Anthropic API operations.')
param anthropicOpenApiSpec string

@description('APIM product name; all three APIs are grouped under this product.')
param apimProductName string

@description('Display name for the APIM product.')
param apimProductDisplayName string

@description('Description for the APIM product.')
param apimProductDescription string

@description('Resource name for the catalog API.')
param catalogApiName string

@description('Display name for the catalog API.')
param catalogApiDisplayName string

@description('URL path for the catalog API (no leading slash).')
param catalogApiPath string

@description('Inline policy XML for the catalog API (return-response; catalog body baked in).')
param catalogApiXml string

@description('Inline OpenAPI (JSON) spec for the catalog API.')
param catalogOpenApiSpec string

@description('Resource name for the catalog-only APIM product.')
param catalogProductName string

@description('Display name for the catalog product.')
param catalogProductDisplayName string

@description('Description for the catalog product.')
param catalogProductDescription string

resource parentAPIM 'Microsoft.ApiManagement/service@2023-03-01-preview' existing = {
  name: apimName
}

// --- ServiceLocked race mitigation ---
//
// On Developer SKU (single instance) parallel child-resource writes against a
// transitioning APIM service produce `ServiceLocked: The API Service is
// transitioning at this time`. To make deploys deterministic on classic-tier
// APIM, every backend / API / policy / diagnostic / product / product-api
// resource below is chained via `dependsOn` so they land sequentially rather
// than fan-out in parallel. The chain order is documented inline at each
// resource. Do NOT remove the `dependsOn` edges without a replacement
// serialization strategy — they look redundant under `parent:` but are not:
// `parent:` is a referential edge, `dependsOn:` is what ARM uses to serialize
// the actual control-plane operations. See aifapim AGENTS.md "Developer SKU
// ServiceLocked race".

resource primarybackend 'Microsoft.ApiManagement/service/backends@2023-03-01-preview' = {
  name: 'aoai-primary-backend'
  parent: parentAPIM
  properties: {
    description: 'Primary AOAI endpoint'
    protocol: 'http'
    url: serviceUrlPrimary
  }
}

resource secondarybackend 'Microsoft.ApiManagement/service/backends@2023-03-01-preview' = {
  name: 'aoai-secondary-backend'
  parent: parentAPIM
  dependsOn: [primarybackend]
  properties: {
    description: 'Secondary AOAI endpoint'
    protocol: 'http'
    url: serviceUrlSecondary
  }
}

resource openaiV1MessagesPrimaryBackend 'Microsoft.ApiManagement/service/backends@2023-03-01-preview' = {
  name: 'aoai-v1-messages-primary-backend'
  parent: parentAPIM
  dependsOn: [secondarybackend]
  properties: {
    description: 'Primary AOAI v1 Messages endpoint'
    protocol: 'http'
    url: serviceUrlPrimary
  }
}

resource openaiV1MessagesSecondaryBackend 'Microsoft.ApiManagement/service/backends@2023-03-01-preview' = {
  name: 'aoai-v1-messages-secondary-backend'
  parent: parentAPIM
  dependsOn: [openaiV1MessagesPrimaryBackend]
  properties: {
    description: 'Secondary AOAI v1 Messages endpoint'
    protocol: 'http'
    url: serviceUrlSecondary
  }
}

resource anthropicPrimaryBackend 'Microsoft.ApiManagement/service/backends@2023-03-01-preview' = {
  name: 'anthropic-primary-backend'
  parent: parentAPIM
  dependsOn: [openaiV1MessagesSecondaryBackend]
  properties: {
    description: 'Primary Anthropic endpoint'
    protocol: 'http'
    url: anthropicServiceUrlPrimary
  }
}

resource anthropicSecondaryBackend 'Microsoft.ApiManagement/service/backends@2023-03-01-preview' = {
  name: 'anthropic-secondary-backend'
  parent: parentAPIM
  dependsOn: [anthropicPrimaryBackend]
  properties: {
    description: 'Secondary Anthropic endpoint'
    protocol: 'http'
    url: anthropicServiceUrlSecondary
  }
}

resource api 'Microsoft.ApiManagement/service/apis@2023-03-01-preview' = {
  parent: parentAPIM
  name: apiName
  dependsOn: [anthropicSecondaryBackend]
  properties: {
    displayName: openaiApiDisplayName
    description: 'Azure OpenAI data-plane inference API. Supports chat completions, embeddings, and model listing operations.'
    format: 'openapi'
    value: openApiSpec
    path: apiPath
    subscriptionRequired: true
    subscriptionKeyParameterNames: {
      header: 'x-api-key'
      query: 'subscription-key'
    }
  }
}

resource apiPolicy 'Microsoft.ApiManagement/service/apis/policies@2023-03-01-preview' = {
  parent: api
  name: 'policy'
  properties: {
    format: 'xml'
    value: openApiXml
  }
}

resource aoaiDiagnostic 'Microsoft.ApiManagement/service/apis/diagnostics@2024-06-01-preview' = {
  parent: api
  dependsOn: [apiPolicy]
  name: 'applicationinsights'
  properties: {
    alwaysLog: 'allErrors'
    httpCorrelationProtocol: 'Legacy'
    verbosity: 'information'
    logClientIp: true
    loggerId: aiLoggerId
    metrics: true
    sampling: {
      samplingType: 'fixed'
      percentage: 100
    }
    frontend: {
      request: {
        headers: ['X-Forwarded-For']
        body: { bytes: 0 }
      }
      response: {
        headers: []
        body: { bytes: 0 }
      }
    }
    // Log token usage (prompt/completion/total tokens), model name, and
    // optionally request/response messages for LLM APIs.
    // See https://learn.microsoft.com/azure/api-management/api-management-howto-llm-logs
    largeLanguageModel: {
      logs: 'enabled'
      requests: {
        maxSizeInBytes: 32768
        messages: 'all'
      }
      responses: {
        maxSizeInBytes: 32768
        messages: 'all'
      }
    }
  }
}

resource diagnostic 'Microsoft.ApiManagement/service/diagnostics@2023-03-01-preview' = {
  parent: parentAPIM
  dependsOn: [aoaiDiagnostic]
  name: 'applicationinsights'
  properties: {
    alwaysLog: 'allErrors'
    httpCorrelationProtocol: 'Legacy'
    verbosity: 'information'
    logClientIp: true
    loggerId: aiLoggerId
    metrics: true
    sampling: {
      samplingType: 'fixed'
      percentage: 100
    }
    frontend: {
      request: {
        headers: ['X-Forwarded-For']
        body: {
          bytes: 0
        }
      }
      response: {
        headers: []
        body: {
          bytes: 0
        }
      }
    }
    backend: {
      request: {
        headers: []
        body: {
          bytes: 0
        }
      }
      response: {
        headers: []
        body: {
          bytes: 0
        }
      }
    }
  }
}

// --- Azure OpenAI v1 Messages API ---

resource openaiV1MessagesApi 'Microsoft.ApiManagement/service/apis@2023-03-01-preview' = {
  parent: parentAPIM
  name: openaiV1MessagesApiName
  dependsOn: [diagnostic]
  properties: {
    displayName: openaiV1MessagesApiDisplayName
    description: 'Azure OpenAI v1 Messages-compatible API. Translates OpenAI Messages format to Azure OpenAI data-plane calls.'
    path: openaiV1MessagesApiPath
    protocols: [
      'https'
    ]
    subscriptionRequired: true
    subscriptionKeyParameterNames: {
      header: 'x-api-key'
      query: 'subscription-key'
    }
    format: 'openapi+json'
    value: openaiV1MessagesOpenApiSpec
  }
}

resource openaiV1MessagesApiPolicy 'Microsoft.ApiManagement/service/apis/policies@2023-03-01-preview' = {
  parent: openaiV1MessagesApi
  name: 'policy'
  // Backend deps are pre-existing referential requirements. The
  // openaiV1MessagesApi dep is part of the explicit serialization chain
  // (see header comment); the linter flags it as redundant under `parent:`
  // but that conflates the two edge types — see header.
  dependsOn: [
    openaiV1MessagesPrimaryBackend
    openaiV1MessagesSecondaryBackend
    #disable-next-line no-unnecessary-dependson
    openaiV1MessagesApi
  ]
  properties: {
    format: 'xml'
    value: openaiV1MessagesApiXml
  }
}

resource openaiV1MessagesDiagnostic 'Microsoft.ApiManagement/service/apis/diagnostics@2024-06-01-preview' = {
  parent: openaiV1MessagesApi
  dependsOn: [openaiV1MessagesApiPolicy]
  name: 'applicationinsights'
  properties: {
    alwaysLog: 'allErrors'
    httpCorrelationProtocol: 'Legacy'
    verbosity: 'information'
    logClientIp: true
    loggerId: aiLoggerId
    metrics: true
    sampling: {
      samplingType: 'fixed'
      percentage: 100
    }
    frontend: {
      request: {
        headers: ['X-Forwarded-For']
        body: { bytes: 0 }
      }
      response: {
        headers: []
        body: { bytes: 0 }
      }
    }
    // Log token usage (prompt/completion/total tokens), model name, and
    // optionally request/response messages for LLM APIs.
    // See https://learn.microsoft.com/azure/api-management/api-management-howto-llm-logs
    largeLanguageModel: {
      logs: 'enabled'
      requests: {
        maxSizeInBytes: 32768
        messages: 'all'
      }
      responses: {
        maxSizeInBytes: 32768
        messages: 'all'
      }
    }
  }
}

// --- Anthropic API ---

resource anthropicApi 'Microsoft.ApiManagement/service/apis@2023-03-01-preview' = {
  parent: parentAPIM
  name: anthropicApiName
  dependsOn: [openaiV1MessagesDiagnostic]
  properties: {
    displayName: anthropicApiDisplayName
    description: 'Anthropic Claude API. Provides access to Anthropic models via the Azure AI Foundry Anthropic endpoint.'
    path: anthropicApiPath
    protocols: [
      'https'
    ]
    subscriptionRequired: true
    subscriptionKeyParameterNames: {
      header: 'x-api-key'
      query: 'subscription-key'
    }
    format: 'openapi+json'
    value: anthropicOpenApiSpec
  }
}

resource anthropicApiPolicy 'Microsoft.ApiManagement/service/apis/policies@2023-03-01-preview' = {
  parent: anthropicApi
  name: 'policy'
  properties: {
    format: 'xml'
    value: anthropicApiXml
  }
}

resource anthropicDiagnostic 'Microsoft.ApiManagement/service/apis/diagnostics@2024-06-01-preview' = {
  parent: anthropicApi
  dependsOn: [anthropicApiPolicy]
  name: 'applicationinsights'
  properties: {
    alwaysLog: 'allErrors'
    httpCorrelationProtocol: 'Legacy'
    verbosity: 'information'
    logClientIp: true
    loggerId: aiLoggerId
    metrics: true
    sampling: {
      samplingType: 'fixed'
      percentage: 100
    }
    frontend: {
      request: {
        headers: ['X-Forwarded-For']
        body: { bytes: 0 }
      }
      response: {
        headers: []
        body: { bytes: 0 }
      }
    }
    // Log token usage (prompt/completion/total tokens), model name, and
    // optionally request/response messages for LLM APIs.
    // See https://learn.microsoft.com/azure/api-management/api-management-howto-llm-logs
    largeLanguageModel: {
      logs: 'enabled'
      requests: {
        maxSizeInBytes: 32768
        messages: 'all'
      }
      responses: {
        maxSizeInBytes: 32768
        messages: 'all'
      }
    }
  }
}

// --- APIM product: groups all APIs under a single product ---

resource apimProduct 'Microsoft.ApiManagement/service/products@2023-03-01-preview' = {
  parent: parentAPIM
  name: apimProductName
  dependsOn: [anthropicDiagnostic]
  properties: {
    displayName: apimProductDisplayName
    description: apimProductDescription
    subscriptionRequired: true
    // approvalRequired: true gates portal/manual subscriptions.
    // Programmatic provisioning via aifapim-config/apim-subscriptions.bicep
    // creates subscriptions in 'active' state directly, bypassing this gate.
    approvalRequired: true
    state: 'published'
  }
}

resource apimProductOpenAiApi 'Microsoft.ApiManagement/service/products/apis@2023-03-01-preview' = {
  parent: apimProduct
  name: api.name
}

resource apimProductAnthropicApi 'Microsoft.ApiManagement/service/products/apis@2023-03-01-preview' = {
  parent: apimProduct
  name: anthropicApi.name
  dependsOn: [apimProductOpenAiApi]
}

resource apimProductOpenAiV1MessagesApi 'Microsoft.ApiManagement/service/products/apis@2023-03-01-preview' = {
  parent: apimProduct
  name: openaiV1MessagesApi.name
  dependsOn: [apimProductAnthropicApi]
}

// --- Catalog API: static return-response, no backend ---
//
// GET /catalog returns the curated model list baked in at deploy time.
// Chained after the main product associations to maintain the linear
// dependsOn serialization required on Developer SKU APIM.

resource catalogApi 'Microsoft.ApiManagement/service/apis@2023-03-01-preview' = {
  parent: parentAPIM
  name: catalogApiName
  dependsOn: [apimProductOpenAiV1MessagesApi]
  properties: {
    displayName: catalogApiDisplayName
    description: 'Returns the curated list of chat-LLM models with provider, context window, and max output tokens. Body is static and baked in at deploy time — no backend call is made.'
    format: 'openapi+json'
    value: catalogOpenApiSpec
    path: catalogApiPath
    subscriptionRequired: true
    subscriptionKeyParameterNames: {
      header: 'x-api-key'
      query: 'subscription-key'
    }
  }
}

resource catalogApiPolicy 'Microsoft.ApiManagement/service/apis/policies@2023-03-01-preview' = {
  parent: catalogApi
  name: 'policy'
  properties: {
    format: 'xml'
    value: catalogApiXml
  }
}

// --- Catalog product: scoped to /catalog only ---
//
// Keys issued under this product cannot call inference endpoints.
// Intended for the ansible catalog poller (machine consumer, vaulted key).

resource catalogProduct 'Microsoft.ApiManagement/service/products@2023-03-01-preview' = {
  parent: parentAPIM
  name: catalogProductName
  dependsOn: [catalogApiPolicy]
  properties: {
    displayName: catalogProductDisplayName
    description: catalogProductDescription
    subscriptionRequired: true
    approvalRequired: true
    state: 'published'
  }
}

resource catalogProductCatalogApi 'Microsoft.ApiManagement/service/products/apis@2023-03-01-preview' = {
  parent: catalogProduct
  name: catalogApi.name
}
