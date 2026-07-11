@description('Azure region for the virtual network.')
param location string

@description('Name of the virtual network.')
param name string = 'apim-ai-network'

@description('Address space for the virtual network.')
param addressPrefixes array = [
  '10.0.0.0/16'
]

@description('Subnets to create within the virtual network.')
param subnets array = [
  {
    name: 'openai'
    addressPrefix: '10.0.0.0/24'
  }
]

@description('Tags to apply to the virtual network.')
param tags object = {}

// Declare the vnet WITHOUT inline subnets so that redeploys of this module
// do not remove subnets that are managed externally (e.g. the `apim` subnet
// created by modules/network.bicep for the APIM gateway). Subnets owned by
// this module are created as separate child resources below, and serialized
// via dependsOn to avoid concurrent-update conflicts on the same vnet.
resource vnet 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: addressPrefixes
    }
  }
}

resource defaultNsg 'Microsoft.Network/networkSecurityGroups@2023-11-01' = {
  name: 'nsg-${name}'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        // Allow outbound HTTPS to private endpoints in the VNet/peered VNets.
        // Private endpoint IPs fall under the VirtualNetwork service tag and
        // would otherwise be blocked by Deny_Lateral_Outbound_VirtualNetwork
        // (priority 4096) below. Do not remove.
        name: 'Allow_Outbound_To_Private_Endpoints'
        properties: {
          description: 'Allow outbound HTTPS to private endpoints in the VNet/peered VNets.'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '443'
          sourceAddressPrefix: 'VirtualNetwork'
          destinationAddressPrefix: 'VirtualNetwork'
          access: 'Allow'
          priority: 300
          direction: 'Outbound'
        }
      }
      {
        name: 'Deny_Lateral_Outbound_VirtualNetwork'
        properties: {
          description: 'Deny outbound lateral management connections from non-management hosts (Azure.NSG.LateralTraversal).'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: 'VirtualNetwork'
          destinationAddressPrefix: 'VirtualNetwork'
          access: 'Deny'
          priority: 4096
          direction: 'Outbound'
        }
      }
    ]
  }
}

@batchSize(1)
resource subnetResources 'Microsoft.Network/virtualNetworks/subnets@2023-11-01' = [for subnet in subnets: {
  parent: vnet
  name: subnet.name
  properties: {
    addressPrefix: subnet.addressPrefix
    defaultOutboundAccess: false
    networkSecurityGroup: {
      id: defaultNsg.id
    }
  }
}]

output vnetName string = vnet.name
output vnetId string = vnet.id
output subnetIds object = toObject(subnets, subnet => subnet.name, subnet => resourceId('Microsoft.Network/virtualNetworks/subnets', vnet.name, subnet.name))
