// Standalone Azure Monitor Workbook for LLM Token Usage Analytics
//
// Deploys a workbook that visualizes token usage for all LLM APIs (AOAI, OpenAI v1
// Messages, Anthropic) with proper Model dimension, sourcing data from AppMetrics
// where Model is reliably populated.
//
// Usage:
//   az deployment group create \
//     -g <resource-group> \
//     -f llm-token-usage-workbook.bicep \
//     -p applicationInsightsId=<app-insights-resource-id> \
//        logAnalyticsWorkspaceId=<log-analytics-workspace-resource-id>
//
// After deployment, find the workbook in:
//   Azure Portal → Application Insights → Workbooks → "LLM Token Usage"
//
// Why two IDs: AppMetrics is a workspace-scoped table. The workbook is associated
// with the App Insights component (so it surfaces in the AI Workbooks blade), but
// each query targets the Log Analytics workspace directly via crossComponentResources
// because the component query scope cannot resolve AppMetrics.

param location string = resourceGroup().location

@description('Resource ID of the Application Insights component to associate the workbook with.')
param applicationInsightsId string

@description('Resource ID of the Log Analytics workspace backing the Application Insights component. Required because AppMetrics is a workspace-scoped table that the App Insights component scope cannot resolve at query time.')
param logAnalyticsWorkspaceId string

@description('Display name for the workbook.')
param workbookDisplayName string = 'LLM Token Usage'

// Generate a stable GUID for the workbook based on RG and name
var workbookId = guid(resourceGroup().id, workbookDisplayName)

