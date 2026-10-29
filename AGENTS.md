# AGENTS.md — aifapim

Infrastructure-as-Code (Bicep) repo deploying Azure AI Foundry (AIServices)
behind Azure API Management. Originally developed for NSLS-II at Brookhaven
National Laboratory; forks welcome. No application code, no automated test
suite, no build pipeline — post-deploy verification is the smoke-test workflow
documented under "Verification via examples" below.

## What this repo is

Pure Bicep IaC. There is no `npm install`, no Python package and no
automated test suite. CI only validates the repo: a lint gate
(`.github/workflows/lint.yml`, the committed pre-commit hooks) and an advisory
PSRule for Azure analysis (`.github/workflows/psrule.yml`). Nothing is
deployed by CI: changes are applied by running `az deployment group create`
manually, and post-deploy checks are the smoke test described under
"Verification via examples/test-apim.py".

### Lint and static analysis

Run these before committing; CI repeats the lint on changed files.

```bash
pixi run --frozen -e dev lint-files <file1> <file2> ...   # changed files
pixi run --frozen -e dev lint                             # everything
pixi run -e dev lint-psrule                               # PSRule, manual
```

`lint-psrule` needs `pwsh`, the `PSRule.Rules.Azure` module and the Bicep
CLI, and fails when a rule fails. It expands the stack through
`aifapim.example.bicepparam`; rules that do not apply are excluded in
`ps-rule.yaml` with the reason.

## Deployment commands

### Full stack (AI Foundry + APIM)

Real `*.bicepparam` files are gitignored; copy `aifapim.example.bicepparam` to
`aifapim-<env>.bicepparam` and customize per environment before deploying.

```bash
az deployment group create \
  --resource-group <rg> \
  --template-file aifapim.bicep \
  --parameters aifapim-prod.bicepparam   # or whichever env file you copied
```

Do **not** prefix `.bicepparam` files with `@` on the `--parameters` flag —
that syntax is for raw JSON parameter files and causes the CLI to fail with
`unrecognized template parameter 'using 'aifapim.bicep'...'`. For
`.bicepparam`, pass the path directly.

The template file is **`aifapim.bicep`** (note: no hyphen).

### Workbook

**The canonical workbook now lives in the `aifapim-config` repo.** Deploy it
from there; see `aifapim-config/AGENTS.md` §"Workbook deployment" for the full
recipe and `aifapim-config/llm-token-usage-workbook.bicep` for the maintained
source.

The canonical workbook includes cost-analytics tiles and optional non-owner
group read access (Monitoring Reader) in addition to the token-usage views. It
is a separate `az deployment group create` from the main APIM stack, as it
always was.

This repo retains `llm-token-usage-workbook.example.bicep` — a
**point-in-time snapshot** of the workbook as it stood before the move. It is
an illustrative reference only; do **not** deploy it. The canonical version
will diverge from this snapshot as cost tiles and other features are added. The
2026-06 drift gotcha (commit `b0c4b86`, documented below) is the exact failure
mode of running a stale copy — avoid it by always deploying from
`aifapim-config`.

### Provision a user subscription key

Subscription-key provisioning tooling is maintained out-of-tree. For ad-hoc
use, call APIM directly:

```bash
az apim subscription create \
  --resource-group <rg> \
  --service-name <apim-name> \
  --name <sub-name> \
  --display-name "<Display Name>" \
  --scope "/products/<apimProductName>"
```

Fetch the keys with
`az rest --method POST .../subscriptions/<name>/listSecrets?api-version=2023-03-01-preview`.

## Key architecture facts

- **Two regions**: `eastus` (label `eus`, primary index 0) and `eastus2`
  (label `eus2`, primary index 1). **`regions[1]` (eastus2) is the primary
  backend**; eastus is the failover.
