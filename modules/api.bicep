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

@description('Backend URL of the Black Forest Labs provider route on the primary model account (ends in /providers/blackforestlabs/v1).')
param bflServiceUrlPrimary string

@description('Backend URL of the Black Forest Labs provider route on the secondary model account.')
param bflServiceUrlSecondary string

@description('Resource name and id for the Black Forest Labs API.')
param bflApiName string

@description('Display name for the Black Forest Labs API.')
param bflApiDisplayName string

@description('Path suffix for the Black Forest Labs API (the same path Azure uses).')
param bflApiPath string

@description('Inline policy XML for the Black Forest Labs API.')
param bflApiXml string

@description('Inline OpenAPI (JSON) spec defining the Black Forest Labs API operations.')
param bflOpenApiSpec string

@description('Backend URL of the MAI image API (ends in /mai/v1). The MAI models are deployed in the secondary region only, so there is one backend.')
param maiServiceUrl string

@description('Resource name and id for the MAI image API.')
param maiApiName string

@description('Display name for the MAI image API.')
param maiApiDisplayName string

@description('Path suffix for the MAI image API (the same path Azure uses).')
param maiApiPath string

@description('Inline policy XML for the MAI image API.')
param maiApiXml string

@description('Inline OpenAPI (JSON) spec defining the MAI image API operations.')
param maiOpenApiSpec string

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

@description('Service products, each { name, displayName, description, policyXml, open }. policyXml is a product-level policy, or empty for none. An open product (open: true) needs no subscription key: its policy is then the only access check, so it is never empty.')
param serviceProducts array = []

// Request headers copied into Application Insights (AppRequests, as
// Request-<name>). The WAF in front of hermes.nsls2.bnl.gov (Signal Sciences)
// adds the X-Sigsci headers: the request id finds the request in the WAF
// console, which records the client address the WAF saw, and the tags list the
// signals it raised. Since 2026-11-04 it also adds X-Forwarded-For, appended
// to any value the client sent, so only the last entry can be trusted.
// Fastly-Client-IP is logged to see whether the WAF sets it; where it exists a
// client can send its own value, so the same caution applies. Never add
// Fastly-Key: it is an API token.
var loggedRequestHeaders = [
  'X-Forwarded-For'
  'X-Sigsci-Requestid'
  'X-Sigsci-Agentresponse'
  'X-Sigsci-Tags'
  'Fastly-Client-IP'
  'Fastly-Client'
  'Fastly-FF'
  'Fastly-SSL'
]

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
// serialization strategy. A `parent:` already adds an implicit dependency on
// the parent, so repeating the parent in `dependsOn` orders nothing; the
// edges that serialize the writes are the ones between SIBLING resources
// (backend to backend, API to API, policy to diagnostic, and so on). See
// aifapim AGENTS.md "Developer SKU ServiceLocked race".

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

resource bflPrimaryBackend 'Microsoft.ApiManagement/service/backends@2023-03-01-preview' = {
  name: 'bfl-primary-backend'
  parent: parentAPIM
  dependsOn: [anthropicSecondaryBackend]
  properties: {
    description: 'Primary Black Forest Labs provider route'
    protocol: 'http'
    url: bflServiceUrlPrimary
  }
}

resource bflSecondaryBackend 'Microsoft.ApiManagement/service/backends@2023-03-01-preview' = {
  name: 'bfl-secondary-backend'
  parent: parentAPIM
  dependsOn: [bflPrimaryBackend]
  properties: {
    description: 'Secondary Black Forest Labs provider route'
    protocol: 'http'
    url: bflServiceUrlSecondary
  }
}

resource maiBackend 'Microsoft.ApiManagement/service/backends@2023-03-01-preview' = {
  name: 'mai-backend'
  parent: parentAPIM
  dependsOn: [bflSecondaryBackend]
  properties: {
    description: 'MAI image endpoint (secondary region only)'
    protocol: 'http'
    url: maiServiceUrl
  }
}

resource api 'Microsoft.ApiManagement/service/apis@2023-03-01-preview' = {
  parent: parentAPIM
  name: apiName
  dependsOn: [maiBackend]
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
        headers: loggedRequestHeaders
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
        headers: loggedRequestHeaders
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
    description: 'Azure OpenAI v1 API: Responses, embeddings and model listing, forwarded to the Azure OpenAI v1 data plane.'
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
  // The backends are siblings the policy refers to; the parent API is an
  // implicit dependency through `parent:` and is not repeated here.
  dependsOn: [
    openaiV1MessagesPrimaryBackend
    openaiV1MessagesSecondaryBackend
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
        headers: loggedRequestHeaders
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
        headers: loggedRequestHeaders
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

// --- Black Forest Labs API ---
//
// FLUX.2-pro is served by Azure only on the Black Forest Labs provider route,
// so it has its own API, backends and policy. The API path is the path Azure
// uses, so a client changes only the host and the key header.

resource bflApi 'Microsoft.ApiManagement/service/apis@2023-03-01-preview' = {
  parent: parentAPIM
  name: bflApiName
  dependsOn: [anthropicDiagnostic]
  properties: {
    displayName: bflApiDisplayName
    description: 'Black Forest Labs provider API for FLUX.2-pro image creation and editing.'
    path: bflApiPath
    protocols: [
      'https'
    ]
    subscriptionRequired: true
    subscriptionKeyParameterNames: {
      header: 'x-api-key'
      query: 'subscription-key'
    }
    format: 'openapi+json'
    value: bflOpenApiSpec
  }
}

resource bflApiPolicy 'Microsoft.ApiManagement/service/apis/policies@2023-03-01-preview' = {
  parent: bflApi
  name: 'policy'
  properties: {
    format: 'xml'
    value: bflApiXml
  }
}

resource bflDiagnostic 'Microsoft.ApiManagement/service/apis/diagnostics@2024-06-01-preview' = {
  parent: bflApi
  dependsOn: [bflApiPolicy]
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
        headers: loggedRequestHeaders
        body: { bytes: 0 }
      }
      response: {
        headers: []
        body: { bytes: 0 }
      }
    }
  }
}

