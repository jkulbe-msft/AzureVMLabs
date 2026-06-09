# AzureVMLabs

Azure Resource Manager (ARM) templates that build a small Azure demo environment for hosting **Azure Virtual Desktop** and **Windows 365** demos. The environment is inspired by the [nested-vms-in-virtual-network](https://github.com/azure/azure-quickstart-templates/tree/master/demos/nested-vms-in-virtual-network) quickstart and is split into three independent components so you can deploy and tear down pieces individually.

Each component ships as a self-contained `azuredeploy.json` ARM template with a matching **Deploy to Azure** button.

## Components

| # | Component | Folder | Purpose |
|---|-----------|--------|---------|
| 1 | Network infrastructure | [`network/`](./network) | Virtual network `10.0.0.0/22` with the `NAT` (Hyper-V host) and `Azure-VMs` (Domain Controller) subnets and their NSGs. |
| 2 | Domain Controller | [`domain-controller/`](./domain-controller) | A `Standard_B2s_v2` Windows Server **2025 Azure Edition (Hotpatch)** VM on the `Azure-VMs` subnet (static IP `10.0.3.4`), with the AD DS database, logs and SYSVOL placed on a separate data disk whose host caching is set to `None`, following [Deploy AD DS on an Azure VM](https://learn.microsoft.com/en-us/windows-server/identity/ad-ds/deploy/virtual-dc/adds-on-azure-vm). Patching uses `AutomaticByPlatform` with `enableHotpatching: true`, as required by Hotpatch-compatible images. The public IP is intended to be protected by Just-In-Time (JIT) access. |
| 3 | Hyper-V host | [`hyper-v-host/`](./hyper-v-host) | A `Standard_D8as_v7` Windows Server **2025 Azure Edition (Hotpatch)** VM (`MicrosoftWindowsServer` / `WindowsServer` / `2025-datacenter-azure-edition`) on the `NAT` subnet with Hyper-V enabled and an internal switch wired up via the WinNAT stack (`New-NetNat`) plus an in-box DHCP scope so nested VMs get DHCP, outbound internet, and reach the DC for DNS. After it boots, the host automatically builds a golden Windows 11 VHDX and provisions **6 Generation 2 lab VMs** (4 vCPU, 2–4 GB dynamic memory, Secure Boot + vTPM) on `NestedSwitch`, each booted to OOBE and checkpointed as `OOBE` — using only in-box tooling (no AutomatedLab). Patching uses `AutomaticByPlatform` with `enableHotpatching: true`. The host is **not** domain-joined. The public IP is intended to be protected by JIT. |

All three templates use the selected **resource group location** and prompt for the resource group at deployment time (recommended: **swedencentral**).

> Deploy them in order: **Network → Domain Controller → Hyper-V Host**. The latter two assume the network and (for the Hyper-V host) the Domain Controller are already in place.

## Deploy

You can deploy either with the Azure CLI or with the **Deploy to Azure** button.

### Azure CLI

```powershell
# 1. Network
az group create -n AzureVMLabs -l swedencentral
az deployment group create -g AzureVMLabs -f network/azuredeploy.json

# 2. Domain Controller
az deployment group create -g AzureVMLabs -f domain-controller/azuredeploy.json `
    --parameters adminUsername=labadmin adminPassword='<password>'

# 3. Hyper-V host
az deployment group create -g AzureVMLabs -f hyper-v-host/azuredeploy.json `
    --parameters adminUsername=labadmin adminPassword='<password>'
```

### Deploy to Azure buttons

#### 1. Network infrastructure

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fjkulbe-msft%2FAzureVMLabs%2Fmain%2Fnetwork%2Fazuredeploy.json)

Location comes from the selected resource group.

#### 2. Domain Controller (`Standard_B2s_v2`, Windows Server 2025 Azure Edition, Hotpatch)

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fjkulbe-msft%2FAzureVMLabs%2Fmain%2Fdomain-controller%2Fazuredeploy.json)