- **Four APIs** exposed via APIM, all using `x-api-key` header
  (not `Authorization: Bearer`):
  - `azure-openai-service-api` — path `""` (root), OpenAI Chat/Completions,
    plus `GET /models?api-version=...` and
    `GET /models/{model_id}?api-version=...` (classic AOAI listing).
    Grouped under `apimProductName` product (default `aifapim`).
  - `azure-openai-v1-messages-api` — path `openai`, OpenAI v1 Responses API
    (requires `openai>=1.66.0`), plus `GET /v1/models` and
    `GET /v1/models/{model}`.
    Grouped under `apimProductName` product.
  - `anthropic-service-api` — path `anthropic`, only `POST /v1/messages` and
    `POST /v1/messages/count_tokens`. Foundry returns 404 `api_not_supported`
    for `/anthropic/v1/models`; that route is intentionally not exposed.
    Grouped under `apimProductName` product.
  - `catalog-api` — path `catalog`, `GET /catalog` only. Returns a static
    JSON array of chat-LLM models with `id`, `name`, `provider`, `context`,
    and `output` fields baked in at deploy time from `model-catalog.json`
    (in the `aifapim-config` repo, passed as the `catalogJson` param).
    Grouped under its own **`aifapim-catalog` product** — keys scoped to this
    product cannot call any inference endpoint. No backend is contacted;
    the policy uses `<return-response>` in `<inbound>`. Used by the ansible
    catalog poller to discover models and token windows at play-time.
    **Route composition note:** APIM constructs the gateway route as
    `<API path> + <operation urlTemplate>`. The catalog API uses
    `path = 'catalog'` and `urlTemplate = '/'`, giving the effective route
    `/catalog`. Do **not** put `/catalog` in the OpenAPI operation path — that
    doubles the segment to `/catalog/catalog` and produces a 404.
- **Anthropic models are available on AI Foundry in select regions only.**
  As of 2026-07: `eastus2` has the full catalog; `eastus` carries a partial
  subset (`claude-haiku-4-5`, `claude-opus-4-8`, `claude-sonnet-5`). Populate
  Anthropic-format entries only in the `modelDeployments[i]` whose paired
  `regions[i].name` actually hosts them — verify with
  <!-- markdownlint-disable-next-line MD013 -->
  `az cognitiveservices model list -l <region> --query "[?contains(model.name,'claude')].model.name" -o tsv`
  before adding entries.
- **Inference retry policies do NOT retry on 404.** A 404 from primary
  (eastus2) means the deployment does not exist there — failing over to
  secondary (eastus) is counterproductive because eastus carries fewer
  models, and once a retry switches to the secondary the policy never
  returns to the primary, so the secondary's 404 hides the real error
  (for example a 429 from eastus2). The retry condition in all three of
  `apim_policies/{AOAI,OpenAIv1Messages,Anthropic}_Policy-Managed_Identity_with_Retry_MultiRegion.xml`
  only retries on 429 (rate limit) and 5xx (server errors). Do not add 404
  back. Do not add `<base />` to the `<backend>` section either: APIM
  allows one backend policy, and `<base />` plus `<retry>` fails deploy
  validation (see `7b299f5`, which also reverted this fix by accident).
- **Inference retry policies fail over only for models the secondary has.**
  Each policy sets `canFailover` in `<inbound>` from the request's model
  (body `model` for Anthropic and OpenAI v1, the path segment after
  `deployments` for AOAI) and checks it against `__SECONDARY_MODELS__`,
  which `aifapim.bicep` fills with `'|name|name|'` from `modelDeployments[0]`
  (the secondary region). Models not in that list (all Claude models today)
  retry against the primary with the normal backoff. Why: on 2026-10-23 a
  prod `eastus2` connection reset (`BackendConnectionFailure`, socket error
  10054, about 19 s in) on 14 Claude requests triggered failover to `eastus`,
  which has no Claude deployments, and clients saw a 404 "deployment does
  not exist" instead of a retry. Azure metrics showed no 429s or 5xx from
  `eastus2` in that window. If Claude is later deployed in `eastus`, add it
  to `modelDeployments[0]` and it will fail over automatically.
