using 'aifapim.bicep'

// =============================================================================
// AIF APIM example parameter file.
//
// Copy this file to e.g. aifapim-prod.bicepparam or aifapim-dev.bicepparam,
// replace the placeholder values below with your environment-specific
// settings, then deploy with:
//
//     az deployment group create \
//       --resource-group <your-rg> \
//       --template-file aifapim.bicep \
//       --parameters <your-env>.bicepparam
//
// Real (non-example) *.bicepparam files are gitignored; see .gitignore.
// =============================================================================

// ---- APIM SKU ----
// One of: 'Developer', 'BasicV2', 'StandardV2', 'Premium'.
// 'Developer' is the classic tier used for non-production; v2 tiers and
// 'Premium' support different feature sets (see README "Platform behaviors").
param apiManagementSku = 'Developer'

// ---- Networking ----
// APIM subnet CIDR. Must lie inside regions[0].vnetAddressPrefix below
// (the APIM subnet is added to regions[0]'s VNet).
param apiManagementSubnetIPPrefix = '10.10.2.0/24'

// ---- Publisher metadata (shown in APIM portal + emails) ----
param apiManagementPublisherName  = '<Your Organization>'
param apiManagementPublisherEmail = 'apim-admin@example.com'

// ---- Alert action group recipient ----
param alertEmailName    = '<Your Org> AIF APIM Alerts'
param alertEmailAddress = 'alerts@example.com'

// ---- Custom domain (TLS via Key Vault) ----
// Leave apimGatewayHostName empty to skip custom-domain wiring entirely.
param apimGatewayHostName       = 'api.example.com'
param gatewayKeyVaultSecretName = '<kv-secret-name-for-gateway-cert>'

// ---- Key Vault holding the TLS certificate secrets ----
// The Key Vault must be RBAC-enabled and contain the gateway cert stored as
// a *secret* (not a certificate). The deployment grants the APIM user-
// assigned managed identity 'Key Vault Secrets User' on this vault before
// APIM is created (solves the chicken-and-egg problem at deploy time).
param keyVaultName          = '<your-kv-name>'
param keyVaultResourceGroup = '<your-kv-resource-group>'

// ---- Optional CA certificates added to the APIM cert store ----
// PEM-encoded intermediate / root CA certs to add to APIM's CertificateAuthority
// and Root stores, respectively. Both default to empty (skip).
//
// loadTextContent() runs at bicepparam compile time, so the file paths are
// resolved relative to this .bicepparam file. The bundled resources/ directory
// is gitignored aside from a .gitkeep; place your PEM files there (or any path
// you prefer) and uncomment the matching line below.
//
// param intermediateCaCert = loadTextContent('resources/<your-intermediate>.pem')
// param rootCaCert         = loadTextContent('resources/<your-root>.pem')

// ---- Anthropic provider attestation ----
// Required by Anthropic for Anthropic-format model deployments on Azure AI
// Foundry. These values are sent to Anthropic with the deployment metadata.
param anthropicIndustry         = 'Technology'
param anthropicCountryCode      = 'US'   // ISO 3166-1 alpha-2
param anthropicOrganizationName = '<Your Organization>'

// ---- Default model capacities (TPM) ----
// Overridable per-entry in modelDeployments via the optional `capacity` key.
param openaiCapacity    = 100
param anthropicCapacity = 100

// ---- Per-request backend timeout (seconds) ----
// Capped at 240 on classic-tier APIM.
param backendTimeoutSeconds = 240

// ---- APIM product ----
// All three APIs (azure-openai-service-api, azure-openai-v1-messages-api,
// anthropic-service-api) are grouped under this product. The same value is
// also used as the App Insights custom-metric namespace by the
// <llm-emit-token-metric> and <emit-metric> policies, so queries against
// AppMetrics filter by this namespace. Must be a valid APIM resource name
// (lowercase alphanumerics + hyphens).
param apimProductName        = 'aifapim'
param apimProductDisplayName = 'AIFAPIM'
param apimProductDescription = 'AI Foundry APIM product. Groups the Azure OpenAI, Azure OpenAI v1 Messages, and Anthropic APIs.'

// ---- Inbound IP allow-list ----
// Applied to all three APIM APIs. Entries are either a single IPv4 address
// or a CIDR range. CIDR entries are expanded via parseCidr().firstUsable/
// lastUsable, so the network and broadcast addresses are excluded.
// An empty list is rejected at deploy time (@minLength(1)).
//
// The values below are RFC 5737 documentation IPs — they cannot route real
// traffic. Replace with your actual client IPs/ranges before deploying.
param allowedClientIps = [
  '192.0.2.10'         // example single IPv4 (TEST-NET-1)
  '198.51.100.0/24'    // example /24 (TEST-NET-2)
  '203.0.113.0/24'     // example /24 (TEST-NET-3)
]

// ---- Model catalog ----
// JSON array served by GET /catalog (id/name/provider/context/output per
// chat-LLM model), baked into the catalog policy at deploy time. Replace the
// example with a catalog that matches modelDeployments below; context and
// output windows must come from the vendor model cards.
param catalogJson = loadTextContent('./model-catalog.example.json')

