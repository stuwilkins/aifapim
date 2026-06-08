@description('Private DNS zone name, e.g. privatelink.openai.azure.com.')
param zoneName string

@description('Virtual network resource ID to link the zone to.')
param vnetId string

@description('Tags to apply to the private DNS zone.')
param tags object = {}

resource privateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: zoneName
  location: 'global'
  tags: tags
}

resource vnetLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: privateDnsZone
  name: 'vnet-link'
  location: 'global'
  tags: tags
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: vnetId
    }
  }
}

output zoneId string = privateDnsZone.id
output zoneName string = privateDnsZone.name