- **Image models** (Black Forest Labs FLUX, format `'Black Forest Labs'`)
  are deployed as `DataZoneStandard` so processing stays in the US data zone.
  `FLUX.2-pro` and `FLUX.1-Kontext-pro` create and edit images; `FLUX-1.1-pro`
  creates only. They live in `modelDeployments` like any other model, with
  these differences:
  - `capacity` is required (`modules/aif-deployments.bicep` has no default for
    formats other than OpenAI and Anthropic) and is counted in requests per
    minute, not tokens.
  - The `DataZoneStandard` quota is **one pool per subscription**, shared by
    both regions and by every Foundry account in it (prod, dev and others),
    like the `gpt-6-astra` pool. Check it with
    `az cognitiveservices usage list -l <region>`
    (`AIServices.DataZoneStandard.FLUX.2-pro` and so on) before choosing
    capacities, and keep the sum over all deployments at or below the limit.
  - They are served under `api-version=preview`, return base64 images, and
    are reached through `POST /deployments/{name}/images/{generations,edits}`
    (root API) and `POST /openai/v1/images/{generations,edits}` (v1 API). The
    `images/edits` operations are local additions to the specs (upstream
    2024-10-21 has no edits).
  - Both inference policies skip the token limit and token metric policies
    when the path contains `/images/`, and emit an `Image Count` metric
    (value = images in the response `data`) in `<outbound>` instead. The v1
    policy reads `model` from the multipart form text when the body is not
    JSON, because edits are multipart.
  - They are not added to `model-catalog.json`: `/catalog` lists chat models
    with token windows only.
  - The other image models (`gpt-image-*`, `MAI-Image-*`, `FLUX.2-flex`) offer
    only `GlobalStandard`, which can process outside the US. As of 2026-10,
    `gpt-image-1.5` is the only OpenAI image model with `DataZoneStandard`; it
    is eastus2-only and retires 2026-12-16, so it is not deployed here.
- **APIM authenticates to AI Foundry via system-assigned managed identity**
  (no API keys to backends). End-users authenticate to APIM via APIM
  subscription keys.
- **Private networking**: AI Foundry public access is disabled when a
  `subnetId` is provided. Three private DNS zones are required:
  `privatelink.openai.azure.com`,
  `privatelink.cognitiveservices.azure.com`,
  `privatelink.services.ai.azure.com`.
- **NSG lateral-traversal rule + private endpoint carve-out**: Both NSGs
  (`modules/network.bicep` for the APIM subnet, `modules/vnet.bicep` for all
  other subnets) include `Deny_Lateral_Outbound_VirtualNetwork` (priority 4096,
  `VirtualNetwork → VirtualNetwork Deny *`) to satisfy PSRule
  `Azure.NSG.LateralTraversal`. This rule also blocks APIM's outbound HTTPS to
  the AI Foundry private endpoint IPs (which fall under the `VirtualNetwork`
  service tag). The companion rule `Allow_Outbound_To_Private_Endpoints`
  (priority 300, `VirtualNetwork → VirtualNetwork Allow TCP 443`) carves out
  the specific path APIM needs. **Do not remove either rule without
  understanding the dependency** — removing the allow rule causes all backend
  requests to hang silently; removing the deny rule breaks PSRule compliance.
  The same pattern covers the rest of APIM's lateral traffic, each rule at a
  lower priority number than the deny: node-to-node cache (TCP 6381-6383, 310)
  and rate-limit counter sync (UDP 4290, 320), which matter once the service
  has more than one unit (Premium), and AMQP (TCP 5671-5672, 330) to the Event
  Hub private endpoint.
- **Event Hub**: `modules/event-hub.bicep` creates a namespace with local auth
  and public network access disabled, reached only through a private endpoint
  (group `namespace`) in the `openai` subnet of `regions[0]` and registered in
  `privatelink.servicebus.windows.net`, linked to that VNet. Private endpoints
  need the Standard or Premium SKU. The namespace and the APIM Data Sender role
  are provisioned, but no APIM logger sends to it yet (only the Application
  Insights logger exists); it is not used by `aifapim-config`.
