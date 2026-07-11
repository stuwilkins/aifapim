# AGENTS.md — aifapim

Infrastructure-as-Code (Bicep) repo deploying Azure AI Foundry (AIServices) behind Azure API Management. Originally developed for NSLS-II at Brookhaven National Laboratory; forks welcome. No application code, no automated test suite, no build pipeline — post-deploy verification is the smoke-test workflow documented under "Verification via examples" below.

## What this repo is

Pure Bicep IaC. There is no `npm install`, no Python package, no lint/typecheck step, and no CI. Changes are applied by running `az deployment group create` manually.

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

Do **not** prefix `.bicepparam` files with `@` on the `--parameters` flag — that syntax is for raw JSON parameter files and causes the CLI to fail with `unrecognized template parameter 'using 'aifapim.bicep'...'`. For `.bicepparam`, pass the path directly.

The template file is **`aifapim.bicep`** (note: no hyphen).

### Workbook

**The canonical workbook now lives in the `aifapim-config` repo.** Deploy it from
there; see `aifapim-config/AGENTS.md` §"Workbook deployment" for the full recipe
and `aifapim-config/llm-token-usage-workbook.bicep` for the maintained source.

The canonical workbook includes cost-analytics tiles and optional non-owner group
read access (Monitoring Reader) in addition to the token-usage views. It is a
separate `az deployment group create` from the main APIM stack, as it always was.

This repo retains `llm-token-usage-workbook.example.bicep` — a **point-in-time
snapshot** of the workbook as it stood before the move. It is an illustrative
reference only; do **not** deploy it. The canonical version will diverge from this
snapshot as cost tiles and other features are added. The 2026-06 drift gotcha
(commit `b0c4b86`, documented below) is the exact failure mode of running a stale
copy — avoid it by always deploying from `aifapim-config`.

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

Fetch the keys with `az rest --method POST .../subscriptions/<name>/listSecrets?api-version=2023-03-01-preview`.

## Key architecture facts

- **Two regions**: `eastus` (label `eus`, primary index 0) and `eastus2` (label `eus2`, primary index 1). **`regions[1]` (eastus2) is the primary backend**; eastus is the failover.
- **Three APIs** exposed via APIM, all grouped under a single configurable product (`apimProductName`, default `aifapim`), all using `x-api-key` header (not `Authorization: Bearer`):
  - `azure-openai-service-api` — path `""` (root), OpenAI Chat/Completions, plus `GET /models?api-version=...` and `GET /models/{model_id}?api-version=...` (classic AOAI listing)
  - `azure-openai-v1-messages-api` — path `openai`, OpenAI v1 Responses API (requires `openai>=1.66.0`), plus `GET /v1/models` and `GET /v1/models/{model}`
  - `anthropic-service-api` — path `anthropic`, only `POST /v1/messages` and `POST /v1/messages/count_tokens`. Foundry returns 404 `api_not_supported` for `/anthropic/v1/models`; that route is intentionally not exposed.
- **Anthropic models are only available on AI Foundry in select regions** (currently `eastus2`); this is a Foundry availability constraint, not a deployment choice. Populate Anthropic-format entries only in the `modelDeployments[i]` whose paired `regions[i].name` hosts them.
- **APIM authenticates to AI Foundry via system-assigned managed identity** (no API keys to backends). End-users authenticate to APIM via APIM subscription keys.
- **Private networking**: AI Foundry public access is disabled when a `subnetId` is provided. Three private DNS zones are required: `privatelink.openai.azure.com`, `privatelink.cognitiveservices.azure.com`, `privatelink.services.ai.azure.com`.
- **Custom TLS**: Certificates must be stored as **secrets** (not certificates) in Key Vault. A user-assigned managed identity is created and granted Key Vault Secrets User *before* APIM is deployed to solve the chicken-and-egg problem.
- **IP filtering**: All three APIM policies share an inbound `<ip-filter action="allow">` block populated at deploy time from the `allowedClientIps` parameter in the bicepparam files. Entries may be bare IPv4 addresses or CIDR ranges (CIDR is expanded via `parseCidr().firstUsable`/`lastUsable`, so the network and broadcast addresses are excluded). Typical contents are your client network range plus any provider-side egress IPs you need to allow (for example, the Anthropic egress IPs needed for `/anthropic/*` traffic on Foundry). The policy XML files contain a sentinel `__ALLOWED_CLIENT_IPS__` token, not a live IP list — `aifapim.bicep` substitutes it during compilation.

