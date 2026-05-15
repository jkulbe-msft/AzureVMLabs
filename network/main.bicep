metadata description = 'Deploys the virtual network infrastructure used by the AzureVMLabs demo environment. Two subnets are defined: NAT (for the Hyper-V host) and Azure-VMs (for the Domain Controller and any other Azure-hosted VMs). Nested VMs sit behind the Hyper-V host on an internal Hyper-V switch and reach the network through host-side NAT, so no Azure subnet is required for them.'

@description('Location for all network resources.')
param location string = 'northeurope'

@description('Name of the virtual network.')
param virtualNetworkName string = 'VirtualNetwork'

@description('Virtual network address space. Wide enough to accommodate future subnets without redeploying.')
param virtualNetworkAddressPrefix string = '10.0.0.0/22'

@description('Name of the NAT subnet (used by the Hyper-V host NIC).')
param natSubnetName string = 'NAT'

@description('Address prefix of the NAT subnet.')
param natSubnetPrefix string = '10.0.0.0/24'

@description('Name of the subnet for Azure-hosted VMs such as the Domain Controller.')
param azureVMsSubnetName string = 'Azure-VMs'

@description('Address prefix of the Azure-VMs subnet.')
param azureVMsSubnetPrefix string = '10.0.3.0/24'

resource natSubnetNSG 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: '${natSubnetName}NSG'
  location: location
  properties: {}
}

resource azureVMsSubnetNSG 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: '${azureVMsSubnetName}NSG'
  location: location
  properties: {}
}

resource virtualNetwork 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: virtualNetworkName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        virtualNetworkAddressPrefix
      ]
    }
    subnets: [
      {
        name: natSubnetName
        properties: {
          addressPrefix: natSubnetPrefix
          networkSecurityGroup: {
            id: natSubnetNSG.id
          }
        }
      }
      {
        name: azureVMsSubnetName
        properties: {
          addressPrefix: azureVMsSubnetPrefix
          networkSecurityGroup: {
            id: azureVMsSubnetNSG.id
          }
        }
      }
    ]
  }
}

output virtualNetworkName string = virtualNetwork.name
output virtualNetworkId string = virtualNetwork.id
output natSubnetName string = natSubnetName
output azureVMsSubnetName string = azureVMsSubnetName
output virtualNetworkAddressPrefix string = virtualNetworkAddressPrefix