- **Request body log** (`requestBodyLogging`, off by default): the built-in
  LLM log (`ApiManagementGatewayLlmLog`) drops the prompt of Anthropic requests
  whose `system` field is a list of blocks (measured 2026-10: a plain-string
  `system` is logged, a list is not, with or without `cache_control`; replies
  are still logged), which is what Claude Code and OpenCode send. When the
  switch is true, `apim_policies/RequestBodyLog_Fragment.xml` replaces the
  `<!-- __REQUEST_LOG__ -->` marker in `<inbound>` of the three inference
  policies. It writes the raw body of every POST to a write-once blob with
  `<send-one-way-request>` (managed identity, `If-None-Match: *`, fire and
  forget, name = request id = `CorrelationId`). `modules/request-log.bicep`
  builds the rest: the data storage account (private endpoint, shared-key
  access off, container-level time-based immutability, Hot to Cold at 7 days
  to Archive at 90, no delete), Event Grid `BlobCreated` to a queue on a host
  storage account, a Flex Consumption function app in a delegated subnet of
  `regions[0]`'s VNet (private subnet with a NAT gateway, private endpoints
  for the host storage), and a separate `law-prompts-<unique>` workspace with
  the custom table `LlmRequestBody_CL` behind a data collection rule. The
  function code is in `aifapim-config` (`request-log/`), with its operator
  runbook. Things to know:
  - The immutability policy is created **unlocked**. Locking is irreversible
    and is a separate operator script. After locking, set
    `requestLogManageImmutabilityPolicy = false` so a redeploy does not try to
    rewrite the locked policy.
  - The workspace copy is not isolated from subscription-level `Reader` (it
    includes `*/read`), Owner or Contributor. Only the blobs are protected by
    data-plane roles.
  - The gateway identity holds Storage Blob Data Contributor with an ABAC
    condition (`conditionVersion` 2.0) that removes the read, delete and move
    data actions. The control-plane `generateUserDelegationKey` action in that
    role cannot be restricted by a condition.
  - Flex Consumption rejects some site properties (`ftpsState`, `alwaysOn`).
    Keep `siteConfig` to `appSettings`, and do not set
    `FUNCTIONS_WORKER_RUNTIME` or the other deprecated settings.
  - The Flex Consumption subnet cannot also be used for service endpoints, so
    storage is reached through private endpoints, like AI Foundry.
  - The blob endpoint in the policy is substituted from
    `environment().suffixes.storage`; do not hard-code it. The marker and the
    `__REQUEST_LOG_*__` placeholders are replaced everywhere they appear, so
    keep them out of other comments.
  - A write failure never reaches the client (fire and forget). Watch
    `StorageBlobLogs` and the `verify.sh` reconciliation instead.
- **Custom TLS**: Certificates must be stored as **secrets** (not
  certificates) in Key Vault. A user-assigned managed identity is created and
  granted Key Vault Secrets User *before* APIM is deployed to solve the
  chicken-and-egg problem.
- **IP filtering**: All three APIM policies share an inbound
  `<ip-filter action="allow">` block populated at deploy time from the
  `allowedClientIps` parameter in the bicepparam files. Entries may be bare
  IPv4 addresses or CIDR ranges (CIDR is expanded via
  `parseCidr().firstUsable`/`lastUsable`, so the network and broadcast
  addresses are excluded). Typical contents are your client network range plus
  any provider-side egress IPs you need to allow (for example, the Anthropic
  egress IPs needed for `/anthropic/*` traffic on Foundry). The policy XML
  files contain a sentinel `__ALLOWED_CLIENT_IPS__` token, not a live IP list
  — `aifapim.bicep` substitutes it during compilation.

## Module layout