// Workbook JSON structure
// Each item in the items array is a workbook element (parameter, query, text, etc.)
var workbookContent = {
  version: 'Notebook/1.0'
  items: [
    // Section 1: Title and description
    {
      type: 1
      content: {
        json: '''
## LLM Token Usage Analytics

This workbook visualizes token usage for LLM APIs published through Azure API Management, including Azure OpenAI and Anthropic models.

**Data Source**: `AppMetrics` table (workspace-based Application Insights). Receives custom metrics emitted by the `<llm-emit-token-metric>` / `<azure-openai-emit-token-metric>` policies (prompt tokens, plus completion tokens for OpenAI/Llama) and the Anthropic policy's `<outbound>` `<emit-metric>` block (`Anthropic Completion Tokens` for non-streaming Anthropic responses).

**Anthropic completion tokens** come from the `Anthropic Completion Tokens` custom metric emitted by the Anthropic policy's `<outbound>` block, which parses `usage.output_tokens` from non-streaming response bodies. The custom-namespace `Completion Tokens` value emitted by APIM auto-emit is always 0 for Anthropic (APIM's classic-tier LLM diagnostic does not extract `output_tokens` from Anthropic responses). **Anthropic streaming completion tokens remain unmeasurable on this APIM tier** — SSE response streams cannot be parsed as a single JSON object in `<outbound>`, so streaming Anthropic rows will show `Completion = 0`.

**Model Dimension**: Populated via explicit `<llm-emit-token-metric>` policies on each API, extracting the model name from the request body or URL path.

> Queries target the Log Analytics workspace directly (via `crossComponentResources`) and use a `union isfuzzy=true AppMetrics, (datatable(...) [])` schema-fallback so tiles render gracefully even if the table is renamed or its ingestion is paused. If every tile is empty after deployment, verify the `<llm-emit-token-metric>` policies are firing and that APIM's diagnostic logger targets this Application Insights component.
'''
      }
      name: 'text-title'
    }
    // Section 2: Time Range Parameter
    {
      type: 9
      content: {
        version: 'KqlParameterItem/1.0'
        parameters: [
          {
            id: 'timeRange'
            version: 'KqlParameterItem/1.0'
            name: 'TimeRange'
            type: 4
            isRequired: true
            value: {
              durationMs: 604800000 // 7 days in ms
            }
            typeSettings: {
              selectableValues: [
                { durationMs: 86400000, displayName: 'Last 24 hours' }
                { durationMs: 604800000, displayName: 'Last 7 days' }
                { durationMs: 2592000000, displayName: 'Last 30 days' }
              ]
              allowCustom: true
            }
            label: 'Time Range'
          }
        ]
        style: 'pills'
        queryType: 0
      }
      name: 'parameters-timerange'
    }
    // Section 3: Summary Tiles
    {
      type: 1
      content: {
        json: '### Summary'
      }
      name: 'text-summary-header'
    }
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: '''
let promptCompletion =
    union isfuzzy=true
        AppMetrics,
        (datatable(TimeGenerated:datetime, Properties:dynamic, Name:string, Sum:real) [])
    | where TimeGenerated {TimeRange}
    | extend ApiId = tostring(Properties["API ID"])
    | extend TokenType = case(
          Name == "Prompt Tokens", "Prompt",
          Name == "Completion Tokens" and ApiId != "anthropic-service-api", "Completion",
          Name == "Anthropic Completion Tokens", "Completion",
      "Skip")
| where TokenType in ("Prompt", "Completion")
| summarize Tokens = sum(Sum) by TokenType;
let total = promptCompletion | summarize Tokens = sum(Tokens) | extend TokenType = "Total";
promptCompletion
| union total
| order by case(TokenType == "Prompt", 1, TokenType == "Completion", 2, 3) asc
'''
        size: 4
        timeContextFromParameter: 'TimeRange'
        queryType: 0
        resourceType: 'microsoft.operationalinsights/workspaces'
        crossComponentResources: [
          logAnalyticsWorkspaceId
        ]
        visualization: 'tiles'
        tileSettings: {
          titleContent: {
            columnMatch: 'TokenType'
            formatter: 1
          }
          leftContent: {
            columnMatch: 'Tokens'
            formatter: 12
            numberFormat: {
              unit: 0
              options: {
                style: 'decimal'
                maximumFractionDigits: 0
              }
            }
          }
          showBorder: true
        }
      }
      name: 'query-summary-tiles'
    }
    // Section 4: Token Usage by API
    {
      type: 1
      content: {
        json: '### Token Usage by API'
      }
      name: 'text-by-api-header'
    }
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: '''
union isfuzzy=true
    AppMetrics,
    (datatable(TimeGenerated:datetime, Properties:dynamic, Name:string, Sum:real) [])
| where TimeGenerated {TimeRange}
| extend ApiId = tostring(Properties["API ID"])
| extend TokenType = case(
      Name == "Prompt Tokens", "Prompt",
      Name == "Completion Tokens" and ApiId != "anthropic-service-api", "Completion",
      Name == "Anthropic Completion Tokens", "Completion",
      "Skip")
| where TokenType in ("Prompt", "Completion") and isnotempty(ApiId)
| summarize
    Prompt = sumif(Sum, TokenType == "Prompt"),
    Completion = sumif(Sum, TokenType == "Completion")
    by ApiId
| extend Total = Prompt + Completion
| order by Total desc
'''
        size: 0
        timeContextFromParameter: 'TimeRange'
        queryType: 0
        resourceType: 'microsoft.operationalinsights/workspaces'
        crossComponentResources: [
          logAnalyticsWorkspaceId
        ]
        visualization: 'barchart'
        chartSettings: {
          xAxis: 'ApiId'
          yAxis: ['Prompt', 'Completion']
          group: null
          createOtherGroup: 0
          showLegend: true
        }
      }
      name: 'query-by-api'
    }
    // Section 5: Token Usage by Model (the key visualization)
    {
      type: 1
      content: {
        json: '### Token Usage by Model'
      }
      name: 'text-by-model-header'
    }
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: '''
union isfuzzy=true
    AppMetrics,
    (datatable(TimeGenerated:datetime, Properties:dynamic, Name:string, Sum:real) [])
| where TimeGenerated {TimeRange}
| extend ApiId = tostring(Properties["API ID"])
| extend Model = tostring(Properties["Model"])
| extend TokenType = case(
      Name == "Prompt Tokens", "Prompt",
      Name == "Completion Tokens" and ApiId != "anthropic-service-api", "Completion",
      Name == "Anthropic Completion Tokens", "Completion",
      "Skip")
| where TokenType in ("Prompt", "Completion") and isnotempty(Model)
| summarize
    Prompt = sumif(Sum, TokenType == "Prompt"),
    Completion = sumif(Sum, TokenType == "Completion")
    by Model
| extend Total = Prompt + Completion
| order by Total desc
'''
        size: 0
        timeContextFromParameter: 'TimeRange'
        queryType: 0
        resourceType: 'microsoft.operationalinsights/workspaces'
        crossComponentResources: [
          logAnalyticsWorkspaceId
        ]
        visualization: 'barchart'
        chartSettings: {
          xAxis: 'Model'
          yAxis: ['Prompt', 'Completion']
          group: null
          createOtherGroup: 0
          showLegend: true
        }
      }
      name: 'query-by-model'
    }
    // Section 6: Token Usage by Subscription (for billing)
    {
      type: 1
      content: {
        json: '### Token Usage by APIM Subscription'
      }
      name: 'text-by-subscription-header'
    }
    // Bar chart: Token usage by subscription (grouped Prompt/Completion)
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: '''
union isfuzzy=true
    AppMetrics,
    (datatable(TimeGenerated:datetime, Properties:dynamic, Name:string, Sum:real) [])
| where TimeGenerated {TimeRange}
| extend ApiId = tostring(Properties["API ID"])
| extend
    SubscriptionName = tostring(Properties["Subscription Name"]),
    SubscriptionId = tostring(Properties["Subscription ID"])
| extend TokenType = case(
      Name == "Prompt Tokens", "Prompt",
      Name == "Completion Tokens" and ApiId != "anthropic-service-api", "Completion",
      Name == "Anthropic Completion Tokens", "Completion",
      "Skip")
| where TokenType in ("Prompt", "Completion") and (isnotempty(SubscriptionName) or isnotempty(SubscriptionId))
| extend Subscription = iff(isnotempty(SubscriptionName), SubscriptionName, SubscriptionId)
| summarize
    Prompt = sumif(Sum, TokenType == "Prompt"),
    Completion = sumif(Sum, TokenType == "Completion")
    by Subscription
| extend Total = Prompt + Completion
| order by Total desc
'''
        size: 0
        timeContextFromParameter: 'TimeRange'
        queryType: 0
        resourceType: 'microsoft.operationalinsights/workspaces'
        crossComponentResources: [
          logAnalyticsWorkspaceId
        ]
        visualization: 'barchart'
        chartSettings: {
          xAxis: 'Subscription'
          yAxis: ['Prompt', 'Completion']
          group: null
          createOtherGroup: 0
          showLegend: true
        }
      }
      name: 'query-by-subscription-chart'
    }
    // Table: Detailed breakdown by subscription and model
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: '''
union isfuzzy=true
    AppMetrics,
    (datatable(TimeGenerated:datetime, Properties:dynamic, Name:string, Sum:real) [])
| where TimeGenerated {TimeRange}
| extend
    SubscriptionName = tostring(Properties["Subscription Name"]),
    SubscriptionId = tostring(Properties["Subscription ID"]),
    Model = tostring(Properties["Model"]),
    ApiId = tostring(Properties["API ID"])
| extend TokenType = case(
      Name == "Prompt Tokens", "Prompt",
      Name == "Completion Tokens" and ApiId != "anthropic-service-api", "Completion",
      Name == "Anthropic Completion Tokens", "Completion",
      "Skip")
| where TokenType in ("Prompt", "Completion") and (isnotempty(SubscriptionName) or isnotempty(SubscriptionId))
| extend Subscription = iff(isnotempty(SubscriptionName), SubscriptionName, SubscriptionId)
| summarize
    Prompt = sumif(Sum, TokenType == "Prompt"),
    Completion = sumif(Sum, TokenType == "Completion")
    by Subscription, Model
| extend Total = Prompt + Completion
| project Subscription, Model, Prompt, Completion, Total
| order by Total desc
'''
        size: 0
        timeContextFromParameter: 'TimeRange'
        queryType: 0
        resourceType: 'microsoft.operationalinsights/workspaces'
        crossComponentResources: [
          logAnalyticsWorkspaceId
        ]
        visualization: 'table'
        gridSettings: {
          sortBy: [
            { itemKey: 'Total', sortOrder: 2 }
          ]
        }
      }
      name: 'query-by-subscription-table'
    }
    // Section 7: Token Usage Over Time
    {
      type: 1
      content: {
        json: '### Token Usage Over Time'
      }
      name: 'text-over-time-header'
    }
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: '''
union isfuzzy=true
    AppMetrics,
    (datatable(TimeGenerated:datetime, Properties:dynamic, Name:string, Sum:real) [])
| where TimeGenerated {TimeRange}
| extend ApiId = tostring(Properties["API ID"])
| extend Model = tostring(Properties["Model"])
| extend TokenType = case(
      Name == "Completion Tokens" and ApiId != "anthropic-service-api", "Completion",
      Name == "Anthropic Completion Tokens", "Completion",
      "Skip")
| where TokenType == "Completion" and isnotempty(Model)
| summarize Tokens = sum(Sum) by bin(TimeGenerated, 1h), Model
| order by TimeGenerated asc
'''
        size: 0
        timeContextFromParameter: 'TimeRange'
        queryType: 0
        resourceType: 'microsoft.operationalinsights/workspaces'
        crossComponentResources: [
          logAnalyticsWorkspaceId
        ]
        visualization: 'linechart'
        chartSettings: {
          xAxis: 'TimeGenerated'
          yAxis: ['Tokens']
          group: 'Model'
          createOtherGroup: 0
          showLegend: true
        }
      }
      name: 'query-over-time'
    }
    // Section 8: Data Source Notes
    {
      type: 1
      content: {
        json: '''
---

### Data Source Notes

This workbook queries the `AppMetrics` table in the Log Analytics workspace backing the Application Insights component (via `crossComponentResources`). `AppMetrics` receives custom metrics emitted by:

- `<llm-emit-token-metric>` / `<azure-openai-emit-token-metric>` policies on the APIM LLM APIs — supply prompt tokens for all APIs, plus completion tokens for OpenAI/Llama APIs.
- The Anthropic policy's `<outbound>` `<emit-metric>` block — supplies `Anthropic Completion Tokens` for non-streaming Anthropic responses by parsing `usage.output_tokens` from the response body.

(The legacy `customMetrics` table is empty in workspace-based App Insights; all custom metrics now land in `AppMetrics`.)

**Why not use `ApiManagementGatewayLlmLog`?**

The `ApiManagementGatewayLlmLog` table is populated by APIM's built-in LLM diagnostic setting. On classic-tier APIM (Developer, Basic, Standard, Premium), this table has known limitations for Anthropic:

- `ModelName` column is **always empty** for Anthropic streaming (workaround: use `DeploymentName`).
- `CompletionTokens` column is **always 0** for Anthropic — both streaming and non-streaming. APIM's classic-tier diagnostic does not parse Anthropic Messages API response payloads.

These gaps are platform-side parser limitations. The Anthropic policy's `<outbound>` `<emit-metric>` block compensates by extracting `usage.output_tokens` from the response body directly. This only works for non-streaming responses; SSE-streamed Anthropic responses cannot be parsed in `<outbound>` and remain unmeasurable for completion tokens (rows show `Completion = 0`).

**Metric Families**

- `Prompt Tokens`, `Completion Tokens`, `Total Tokens` — emitted by `<llm-emit-token-metric>` / `<azure-openai-emit-token-metric>` policies (and APIM auto-emit) under the App Insights custom-metric namespace configured via `apimProductName` (substituted into the policy XML at deploy time). Used for OpenAI/Llama APIs (all token types) and for Anthropic **prompt** tokens.
- `Anthropic Completion Tokens` — emitted by the Anthropic policy's `<outbound>` `<emit-metric>` block under the same configured namespace. Used for Anthropic **completion** tokens on non-streaming responses only.

The workbook queries branch on `Properties["API ID"]` to pick the correct completion-token source per API.
'''
      }
      name: 'text-data-source-notes'
    }
  ]
  isLocked: false
}

// Serialize the workbook content to JSON string
var serializedData = string(workbookContent)

resource workbook 'Microsoft.Insights/workbooks@2022-04-01' = {
  name: workbookId
  location: location
  kind: 'shared'
  properties: {
    displayName: workbookDisplayName
    serializedData: serializedData
    version: '1.0'
    sourceId: applicationInsightsId
    category: 'workbook'
  }
}

output workbookResourceId string = workbook.id
output workbookName string = workbook.name
output applicationInsightsIdEcho string = applicationInsightsId
output logAnalyticsWorkspaceIdEcho string = logAnalyticsWorkspaceId
