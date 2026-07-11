param location string
param logAnalyticsName string

@minValue(30)
@maxValue(730)
param retentionInDays int = 90
param tags object = {}

resource logAnalyticcsWorkspace 'Microsoft.OperationalInsights/workspaces@2020-08-01' = {
  name: logAnalyticsName
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: retentionInDays
  }
}

output id string = logAnalyticcsWorkspace.id
output name string = logAnalyticcsWorkspace.name