```text
aifapim.bicep                           # Orchestrator — start reading here
aifapim.example.bicepparam              # Parameter template — copy to aifapim-<env>.bicepparam and customize
model-catalog.example.json              # Example GET /catalog body loaded by the example parameter file
llm-token-usage-workbook.example.bicep  # Reference snapshot only — NOT deployed (canonical in aifapim-config)
modules/
  aif.bicep                     # AI Foundry account + private endpoint
  aif-deployments.bicep         # Model deployments (sub-module; avoids race on account provisioning)
  api-management-private.bicep  # APIM instance, custom domains, CA certs
  api.bicep                     # All three APIs, backends, product, diagnostics
  app-insights.bicep            # Application Insights
  cognitive-services-role.bicep # Cognitive Services / AI User RBAC for APIM system identity
  event-hub.bicep               # Event Hub namespace (private endpoint only; not wired to an APIM logger yet)
  keyvault-role.bicep           # Key Vault RBAC for APIM user-assigned identity
  llm-latency-alerts.bicep      # Scheduled-query latency alerts on ApiManagementGatewayLogs
  log-analytics-workspace.bicep # Log Analytics workspace
  network.bicep                 # APIM subnet (added to regions[0] vnet)
  private-dns-zone.bicep        # Private DNS zone (AI Foundry endpoints, Event Hub, request log storage)
  request-log.bicep             # Request body log wrapper (optional; requestBodyLogging)
  request-log-storage.bicep     #   WORM data storage account, lifecycle, blob private endpoint
  request-log-function.bicep    #   Loader function app, NAT subnet, host storage, Event Grid, roles
  request-log-workspace.bicep   #   law-prompts workspace, LlmRequestBody_CL table, DCE and DCR
  storage-private-endpoint.bicep # Private endpoint + DNS zone group for a storage account
  vnet.bicep                    # Virtual network
apim_policies/                  # APIM policy XML (loaded inline via loadTextContent)
                                #   RequestBodyLog_Fragment.xml  (inserted into the three inference policies)
                                #   Catalog_Policy.xml  (return-response; no backend)
api_definitions/                # OpenAPI specs (loaded inline via loadTextContent):
                                #   AzureOpenAI_inference_2024-10-21.yaml  (root API; vendored from azure-rest-api-specs)
                                #   AzureOpenAI_v1_Messages_OpenAPI.json   (v1 Messages API)
                                #   AzureAnthropic_OpenAPI.json            (Anthropic Messages API)
                                #   Catalog_OpenAPI.json                   (GET /catalog; static model list)
resources/                      # User-supplied CA PEMs loaded via loadTextContent
                                # in the bicepparam file (intermediateCaCert /
                                # rootCaCert params). Gitignored except .gitkeep.
```

## Policies and API specs are loaded inline

`aifapim.bicep` uses `loadTextContent(...)` to embed policy XML and OpenAPI
specs at compile time. Editing a file in `apim_policies/` or `api_definitions/`
requires a new `az deployment group create` to take effect — there is no live
reload.

The same applies to `llm-token-usage-workbook.bicep`: the workbook JSON is
built inline from `var workbookContent` and embedded as `serializedData`.
Workbook deploys are **in-place upserts** keyed by
`guid(resourceGroup().id, workbookDisplayName)`, so the workbook resource GUID
and Azure Portal URL/bookmarks are preserved across redeploys. Any change to
the embedded queries, parameters, or display elements requires a fresh
`az deployment group create -f llm-token-usage-workbook.bicep …` per
environment — there is no auto-propagation from a `git pull` until you
redeploy.

Historical gotcha (2026-06): commit `b0c4b86` fixed the workbook to scope
queries at the Log Analytics workspace
(`microsoft.operationalinsights/workspaces` + `crossComponentResources`)
instead of the App Insights component, but the fix was deployed to dev only.
Prod's portal-rendered workbook stayed stuck on the pre-fix
`microsoft.insights/components` scope which cannot resolve `AppMetrics`,
producing
`'where' operator: Failed to resolve table or column expression named 'AppMetrics'`
on every tile. Diagnose by REST-GETting
`https://management.azure.com/.../workbooks/{guid}?api-version=2023-06-01&canFetchContent=true`
and inspecting
`properties.serializedData.items[*].content.{resourceType,crossComponentResources}`.
Fix: redeploy via the command in the "Workbook only" section above.

All three OpenAPI specs are embedded from local files in `api_definitions/`.
The Azure OpenAI data-plane inference spec is a vendored copy of the upstream
stable `2024-10-21/inference.yaml` from the Azure REST API specs repo, pinned
locally for deterministic deploys (deploys no longer depend on github.com being
reachable). The local copy is augmented with `/models` and `/models/{model_id}`
listing operations, which are not part of the upstream data-plane spec.