## Module layout

```
aifapim.bicep                           # Orchestrator — start reading here
aifapim.example.bicepparam              # Parameter template — copy to aifapim-<env>.bicepparam and customize
llm-token-usage-workbook.example.bicep  # Reference snapshot only — NOT deployed (canonical in aifapim-config)
modules/
  aif.bicep                     # AI Foundry account + private endpoint
  aif-deployments.bicep         # Model deployments (sub-module; avoids race on account provisioning)
  api-management-private.bicep  # APIM instance, custom domains, CA certs
  api.bicep                     # All three APIs, backends, product, diagnostics
  app-insights.bicep            # Application Insights
  cognitive-services-role.bicep # Cognitive Services / AI User RBAC for APIM system identity
  event-hub.bicep               # Event Hub for APIM logging
  keyvault-role.bicep           # Key Vault RBAC for APIM user-assigned identity
  llm-latency-alerts.bicep      # Scheduled-query latency alerts on ApiManagementGatewayLogs
  log-analytics-workspace.bicep # Log Analytics workspace
  network.bicep                 # APIM subnet (added to regions[0] vnet)
  private-dns-zone.bicep        # Private DNS zone for AI Foundry endpoints
  role.bicep                    # Generic role-assignment helper
  vnet.bicep                    # Virtual network
apim_policies/                  # APIM policy XML (loaded inline via loadTextContent)
api_definitions/                # OpenAPI specs (loaded inline via loadTextContent):
                                #   AzureOpenAI_inference_2024-10-21.yaml  (root API; vendored from azure-rest-api-specs)
                                #   AzureOpenAI_v1_Messages_OpenAPI.json   (v1 Messages API)
                                #   AzureAnthropic_OpenAPI.json            (Anthropic Messages API)
resources/                      # User-supplied CA PEMs loaded via loadTextContent
                                # in the bicepparam file (intermediateCaCert /
                                # rootCaCert params). Gitignored except .gitkeep.
```

## Policies and API specs are loaded inline

`aifapim.bicep` uses `loadTextContent(...)` to embed policy XML and OpenAPI specs at compile time. Editing a file in `apim_policies/` or `api_definitions/` requires a new `az deployment group create` to take effect — there is no live reload.

The same applies to `llm-token-usage-workbook.bicep`: the workbook JSON is built inline from `var workbookContent` and embedded as `serializedData`. Workbook deploys are **in-place upserts** keyed by `guid(resourceGroup().id, workbookDisplayName)`, so the workbook resource GUID and Azure Portal URL/bookmarks are preserved across redeploys. Any change to the embedded queries, parameters, or display elements requires a fresh `az deployment group create -f llm-token-usage-workbook.bicep …` per environment — there is no auto-propagation from a `git pull` until you redeploy.

Historical gotcha (2026-06): commit `b0c4b86` fixed the workbook to scope queries at the Log Analytics workspace (`microsoft.operationalinsights/workspaces` + `crossComponentResources`) instead of the App Insights component, but the fix was deployed to dev only. Prod's portal-rendered workbook stayed stuck on the pre-fix `microsoft.insights/components` scope which cannot resolve `AppMetrics`, producing `'where' operator: Failed to resolve table or column expression named 'AppMetrics'` on every tile. Diagnose by REST-GETting `https://management.azure.com/.../workbooks/{guid}?api-version=2023-06-01&canFetchContent=true` and inspecting `properties.serializedData.items[*].content.{resourceType,crossComponentResources}`. Fix: redeploy via the command in the "Workbook only" section above.

All three OpenAPI specs are embedded from local files in `api_definitions/`. The Azure OpenAI data-plane inference spec is a vendored copy of the upstream stable `2024-10-21/inference.yaml` from the Azure REST API specs repo, pinned locally for deterministic deploys (deploys no longer depend on github.com being reachable). The local copy is augmented with `/models` and `/models/{model_id}` listing operations, which are not part of the upstream data-plane spec.

### Refreshing the vendored AOAI spec

To pull a newer upstream `inference.yaml`:

