<#
.SYNOPSIS
    Configures the Hyper-V host VM for the AzureVMLabs demo environment.

.DESCRIPTION
    Based on the HVHostSetup script from
    https://github.com/azure/azure-quickstart-templates/tree/master/demos/nested-vms-in-virtual-network
    with the addition of a -DNSServerAddress parameter so nested VMs use the Domain Controller
    (10.0.3.4 by default) for DNS.

    The script:
      * Installs the Hyper-V, Routing (RRAS) and DHCP-Server roles.
      * Creates an internal Hyper-V virtual switch named "NestedSwitch" with a host vNIC
        sitting in the nested (Ghosted) subnet.
      * Configures RRAS to NAT nested-VM traffic out through the host's primary Azure NIC,
        and to route the Azure-VMs subnet traffic via the secondary Hyper-V LAN NIC.
      * Configures a DHCP scope for the Ghosted subnet that hands out the Domain Controller
        IP as the DNS server, so nested VMs connected to NestedSwitch get internet
        connectivity and use the DC for name resolution.

.PARAMETER NIC1IPAddress
    Private IP address of the host's primary (NAT subnet) NIC. Used as the NAT external address.

.PARAMETER NIC2IPAddress
    Private IP address of the host's secondary (Hyper-V LAN subnet) NIC. Used as the next-hop
    that the Azure-VMs subnet UDR points at.

.PARAMETER GhostedSubnetPrefix
    CIDR of the nested (Ghosted) subnet used by the internal Hyper-V switch (default 10.0.2.0/24).

.PARAMETER VirtualNetworkPrefix
    CIDR of the entire Azure virtual network (default 10.0.0.0/22).

.PARAMETER DNSServerAddress
    IP address of the DNS server (Domain Controller) advertised to nested VMs through DHCP.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string]$NIC1IPAddress,
    [Parameter(Mandatory = $true)] [string]$NIC2IPAddress,
    [Parameter(Mandatory = $true)] [string]$GhostedSubnetPrefix,
    [Parameter(Mandatory = $true)] [string]$VirtualNetworkPrefix,
    [Parameter(Mandatory = $true)] [string]$DNSServerAddress
)

$ErrorActionPreference = 'Stop'
Start-Transcript -Path "$env:SystemDrive\HVHostSetup.log" -Append

try {
    Write-Output "Installing Hyper-V, RRAS and DHCP roles..."
    Install-WindowsFeature -Name Hyper-V, RemoteAccess, Routing, DHCP -IncludeManagementTools -IncludeAllSubFeature | Out-Null

    # Parse Ghosted subnet so we can derive the host vNIC IP, DHCP scope and NAT subnet.
    $ghostedParts = $GhostedSubnetPrefix.Split('/')
    $ghostedNetwork = $ghostedParts[0]              # e.g. 10.0.2.0
    $ghostedPrefix  = [int]$ghostedParts[1]
    $ghostedOctets  = $ghostedNetwork.Split('.')

    # Host vNIC inside the internal switch will be x.x.x.1 of the Ghosted subnet.
    $hostVNicIP    = '{0}.{1}.{2}.1'   -f $ghostedOctets[0], $ghostedOctets[1], $ghostedOctets[2]
    $scopeStart    = '{0}.{1}.{2}.100' -f $ghostedOctets[0], $ghostedOctets[1], $ghostedOctets[2]
    $scopeEnd      = '{0}.{1}.{2}.200' -f $ghostedOctets[0], $ghostedOctets[1], $ghostedOctets[2]

    # Translate the Ghosted prefix into a dotted-quad subnet mask.
    $maskInt   = ([uint32]0xFFFFFFFF) -shl (32 - $ghostedPrefix)
    $maskBytes = [BitConverter]::GetBytes([uint32]$maskInt)
    if ([BitConverter]::IsLittleEndian) { [Array]::Reverse($maskBytes) }
    $subnetMask = ([System.Net.IPAddress]::new($maskBytes)).ToString()

    Write-Output "Creating internal Hyper-V virtual switch 'NestedSwitch'..."
    if (-not (Get-VMSwitch -Name 'NestedSwitch' -ErrorAction SilentlyContinue)) {
        New-VMSwitch -Name 'NestedSwitch' -SwitchType Internal | Out-Null
    }

    # Locate the host vNIC created by the internal switch and assign the Ghosted gateway IP.
    $hostAdapter = Get-NetAdapter | Where-Object { $_.Name -like '*NestedSwitch*' } | Select-Object -First 1
    if ($null -eq $hostAdapter) {
        throw "Unable to locate the host virtual adapter for the NestedSwitch."
    }
    if (-not (Get-NetIPAddress -InterfaceIndex $hostAdapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object IPAddress -eq $hostVNicIP)) {
        New-NetIPAddress -InterfaceIndex $hostAdapter.ifIndex -IPAddress $hostVNicIP -PrefixLength $ghostedPrefix | Out-Null
    }

    Write-Output "Configuring RRAS for NAT and routing..."
    # Install-RemoteAccess requires the RemoteAccess role; configure for routing and NAT.
    Install-RemoteAccess -VpnType RoutingOnly -ErrorAction SilentlyContinue | Out-Null

    # netsh is still the most reliable way to scriptably configure RRAS NAT.
    cmd.exe /c "netsh routing ip nat install" | Out-Null
    cmd.exe /c "netsh routing ip nat add interface name=`"$($hostAdapter.Name)`" mode=PRIVATE" | Out-Null

    $externalAdapter = Get-NetAdapter | Where-Object { (Get-NetIPAddress -InterfaceIndex $_.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object IPAddress -eq $NIC1IPAddress) } | Select-Object -First 1
    if ($null -ne $externalAdapter) {
        cmd.exe /c "netsh routing ip nat add interface name=`"$($externalAdapter.Name)`" mode=FULL" | Out-Null
    }

    Write-Output "Enabling IP forwarding on all adapters so the host routes nested traffic..."
    Set-NetIPInterface -Forwarding Enabled -ErrorAction SilentlyContinue

    Write-Output "Configuring DHCP scope for nested VMs..."
    Add-DhcpServerv4Scope `
        -Name 'NestedVMs' `
        -StartRange $scopeStart `
        -EndRange $scopeEnd `
        -SubnetMask $subnetMask `
        -State Active `
        -ErrorAction SilentlyContinue | Out-Null

    Set-DhcpServerv4OptionValue `
        -ScopeId $ghostedNetwork `
        -Router $hostVNicIP `
        -DnsServer $DNSServerAddress `
        -Force `
        -ErrorAction SilentlyContinue | Out-Null

    # Authorize the DHCP server locally so it serves the nested switch even without AD.
    Set-Service -Name DHCPServer -StartupType Automatic
    Start-Service -Name DHCPServer -ErrorAction SilentlyContinue

    Write-Output "Hyper-V host configuration complete."
    Write-Output "Nested VMs connected to 'NestedSwitch' will receive DHCP from $hostVNicIP and use $DNSServerAddress as their DNS server."
    Write-Output "Outbound traffic from nested VMs is NATted via $NIC1IPAddress; Azure VNet ($VirtualNetworkPrefix) is reachable through $NIC2IPAddress."
}
finally {
    Stop-Transcript
}

# Hyper-V install requires a reboot before VMs can be created.
shutdown.exe /r /t 30 /c "Rebooting to complete Hyper-V installation" | Out-Null