### Refreshing the vendored AOAI spec

To pull a newer upstream `inference.yaml`:

```bash
curl -sS -o api_definitions/AzureOpenAI_inference_2024-10-21.yaml \
  https://raw.githubusercontent.com/Azure/azure-rest-api-specs/refs/heads/main/specification/cognitiveservices/data-plane/AzureOpenAI/inference/stable/2024-10-21/inference.yaml
```

Then re-apply the local `/models` and `/models/{model_id}` path additions
(they are not in upstream) and redeploy. Diff against the previous version
before committing to confirm no unexpected upstream operation changes.

## Developer SKU ServiceLocked race

On Developer SKU APIM (`apiManagementSku = 'Developer'`, single unit, no
redundancy) every `az deployment group create` triggers a service-level
mutation, and the single-instance service transitions while child writes
land. With unserialized fan-out across the ~19 child resources in
`modules/api.bicep` (backends, three APIs, three policies, three per-API
diagnostics, service diagnostic, product, three product/api links), ARM
deterministically fails the `api-management` nested deployment with
`ServiceLocked: The API Service apim-<unique> is transitioning at this
time`. The service itself is healthy (`provisioningState: Succeeded`)
between attempts, so retrying without a fix loops forever.

Two interventions in this repo prevent the race:

1. **Service-level property pinning** in
   `modules/api-management-private.bicep`. `publicNetworkAccess: 'Enabled'`
   and `legacyPortalStatus: 'Disabled'` are set explicitly so ARM does not
   force-mutate them on every deploy. They match the platform-default live
   state on External-VNet Developer SKU. `natGatewayState` is intentionally
   left omitted: its live value is the read-only `Unsupported` state on
   Developer SKU and supplying it as input risks rejection. The residual
   one-property service diff (if any) is absorbed by intervention #2.
2. **Linear `dependsOn` serialization** in `modules/api.bicep`. Every child
   resource is chained so backends → APIs → policies → diagnostics →
   product → product/api links land sequentially, not in parallel. The
   chain is documented inline at each resource. The edges that serialize
   the writes are the ones between sibling resources; a `parent:` already
   adds an implicit dependency on the parent, so listing the parent again
   in `dependsOn` (which the bicep linter flags) adds no ordering and is
   left out. Do NOT remove the sibling edges without a replacement
   serialization strategy.

Tradeoff: deploys are slower (sequential child writes against a single
APIM unit) in exchange for determinism. On Standard/Premium tiers with
multi-unit redundancy this race does not occur and the chaining is a
no-op cost-wise; the pinning is also harmless on those tiers.

## Token usage analytics quirks (verified on Developer SKU)

- **Anthropic completion tokens are always 0 in BOTH
  `AppMetrics.Completion Tokens` AND
  `ApiManagementGatewayLlmLog.CompletionTokens`** — streaming and
  non-streaming alike. APIM's classic-tier LLM diagnostic does not parse
  `usage.output_tokens` from Anthropic Messages API responses. The Anthropic
  policy XML
  (`apim_policies/Anthropic_Policy-Managed_Identity_with_Retry_MultiRegion.xml`)
  compensates with an `<outbound>` `<emit-metric>` block that reads
  `usage.output_tokens` from the response body and emits an
  `Anthropic Completion Tokens` custom metric (namespace = the configured
  `apimProductName`).
- **Anthropic streaming completion tokens remain unmeasurable**. The
  `<outbound>` `<emit-metric>` block is gated on a `requestIsStream` flag
  captured in `<inbound>`; SSE-streamed responses cannot be parsed as a single
  JSON object via `context.Response.Body.As<JObject>()`. Streaming Anthropic
  rows in the workbook show `Completion = 0`. No workaround on classic-tier
  APIM.
- **Anthropic streaming `ModelName` is always empty in `LlmLog`**. Use
  `DeploymentName` from the same row or `Properties.Model` from `AppMetrics`
  (the `<llm-emit-token-metric>` policy on the Anthropic API extracts the
  model from the request body and emits it as a dimension).