```bash
curl -sS -o api_definitions/AzureOpenAI_inference_2024-10-21.yaml \
  https://raw.githubusercontent.com/Azure/azure-rest-api-specs/refs/heads/main/specification/cognitiveservices/data-plane/AzureOpenAI/inference/stable/2024-10-21/inference.yaml
```

Then re-apply the local `/models` and `/models/{model_id}` path additions (they are not in upstream) and redeploy. Diff against the previous version before committing to confirm no unexpected upstream operation changes.

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
   chain is documented inline at each resource. The edges look redundant
   under `parent:` to the bicep linter — `parent:` is a referential edge,
   `dependsOn:` is what ARM uses to order the actual control-plane writes.
   Do NOT remove them without a replacement serialization strategy. The
   one place this trips the linter (`openaiV1MessagesApiPolicy` depending
   on its own parent API) carries an inline `#disable-next-line`.

Tradeoff: deploys are slower (sequential child writes against a single
APIM unit) in exchange for determinism. On Standard/Premium tiers with
multi-unit redundancy this race does not occur and the chaining is a
no-op cost-wise; the pinning is also harmless on those tiers.

## Token usage analytics quirks (verified on Developer SKU)

- **Anthropic completion tokens are always 0 in BOTH `AppMetrics.Completion Tokens` AND `ApiManagementGatewayLlmLog.CompletionTokens`** — streaming and non-streaming alike. APIM's classic-tier LLM diagnostic does not parse `usage.output_tokens` from Anthropic Messages API responses. The Anthropic policy XML (`apim_policies/Anthropic_Policy-Managed_Identity_with_Retry_MultiRegion.xml`) compensates with an `<outbound>` `<emit-metric>` block that reads `usage.output_tokens` from the response body and emits an `Anthropic Completion Tokens` custom metric (namespace = the configured `apimProductName`).
- **Anthropic streaming completion tokens remain unmeasurable**. The `<outbound>` `<emit-metric>` block is gated on a `requestIsStream` flag captured in `<inbound>`; SSE-streamed responses cannot be parsed as a single JSON object via `context.Response.Body.As<JObject>()`. Streaming Anthropic rows in the workbook show `Completion = 0`. No workaround on classic-tier APIM.
- **Anthropic streaming `ModelName` is always empty in `LlmLog`**. Use `DeploymentName` from the same row or `Properties.Model` from `AppMetrics` (the `<llm-emit-token-metric>` policy on the Anthropic API extracts the model from the request body and emits it as a dimension).
- Custom policy metrics (`<llm-emit-token-metric>` dimensions and the explicit `Anthropic Completion Tokens` emit) all land in `AppMetrics` under the namespace given by `apimProductName` (substituted into the policy XML at deploy time via the `__METRIC_NAMESPACE__` sentinel).
- These are Developer SKU (classic tier) limitations; v2 tiers may differ.

## Foundry diagnostics

Each `Microsoft.CognitiveServices/accounts` (AI Foundry) account sends `Audit`, `AzureOpenAIRequestUsage`, and `AllMetrics` to the in-stack Log Analytics workspace (`law-${unique}`) by default. This provides Foundry-side observability that is independent of APIM — useful for traffic that bypasses the gateway (e.g., Entra-ID-authenticated direct callers, internal Foundry portal usage) and for management-plane audit. The verbose `RequestResponse` (full request/response bodies) and `Trace` (internal traces) categories are off by default; flip them on per-deployment via the bicep params `aifDiagnosticsEnableRequestResponse=true` and `aifDiagnosticsEnableTrace=true` when troubleshooting.

Foundry logs land in the `AzureDiagnostics` table — distinct from the APIM-managed `ApiManagementGatewayLogs` / `ApiManagementGatewayLlmLog` / `AppMetrics` tables — and can be queried with:

```kusto
AzureDiagnostics
| where TimeGenerated > ago(1h)
| where ResourceProvider == "MICROSOFT.COGNITIVESERVICES"
| summarize count() by Category, Resource, OperationName
```

## OpenCode configuration

`examples/opencode.json` is a ready-to-use OpenCode config. The two providers (`aifapim-openapi`, `aifapim-anthropic`) read `AIFAPIM_HOST` and `AIFAPIM_API_KEY` from the environment. The `apiKey` field in the config is intentionally set to `"dummy"` — authentication is via the `x-api-key` header.

