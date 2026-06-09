<#
.SYNOPSIS
    Creates Generation 2 nested lab VMs from a golden Windows VHDX and checkpoints
    each one once it reaches the out-of-box experience (OOBE).

.DESCRIPTION
    For each VM the script makes an independent full copy of the golden VHDX
    (no differencing disks), then builds a Generation 2 VM with:
      * 4 virtual processors,
      * dynamic memory (2 GB startup, 2 GB minimum, 4 GB maximum),
      * Secure Boot enabled (MicrosoftWindows template),
      * a virtual TPM backed by a local key protector,
      * a single NIC on the existing internal switch (NestedSwitch) so the guest
        gets its IP, gateway and DNS from the host's DHCP scope and reaches the
        internet and the domain controller, and
      * the hard disk set as the first boot device (so the VM boots the applied
        image straight away instead of waiting on PXE).

    After starting a VM the script waits for the Hyper-V Heartbeat integration
    service to report healthy, lets the first-boot specialize pass and its reboot
    settle, then takes a Standard (memory-inclusive) checkpoint named 'OOBE' so
    the lab can be reverted to a clean OOBE screen at any time.

    The administrator account and all other guest defaults are left untouched -
    nothing is injected into the image.

.PARAMETER Count
    Number of lab VMs to create. Defaults to 6.

.PARAMETER GoldenVhdxPath
    Path to the golden VHDX produced by New-GoldenImage.ps1.

.PARAMETER SwitchName
    Name of the internal Hyper-V switch to attach the VMs to. Defaults to
    NestedSwitch.

.PARAMETER NamePrefix
    VM name prefix; VMs are named <NamePrefix>1..<NamePrefix><Count>. Defaults to
    LabVM.

.PARAMETER VCpu
    Virtual processor count per VM. Defaults to 4.

.PARAMETER StartupMB / MinMB / MaxMB
    Dynamic memory startup / minimum / maximum in MB. Default 2048 / 2048 / 4096.

.PARAMETER VhdRoot
    Folder that receives the per-VM VHDX copies. Defaults to F:\VMLABSource\VHDs.

.PARAMETER CheckpointName
    Name of the checkpoint taken once the VM reaches OOBE. Defaults to OOBE.

.PARAMETER HeartbeatTimeoutMinutes
    How long to wait for each heartbeat signal. Defaults to 20.

.PARAMETER OobeSettleSeconds
    Pause after the first heartbeat to ride out the specialize reboot before the
    second heartbeat check and checkpoint. Defaults to 150.

.EXAMPLE
    .\New-LabVMs.ps1 -GoldenVhdxPath F:\VMLABSource\GoldenImages\Win11.vhdx
#>
[CmdletBinding()]
param(
    [int]$Count = 6,
    [string]$GoldenVhdxPath = 'F:\VMLABSource\GoldenImages\Win11.vhdx',
    [string]$SwitchName = 'NestedSwitch',
    [string]$NamePrefix = 'LabVM',
    [int]$VCpu = 4,
    [int]$StartupMB = 2048,
    [int]$MinMB = 2048,
    [int]$MaxMB = 4096,
    [string]$VhdRoot = 'F:\VMLABSource\VHDs',
    [string]$CheckpointName = 'OOBE',
    [int]$HeartbeatTimeoutMinutes = 20,
    [int]$OobeSettleSeconds = 150
)

$ErrorActionPreference = 'Stop'

function Wait-VMHeartbeat {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$VMName,
        [int]$TimeoutMinutes = 20,
        [int]$PollSeconds = 10
    )

    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    while ((Get-Date) -lt $deadline) {
        $hb = Get-VMIntegrationService -VMName $VMName -Name 'Heartbeat' -ErrorAction SilentlyContinue
        if ($hb -and $hb.Enabled -and $hb.PrimaryStatusDescription -like 'OK*') {
            return $true
        }
        Start-Sleep -Seconds $PollSeconds
    }
    return $false
}

if (-not (Test-Path -LiteralPath $GoldenVhdxPath)) {
    throw "Golden VHDX not found at '$GoldenVhdxPath'. Run New-GoldenImage.ps1 first."
}

