# AzureVMLabs

ARM templates that build a small Azure demo environment for hosting **Azure Virtual Desktop** and **Windows 365** demos. The environment is based on the [nested-vms-in-virtual-network](https://github.com/azure/azure-quickstart-templates/tree/master/demos/nested-vms-in-virtual-network) quickstart and is split into three independent components so you can deploy and tear down pieces individually.

## Components

| # | Component | Folder | Purpose |
|---|-----------|--------|---------|
| 1 | Network infrastructure | [`network/`](./network) | Virtual network `10.0.0.0/22` with the `NAT`, `Hyper-V-LAN`, `Ghosted` and `Azure-VMs` subnets, NSGs and the user-defined route required to send nested-VM traffic via the Hyper-V host. |
| 2 | Domain Controller | [`domain-controller/`](./domain-controller) | A `Standard_B2s_v2` Windows Server VM on the `Azure-VMs` subnet (static IP `10.0.3.4`), with the AD DS database, logs and SYSVOL placed on a separate data disk whose host caching is set to `None`, following [Deploy AD DS on an Azure VM](https://learn.microsoft.com/en-us/windows-server/identity/ad-ds/deploy/virtual-dc/adds-on-azure-vm). The public IP is intended to be protected by Just-In-Time (JIT) access. |
| 3 | Hyper-V host | [`hyper-v-host/`](./hyper-v-host) | A `Standard_D8as_v7` Windows 11 VM (`microsoftwindowsdesktop` / `windows-11` / `win11-25h2-ent`) with Hyper-V enabled and a virtual switch wired up so nested VMs get internet connectivity and use `10.0.3.4` as their DNS server. The public IP is intended to be protected by JIT. |

All three templates default to **North Europe** and prompt for the resource group at deployment time.

> Deploy them in order: **Network → Domain Controller → Hyper-V Host**. The latter two assume the network and (for the Hyper-V host) the Domain Controller are already in place.

## Deploy to Azure

### 1. Network infrastructure

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fjkulbe-msft%2FAzureVMLabs%2Fmain%2Fnetwork%2Fazuredeploy.json)

Default location: **northeurope**. You will be prompted for the resource group during deployment.

### 2. Domain Controller (`Standard_B2s_v2`)

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fjkulbe-msft%2FAzureVMLabs%2Fmain%2Fdomain-controller%2Fazuredeploy.json)

Default location: **northeurope**, default size: **Standard_B2s_v2**, default private IP: **10.0.3.4**. You will be prompted for the resource group, machine username and password.

### 3. Hyper-V host (`Standard_D8as_v7`, Windows 11)

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fjkulbe-msft%2FAzureVMLabs%2Fmain%2Fhyper-v-host%2Fazuredeploy.json)

Default location: **northeurope**, default size: **Standard_D8as_v7**, default image: **microsoftwindowsdesktop / windows-11 / win11-25h2-ent**. You will be prompted for the resource group, machine username and password.

## Notes

* **Just-In-Time access.** The Domain Controller and Hyper-V host templates both deploy a `Microsoft.Security/locations/jitNetworkAccessPolicies` resource that registers the VM for JIT access on the management ports (`3389`, `5985`, `5986`, plus `22` for the host). RDP/WinRM are denied by default and can be opened on demand from the **Microsoft Defender for Cloud → Just-in-time VM access** blade. Microsoft Defender for Servers Plan 2 is required to actually request access; without it the policy is still created but JIT requests will need to be triggered through Defender for Cloud.
* **Internet & VNet connectivity.** Both VMs are deployed with a public IP and outbound internet is allowed by default Azure routing. The Hyper-V host has two NICs (NAT subnet + Hyper-V-LAN subnet) and IP forwarding enabled on the second NIC; the `Azure-VMs` subnet user-defined route points nested-VM traffic (`10.0.2.0/24`) at `10.0.1.4` so the host can route between Azure and nested VMs.
* **Nested VM connectivity.** [`scripts/HVHostSetup.ps1`](./scripts/HVHostSetup.ps1) installs Hyper-V, RRAS and DHCP on the host, creates an internal virtual switch called **`NestedSwitch`**, NATs nested traffic out through the host's primary NIC, and runs a DHCP scope on the Ghosted subnet that hands out the Domain Controller (`10.0.3.4` by default) as the DNS server. Attach any nested demo VM to `NestedSwitch` to inherit internet connectivity and DC-based DNS.
* **AD DS database location.** [`scripts/ConfigureDC.ps1`](./scripts/ConfigureDC.ps1) initializes the data disk, formats it as `F:`, installs the `AD-Domain-Services` role and promotes the VM to the first domain controller of a new forest with `DatabasePath`, `LogPath` and `SysvolPath` all on `F:`, in line with the Microsoft Learn guidance.
