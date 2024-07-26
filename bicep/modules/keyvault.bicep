param region string
param allowedUserObjID string
param whitelist_ips array

var kvName = substring('keyVault${uniqueString(resourceGroup().id)}', 0, 16)

resource kv 'Microsoft.KeyVault/vaults@2023-02-01' = {
  name: kvName
  location: region
  properties: {
    sku: {
      name: 'standard'
      family: 'A'
    }
    accessPolicies: [
      {
        tenantId: subscription().tenantId
        objectId: allowedUserObjID
        permissions: {
          secrets: [
            'get'
            'list'
            'set'
          ]
        }
      }
    ]
    tenantId: subscription().tenantId
    enabledForDeployment: true
    enabledForTemplateDeployment: true
    enabledForDiskEncryption: true
    softDeleteRetentionInDays: 7
    enableSoftDelete: true
    enablePurgeProtection: true
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Deny'
      ipRules: map(whitelist_ips, ipaddr => { value: ipaddr })
    }
  }
}

output name string = kv.name