// --- MAI image API ---
//
// The MAI image models use Microsoft's own image routes (mai/v1/images/...),
// which differ from the OpenAI ones, and are deployed in the secondary region
// only. The API path is the path Azure uses.

resource maiApi 'Microsoft.ApiManagement/service/apis@2023-03-01-preview' = {
  parent: parentAPIM
  name: maiApiName
  dependsOn: [bflDiagnostic]
  properties: {
    displayName: maiApiDisplayName
    description: 'Microsoft MAI image API for MAI-Image-2.6 and MAI-Image-2.6-Flash image creation and editing.'
    path: maiApiPath
    protocols: [
      'https'
    ]
    subscriptionRequired: true
    subscriptionKeyParameterNames: {
      header: 'x-api-key'
      query: 'subscription-key'
    }
    format: 'openapi+json'
    value: maiOpenApiSpec
  }
}

resource maiApiPolicy 'Microsoft.ApiManagement/service/apis/policies@2023-03-01-preview' = {
  parent: maiApi
  name: 'policy'
  properties: {
    format: 'xml'
    value: maiApiXml
  }
}

resource maiDiagnostic 'Microsoft.ApiManagement/service/apis/diagnostics@2024-06-01-preview' = {
  parent: maiApi
  dependsOn: [maiApiPolicy]
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
        headers: loggedRequestHeaders
        body: { bytes: 0 }
      }
      response: {
        headers: []
        body: { bytes: 0 }
      }
    }
  }
}

// --- APIM product: groups all APIs under a single product ---

resource apimProduct 'Microsoft.ApiManagement/service/products@2023-03-01-preview' = {
  parent: parentAPIM
  name: apimProductName
  dependsOn: [maiDiagnostic]
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

resource apimProductBflApi 'Microsoft.ApiManagement/service/products/apis@2023-03-01-preview' = {
  parent: apimProduct
  name: bflApi.name
  dependsOn: [apimProductOpenAiV1MessagesApi]
}

resource apimProductMaiApi 'Microsoft.ApiManagement/service/products/apis@2023-03-01-preview' = {
  parent: apimProduct
  name: maiApi.name
  dependsOn: [apimProductBflApi]
}

// --- Catalog API: static return-response, no backend ---
//
// GET /catalog returns the curated chat model list and GET /catalog/images the
// image model list, both baked in at deploy time.
// Chained after the main product associations to maintain the linear
// dependsOn serialization required on Developer SKU APIM.

resource catalogApi 'Microsoft.ApiManagement/service/apis@2023-03-01-preview' = {
  parent: parentAPIM
  name: catalogApiName
  dependsOn: [apimProductMaiApi]
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

// --- The catalog API is also part of the user product ---
//
// The service products below have it too. Chained after the catalog product
// association to keep the sequential order the Developer SKU needs.

resource apimProductCatalogApi 'Microsoft.ApiManagement/service/products/apis@2023-03-01-preview' = {
  parent: apimProduct
  name: catalogApi.name
  dependsOn: [catalogProductCatalogApi]
}

// --- Service products ---
//
// Same APIs as the user product (the five inference APIs and the catalog API).
// A product-level policy (the NAT-pool lock) is added when the entry has one.
// Everything is written one at a time, in this order: products, then their API
// links, then their policies.

@batchSize(1)
resource serviceProduct 'Microsoft.ApiManagement/service/products@2023-03-01-preview' = [for p in serviceProducts: {
  parent: parentAPIM
  name: p.name
  dependsOn: [apimProductCatalogApi]
  properties: {
    displayName: p.displayName
    description: p.description
    subscriptionRequired: !(p.?open ?? false)
    // APIM refuses any value for approvalRequired (even false) when no subscription is required.
    ...((p.?open ?? false) ? {} : { approvalRequired: true })
    state: 'published'
  }
}]

var serviceProductApiNames = [
  apiName
  openaiV1MessagesApiName
  anthropicApiName
  bflApiName
  maiApiName
  catalogApiName
]
var serviceProductApiLinks = flatten(map(range(0, length(serviceProducts)), i => map(serviceProductApiNames, a => {
  productIndex: i
  api: a
})))

@batchSize(1)
resource serviceProductApi 'Microsoft.ApiManagement/service/products/apis@2023-03-01-preview' = [for link in serviceProductApiLinks: {
  parent: serviceProduct[link.productIndex]
  name: link.api
  dependsOn: [serviceProduct]
}]

// A product always gets a policy. Without a restriction it only inherits, so a
// restriction that is removed from the parameters is removed from the product too:
// an incremental deployment never deletes a policy, and skipping the resource
// would leave the old allow-list in place.
var serviceProductInheritOnlyPolicy = '<policies><inbound><base /></inbound><backend><base /></backend><outbound><base /></outbound><on-error><base /></on-error></policies>'

@batchSize(1)
resource serviceProductPolicy 'Microsoft.ApiManagement/service/products/policies@2023-03-01-preview' = [for (p, i) in serviceProducts: {
  parent: serviceProduct[i]
  name: 'policy'
  dependsOn: [serviceProductApi]
  properties: {
    format: 'xml'
    value: empty(p.policyXml) ? serviceProductInheritOnlyPolicy : p.policyXml
  }
}]
