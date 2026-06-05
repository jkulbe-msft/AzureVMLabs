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
        * Enables IPv4 forwarding on the internal vNIC and moves it to the Private
          network profile so WinNAT can route packets between the nested subnet and
          the Azure NIC and so the Windows Defender Firewall doesn't drop DHCP
          replies / forwarded traffic to the nested guests.
        * Creates a New-NetNat mapping for the nested subnet, so nested-VM egress is
          SNATted out through the host's primary Azure NIC. Azure return traffic
          (including DC DNS replies for nested DNS queries) is delivered by default
          Azure routing. The Azure NIC has enableIPForwarding=true so the platform
          permits the forwarded flow.
        * Turns on Hyper-V Enhanced Session Mode.
        * Initializes the 512 GB data disk attached at LUN 0 as F: and points the
          Hyper-V default VM / VHD paths at F:\Hyper-V so guest storage stays off
          the OS disk.
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

    # The scheduled task is triggered AtStartup, which can fire before the Hyper-V
    # Virtual Machine Management Service (vmms) has finished initializing its WMI
    # provider. Calling New-VMSwitch / Get-VMSwitch before then fails with:
    #   "Hyper-V encountered an error trying to access an object on computer
    #    'HVHOST' because the object was not found..."
    # Wait for vmms to reach Running and for Get-VMHost (a cheap WMI round-trip)
    # to succeed before touching any Hyper-V cmdlets.
    Write-Output 'Waiting for Hyper-V Virtual Machine Management Service (vmms) to be ready...'
    $vmmsDeadline = (Get-Date).AddMinutes(5)
    while ((Get-Date) -lt $vmmsDeadline) {
        $svc = Get-Service -Name vmms -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -eq 'Running') {
            try {
                Get-VMHost -ErrorAction Stop | Out-Null
                break
            }
            catch {
                # WMI provider not ready yet; keep polling.
            }
        }
        elseif ($svc -and $svc.Status -ne 'Running' -and $svc.StartType -ne 'Disabled') {
            try { Start-Service -Name vmms -ErrorAction Stop } catch { }
        }
        Start-Sleep -Seconds 5
    }
    if ((Get-Date) -ge $vmmsDeadline) {
        throw "Timed out waiting for the Hyper-V Virtual Machine Management Service (vmms) to become ready."
    }

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

    # Required for nested-VM connectivity:
    #  - Forwarding Enabled on the internal vNIC so the host kernel will route
    #    packets between the nested subnet and the Azure NIC (WinNAT relies on
    #    in-box IPv4 forwarding; on Windows Server it is off by default).
    #  - NetworkCategory Private so Windows Defender Firewall doesn't drop the
    #    DHCP / forwarded traffic to the nested guests (the internal vNIC has
    #    no gateway and would otherwise be classified as Public).
    Write-Output 'Enabling IPv4 forwarding and Private network profile on the NestedSwitch host vNIC...'
    Set-NetIPInterface -InterfaceIndex $hostAdapter.ifIndex -AddressFamily IPv4 -Forwarding Enabled -ErrorAction SilentlyContinue
    Set-NetConnectionProfile -InterfaceIndex $hostAdapter.ifIndex -NetworkCategory Private -ErrorAction SilentlyContinue

    if (-not (Get-NetNat -Name 'NestedNat' -ErrorAction SilentlyContinue)) {
        Write-Output "Creating NAT for $($state.NestedSubnetPrefix)..."
        New-NetNat -Name 'NestedNat' -InternalIPInterfaceAddressPrefix $state.NestedSubnetPrefix | Out-Null
    }

    # Enhanced Session Mode lets users RDP into nested VMs through VMConnect with
    # clipboard / drive / device redirection without a working network connection
    # to the guest. Server defaults this off; turn it on.
    Write-Output 'Enabling Hyper-V Enhanced Session Mode...'
    Set-VMHost -EnableEnhancedSessionMode $true

    # Move VM and VHD storage off the OS disk onto the dedicated 512 GB data disk
    # attached at LUN 0. The disk arrives as RAW; initialize it as GPT, give it
    # drive letter F:, format as NTFS, then point Hyper-V's default paths at it.
    $rawDisk = Get-Disk | Where-Object { $_.PartitionStyle -eq 'RAW' } | Sort-Object Number | Select-Object -First 1
    if ($rawDisk) {
        Write-Output "Initializing data disk (Number $($rawDisk.Number)) as F: for Hyper-V storage..."
        Initialize-Disk -Number $rawDisk.Number -PartitionStyle GPT -Confirm:$false | Out-Null
        New-Partition -DiskNumber $rawDisk.Number -DriveLetter F -UseMaximumSize | Out-Null
        Format-Volume -DriveLetter F -FileSystem NTFS -NewFileSystemLabel 'HyperV' -Confirm:$false | Out-Null
    }
    if (Test-Path 'F:\') {
        New-Item -ItemType Directory -Path 'F:\Hyper-V\VirtualMachines' -Force | Out-Null
        New-Item -ItemType Directory -Path 'F:\Hyper-V\VirtualHardDisks' -Force | Out-Null
        Write-Output "Setting Hyper-V default VM and VHD paths to F:\Hyper-V..."
        Set-VMHost -VirtualMachinePath 'F:\Hyper-V\VirtualMachines' `
                   -VirtualHardDiskPath 'F:\Hyper-V\VirtualHardDisks'
    }
    else {
        Write-Warning "Data disk for Hyper-V storage not found; leaving Hyper-V default paths on the OS disk."
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

    # Install AutomatedLab
    # All web calls below require TLS 1.2 (PSGallery, GitHub, live.sysinternals.com).
    # Server 2025 / PowerShell 5.1 defaults to TLS 1.0/1.1, so force 1.2 once up front.
    Write-Output 'Forcing TLS 1.2 for the current PowerShell session...'
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    Write-Output 'Installing the NuGet package provider...'
    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force | Out-Null
    Write-Output 'Trusting the PSGallery repository...'
    Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
    Write-Output 'Installing the AutomatedLab module from PSGallery (this can take a few minutes)...'
    Install-Module -Name AutomatedLab -Force -AllowClobber -SkipPublisherCheck -Scope AllUsers
    Write-Output 'AutomatedLab module installed.'

    Write-Output 'Setting AUTOMATEDLAB_TELEMETRY_OPTIN=true (machine and process scope)...'
    [Environment]::SetEnvironmentVariable('AUTOMATEDLAB_TELEMETRY_OPTIN', 'true', 'Machine')
    $env:AUTOMATEDLAB_TELEMETRY_OPTIN = 'true'

    Write-Output 'Creating the AutomatedLab Lab Sources folder on F:\...'
    New-LabSourcesFolder -DriveLetter F -Force

    # Enable-LabHostRemoting -Force has been observed to hang indefinitely on a
    # freshly-imaged Server 2025 host running under SYSTEM (no interactive console).
    # The transcript shows it completes all four of the steps it announces
    # (CredSSP Client, TrustedHosts, AllowFreshCredentialsWhenNTLMOnly,
    # AllowFreshCredentials) and then blocks on an internal follow-up call
    # (Enable-PSRemoting retry / WinRM listener restart) that wants an interactive
    # console. As a defence in depth, also apply those same four settings
    # directly via Enable-WSManCredSSP / WSMan:\localhost\Client\TrustedHosts /
    # the CredentialsDelegation policy registry keys BEFORE invoking the
    # AutomatedLab cmdlet, so if the cmdlet hangs and we time it out the
    # configuration the lab deployment actually needs is still in place.
    Write-Output 'Pre-applying CredSSP / TrustedHosts / credential delegation policy directly...'
    try {
        Enable-WSManCredSSP -Role Client -DelegateComputer '*' -Force | Out-Null
    }
    catch {
        Write-Warning "Enable-WSManCredSSP failed: $($_.Exception.Message)"
    }
    try {
        Set-Item -Path WSMan:\localhost\Client\TrustedHosts -Value '*' -Force | Out-Null
    }
    catch {
        Write-Warning "Setting TrustedHosts failed: $($_.Exception.Message)"
    }
    $credDelegationRoot = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CredentialsDelegation'
    foreach ($policy in @('AllowFreshCredentials', 'AllowFreshCredentialsWhenNTLMOnly')) {
        try {
            $policyKey = Join-Path $credDelegationRoot $policy
            if (-not (Test-Path $policyKey)) { New-Item -Path $policyKey -Force | Out-Null }
            New-ItemProperty -Path $credDelegationRoot -Name $policy                          -PropertyType DWord  -Value 1     -Force | Out-Null
            New-ItemProperty -Path $credDelegationRoot -Name "Concatenate${policy}_AllowFresh" -PropertyType DWord  -Value 1     -Force | Out-Null
            New-ItemProperty -Path $policyKey          -Name '1'                              -PropertyType String -Value 'WSMAN/*' -Force | Out-Null
        }
        catch {
            Write-Warning "Setting credential delegation policy '$policy' failed: $($_.Exception.Message)"
        }
    }

    Write-Output 'Enabling AutomatedLab host remoting (CredSSP / TrustedHosts / policy) with 3-minute timeout...'
    $remotingJob = Start-Job -ScriptBlock {
        try {
            Import-Module AutomatedLab -Force -ErrorAction Stop
            Enable-LabHostRemoting -Force
        }
        catch {
            Write-Output "Enable-LabHostRemoting failed inside job: $($_.Exception.Message)"
        }
    }
    if (Wait-Job -Job $remotingJob -Timeout 180) {
        Receive-Job -Job $remotingJob | ForEach-Object { Write-Output "  [remoting] $_" }
        Write-Output 'Enable-LabHostRemoting finished.'
    }
    else {
        Write-Warning 'Enable-LabHostRemoting did not complete within 3 minutes; stopping the job and continuing. CredSSP / TrustedHosts / policy were already applied directly above.'
        Stop-Job -Job $remotingJob -ErrorAction SilentlyContinue
    }
    Remove-Job -Job $remotingJob -Force -ErrorAction SilentlyContinue

    # Update-LabSysinternalsTools downloads PsTools from live.sysinternals.com and
    # has been observed to hang indefinitely on a freshly-imaged Server 2025 host
    # (workgroup, SYSTEM context, no IE first-run state, COM/BITS quirks). It is
    # purely a convenience step - none of the LAB1..LAB8 deployment below depends
    # on it - so run it in a background job with a 5-minute hard timeout and
    # warn-and-skip on hang or failure instead of blocking the whole post-boot.
    Write-Output 'Updating Sysinternals tools via AutomatedLab (with 5-minute timeout)...'
    $sysinternalsJob = Start-Job -ScriptBlock {
        try {
            Import-Module AutomatedLab -Force -ErrorAction Stop
            Update-LabSysinternalsTools
        }
        catch {
            Write-Output "Update-LabSysinternalsTools failed inside job: $($_.Exception.Message)"
        }
    }
    if (Wait-Job -Job $sysinternalsJob -Timeout 300) {
        Receive-Job -Job $sysinternalsJob | ForEach-Object { Write-Output "  [sysinternals] $_" }
        Write-Output 'Sysinternals tools update finished.'
    }
    else {
        Write-Warning 'Update-LabSysinternalsTools did not complete within 5 minutes; stopping the job and continuing.'
        Stop-Job -Job $sysinternalsJob -ErrorAction SilentlyContinue
    }
    Remove-Job -Job $sysinternalsJob -Force -ErrorAction SilentlyContinue

    Write-Output 'Setting AutomatedLab PSFConfig: DoNotWaitForLinux = true...'
    Set-PSFConfig -Module AutomatedLab -Name DoNotWaitForLinux -Value $true
    Write-Output 'AutomatedLab setup complete.'

    # Pre-stage a Windows 11 ISO into F:\LabSources\ISOs so AutomatedLab can use it as
    # an OS source without a manual download. The fwlink resolves to the current
    # multi-edition Win11 English (US) ISO. Best-effort: any failure (no internet,
    # link change, BITS unavailable, disk full, etc.) is logged as a warning and the
    # post-boot task continues - AutomatedLab itself works fine without the ISO and
    # the user can drop one in later.
    $isoDir  = 'F:\LabSources\ISOs'
    $isoPath = Join-Path $isoDir 'Windows11.iso'
    $isoUrl  = 'https://go.microsoft.com/fwlink/?linkid=2334167&clcid=0x409&culture=en-us&country=us'
    try {
        if (-not (Test-Path $isoDir)) {
            New-Item -ItemType Directory -Path $isoDir -Force | Out-Null
        }
        if (Test-Path $isoPath) {
            Write-Output "Windows 11 ISO already present at $isoPath; skipping download."
        }
        else {
            Write-Output "Downloading Windows 11 ISO to $isoPath..."
            # BITS streams straight to disk and survives transient network blips, which
            # matters for a multi-GB ISO. Fall back to Invoke-WebRequest if BITS isn't
            # available (service disabled, etc.).
            $bitsOk = $false
            try {
                Start-BitsTransfer -Source $isoUrl -Destination $isoPath -ErrorAction Stop
                $bitsOk = $true
            }
            catch {
                Write-Warning "BITS transfer failed ($($_.Exception.Message)); falling back to Invoke-WebRequest."
            }
            if (-not $bitsOk) {
                $progPref = $ProgressPreference
                $ProgressPreference = 'SilentlyContinue'  # massively faster for large downloads
                try {
                    Invoke-WebRequest -Uri $isoUrl -OutFile $isoPath -UseBasicParsing -ErrorAction Stop
                }
                finally {
                    $ProgressPreference = $progPref
                }
            }
            Write-Output "Windows 11 ISO download complete."
        }
    }
    catch {
        Write-Warning "Failed to stage Windows 11 ISO at $isoPath`: $($_.Exception.Message). Continuing without it."
        if ((Test-Path $isoPath) -and ((Get-Item $isoPath).Length -lt 100MB)) {
            # Remove a partial / truncated download so a future re-run will retry cleanly.
            Remove-Item -Path $isoPath -Force -ErrorAction SilentlyContinue
        }
    }

    # Deploy 8 AutomatedLab labs (LAB1..LAB8), each containing a single Windows 11 VM
    # with 4 GB dynamic memory, attached to the existing 'NestedSwitch' internal switch
    # so the VM gets DHCP / DNS / NAT from this host. For each VM we then:
    #   1. Run Get-WindowsAutopilotInfo inside the guest and write the hash to
    #      C:\HWID\<COMPUTERNAME>.csv (so LAB1.csv .. LAB8.csv).
    #   2. Pull the CSV onto the host at F:\LabSources\Autopilot\LAB<n>.csv.
    #   3. Sysprep /generalize /oobe /shutdown so the VM is sealed back to OOBE.
    #   4. Snapshot the powered-off VM as 'AutopilotReady' so the demo can revert to
    #      a clean, pre-enrolled-device state on every run.
    # The whole block is best-effort: any per-lab failure is logged and we move on to
    # the next one; if the ISO never made it onto disk we skip the block entirely.
    $autopilotDir     = 'F:\LabSources\Autopilot'
    $captureScriptDir = 'F:\LabSources\CustomAssets\Scripts'
    $captureScript    = Join-Path $captureScriptDir 'CaptureHash.ps1'

    function Wait-LabRemotingReady {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory = $true)] [string]$ComputerName,
            [int]$TimeoutMinutes = 25,
            [int]$PollSeconds = 20
        )

        $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
        while ((Get-Date) -lt $deadline) {
            try {
                $probe = Invoke-LabCommand -ComputerName $ComputerName -ScriptBlock { 'READY' } -PassThru -NoDisplay -ErrorAction Stop
                if ($probe -match 'READY') {
                    return $true
                }
            }
            catch {
                # VM is still booting / configuring WinRM; keep waiting.
            }
            Start-Sleep -Seconds $PollSeconds
        }

        return $false
    }

    if (Test-Path $isoPath) {
        try {
            # AutomatedLab uses non-terminating errors internally for control flow.
            # Keep those non-terminating while running AL commands and restore strict
            # error handling for the rest of this script afterwards.
            $scriptEapBackup = $ErrorActionPreference
            $scriptConfirmBackup = $ConfirmPreference
            $scriptConfirmDefaultBackupExists = $PSDefaultParameterValues.ContainsKey('*:Confirm')
            if ($scriptConfirmDefaultBackupExists) {
                $scriptConfirmDefaultBackup = $PSDefaultParameterValues['*:Confirm']
            }
            $ErrorActionPreference = 'Continue'
            $ConfirmPreference = 'None'
            $PSDefaultParameterValues['*:Confirm'] = $false

            if (-not (Test-Path $autopilotDir))     { New-Item -ItemType Directory -Path $autopilotDir     -Force | Out-Null }
            if (-not (Test-Path $captureScriptDir)) { New-Item -ItemType Directory -Path $captureScriptDir -Force | Out-Null }

            # CaptureHash.ps1 runs inside each lab VM. Installs the community
            # Get-WindowsAutopilotInfo script and writes the device's hardware hash
            # CSV to C:\HWID\<COMPUTERNAME>.csv. The host then copies the CSV out
            # and renames are unnecessary because the VMs are already named LAB1..LAB8.
            #
            # NOTE: this is intentionally NOT a nested here-string (@'...'@). The
            # outer post-boot script is itself a single-quoted here-string in
            # HVHostSetup.ps1, and a nested '@ at column 1 would terminate the
            # outer here-string prematurely and break parsing of HVHostSetup.ps1.
            # Building the content from an array of single-quoted lines avoids
            # that gotcha entirely.
            $captureScriptContent = @(
                '$ErrorActionPreference = ''Stop'''
                'if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {'
                '    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force | Out-Null'
                '}'
                'Set-PSRepository -Name PSGallery -InstallationPolicy Trusted'
                'Install-Script -Name Get-WindowsAutopilotInfo -Force | Out-Null'
                'New-Item -ItemType Directory -Path C:\HWID -Force | Out-Null'
                '$csv = "C:\HWID\$($env:COMPUTERNAME).csv"'
                '& "$env:ProgramFiles\WindowsPowerShell\Scripts\Get-WindowsAutopilotInfo.ps1" -OutputFile $csv'
            ) -join [Environment]::NewLine
            Set-Content -Path $captureScript -Value $captureScriptContent -Encoding UTF8

            # The Windows 11 fwlink ISO is a multi-edition image whose actual
            # OperatingSystemName (as seen by AutomatedLab) varies by build - e.g.
            # 'Windows 11 Pro', 'Windows 11 Enterprise Evaluation', etc. Hard-coding
            # one of those names breaks Add-LabMachineDefinition when MS rev's the
            # ISO. Ask AutomatedLab what it actually sees inside the ISO and pick
            # the first edition. Preference order: Pro > Enterprise > anything.
            Write-Output "Detecting OperatingSystemName from $isoPath via Get-LabAvailableOperatingSystem..."
            $availableOs = Get-LabAvailableOperatingSystem -Path $isoPath
            if (-not $availableOs) {
                throw "Get-LabAvailableOperatingSystem returned nothing for $isoPath."
            }
            $preferredOs = $availableOs | Where-Object { $_.OperatingSystemName -match 'Windows 11 Pro' } | Select-Object -First 1
            if (-not $preferredOs) {
                $preferredOs = $availableOs | Where-Object { $_.OperatingSystemName -match 'Windows 11 Enterprise' } | Select-Object -First 1
            }
            if (-not $preferredOs) {
                $preferredOs = $availableOs | Select-Object -First 1
            }
            $operatingSystemName = $preferredOs.OperatingSystemName
            Write-Output "Selected operating system: '$operatingSystemName'."

            foreach ($labName in (1..8 | ForEach-Object { "LAB$_" })) {
                try {
                    # Skip labs that already exist so re-runs of the post-boot task are
                    # idempotent and don't blow away in-progress work.
                    $labRoot = Join-Path (Get-LabSourcesLocation) ('Labs\' + $labName)
                    if (Test-Path $labRoot) {
                        Write-Output "Lab '$labName' already exists at $labRoot; skipping."
                        continue
                    }

                    Write-Output "Defining lab '$labName'..."
                    New-LabDefinition -Name $labName -DefaultVirtualizationEngine HyperV -VmPath 'F:\Hyper-V\VirtualMachines'
                    Add-LabIsoImageDefinition -Name "Win11-$labName" -Path $isoPath

                    # Re-declare the network definition so AutomatedLab attaches the
                    # machine to the existing 'NestedSwitch' (internal) we created
                    # earlier in this same post-boot script. -AddressSpace matches
                    # the nested subnet so AutomatedLab doesn't try to invent one.
                    Add-LabVirtualNetworkDefinition `
                        -Name 'NestedSwitch' `
                        -HyperVProperties @{ SwitchType = 'Internal' } `
                        -AddressSpace $state.NestedSubnetPrefix

                    # Use DHCP from the host-side DHCP scope (set up earlier) so the
                    # VM gets the host vNIC as default gateway and the DC as DNS.
                    $nic = New-LabNetworkAdapterDefinition -VirtualSwitch 'NestedSwitch' -UseDhcp

                    Add-LabMachineDefinition `
                        -Name $labName `
                        -OperatingSystem $operatingSystemName `
                        -Memory    4GB `
                        -MinMemory 512MB `
                        -MaxMemory 4GB `
                        -NetworkAdapter $nic

                    Write-Output "Installing lab '$labName' ($operatingSystemName) with checkpoints disabled..."
                    Install-Lab -CreateCheckPoints:$false

                    Write-Output "Waiting for remoting to become available on '$labName'..."
                    if (-not (Wait-LabRemotingReady -ComputerName $labName -TimeoutMinutes 25 -PollSeconds 20)) {
                        throw "Remoting did not become ready on '$labName' within the timeout window."
                    }

                    Write-Output "Capturing Autopilot hash for '$labName'..."
                    $captureSuccess = $false
                    for ($attempt = 1; $attempt -le 3 -and -not $captureSuccess; $attempt++) {
                        try {
                            Invoke-LabCommand -ComputerName $labName -FilePath $captureScript -NoDisplay -ErrorAction Stop
                            $captureSuccess = $true
                        }
                        catch {
                            if ($attempt -lt 3) {
                                Write-Warning "Autopilot capture attempt $attempt failed on '$labName': $($_.Exception.Message). Retrying in 30 seconds..."
                                Start-Sleep -Seconds 30
                            }
                            else {
                                throw
                            }
                        }
                    }

                    # Pull the CSV onto the host as F:\LabSources\Autopilot\LAB<n>.csv.
                    $hostCsv = Join-Path $autopilotDir ($labName + '.csv')
                    $csvContent = Invoke-LabCommand -ComputerName $labName -ScriptBlock {
                        Get-Content -Path ("C:\HWID\" + $env:COMPUTERNAME + ".csv") -Raw
                    } -PassThru -NoDisplay
                    if ($csvContent) {
                        Set-Content -Path $hostCsv -Value $csvContent -Encoding UTF8
                        Write-Output "Autopilot hash for '$labName' saved to $hostCsv."
                    }
                    else {
                        Write-Warning "No Autopilot hash CSV captured from '$labName'."
                    }

                    # Sysprep /generalize /oobe /shutdown without -Wait: WinRM will
                    # be torn down when the VM shuts down, which would otherwise hang
                    # Invoke-LabCommand. Poll Get-VM state from the host instead.
                    Write-Output "Sysprep'ing '$labName' back to OOBE and shutting it down..."
                    Invoke-LabCommand -ComputerName $labName -ScriptBlock {
                        Start-Process -FilePath "$env:SystemRoot\System32\Sysprep\Sysprep.exe" `
                                      -ArgumentList '/generalize /oobe /shutdown /quiet'
                    } -NoDisplay

                    $shutdownDeadline = (Get-Date).AddMinutes(30)
                    while ((Get-Date) -lt $shutdownDeadline) {
                        $vm = Get-VM -Name $labName -ErrorAction SilentlyContinue
                        if ($vm -and $vm.State -eq 'Off') { break }
                        Start-Sleep -Seconds 10
                    }
                    if (((Get-VM -Name $labName -ErrorAction SilentlyContinue).State) -ne 'Off') {
                        Write-Warning "'$labName' did not shut down within the deadline; forcing stop before snapshot."
                        Stop-VM -Name $labName -TurnOff -Force -ErrorAction SilentlyContinue
                    }

                    Write-Output "Snapshotting '$labName' as 'AutopilotReady'..."
                    Checkpoint-VM -Name $labName -SnapshotName 'AutopilotReady'
                }
                catch {
                    Write-Warning "Lab '$labName' setup failed: $($_.Exception.Message). Continuing with the next lab."
                }
            }
        }
        catch {
            Write-Warning "AutomatedLab deployment block failed: $($_.Exception.Message). Continuing."
        }
        finally {
            if ($scriptEapBackup) {
                $ErrorActionPreference = $scriptEapBackup
            }
            if ($scriptConfirmBackup) {
                $ConfirmPreference = $scriptConfirmBackup
            }
            if ($scriptConfirmDefaultBackupExists) {
                $PSDefaultParameterValues['*:Confirm'] = $scriptConfirmDefaultBackup
            }
            else {
                [void]$PSDefaultParameterValues.Remove('*:Confirm')
            }
        }
    }
    else {
        Write-Warning "Windows 11 ISO not present at $isoPath; skipping LAB1..LAB8 deployment."
    }

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
