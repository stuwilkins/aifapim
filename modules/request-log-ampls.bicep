@description('Unique suffix used in resource names.')
param uniqueSuffix string

param tags object = {}

@description('Region of the private endpoint. Must be the region of the subnet virtual network.')
param location string

@description('Resource ID of the virtual network the private DNS zones are linked to.')
param vnetId string

@description('Subnet resource ID for the Azure Monitor private endpoint.')
param privateEndpointSubnetId string

@description('Resource ID of the privatelink.blob.core.windows.net zone, which Azure Monitor private link also uses (the agent solution packs are served from blob storage).')
param blobPrivateDnsZoneId string

@description('Azure Monitor resources to put in the scope: each is { name, id } for a data collection endpoint, a Log Analytics workspace or an Application Insights component.')
param scopedResources array

// An Azure Monitor private link scope (AMPLS) gives the function a private
// path to the Logs Ingestion endpoint. BNL policy denies public IP addresses,
// so a NAT gateway is not possible, and the AIFAPIM VNets are not connected to
// the BNL hub that provides internet egress.
//
// One scope per DNS: creating the private endpoint writes private records for
// the Azure Monitor names into the zones below, for every client that uses
// this VNet's DNS. The zones are linked to this one VNet only. Both access modes
// are Open, so Azure Monitor resources that are not in the scope (for example
// ones belonging to other stacks) stay reachable over the public network.
var monitorZones = [
  'privatelink.monitor.azure.com'
  'privatelink.oms.opinsights.azure.com'
  'privatelink.ods.opinsights.azure.com'
  'privatelink.agentsvc.azure-automation.net'
]

resource scope 'microsoft.insights/privateLinkScopes@2021-07-01-preview' = {
  name: 'ampls-llmreq-${uniqueSuffix}'
  location: 'global'
  tags: tags
  properties: {
    accessModeSettings: {
      queryAccessMode: 'Open'
      ingestionAccessMode: 'Open'
    }
  }
}

// Scoped resources on one scope are written one at a time: concurrent writes
// to the same scope can fail with a conflict.
@batchSize(1)
resource scopedResource 'microsoft.insights/privateLinkScopes/scopedResources@2021-07-01-preview' = [for r in scopedResources: {
  parent: scope
  name: r.name
  properties: {
    linkedResourceId: r.id
  }
}]

module zones 'private-dns-zone.bicep' = [for zone in monitorZones: {
  name: 'pdz-${replace(zone, '.', '-')}'
  params: {
    zoneName: zone
    vnetId: vnetId
    tags: tags
  }
}]

resource privateEndpoint 'Microsoft.Network/privateEndpoints@2023-11-01' = {
  name: 'pe-ampls-llmreq-${uniqueSuffix}'
  location: location
  tags: tags
  properties: {
    subnet: {
      id: privateEndpointSubnetId
    }
    privateLinkServiceConnections: [
      {
        name: 'plsc-ampls-llmreq-${uniqueSuffix}'
        properties: {
          privateLinkServiceId: scope.id
          groupIds: [
            'azuremonitor'
          ]
        }
      }
    ]
  }
  dependsOn: [
    scopedResource
  ]
}

// The four Azure Monitor zones plus the blob zone.
var monitorZoneIds = [for zone in monitorZones: resourceId('Microsoft.Network/privateDnsZones', zone)]
var allZoneIds = concat(monitorZoneIds, [blobPrivateDnsZoneId])

resource zoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-11-01' = {
  parent: privateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [for (zoneId, i) in allZoneIds: {
      name: 'config-${i}'
      properties: {
        privateDnsZoneId: zoneId
      }
    }]
  }
  dependsOn: [
    zones
  ]
}

output scopeId string = scope.id
output scopeName string = scope.name
