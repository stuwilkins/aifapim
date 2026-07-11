// Scheduled log-search alerts on ApiManagementGatewayLogs.
//
// Replaces the previous classic metricAlert on App Insights `requests/duration`,
// which fired ~daily because its 3-unit threshold was effectively ~3 ms and
// any real LLM request exceeded it. Two split alerts give meaningful coverage:
//
//   1. APIM-Overhead-Latency  - p95 of (TotalTime - BackendTime) > 1500 ms
//      Detects gateway-level slowness independent of LLM backend latency.
//
//   2. LLM-Latency             - per-ApiId p95 of TotalTime > 90 s
//      Detects genuinely stuck/runaway requests; p99 today is ~55-62 s, so
//      90 s comfortably exceeds normal Claude/GPT completion times.
//
// Both run KQL against the existing Log Analytics workspace and route to the
// existing action group (eag-<unique>). Severity is 2 (Warning).

@description('Azure region for the scheduled query rule resources. Must match the Log Analytics workspace region.')
param location string

@description('Resource ID of the Log Analytics workspace that ingests ApiManagementGatewayLogs.')
param workspaceResourceId string

@description('Resource ID of the action group to route alerts to (typically eag-<unique>).')
param actionGroupId string

@description('Unique resource-name suffix used elsewhere in the template (matches uniqueString(...) in aifapim.bicep).')
param uniqueSuffix string

@description('Threshold (milliseconds) on p95 of APIM gateway overhead (TotalTime - BackendTime).')
param apimOverheadThresholdMs int = 1500

@description('Threshold (milliseconds) on p95 of total request duration per ApiId.')
param llmLatencyThresholdMs int = 90000

@description('Evaluation window (KQL ago(...) horizon and Azure Monitor windowSize).')
param windowSize string = 'PT15M'

@description('How often the rule is evaluated.')
param evaluationFrequency string = 'PT5M'

@description('Alert severity (0 = Critical, 2 = Warning, 4 = Verbose).')
param severity int = 2

@description('Tags to apply to alert resources.')
param tags object = {}

// ---------------------------------------------------------------------------
// Alert 1: APIM gateway-overhead latency
// ---------------------------------------------------------------------------
resource apimOverheadAlert 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = {
  name: 'APIM-Overhead-Latency-${uniqueSuffix}'
  location: location
  tags: tags
  properties: {
    description: 'p95 of APIM gateway overhead (TotalTime - BackendTime) exceeded ${apimOverheadThresholdMs} ms over the last ${windowSize}.'
    enabled: true
    severity: severity
    evaluationFrequency: evaluationFrequency
    windowSize: windowSize
    scopes: [
      workspaceResourceId
    ]
    criteria: {
      allOf: [
        {
          query: '''
ApiManagementGatewayLogs
| where ResponseCode < 500
| extend apimOverhead = TotalTime - BackendTime
| where isnotnull(apimOverhead)
| summarize p95 = percentile(apimOverhead, 95), n = count()
| where n >= 20
| project p95
'''
          timeAggregation: 'Maximum'
          metricMeasureColumn: 'p95'
          operator: 'GreaterThan'
          threshold: apimOverheadThresholdMs
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    actions: {
      actionGroups: [
        actionGroupId
      ]
    }
    autoMitigate: true
  }
}

// ---------------------------------------------------------------------------
// Alert 2: LLM end-to-end latency, per ApiId
// ---------------------------------------------------------------------------
resource llmLatencyAlert 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = {
  name: 'LLM-Latency-${uniqueSuffix}'
  location: location
  tags: tags
  properties: {
    description: 'p95 of LLM end-to-end TotalTime exceeded ${llmLatencyThresholdMs} ms over the last ${windowSize} for one of the AI APIs.'
    enabled: true
    severity: severity
    evaluationFrequency: evaluationFrequency
    windowSize: windowSize
    scopes: [
      workspaceResourceId
    ]
    criteria: {
      allOf: [
        {
          query: '''
ApiManagementGatewayLogs
| where ApiId in ("anthropic-service-api", "azure-openai-v1-messages-api", "azure-openai-service-api")
| where ResponseCode < 500
| summarize p95 = percentile(TotalTime, 95), n = count() by ApiId
| where n >= 10
| project ApiId, p95
'''
          timeAggregation: 'Maximum'
          metricMeasureColumn: 'p95'
          dimensions: [
            {
              name: 'ApiId'
              operator: 'Include'
              values: [
                '*'
              ]
            }
          ]
          operator: 'GreaterThan'
          threshold: llmLatencyThresholdMs
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    actions: {
      actionGroups: [
        actionGroupId
      ]
    }
    autoMitigate: true
  }
}