```bash
export AIFAPIM_HOST=<gateway-hostname>
export AIFAPIM_API_KEY=<subscription-key>
cp examples/opencode.json opencode.json
opencode
```

Note: the `aifapim-openapi` provider's `baseURL` points at `https://{AIFAPIM_HOST}/openai/v1`, which only exposes the OpenAI **Responses API** (`POST /v1/responses`) — Chat Completions is not proxied at that path. Verified empirically against opencode 1.14.41 + bundled `@ai-sdk/openai`: requests route to `POST /openai/v1/responses` (HTTP 200), not `/v1/chat/completions` (which would 404), for both AI-SDK-known model ids (e.g. `gpt-4.1-mini`) and custom deployment names (e.g. `my-custom-deployment-name`). If a future opencode/AI-SDK upgrade ever falls back to `/v1/chat/completions`, switch the `aifapim-openapi` provider to `"npm": "@ai-sdk/openai-compatible"` or pin a known-good `@ai-sdk/openai` version.

## Resource naming

All shared resources use a deterministic suffix: `uniqueString(resourceGroup().id, subscription().id)`. The APIM service name is `apim-<unique>`. Any out-of-tree subscription provisioning must target the same resource group so it can resolve the APIM service by this naming pattern.

## Verification via examples/test-apim.py

There is no automated test suite or CI. Post-deploy verification is driven by a single smoke-test script: `examples/test-apim.py`.

`examples/test-apim.py` exercises every public API surface using a subscription key from `AIFAPIM_API_KEY`:

- root API: `client.chat.completions.create` against `{endpoint}/deployments/{deployment}` (classic AOAI)
- v1 Messages API: `client.responses.create` against `{endpoint}/openai/v1/`
- Anthropic API: `client.messages.create` against `{endpoint}/anthropic`

Reads `AIFAPIM_HOST` and `AIFAPIM_API_KEY` from the environment; raises `KeyError` if either is unset. Set them to your dev or prod gateway hostname and a valid subscription key before running. No assertions — visual inspection of output is the success criterion.

### Running it

The preferred invocation uses the bundled pixi environment (`examples/pixi.toml`), which pins `openai`, `anthropic`, and `rich` from conda-forge and exposes a single `example` task:

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

1. Confirm `az deployment group create … --parameters aifapim-<env>.bicepparam` returned `Succeeded`.
2. Pick deployment names that actually exist in your environment's parameter file — the model list changes over time:
   ```bash
   grep -E "^\s+name:" aifapim-<env>.bicepparam
   ```
3. Update the `__main__` block in `examples/test-apim.py` if the hard-coded model names are stale, then:
   ```bash
   export AIFAPIM_HOST=<your-dev-gateway>
   export AIFAPIM_API_KEY=<dev-subscription-key>
   cd examples && pixi run example
   # alternative without pixi:
   #   python examples/test-apim.py
   ```
   Every `run_chat`, `run_chat_v1`, `run_anthropic`, and `run_embedding_v1` call should print a coherent answer (or, for embeddings, a vector dimension and prompt-token count).
4. Smoke-test the `/models` listing routes added to all three APIs:
   ```bash
   curl -sS "https://$AIFAPIM_HOST/openai/v1/models"            -H "x-api-key: $AIFAPIM_API_KEY" | jq '.data[].id'
   curl -sS "https://$AIFAPIM_HOST/models?api-version=2024-10-21" -H "x-api-key: $AIFAPIM_API_KEY" | jq '.data[].id'
   ```
   Both must return 200 with a non-empty `data` array. Foundry intentionally does not proxy `/anthropic/v1/models` (returns 404 `api_not_supported`) — do not test that route.
5. Tail `ApiManagementGatewayLogs` in Log Analytics (workspace `law-<unique>`) for the last 15 minutes and confirm no unexpected 4xx/5xx:
   ```kusto
   ApiManagementGatewayLogs
   | where TimeGenerated > ago(15m)
   | where ResponseCode >= 400
   | project TimeGenerated, ApiId, OperationId, Method, Url, ResponseCode, BackendResponseCode
   | order by TimeGenerated desc
   ```

Failure of any of the above is a no-go for promotion to prod. Re-running `examples/test-apim.py` with `AIFAPIM_HOST=<your-prod-gateway>` and a prod subscription key constitutes the prod smoke test.
