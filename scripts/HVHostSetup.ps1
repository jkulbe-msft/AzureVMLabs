<#
.SYNOPSIS
    Configures the Hyper-V host VM (Windows Server 2025 Azure Edition) for the
    AzureVMLabs demo environment.

.DESCRIPTION
    The Hyper-V host runs Windows Server (not domain-joined). It uses:
      * Hyper-V                         - for nested virtualization
      * RemoteAccess (Routing)          - to install the WinNAT driver used by New-NetNat
      * DHCP Server                     - to hand out IPs / gateway / DNS to nested VMs

    The script runs in two phases because Hyper-V services are only available after a
    reboot:

      Phase 1 (this script, run by the Custom Script Extension):
        * Installs the Hyper-V, RemoteAccess/Routing and DHCP-Server roles + tools.
        * Persists state needed by phase 2 (nested subnet, DC IP, derived host IP).
        * Registers a one-shot "HVHostPostBoot" scheduled task that runs at startup.
        * Reboots the host (after letting the extension report success).

      Phase 2 (HVHostPostBoot.ps1, run as SYSTEM on the next boot):
        * Creates the Internal Hyper-V virtual switch "NestedSwitch".
        * Assigns the host vNIC the gateway IP of the nested subnet (e.g. 10.0.2.1/24).
        * Creates a New-NetNat mapping for the nested subnet, so nested-VM egress is
          SNATted out through the host's primary Azure NIC. Azure return traffic
          (including DC DNS replies for nested DNS queries) is delivered by default
          Azure routing.
        * Disables DHCP rogue detection (the host is not in AD), starts the DHCP Server
          service, and creates a scope for the nested subnet that hands out the host
          vNIC IP as the default gateway (option 003) and the Domain Controller IP as
          the DNS server (option 006).
        * Unregisters itself so it only runs once.

    Nested VMs attached to "NestedSwitch" with their NIC left at "Obtain an IP address
    automatically" / "Obtain DNS server address automatically" pick up internet
    connectivity and DC-based DNS via DHCP - no static configuration required.

.PARAMETER NestedSubnetPrefix
    CIDR of the nested subnet behind the internal Hyper-V switch (default 10.0.2.0/24).
    The host vNIC is assigned <network>.1 and that address is the gateway / NAT outbound
    point and the default-gateway option in the DHCP scope.

.PARAMETER DNSServerAddress
    IP address of the Domain Controller, handed out as DHCP option 006 (DNS Servers).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string]$NestedSubnetPrefix,
    [Parameter(Mandatory = $true)] [string]$DNSServerAddress
)

$ErrorActionPreference = 'Stop'
Start-Transcript -Path "$env:SystemDrive\HVHostSetup.log" -Append