Default size: **Standard_B2s_v2**, default private IP: **10.0.3.4**, default SKU: **2025-datacenter-azure-edition** (`enableHotpatching: true`, `patchMode: AutomaticByPlatform`).

#### 3. Hyper-V host (`Standard_D8as_v7`, Windows Server 2025 Azure Edition, Hotpatch)

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fjkulbe-msft%2FAzureVMLabs%2Fmain%2Fhyper-v-host%2Fazuredeploy.json)

Default size: **Standard_D8as_v7**, default image: **MicrosoftWindowsServer / WindowsServer / 2025-datacenter-azure-edition** (`enableHotpatching: true`, `patchMode: AutomaticByPlatform`).

The Domain Controller template also takes a `domainName` parameter (default **`corp.contoso.com`**) that controls the FQDN of the new Active Directory forest root.

## Notes

* **Just-In-Time access.** The Domain Controller and Hyper-V host templates both deploy a `Microsoft.Security/locations/jitNetworkAccessPolicies` resource that registers the VM for JIT access on the management ports (`3389`, `5985`, `5986`, plus `22` for the host). RDP/WinRM are denied by default and can be opened on demand from the **Microsoft Defender for Cloud → Just-in-time VM access** blade. Microsoft Defender for Servers Plan 2 is required to actually request access; without it the policy is still created but JIT requests will need to be triggered through Defender for Cloud.
* **Hotpatch / patch mode.** Both the Domain Controller and the Hyper-V host use Hotpatch-compatible images, so `windowsConfiguration.patchSettings.patchMode` is set to `AutomaticByPlatform` (required by Azure for these images). `enableHotpatching` defaults to `true`; set it to `false` if you do not want Hotpatch but still need to keep `patchMode: AutomaticByPlatform`.
* **AD DS database location.** [`scripts/ConfigureDC.ps1`](./scripts/ConfigureDC.ps1) initializes the data disk, formats it as `F:`, installs the `AD-Domain-Services` role and promotes the VM to the first domain controller of a new forest with `DatabasePath`, `LogPath` and `SysvolPath` all on `F:`, in line with the Microsoft Learn guidance.
* **Nested VM connectivity.** [`scripts/HVHostSetup.ps1`](./scripts/HVHostSetup.ps1) installs the `Hyper-V`, `RemoteAccess`/`Routing` (for the WinNAT driver) and `DHCP-Server` roles, registers a one-shot post-boot scheduled task and reboots the host once. The post-boot task creates the internal switch **`NestedSwitch`**, assigns the host vNIC `10.0.2.1/24`, configures a `New-NetNat` mapping for `10.0.2.0/24`, and creates a DHCP scope `10.0.2.10`–`10.0.2.200` that hands out `10.0.2.1` as the default gateway (option 003) and the Domain Controller IP as the DNS server (option 006). Because the host is in a workgroup, DHCP rogue-detection is disabled and the DHCP service is bound to the internal vNIC only so it never answers on the Azure NIC. Egress from nested VMs is SNATted through the host's Azure NIC, so the same path reaches the internet and the `Azure-VMs` subnet (including the DC on `10.0.3.4` for DNS). The same post-boot task then builds the Windows 11 lab VMs described under [Lab VMs and the golden image](#lab-vms-and-the-golden-image).
* **Lab VMs.** Six Windows 11 lab VMs (`LabVM1`–`LabVM6`) are created automatically and attached to `NestedSwitch` with their NICs left at the defaults, so each receives a `10.0.2.x` lease, `10.0.2.1` as its gateway and the Domain Controller as its DNS server — ready to browse the internet, reach the Azure VNet and join the AD domain. To add your own nested VM, attach it to `NestedSwitch` and leave its NIC at “Obtain an IP address automatically” / “Obtain DNS server address automatically”.
* **Hyper-V host is not domain-joined.** The host is a Windows Server workgroup machine that only provides a Hyper-V execution surface, host-side NAT and a small DHCP scope for nested VMs. Join any nested guest to the domain instead.

## Lab VMs and the golden image