// ---- Service products (optional) ----
// Extra products for service (machine) keys, each with the three inference APIs
// and the catalog API. allowedClientIps restricts a product to those callers
// (a CIDR covers its whole range, network to broadcast), on top of the global
// allowedClientIps. Leave the list empty to have none.
param serviceProducts = [
  {
    name: 'services-external'
    displayName: 'Services (external)'
    description: 'Keys for services, from anywhere the gateway allow-list accepts.'
  }
  {
    name: 'services-internal'
    displayName: 'Services (internal)'
    description: 'Keys for services on site only.'
    allowedClientIps: [
      '192.0.2.0/28'  // example (TEST-NET-1)
    ]
  }
]

// ---- Request body log (optional) ----
// Off by default. When true, the gateway writes the raw body of every POST to
// a write-once blob and a function loads a searchable copy into a separate
// Log Analytics workspace. See README "Request body log". The subnet must lie
// inside regions[0].vnetAddressPrefix, be at least a /27 and not overlap the
// apim or openai subnets.
param requestBodyLogging = false
// param requestLogSubnetIPPrefix = '10.10.4.0/27'
// param requestLogReaderGroupObjectId = '<entra-group-object-id>'

// ---- Regions ----
// Two-region multi-region deployment. regions[1] is the *primary* backend;
// regions[0] is the failover. vnetAddressPrefix and openAiSubnetPrefix must
// not overlap between regions (the two VNets are peered).
param regions = [
  {
    name: 'eastus'
    label: 'eus'
    vnetAddressPrefix:  '10.10.0.0/16'
    openAiSubnetPrefix: '10.10.0.0/24'
  }
  {
    name: 'eastus2'
    label: 'eus2'
    vnetAddressPrefix:  '10.11.0.0/16'
    openAiSubnetPrefix: '10.11.0.0/24'
  }
]

// ---- Model deployments (per region) ----
// Outer array index aligns with `regions[*]` (so modelDeployments[0]
// targets regions[0], modelDeployments[1] targets regions[1]).
//
// Each entry's keys:
//   name      - APIM-facing deployment name (what clients pass as `model`)
//   model     - Azure AI Foundry model id
//   version   - model version
//   skuName   - 'DataZoneStandard' (OpenAI/Foundry) | 'GlobalStandard' (most others)
//   capacity  - (optional) per-deployment TPM, overrides openai/anthropicCapacity.
//               REQUIRED for formats other than OpenAI and Anthropic.
//   format    - (optional) 'Anthropic' | 'Meta' | 'Black Forest Labs' — required for non-OpenAI families
//   versionUpgradeOption - (optional) default 'OnceNewDefaultVersionAvailable'
//
// Image models (format 'Black Forest Labs', for example FLUX.2-pro) are quota
// limited in requests per minute, not tokens. Their DataZoneStandard quota is
// one pool per subscription shared by every region and account in it, so the
// capacities of all deployments of a model must add up to that pool or less.
// Clients reach them through POST /deployments/{name}/images/generations and
// /edits (root API) or POST /openai/v1/images/generations and /edits.
//
// Anthropic models are only offered by Foundry in select regions (currently
// eastus2); leave them out of regions[0] if that region cannot host them.
param modelDeployments = [
  // ---- regions[0] (failover) ----
  [
    {
      name:    'gpt-4.1-mini'
      model:   'gpt-4.1-mini'
      version: '2025-04-14'
      skuName: 'DataZoneStandard'
    }
    {
      name:    'FLUX.2-pro'
      model:   'FLUX.2-pro'
      version: '1'
      skuName: 'DataZoneStandard'
      capacity: 10
      format:  'Black Forest Labs'
      versionUpgradeOption: 'NoAutoUpgrade'
    }
    {
      name:    'Llama-3.3-70B-Instruct'
      model:   'Llama-3.3-70B-Instruct'
      version: '1'
      skuName: 'GlobalStandard'
      capacity: 1
      format:  'Meta'
    }
  ]
  // ---- regions[1] (primary) ----
  [
    {
      name:    'gpt-4.1-mini'
      model:   'gpt-4.1-mini'
      version: '2025-04-14'
      skuName: 'DataZoneStandard'
    }
    {
      name:    'FLUX.2-pro'
      model:   'FLUX.2-pro'
      version: '1'
      skuName: 'DataZoneStandard'
      capacity: 10
      format:  'Black Forest Labs'
      versionUpgradeOption: 'NoAutoUpgrade'
    }
    {
      name:    'claude-sonnet-4-5'
      model:   'claude-sonnet-4-5'
      version: '20250929'
      skuName: 'GlobalStandard'
      format:  'Anthropic'
    }
    {
      name:    'Llama-3.3-70B-Instruct'
      model:   'Llama-3.3-70B-Instruct'
      version: '1'
      skuName: 'GlobalStandard'
      capacity: 1
      format:  'Meta'
    }
  ]
]
