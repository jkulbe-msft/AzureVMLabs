metadata description = 'Deploys a Windows Server 2025 Azure Edition VM acting as a Domain Controller, following https://learn.microsoft.com/en-us/windows-server/identity/ad-ds/deploy/virtual-dc/adds-on-azure-vm. The AD DS database, logs and SYSVOL are placed on a separate data disk with host caching set to None. The VM uses Hotpatch (AutomaticByPlatform) and is attached to the Azure-VMs subnet with a static private IP and a public IP intended to be protected by Just-In-Time (JIT) access.'

@description('Location for all Domain Controller resources.')
param location string = 'northeurope'

@description('Computer name of the Domain Controller VM. 15 characters maximum.')
@maxLength(15)
param vmName string = 'DC01'

@description('Size of the Domain Controller VM. Default is the cheap burstable Standard_B2s_v2.')
param vmSize string = 'Standard_B2s_v2'

@description('Administrator username for the Domain Controller VM. Also used as the initial domain administrator.')
param adminUsername string

@description('Administrator password for the Domain Controller VM. Also used as the Directory Services Restore Mode (DSRM) password during the ADDS promotion.')
@secure()
@minLength(12)
param adminPassword string

@description('FQDN of the Active Directory forest root domain to create on the Domain Controller.')
param domainName string = 'contoso.local'

@description('Static private IP address to assign to the Domain Controller on the Azure-VMs subnet.')
param privateIPAddress string = '10.0.3.4'

@description('Resource group containing the virtual network (deployed by the network template). Defaults to the current resource group.')
param virtualNetworkResourceGroupName string = resourceGroup().name

@description('Name of the existing virtual network.')
param virtualNetworkName string = 'VirtualNetwork'

@description('Name of the Azure-VMs subnet to attach the Domain Controller NIC to.')
param azureVMsSubnetName string = 'Azure-VMs'

@description('SKU of the Windows Server image used for the Domain Controller. Defaults to 2025 Azure Edition (Hotpatch-compatible).')
param windowsServerSku string = '2025-datacenter-azure-edition'

@description('Whether Hotpatch is enabled on the VM. Requires a Hotpatch-compatible image SKU.')
param enableHotpatching bool = true

@description('Size of the data disk that hosts the AD DS database, logs and SYSVOL.')
param dataDiskSizeGB int = 32

@description('Base URI (with trailing slash) where deployment artifacts (PowerShell scripts) are located.')
param _artifactsLocation string = 'https://raw.githubusercontent.com/jkulbe-msft/AzureVMLabs/main/'

@description('Optional SAS token appended to artifact URIs when artifacts are hosted in a secured storage account.')
@secure()
param _artifactsLocationSasToken string = ''

var publicIPAddressName = '${vmName}-pip'
var networkInterfaceName = '${vmName}-nic'
var nsgName = '${vmName}-nsg'
var osDiskName = '${vmName}-osdisk'
var dataDiskName = '${vmName}-data'
var jitPolicyName = '${vmName}-jit'
var configureDcScriptUri = uri(_artifactsLocation, 'scripts/ConfigureDC.ps1${_artifactsLocationSasToken}')

resource subnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' existing = {
  name: '${virtualNetworkName}/${azureVMsSubnetName}'
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
  }
}

resource nic 'Microsoft.Network/networkInterfaces@2024-05-01' = {
  name: networkInterfaceName
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Static'
          privateIPAddress: privateIPAddress
          subnet: {
            id: subnet.id
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
        publisher: 'MicrosoftWindowsServer'
        offer: 'WindowsServer'
        sku: windowsServerSku
        version: 'latest'
      }
      osDisk: {
        name: osDiskName
        createOption: 'FromImage'
        caching: 'ReadWrite'
        managedDisk: {
          storageAccountType: 'StandardSSD_LRS'
        }
      }
      dataDisks: [
        {
          name: dataDiskName
          lun: 0
          createOption: 'Empty'
          diskSizeGB: dataDiskSizeGB
          caching: 'None'
          managedDisk: {
            storageAccountType: 'StandardSSD_LRS'
          }
        }
      ]
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nic.id
        }
      ]
    }
    securityProfile: {
      securityType: 'TrustedLaunch'
      uefiSettings: {
        secureBootEnabled: true
        vTpmEnabled: true
      }
    }
  }
}

resource configureDcExtension 'Microsoft.Compute/virtualMachines/extensions@2024-07-01' = {
  parent: vm
  name: 'ConfigureDC'
  location: location
  properties: {
    publisher: 'Microsoft.Compute'
    type: 'CustomScriptExtension'
    typeHandlerVersion: '1.10'
    autoUpgradeMinorVersion: true
    settings: {
      fileUris: [
        configureDcScriptUri
      ]
    }
    protectedSettings: {
      commandToExecute: 'powershell -ExecutionPolicy Unrestricted -NoProfile -File ConfigureDC.ps1 -DomainName ${domainName} -SafeModeAdminPassword ${adminPassword}'
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

output domainControllerName string = vm.name
output domainControllerPrivateIP string = privateIPAddress
output domainNameOut string = domainName
