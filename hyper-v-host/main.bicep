metadata description = 'Deploys a Windows Server 2025 Azure Edition (Hotpatch) VM that acts as a nested Hyper-V host. The VM has a single NIC on the NAT subnet, a public IP intended to be protected by Just-In-Time (JIT) access, Hyper-V enabled, and an internal virtual switch wired up via the WinNAT stack (New-NetNat) with an in-box DHCP scope so that nested VMs receive DHCP, outbound internet connectivity, and reach the Azure VNet (including the Domain Controller for DNS). The host is NOT domain-joined.'

@description('Location for all Hyper-V host resources.')
param location string = 'northeurope'

@description('Computer name of the Hyper-V host VM. 15 characters maximum.')
@maxLength(15)
param vmName string = 'HVHOST'

@description('Size of the Hyper-V host VM. Default is Standard_D8as_v7 which supports nested virtualization.')
param vmSize string = 'Standard_D8as_v7'

@description('Administrator username for the Hyper-V host VM.')
param adminUsername string

@description('Administrator password for the Hyper-V host VM.')
@secure()
@minLength(12)
param adminPassword string

@description('Marketplace image publisher for the Hyper-V host VM. Defaults to Windows Server (required for the DHCP Server role used to hand out IPs to nested VMs).')
param imagePublisher string = 'MicrosoftWindowsServer'

@description('Marketplace image offer for the Hyper-V host VM.')
param imageOffer string = 'WindowsServer'

@description('Marketplace image SKU for the Hyper-V host VM. Defaults to 2025 Azure Edition (Hotpatch-compatible).')
param imageSku string = '2025-datacenter-azure-edition'

@description('Whether Hotpatch is enabled on the VM. Requires a Hotpatch-compatible image SKU.')
param enableHotpatching bool = true

@description('IP address of the Domain Controller. Handed out as the DNS server option (006) in the DHCP scope so nested VMs resolve Active Directory names against the DC.')
param domainControllerIPAddress string = '10.0.3.4'

@description('CIDR of the nested (internal Hyper-V switch) subnet. Used for the host vNIC IP, the New-NetNat mapping, and the DHCP scope handed out to nested VMs.')
param nestedSubnetPrefix string = '10.0.2.0/24'

@description('Resource group containing the virtual network (deployed by the network template). Defaults to the current resource group.')
param virtualNetworkResourceGroupName string = resourceGroup().name

@description('Name of the existing virtual network.')
param virtualNetworkName string = 'VirtualNetwork'

@description('Name of the NAT subnet to attach the Hyper-V host NIC to.')
param natSubnetName string = 'NAT'

@description('Base URI (with trailing slash) where deployment artifacts (PowerShell scripts) are located.')
param _artifactsLocation string = 'https://raw.githubusercontent.com/jkulbe-msft/AzureVMLabs/main/'

@description('Optional SAS token appended to artifact URIs when artifacts are hosted in a secured storage account.')
@secure()
param _artifactsLocationSasToken string = ''

var publicIPAddressName = '${vmName}-pip'
var nicName = '${vmName}-nic'
var nsgName = '${vmName}-nsg'
var osDiskName = '${vmName}-osdisk'
var jitPolicyName = '${vmName}-jit'
var hvHostSetupScriptUri = uri(_artifactsLocation, 'scripts/HVHostSetup.ps1${_artifactsLocationSasToken}')

resource natSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' existing = {
  name: '${virtualNetworkName}/${natSubnetName}'
  scope: resourceGroup(virtualNetworkResourceGroupName)
}

resource nsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: nsgName
  location: location
  properties: {
    securityRules: []
  }
}

resource publicIP 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: publicIPAddressName
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
    idleTimeoutInMinutes: 4
    dnsSettings: {
      domainNameLabel: toLower('${vmName}-${uniqueString(resourceGroup().id)}')
    }
  }
}

resource nic 'Microsoft.Network/networkInterfaces@2024-05-01' = {
  name: nicName
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: {
            id: natSubnet.id
          }
          publicIPAddress: {
            id: publicIP.id
          }
        }
      }
    ]
    networkSecurityGroup: {
      id: nsg.id
    }
  }
}

resource vm 'Microsoft.Compute/virtualMachines@2024-07-01' = {
  name: vmName
  location: location
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    osProfile: {
      computerName: vmName
      adminUsername: adminUsername
      adminPassword: adminPassword
      windowsConfiguration: {
        provisionVMAgent: true
        enableAutomaticUpdates: true
        patchSettings: {
          // Required for Hotpatch-compatible images such as 2025-datacenter-azure-edition.
          patchMode: 'AutomaticByPlatform'
          enableHotpatching: enableHotpatching
          assessmentMode: 'AutomaticByPlatform'
          automaticByPlatformSettings: {
            rebootSetting: 'IfRequired'
            bypassPlatformSafetyChecksOnUserSchedule: false
          }
        }
      }
    }
    storageProfile: {
      imageReference: {
        publisher: imagePublisher
        offer: imageOffer
        sku: imageSku
        version: 'latest'
      }
      osDisk: {
        name: osDiskName
        createOption: 'FromImage'
        caching: 'ReadWrite'
        managedDisk: {
          storageAccountType: 'Premium_LRS'
        }
      }
    }
    securityProfile: {
      securityType: 'TrustedLaunch'
      uefiSettings: {
        secureBootEnabled: true
        vTpmEnabled: true
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nic.id
        }
      ]
    }
  }
}

resource hvHostSetupExtension 'Microsoft.Compute/virtualMachines/extensions@2024-07-01' = {
  parent: vm
  name: 'HVHostSetup'
  location: location
  properties: {
    publisher: 'Microsoft.Compute'
    type: 'CustomScriptExtension'
    typeHandlerVersion: '1.10'
    autoUpgradeMinorVersion: true
    settings: {
      fileUris: [
        hvHostSetupScriptUri
      ]
    }
    protectedSettings: {
      commandToExecute: 'powershell -ExecutionPolicy Unrestricted -NoProfile -File HVHostSetup.ps1 -NestedSubnetPrefix ${nestedSubnetPrefix} -DNSServerAddress ${domainControllerIPAddress}'
    }
  }
}

resource jitPolicy 'Microsoft.Security/locations/jitNetworkAccessPolicies@2020-01-01' = {
  name: '${location}/${jitPolicyName}'
  kind: 'Basic'
  properties: {
    virtualMachines: [
      {
        id: vm.id
        ports: [
          {
            number: 3389
            protocol: '*'
            allowedSourceAddressPrefix: '*'
            maxRequestAccessDuration: 'PT3H'
          }
          {
            number: 22
            protocol: '*'
            allowedSourceAddressPrefix: '*'
            maxRequestAccessDuration: 'PT3H'
          }
          {
            number: 5985
            protocol: '*'
            allowedSourceAddressPrefix: '*'
            maxRequestAccessDuration: 'PT3H'
          }
          {
            number: 5986
            protocol: '*'
            allowedSourceAddressPrefix: '*'
            maxRequestAccessDuration: 'PT3H'
          }
        ]
      }
    ]
  }
}

output hyperVHostName string = vm.name
output hyperVHostFqdn string = publicIP.properties.dnsSettings.fqdn
