@description('Name of the storage account that holds the request bodies.')
param storageAccountName string

@description('Name of the container the gateway writes request bodies to.')
param containerName string = 'llm-requests'

param location string

param tags object = {}

@description('Subnet resource ID for the blob private endpoint.')
param subnetId string

@description('Resource ID of the privatelink.blob.core.windows.net private DNS zone.')
param blobPrivateDnsZoneId string

@description('Region of the private endpoint. Must be the region of the subnet virtual network.')
param privateEndpointLocation string = location

@description('Public IPv4 addresses or CIDR ranges allowed to read the blobs, for example administrator workstations. Leave empty to allow private endpoint access only (public network access is then disabled).')
param readerIps array = []

@description('Retention period, in days, of the time-based immutability policy (WORM). The maximum Azure allows is 146000 (about 400 years). The policy is created unlocked; locking is irreversible and is a separate, deliberate step (see aifapim-config request-log/lock-worm.sh).')
@minValue(1)
@maxValue(146000)
param immutabilityPeriodDays int = 146000

@description('Whether this template creates and updates the immutability policy. Set to false once the policy has been locked: a locked policy can only be extended, so redeploying it unchanged could fail.')
param manageImmutabilityPolicy bool = true

@description('Move blobs to the Cold tier this many days after creation.')
@minValue(1)
param coldAfterDays int = 7

@description('Move blobs to the Archive tier this many days after creation. Must be later than coldAfterDays.')
@minValue(2)
param archiveAfterDays int = 90

@description('Resource ID of a Log Analytics workspace that receives blob read, write and delete audit logs (never the request content). Leave empty to skip.')
param auditWorkspaceId string = ''

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageAccountName
  location: location
  tags: tags
  kind: 'StorageV2'
  sku: {
    name: 'Standard_LRS'
  }
  properties: {
    accessTier: 'Hot'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    defaultToOAuthAuthentication: true
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    publicNetworkAccess: empty(readerIps) ? 'Disabled' : 'Enabled'
    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'None'
      ipRules: [for ip in readerIps: {
        value: ip
        action: 'Allow'
      }]
    }
  }
}

// Soft delete is a safety net for the settings and the container; the request
// bodies themselves are protected by the immutability policy below.
resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storageAccount
  name: 'default'
  properties: {
    deleteRetentionPolicy: {
      enabled: true
      days: 7
    }
    containerDeleteRetentionPolicy: {
      enabled: true
      days: 7
    }
  }
}

resource container 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: containerName
  properties: {
    publicAccess: 'None'
  }
}

// Time-based retention (WORM) on the container. Blobs can be created and read
// but never changed or deleted until the period ends. The policy is created
// Unlocked, so it can still be adjusted while the pipeline is validated;
// locking cannot be undone and is done by an operator script.
resource immutabilityPolicy 'Microsoft.Storage/storageAccounts/blobServices/containers/immutabilityPolicies@2023-05-01' = if (manageImmutabilityPolicy) {
  parent: container
  name: 'default'
  properties: {
    immutabilityPeriodSinceCreationInDays: immutabilityPeriodDays
    allowProtectedAppendWrites: false
  }
}

// Tiering only: there is no delete action. Tier changes are allowed under an
// immutability policy.
resource lifecycle 'Microsoft.Storage/storageAccounts/managementPolicies@2023-05-01' = {
  parent: storageAccount
  name: 'default'
  properties: {
    policy: {
      rules: [
        {
          name: 'tier-request-bodies'
          enabled: true
          type: 'Lifecycle'
          definition: {
            filters: {
              blobTypes: [
                'blockBlob'
              ]
              prefixMatch: [
                '${containerName}/'
              ]
            }
            actions: {
              baseBlob: {
                tierToCold: {
                  daysAfterCreationGreaterThan: coldAfterDays
                }
                tierToArchive: {
                  daysAfterCreationGreaterThan: archiveAfterDays
                }
              }
            }
          }
        }
      ]
    }
  }
}

module blobPrivateEndpoint 'storage-private-endpoint.bicep' = {
  name: 'pe-${storageAccountName}-blob'
  params: {
    name: 'pe-${storageAccountName}-blob'
    location: privateEndpointLocation
    tags: tags
    storageAccountId: storageAccount.id
    groupId: 'blob'
    subnetId: subnetId
    privateDnsZoneId: blobPrivateDnsZoneId
  }
}

resource auditSettings 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = if (!empty(auditWorkspaceId)) {
  scope: blobService
  name: 'audit-to-law'
  properties: {
    workspaceId: auditWorkspaceId
    logs: [
      {
        category: 'StorageRead'
        enabled: true
      }
      {
        category: 'StorageWrite'
        enabled: true
      }
      {
        category: 'StorageDelete'
        enabled: true
      }
    ]
  }
}

output id string = storageAccount.id
output name string = storageAccount.name
output blobEndpoint string = storageAccount.properties.primaryEndpoints.blob
output containerName string = container.name
