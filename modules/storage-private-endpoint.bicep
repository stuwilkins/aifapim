@description('Name of the private endpoint.')
param name string

param location string

param tags object = {}

@description('Resource ID of the storage account.')
param storageAccountId string

@description('Storage sub-resource the endpoint reaches: blob, queue or table.')
@allowed([
  'blob'
  'queue'
  'table'
])
param groupId string

@description('Subnet resource ID for the private endpoint.')
param subnetId string

@description('Resource ID of the matching privatelink.<groupId>.core.windows.net private DNS zone.')
param privateDnsZoneId string

resource privateEndpoint 'Microsoft.Network/privateEndpoints@2023-11-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    subnet: {
      id: subnetId
    }
    privateLinkServiceConnections: [
      {
        name: 'plsc-${name}'
        properties: {
          privateLinkServiceId: storageAccountId
          groupIds: [
            groupId
          ]
        }
      }
    ]
  }
}

resource privateDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-11-01' = {
  parent: privateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'config-0'
        properties: {
          privateDnsZoneId: privateDnsZoneId
        }
      }
    ]
  }
}