After the Hyper-V host finishes its post-boot networking configuration it provisions a set of nested Windows 11 lab VMs with **no AutomatedLab dependency** — only in-box Hyper-V and DISM tooling. The work is driven by three helper scripts in [`scripts/`](./scripts) that the deployment downloads onto the host alongside `HVHostSetup.ps1` and stages at `F:\VMLABSource\Scripts`:

| Script | Runs on | Purpose |
|--------|---------|---------|
| [`New-GoldenImage.ps1`](./scripts/New-GoldenImage.ps1) | HVHOST | Builds a bootable golden VHDX from a Windows ISO using `Expand-WindowsImage` + `bcdboot`. |
| [`New-LabVMs.ps1`](./scripts/New-LabVMs.ps1) | HVHOST | Creates Generation 2 lab VMs from independent copies of the golden VHDX and checkpoints each at OOBE. |
| [`Get-AutopilotHash.ps1`](./scripts/Get-AutopilotHash.ps1) | a lab VM (at OOBE) | Captures the Windows Autopilot hardware hash to a CSV. |

Everything lives under `F:\VMLABSource` on the host:

| Path | Contents |
|------|----------|
| `ISOs\Windows11.iso` | The downloaded Windows 11 ISO. |
| `GoldenImages\Win11.vhdx` | The golden image applied from the ISO. |
| `VHDs\LabVM<n>.vhdx` | The independent per-VM disk copies. |
| `Scripts\` | The three helper scripts. |
| `Autopilot\` | A convenient place to drop captured hashes. |

### What gets created automatically

Six Generation 2 VMs named `LabVM1`–`LabVM6`, each with **4 vCPU**, **dynamic memory** (2 GB startup / 2 GB minimum / 4 GB maximum), **Secure Boot** and a **virtual TPM**, attached to `NestedSwitch`. Because each VM boots from an *applied* VHDX rather than from the ISO, the “Press any key to boot from CD or DVD…” prompt never appears, so the unattended boot can't stall on it. Each VM is left running at the Windows 11 OOBE screen with a Standard (memory-inclusive) checkpoint named **`OOBE`**, so the lab can be reverted to a clean OOBE at any time.

The lab VMs keep all of their **default settings**, including the built-in administrator account — nothing is injected into the image.

### Rebuild the golden image for a new ISO or a different edition

The automated build downloads the public consumer Windows 11 ISO, which resolves to **Windows 11 Pro**. To rebuild from a newer ISO or a different edition (for example a Windows 11 Enterprise evaluation ISO you downloaded yourself), run on HVHOST:

```powershell
# Rebuild the golden image from a specific ISO, replacing the existing one
F:\VMLABSource\Scripts\New-GoldenImage.ps1 `
    -IsoPath D:\Win11_Enterprise_Eval.iso `
    -Edition 'Windows 11 Enterprise Evaluation' -Force

# Recreate the lab VMs from the (re)built golden image
F:\VMLABSource\Scripts\New-LabVMs.ps1
```

`New-GoldenImage.ps1` auto-selects the `Pro` edition when `-Edition` is omitted; pass `-Edition` to target another edition inside the ISO. `New-LabVMs.ps1` skips VMs that already exist, so remove the ones you want to rebuild first (for example `Get-VM LabVM* | Remove-VM`) — or pass `-NamePrefix` / `-Count` to create an additional set.

### Capture an Autopilot hardware hash

Because the VMs keep their default administrator account, PowerShell Direct from the host isn't wired up. Capture a device's Autopilot hash from inside the VM while it sits at OOBE:

1. At the OOBE screen, press **Shift+F10** to open a command prompt, then run `powershell`.
2. Paste the contents of [`scripts/Get-AutopilotHash.ps1`](./scripts/Get-AutopilotHash.ps1) (also staged at `F:\VMLABSource\Scripts` on the host). It reads the hash from WMI and writes `C:\HWID\<serial>.csv`, echoing the CSV to the console so you can copy it out.
3. Optionally run it with `-Online` to install the official `Get-WindowsAutopilotInfo` script and upload the hash straight to Intune (this path needs internet and an interactive Microsoft Entra sign-in).
