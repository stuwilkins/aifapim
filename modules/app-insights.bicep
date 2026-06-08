param workspaceName string
param applicationInsightsName string
param location string
param uniqueSuffix string

@description('Display name for the alert email receiver.')
param alertEmailName string

@description('Email address for the alert action group.')
param alertEmailAddress string

resource workspace 'Microsoft.OperationalInsights/workspaces@2020-10-01' existing =  {
  name: workspaceName
}

resource applicationInsights 'Microsoft.Insights/components@2020-02-02-preview' = {
  name: applicationInsightsName
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: workspace.id
  }
}

resource emailActionGroup 'microsoft.insights/actionGroups@2019-06-01' = {
  name: 'eag-${uniqueSuffix}'
  location: 'global'
  properties: {
    groupShortName: 'string'
    enabled: true
    emailReceivers: [
      {
        name: alertEmailName
        emailAddress: alertEmailAddress
        useCommonAlertSchema: true
      }
    ]
  }
}

output aiId string = applicationInsights.id
output actionGroupId string = emailActionGroup.id