try {
    # Derive the host vNIC gateway IP, scope range and dotted-quad mask from the prefix.
    $parts        = $NestedSubnetPrefix.Split('/')
    $networkAddr  = $parts[0]
    $prefixLength = [int]$parts[1]
    $octets       = $networkAddr.Split('.')
    $hostVNicIP   = '{0}.{1}.{2}.1'   -f $octets[0], $octets[1], $octets[2]
    $scopeStart   = '{0}.{1}.{2}.10'  -f $octets[0], $octets[1], $octets[2]
    $scopeEnd     = '{0}.{1}.{2}.200' -f $octets[0], $octets[1], $octets[2]
    $scopeId      = $networkAddr

    # Build the dotted-quad subnet mask from the prefix length by setting bits one
    # at a time. Avoids -shl on [uint32], which PowerShell silently promotes through
    # int32 and turns 0xFFFFFFFF into -1, breaking [BitConverter]::GetBytes([uint32]).
    $maskBytes = [byte[]]::new(4)
    for ($i = 0; $i -lt $prefixLength; $i++) {
        $byteIndex = [int][math]::Floor($i / 8)
        $bitIndex  = 7 - ($i % 8)
        $maskBytes[$byteIndex] = [byte]($maskBytes[$byteIndex] -bor (1 -shl $bitIndex))
    }
    $subnetMask = ([System.Net.IPAddress]::new($maskBytes)).ToString()

    $stateDir = "$env:SystemDrive\AzureVMLabs"
    if (-not (Test-Path $stateDir)) {
        New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
    }

    @{
        NestedSubnetPrefix = $NestedSubnetPrefix
        HostVNicIP         = $hostVNicIP
        PrefixLength       = $prefixLength
        SubnetMask         = $subnetMask
        ScopeId            = $scopeId
        ScopeStart         = $scopeStart
        ScopeEnd           = $scopeEnd
        DNSServerAddress   = $DNSServerAddress
    } | ConvertTo-Json | Set-Content -Path "$stateDir\HVHostSetup.state.json" -Encoding UTF8

    # Install Hyper-V via DISM (Enable-WindowsOptionalFeature) rather than
    # Install-WindowsFeature. On Trusted Launch VMs (securityType = TrustedLaunch),
    # the Server Manager cmdlet runs a strict BIOS prerequisite check that incorrectly
    # reports "Hyper-V cannot be installed because virtualization support is not
    # enabled in the BIOS", even on sizes that do support nested virtualization
    # (e.g. Standard_D8as_v7). See:
    # https://learn.microsoft.com/troubleshoot/azure/virtual-machines/windows/troubleshoot-vm-by-use-nested-virtualization
    # The DISM path doesn't run that check and is the same mechanism Windows client
    # SKUs (Windows 10/11) use to enable Hyper-V on Trusted Launch VMs successfully.
    # 'Microsoft-Hyper-V' installs the hypervisor + services; the PowerShell module
    # (needed by the post-boot task for New-VMSwitch / Get-VMSwitch) is a separate
    # optional feature on Windows Server and is enabled explicitly below. The -All
    # switch is a cmdlet parameter that enables parent features, not part of the name.
    Write-Output 'Enabling Hyper-V optional features (DISM)...'
    Enable-WindowsOptionalFeature -Online -FeatureName 'Microsoft-Hyper-V' -All -NoRestart | Out-Null
    Enable-WindowsOptionalFeature -Online -FeatureName 'Microsoft-Hyper-V-Management-PowerShell' -All -NoRestart | Out-Null
    Add-WindowsFeature -Name RSAT -IncludeAllSubFeature

    Write-Output 'Installing RemoteAccess/Routing (for WinNAT) and DHCP Server roles...'
    Install-WindowsFeature -Name RemoteAccess, Routing, DHCP `
        -IncludeManagementTools -IncludeAllSubFeature | Out-Null

    Write-Output 'Writing post-boot configuration script...'
    $postBoot = @'
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Start-Transcript -Path "$env:SystemDrive\HVHostPostBoot.log" -Append

try {
    $state = Get-Content -Path "$env:SystemDrive\AzureVMLabs\HVHostSetup.state.json" -Raw | ConvertFrom-Json

    if (-not (Get-VMSwitch -Name 'NestedSwitch' -ErrorAction SilentlyContinue)) {
        Write-Output "Creating internal Hyper-V virtual switch 'NestedSwitch'..."
        New-VMSwitch -Name 'NestedSwitch' -SwitchType Internal | Out-Null
    }

    $hostAdapter = Get-NetAdapter | Where-Object { $_.Name -like '*NestedSwitch*' } | Select-Object -First 1
    if ($null -eq $hostAdapter) {
        throw "Unable to locate the host virtual adapter for the NestedSwitch."
    }

    $existing = Get-NetIPAddress -InterfaceIndex $hostAdapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object IPAddress -eq $state.HostVNicIP
    if (-not $existing) {
        Write-Output "Assigning $($state.HostVNicIP)/$($state.PrefixLength) to the NestedSwitch host vNIC..."
        New-NetIPAddress -InterfaceIndex $hostAdapter.ifIndex -IPAddress $state.HostVNicIP -PrefixLength $state.PrefixLength | Out-Null
    }

    # The internal vNIC has no upstream gateway; don't register it in DNS.
    Set-DnsClient -InterfaceIndex $hostAdapter.ifIndex -RegisterThisConnectionsAddress $false -ErrorAction SilentlyContinue

    if (-not (Get-NetNat -Name 'NestedNat' -ErrorAction SilentlyContinue)) {
        Write-Output "Creating NAT for $($state.NestedSubnetPrefix)..."
        New-NetNat -Name 'NestedNat' -InternalIPInterfaceAddressPrefix $state.NestedSubnetPrefix | Out-Null
    }

    # Workgroup DHCP server: skip AD authorization and silence rogue-detection warnings.
    Write-Output 'Configuring DHCP Server service for workgroup operation...'
    New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\DHCPServer\Parameters' `
        -Name 'DisableRogueDetection' -PropertyType DWord -Value 1 -Force | Out-Null

    Set-Service -Name DHCPServer -StartupType Automatic
    if ((Get-Service -Name DHCPServer).Status -ne 'Running') {
        Start-Service -Name DHCPServer
    }

    # Bind DHCP Server to the internal vNIC only so it never answers on the Azure NIC.
    $bindings = Get-DhcpServerv4Binding -ErrorAction SilentlyContinue
    foreach ($b in $bindings) {
        if ($b.InterfaceAlias -eq $hostAdapter.Name) {
            if (-not $b.BindingState) { Set-DhcpServerv4Binding -InterfaceAlias $b.InterfaceAlias -BindingState $true | Out-Null }
        }
        else {
            if ($b.BindingState) { Set-DhcpServerv4Binding -InterfaceAlias $b.InterfaceAlias -BindingState $false | Out-Null }
        }
    }

    if (-not (Get-DhcpServerv4Scope -ScopeId $state.ScopeId -ErrorAction SilentlyContinue)) {
        Write-Output "Creating DHCP scope $($state.ScopeId) ($($state.ScopeStart) - $($state.ScopeEnd))..."
        Add-DhcpServerv4Scope `
            -Name 'NestedVMs' `
            -StartRange $state.ScopeStart `
            -EndRange   $state.ScopeEnd `
            -SubnetMask $state.SubnetMask `
            -State Active | Out-Null
    }

    Set-DhcpServerv4OptionValue `
        -ScopeId   $state.ScopeId `
        -Router    $state.HostVNicIP `
        -DnsServer $state.DNSServerAddress `
        -Force | Out-Null

    Write-Output "Nested networking ready. Guest VMs on 'NestedSwitch' using DHCP will receive:"
    Write-Output "  IP      : within $($state.NestedSubnetPrefix) (from $($state.ScopeStart) to $($state.ScopeEnd))"
    Write-Output "  Gateway : $($state.HostVNicIP)"
    Write-Output "  DNS     : $($state.DNSServerAddress)"

    Unregister-ScheduledTask -TaskName 'HVHostPostBoot' -Confirm:$false -ErrorAction SilentlyContinue
}
finally {
    Stop-Transcript
}
'@

    $postBootScript = "$env:SystemDrive\AzureVMLabs\HVHostPostBoot.ps1"
    Set-Content -Path $postBootScript -Value $postBoot -Encoding UTF8

    Write-Output 'Registering one-shot post-boot scheduled task...'
    $action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-ExecutionPolicy Bypass -NoProfile -File `"$postBootScript`""
    $trigger   = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId 'S-1-5-18' -RunLevel Highest
    Register-ScheduledTask -TaskName 'HVHostPostBoot' -Action $action -Trigger $trigger -Principal $principal -Force | Out-Null

    Write-Output 'Initial setup complete. Rebooting to finish role installation; the post-boot task will create the switch, NAT and DHCP scope.'
}
finally {
    Stop-Transcript
}

# Reboot so the Hyper-V services come up and the post-boot task can configure the switch,
# NAT and DHCP scope. The Custom Script Extension is allowed to complete first.
shutdown.exe /r /t 30 /c 'Rebooting to complete Hyper-V installation' | Out-Null