- **Anthropic prompts are mostly missing from `ApiManagementGatewayLlmLog`**:
  when `system` is a list of content blocks (Claude Code, OpenCode) the row has
  a response but an empty `RequestMessages`. Replies are fine. Use the request
  body log (above) when prompts are needed.
- Custom policy metrics (`<llm-emit-token-metric>` dimensions and the explicit
  `Anthropic Completion Tokens` emit) all land in `AppMetrics` under the
  namespace given by `apimProductName` (substituted into the policy XML at
  deploy time via the `__METRIC_NAMESPACE__` sentinel).
- These are Developer SKU (classic tier) limitations; v2 tiers may differ.

## Foundry diagnostics

Each `Microsoft.CognitiveServices/accounts` (AI Foundry) account sends
`Audit`, `AzureOpenAIRequestUsage`, and `AllMetrics` to the in-stack Log
Analytics workspace (`law-${unique}`) by default. This provides Foundry-side
observability that is independent of APIM — useful for traffic that bypasses
the gateway (e.g., Entra-ID-authenticated direct callers, internal Foundry
portal usage) and for management-plane audit. The verbose `RequestResponse`
(full request/response bodies) and `Trace` (internal traces) categories are
off by default; flip them on per-deployment via the bicep params
`aifDiagnosticsEnableRequestResponse=true` and
`aifDiagnosticsEnableTrace=true` when troubleshooting.

Foundry logs land in the `AzureDiagnostics` table — distinct from the
APIM-managed `ApiManagementGatewayLogs` / `ApiManagementGatewayLlmLog` /
`AppMetrics` tables — and can be queried with:

```kusto
AzureDiagnostics
| where TimeGenerated > ago(1h)
| where ResourceProvider == "MICROSOFT.COGNITIVESERVICES"
| summarize count() by Category, Resource, OperationName
```

## OpenCode configuration

`examples/opencode.json` is a ready-to-use OpenCode config. The two providers
(`aifapim-openapi`, `aifapim-anthropic`) read `AIFAPIM_HOST` and
`AIFAPIM_API_KEY` from the environment. The `apiKey` field in the config is
intentionally set to `"dummy"` — authentication is via the `x-api-key` header.

```bash
export AIFAPIM_HOST=<gateway-hostname>
export AIFAPIM_API_KEY=<subscription-key>
cp examples/opencode.json opencode.json
opencode
```

Note: the `aifapim-openapi` provider's `baseURL` points at
`https://{AIFAPIM_HOST}/openai/v1`, which only exposes the OpenAI **Responses
API** (`POST /v1/responses`) — Chat Completions is not proxied at that path.
Verified empirically against opencode 1.14.41 + bundled `@ai-sdk/openai`:
requests route to `POST /openai/v1/responses` (HTTP 200), not
`/v1/chat/completions` (which would 404), for both AI-SDK-known model ids
(e.g. `gpt-4.1-mini`) and custom deployment names
(e.g. `my-custom-deployment-name`). If a future opencode/AI-SDK upgrade ever
falls back to `/v1/chat/completions`, switch the `aifapim-openapi` provider to
`"npm": "@ai-sdk/openai-compatible"` or pin a known-good `@ai-sdk/openai`
version.

## Resource naming

All shared resources use a deterministic suffix:
`uniqueString(resourceGroup().id, subscription().id)`. The APIM service name
is `apim-<unique>`. Any out-of-tree subscription provisioning must target the
same resource group so it can resolve the APIM service by this naming pattern.

## Verification via examples/test-apim.py

There is no automated test suite, and CI does not deploy or call the gateway
(it only lints and runs PSRule). Post-deploy verification is driven by a
single smoke-test script: `examples/test-apim.py`.

`examples/test-apim.py` exercises every public API surface using a
subscription key from `AIFAPIM_API_KEY`:

- root API: `client.chat.completions.create` against
  `{endpoint}/deployments/{deployment}` (classic AOAI)
- v1 Messages API: `client.responses.create` against
  `{endpoint}/openai/v1/`
