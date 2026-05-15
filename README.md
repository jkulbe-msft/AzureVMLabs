# AzureVMLabs

Bicep templates that build a small Azure demo environment for hosting **Azure Virtual Desktop** and **Windows 365** demos. The environment is inspired by the [nested-vms-in-virtual-network](https://github.com/azure/azure-quickstart-templates/tree/master/demos/nested-vms-in-virtual-network) quickstart and is split into three independent components so you can deploy and tear down pieces individually.

The Bicep files (`*.bicep`) are the source of truth. The `azuredeploy.json` ARM templates next to each one are generated from Bicep (`az bicep build`) so the **Deploy to Azure** buttons still work.

## Components

| # | Component | Folder | Purpose |
|---|-----------|--------|---------|
| 1 | Network infrastructure | [`network/`](./network) | Virtual network `10.0.0.0/22` with the `NAT` (Hyper-V host) and `Azure-VMs` (Domain Controller) subnets and their NSGs. |
| 2 | Domain Controller | [`domain-controller/`](./domain-controller) | A `Standard_B2s_v2` Windows Server **2025 Azure Edition (Hotpatch)** VM on the `Azure-VMs` subnet (static IP `10.0.3.4`), with the AD DS database, logs and SYSVOL placed on a separate data disk whose host caching is set to `None`, following [Deploy AD DS on an Azure VM](https://learn.microsoft.com/en-us/windows-server/identity/ad-ds/deploy/virtual-dc/adds-on-azure-vm). Patching uses `AutomaticByPlatform` with `enableHotpatching: true`, as required by Hotpatch-compatible images. The public IP is intended to be protected by Just-In-Time (JIT) access. |
| 3 | Hyper-V host | [`hyper-v-host/`](./hyper-v-host) | A `Standard_D8as_v7` Windows Server **2025 Azure Edition (Hotpatch)** VM (`MicrosoftWindowsServer` / `WindowsServer` / `2025-datacenter-azure-edition`) on the `NAT` subnet with Hyper-V enabled and an internal switch wired up via the WinNAT stack (`New-NetNat`) plus an in-box DHCP scope so nested VMs get DHCP, outbound internet, and reach the DC for DNS. Patching uses `AutomaticByPlatform` with `enableHotpatching: true`. The host is **not** domain-joined. The public IP is intended to be protected by JIT. |

All three templates default to **North Europe** and prompt for the resource group at deployment time.

> Deploy them in order: **Network → Domain Controller → Hyper-V Host**. The latter two assume the network and (for the Hyper-V host) the Domain Controller are already in place.

## Deploy

You can deploy either with the Azure CLI (Bicep) or with the **Deploy to Azure** button (ARM JSON).

### Azure CLI (recommended)

```powershell
# 1. Network
az group create -n AzureVMLabs -l northeurope
az deployment group create -g AzureVMLabs -f network/main.bicep

# 2. Domain Controller
az deployment group create -g AzureVMLabs -f domain-controller/main.bicep `
    --parameters adminUsername=labadmin adminPassword='<password>'

# 3. Hyper-V host
az deployment group create -g AzureVMLabs -f hyper-v-host/main.bicep `
    --parameters adminUsername=labadmin adminPassword='<password>'
```

### Deploy to Azure buttons

#### 1. Network infrastructure

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fjkulbe-msft%2FAzureVMLabs%2Fmain%2Fnetwork%2Fazuredeploy.json)

Default location: **northeurope**.

#### 2. Domain Controller (`Standard_B2s_v2`, Windows Server 2025 Azure Edition, Hotpatch)

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fjkulbe-msft%2FAzureVMLabs%2Fmain%2Fdomain-controller%2Fazuredeploy.json)

Default size: **Standard_B2s_v2**, default private IP: **10.0.3.4**, default SKU: **2025-datacenter-azure-edition** (`enableHotpatching: true`, `patchMode: AutomaticByPlatform`).

#### 3. Hyper-V host (`Standard_D8as_v7`, Windows Server 2025 Azure Edition, Hotpatch)

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fjkulbe-msft%2FAzureVMLabs%2Fmain%2Fhyper-v-host%2Fazuredeploy.json)

Default size: **Standard_D8as_v7**, default image: **MicrosoftWindowsServer / WindowsServer / 2025-datacenter-azure-edition** (`enableHotpatching: true`, `patchMode: AutomaticByPlatform`).

## Notes

* **Just-In-Time access.** The Domain Controller and Hyper-V host templates both deploy a `Microsoft.Security/locations/jitNetworkAccessPolicies` resource that registers the VM for JIT access on the management ports (`3389`, `5985`, `5986`, plus `22` for the host). RDP/WinRM are denied by default and can be opened on demand from the **Microsoft Defender for Cloud → Just-in-time VM access** blade. Microsoft Defender for Servers Plan 2 is required to actually request access; without it the policy is still created but JIT requests will need to be triggered through Defender for Cloud.
* **Hotpatch / patch mode.** Both the Domain Controller and the Hyper-V host use Hotpatch-compatible images, so `windowsConfiguration.patchSettings.patchMode` is set to `AutomaticByPlatform` (required by Azure for these images). `enableHotpatching` defaults to `true`; set it to `false` if you do not want Hotpatch but still need to keep `patchMode: AutomaticByPlatform`.
* **AD DS database location.** [`scripts/ConfigureDC.ps1`](./scripts/ConfigureDC.ps1) initializes the data disk, formats it as `F:`, installs the `AD-Domain-Services` role and promotes the VM to the first domain controller of a new forest with `DatabasePath`, `LogPath` and `SysvolPath` all on `F:`, in line with the Microsoft Learn guidance.
* **Nested VM connectivity.** [`scripts/HVHostSetup.ps1`](./scripts/HVHostSetup.ps1) installs the `Hyper-V`, `RemoteAccess`/`Routing` (for the WinNAT driver) and `DHCP-Server` roles, registers a one-shot post-boot scheduled task and reboots the host once. The post-boot task creates the internal switch **`NestedSwitch`**, assigns the host vNIC `10.0.2.1/24`, configures a `New-NetNat` mapping for `10.0.2.0/24`, and creates a DHCP scope `10.0.2.10`–`10.0.2.200` that hands out `10.0.2.1` as the default gateway (option 003) and the Domain Controller IP as the DNS server (option 006). Because the host is in a workgroup, DHCP rogue-detection is disabled and the DHCP service is bound to the internal vNIC only so it never answers on the Azure NIC. Egress from nested VMs is SNATted through the host's Azure NIC, so the same path reaches the internet and the `Azure-VMs` subnet (including the DC on `10.0.3.4` for DNS).
* **Configuring a nested VM.** Attach the nested VM to `NestedSwitch` and leave its NIC at the defaults (“Obtain an IP address automatically” / “Obtain DNS server address automatically”). It receives a `10.0.2.x` lease, `10.0.2.1` as its gateway and the Domain Controller as its DNS server, so it can browse the internet, reach the Azure VNet, and join the AD domain straight away.
* **Hyper-V host is not domain-joined.** The host is a Windows Server workgroup machine that only provides a Hyper-V execution surface, host-side NAT and a small DHCP scope for nested VMs. Join any nested guest to the domain instead.

## Regenerating ARM JSON from Bicep

```powershell
az bicep build --file network/main.bicep            --outfile network/azuredeploy.json
az bicep build --file domain-controller/main.bicep  --outfile domain-controller/azuredeploy.json
az bicep build --file hyper-v-host/main.bicep       --outfile hyper-v-host/azuredeploy.json
```