if (-not (Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue)) {
    throw "Hyper-V switch '$SwitchName' does not exist."
}

if (-not (Test-Path -LiteralPath $VhdRoot)) {
    New-Item -ItemType Directory -Path $VhdRoot -Force | Out-Null
}

for ($i = 1; $i -le $Count; $i++) {
    $vmName = "$NamePrefix$i"

    try {
        if (Get-VM -Name $vmName -ErrorAction SilentlyContinue) {
            Write-Output "VM '$vmName' already exists; skipping."
            continue
        }

        Write-Output "=== Creating '$vmName' ==="
        $vmVhd = Join-Path $VhdRoot "$vmName.vhdx"
        if (Test-Path -LiteralPath $vmVhd) {
            Remove-Item -LiteralPath $vmVhd -Force
        }
        Write-Output "Copying golden image to $vmVhd..."
        Copy-Item -LiteralPath $GoldenVhdxPath -Destination $vmVhd -Force

        New-VM -Name $vmName -Generation 2 -MemoryStartupBytes ($StartupMB * 1MB) `
            -VHDPath $vmVhd -SwitchName $SwitchName | Out-Null

        Set-VMProcessor -VMName $vmName -Count $VCpu
        Set-VMMemory -VMName $vmName -DynamicMemoryEnabled $true `
            -StartupBytes ($StartupMB * 1MB) `
            -MinimumBytes ($MinMB * 1MB) `
            -MaximumBytes ($MaxMB * 1MB)

        # Standard checkpoints capture live memory, so reverting returns to the
        # exact OOBE screen. Disable automatic checkpoints so starting the VM
        # doesn't create an extra one.
        Set-VM -Name $vmName -CheckpointType Standard -AutomaticCheckpointsEnabled $false

        # Secure Boot + vTPM (both required by the brief; Gen2 only). A local key
        # protector is created in-box with Set-VMKeyProtector -NewLocalKeyProtector,
        # which needs no Host Guardian Service or Shielded-VM RSAT tooling.
        Set-VMFirmware -VMName $vmName -EnableSecureBoot On -SecureBootTemplate 'MicrosoftWindows'
        Set-VMKeyProtector -VMName $vmName -NewLocalKeyProtector
        Enable-VMTpm -VMName $vmName

        # Boot the applied disk first so the VM goes straight to OOBE instead of
        # spending time on a PXE attempt.
        $bootDisk = Get-VMHardDiskDrive -VMName $vmName
        Set-VMFirmware -VMName $vmName -FirstBootDevice $bootDisk

        Write-Output "Starting '$vmName'..."
        Start-VM -Name $vmName

        Write-Output "Waiting for '$vmName' to come up (specialize pass)..."
        if (-not (Wait-VMHeartbeat -VMName $vmName -TimeoutMinutes $HeartbeatTimeoutMinutes)) {
            Write-Warning "'$vmName' never reported a heartbeat; leaving it running and skipping the checkpoint."
            continue
        }

        # Ride out the first-boot specialize reboot before checking again.
        Start-Sleep -Seconds $OobeSettleSeconds

        Write-Output "Waiting for '$vmName' to settle at OOBE..."
        if (-not (Wait-VMHeartbeat -VMName $vmName -TimeoutMinutes $HeartbeatTimeoutMinutes)) {
            Write-Warning "'$vmName' did not report a stable heartbeat after the settle delay; leaving it running and skipping the checkpoint."
            continue
        }

        # Small extra pause so the OOBE UI is fully painted before the snapshot.
        Start-Sleep -Seconds 30

        Write-Output "Checkpointing '$vmName' as '$CheckpointName'..."
        Checkpoint-VM -Name $vmName -SnapshotName $CheckpointName

        Write-Output "'$vmName' is running at OOBE with checkpoint '$CheckpointName'."
    }
    catch {
        Write-Warning "Failed to provision '$vmName': $($_.Exception.Message). Continuing with the next VM."
    }
}

Write-Output 'Lab VM provisioning complete.'