- Anthropic API: `client.messages.create` against `{endpoint}/anthropic`

Reads `AIFAPIM_HOST` and `AIFAPIM_API_KEY` from the environment; raises
`KeyError` if either is unset. Set them to your dev or prod gateway hostname
and a valid subscription key before running. No assertions — visual inspection
of output is the success criterion.

### Running it

The preferred invocation uses the bundled pixi environment
(`examples/pixi.toml`), which pins `openai`, `anthropic`, and `rich` from
conda-forge and exposes a single `example` task:

```bash
export AIFAPIM_HOST=<gateway-hostname>
export AIFAPIM_API_KEY=<subscription-key>
cd examples && pixi run example
# or, from the repo root:
#   pixi run --manifest-path examples/pixi.toml example
```

Or with any Python that has `openai` and `anthropic` installed:

```bash
export AIFAPIM_HOST=<gateway-hostname>
export AIFAPIM_API_KEY=<subscription-key>
python examples/test-apim.py
```

### Standard post-deploy verification workflow

1. Confirm `az deployment group create … --parameters aifapim-<env>.bicepparam`
   returned `Succeeded`.
2. Pick deployment names that actually exist in your environment's parameter
   file — the model list changes over time:

   ```bash
   grep -E "^\s+name:" aifapim-<env>.bicepparam
   ```

3. Update the `__main__` block in `examples/test-apim.py` if the hard-coded
   model names are stale, then:

   ```bash
   export AIFAPIM_HOST=<your-dev-gateway>
   export AIFAPIM_API_KEY=<dev-subscription-key>
   cd examples && pixi run example
   # alternative without pixi:
   #   python examples/test-apim.py
   ```

   Every `run_chat`, `run_chat_v1`, `run_anthropic`, and `run_embedding_v1`
   call should print a coherent answer (or, for embeddings, a vector dimension
   and prompt-token count). The `run_image` and `run_image_v1` calls write the
   generated and edited images to a temporary directory and print each path
   and size.
4. Smoke-test the `/models` listing routes added to the inference APIs and
   the new `/catalog` endpoint:

   ```bash
   curl -sS "https://$AIFAPIM_HOST/openai/v1/models" \
     -H "x-api-key: $AIFAPIM_API_KEY" | jq '.data[].id'
   curl -sS "https://$AIFAPIM_HOST/models?api-version=2024-10-21" \
     -H "x-api-key: $AIFAPIM_API_KEY" | jq '.data[].id'

   # Catalog endpoint — use a key scoped to the aifapim-catalog product.
   # Issue the key first: see aifapim-config/catalog-key.sh.
   export CATALOG_KEY=<catalog-product-key>
   curl -sS "https://$AIFAPIM_HOST/catalog" \
     -H "x-api-key: $CATALOG_KEY" | jq '.[].id'

   # Verify the catalog key cannot call inference (must return 401):
   curl -sS "https://$AIFAPIM_HOST/openai/v1/models" \
     -H "x-api-key: $CATALOG_KEY"
   ```

   The inference listing routes must return 200 with a non-empty `data` array.
   `/catalog` must return 200 with a non-empty JSON array of model objects.
   The catalog key against any inference route must return 401 (not 403 —
   the key is valid but not in the inference product's subscription list).
   Foundry intentionally does not proxy `/anthropic/v1/models` (returns 404
   `api_not_supported`) — do not test that route.
5. Tail `ApiManagementGatewayLogs` in Log Analytics (workspace `law-<unique>`)
   for the last 15 minutes and confirm no unexpected 4xx/5xx:

   ```kusto
   ApiManagementGatewayLogs
   | where TimeGenerated > ago(15m)
   | where ResponseCode >= 400
   | project TimeGenerated, ApiId, OperationId, Method, Url, ResponseCode, BackendResponseCode
   | order by TimeGenerated desc
   ```

Failure of any of the above is a no-go for promotion to prod. Re-running
`examples/test-apim.py` with `AIFAPIM_HOST=<your-prod-gateway>` and a prod
subscription key constitutes the prod smoke test.
