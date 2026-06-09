<#
.SYNOPSIS
    Builds a bootable "golden" Windows VHDX from a Windows ISO using only in-box
    tooling (DISM + the Hyper-V / Storage PowerShell modules).

.DESCRIPTION
    Creates a UEFI/GPT dynamic VHDX, applies a single Windows edition out of the
    ISO's install.wim/install.esd with Expand-WindowsImage, and writes the UEFI
    boot files with bcdboot. The resulting VHDX boots straight into the Windows
    out-of-box experience (OOBE) when attached to a Generation 2 VM.

    This is the supported, AutomatedLab-free replacement for the old lab build:
    because each lab VM boots from an *applied* disk image rather than from the
    ISO itself, the "Press any key to boot from CD or DVD..." prompt never
    appears, so unattended provisioning can't get stuck on it.

    Re-run this script whenever a newer Windows ISO is published or to try a
    different edition - point -IsoPath at the new ISO (and optionally pass
    -Edition) and add -Force to replace an existing golden VHDX.

.PARAMETER IsoPath
    Path to the Windows ISO to apply. Required.

.PARAMETER VhdxPath
    Output path for the golden VHDX. Defaults to
    F:\VMLABSource\GoldenImages\Win11.vhdx.

.PARAMETER Edition
    Name (or partial name) of the Windows edition to apply, matched against the
    ImageName values inside the ISO (e.g. 'Pro', 'Enterprise',
    'Windows 11 Enterprise Evaluation'). If omitted, the script auto-selects the
    plain 'Pro' edition, then any edition containing 'Pro', then 'Enterprise',
    then the first image in the ISO.

.PARAMETER SizeGB
    Size of the dynamic VHDX in GB. Defaults to 64.

.PARAMETER Force
    Replace an existing VHDX at -VhdxPath instead of failing.

.EXAMPLE
    .\New-GoldenImage.ps1 -IsoPath F:\VMLABSource\ISOs\Windows11.iso

.EXAMPLE
    .\New-GoldenImage.ps1 -IsoPath D:\Win11_Enterprise_Eval.iso `
        -Edition 'Windows 11 Enterprise Evaluation' -Force
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string]$IsoPath,
    [string]$VhdxPath = 'F:\VMLABSource\GoldenImages\Win11.vhdx',
    [string]$Edition,
    [int]$SizeGB = 64,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

function Get-FreeDriveLetter {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([int]$Count = 1)

    $used = @(Get-Volume | Where-Object { $_.DriveLetter } | ForEach-Object { [string]$_.DriveLetter })
    $used += @(Get-PSDrive -PSProvider FileSystem | ForEach-Object { $_.Name })

    $free = [System.Collections.Generic.List[string]]::new()
    foreach ($code in ([int][char]'Z')..([int][char]'G')) {
        $letter = [string][char]$code
        if ($used -notcontains $letter) {
            $free.Add($letter)
            if ($free.Count -ge $Count) { break }
        }
    }
    if ($free.Count -lt $Count) {
        throw "Could not find $Count free drive letter(s) to mount the working volumes."
    }
    return [string[]]$free
}

if (-not (Test-Path -LiteralPath $IsoPath)) {
    throw "ISO not found at '$IsoPath'."
}

# Resolve to a full path so Mount-DiskImage / Dismount-DiskImage agree on it.
$IsoPath = (Resolve-Path -LiteralPath $IsoPath).Path

if (Test-Path -LiteralPath $VhdxPath) {
    if ($Force) {
        Write-Output "Removing existing golden image at $VhdxPath (-Force)..."
        Remove-Item -LiteralPath $VhdxPath -Force
    }
    else {
        throw "A golden image already exists at '$VhdxPath'. Re-run with -Force to rebuild it."
    }
}

$outDir = Split-Path -Parent $VhdxPath
if ($outDir -and -not (Test-Path -LiteralPath $outDir)) {
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
}

$isoMounted  = $false
$vhdMounted  = $false
$createdVhdx = $false
$success     = $false

try {
    Write-Output "Mounting ISO '$IsoPath'..."
    $isoImage   = Mount-DiskImage -ImagePath $IsoPath -PassThru
    $isoMounted = $true

    # The volume can take a moment to surface after the image is mounted.
    $isoDrive = $null
    for ($i = 0; $i -lt 10 -and -not $isoDrive; $i++) {
        Start-Sleep -Seconds 1
        $isoDrive = ($isoImage | Get-Volume).DriveLetter
        if (-not $isoDrive) {
            $isoDrive = (Get-DiskImage -ImagePath $IsoPath | Get-Volume).DriveLetter
        }
    }
    if (-not $isoDrive) {
        throw "Unable to determine the drive letter of the mounted ISO."
    }
    Write-Output "ISO mounted at ${isoDrive}:."

    $sources   = "${isoDrive}:\sources"
    $imagePath = $null
    foreach ($name in @('install.wim', 'install.esd')) {
        $candidate = Join-Path $sources $name
        if (Test-Path -LiteralPath $candidate) { $imagePath = $candidate; break }
    }
    if (-not $imagePath) {
        throw "No install.wim or install.esd found under '$sources'."
    }
    Write-Output "Using image file '$imagePath'."

    $images = Get-WindowsImage -ImagePath $imagePath
    if (-not $images) {
        throw "Get-WindowsImage returned no editions for '$imagePath'."
    }

    if ($Edition) {
        $chosen = $images | Where-Object { $_.ImageName -like "*$Edition*" } | Select-Object -First 1
        if (-not $chosen) {
            throw ("Edition '$Edition' not found in the ISO. Available editions: " +
                ($images.ImageName -join ', '))
        }
    }
    else {
        # Prefer the plain 'Pro' edition, then any Pro, then Enterprise, then first.
        $chosen = $images | Where-Object { ($_.ImageName).Trim() -match '(?i)Pro$' } | Select-Object -First 1
        if (-not $chosen) { $chosen = $images | Where-Object { $_.ImageName -match '(?i)Pro' }        | Select-Object -First 1 }
        if (-not $chosen) { $chosen = $images | Where-Object { $_.ImageName -match '(?i)Enterprise' } | Select-Object -First 1 }
        if (-not $chosen) { $chosen = $images | Select-Object -First 1 }
    }
    $index = $chosen.ImageIndex
    Write-Output "Selected edition '$($chosen.ImageName)' (index $index)."

    $letters  = Get-FreeDriveLetter -Count 2
    $sysDrive = $letters[0]
    $osDrive  = $letters[1]

    Write-Output "Creating $SizeGB GB dynamic VHDX at $VhdxPath..."
    New-VHD -Path $VhdxPath -SizeBytes ($SizeGB * 1GB) -Dynamic | Out-Null
    $createdVhdx = $true

    $vhd        = Mount-VHD -Path $VhdxPath -Passthru
    $vhdMounted = $true
    $disk       = Get-Disk -Number $vhd.DiskNumber
    if ($disk.PartitionStyle -eq 'RAW') {
        Initialize-Disk -Number $disk.Number -PartitionStyle GPT | Out-Null
    }

    # EFI System Partition (FAT32) - holds the boot files bcdboot writes.
    Write-Output "Creating EFI system partition (${sysDrive}:)..."
    $espPart = New-Partition -DiskNumber $disk.Number -Size 260MB -GptType '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'
    Start-Sleep -Milliseconds 500
    $espPart | Format-Volume -FileSystem FAT32 -NewFileSystemLabel 'System' -Confirm:$false | Out-Null
    $espPart | Set-Partition -NewDriveLetter $sysDrive

    # Microsoft Reserved Partition (no volume / drive letter).
    New-Partition -DiskNumber $disk.Number -Size 16MB -GptType '{e3c9e316-0b5c-4db8-817d-f92df00215ae}' | Out-Null

    # Windows partition (NTFS, remaining space).
    Write-Output "Creating Windows partition (${osDrive}:)..."
    $osPart = New-Partition -DiskNumber $disk.Number -UseMaximumSize -GptType '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}'
    Start-Sleep -Milliseconds 500
    $osPart | Format-Volume -FileSystem NTFS -NewFileSystemLabel 'Windows' -Confirm:$false | Out-Null
    $osPart | Set-Partition -NewDriveLetter $osDrive

    Write-Output "Applying '$($chosen.ImageName)' to ${osDrive}:\ (this can take several minutes)..."
    Expand-WindowsImage -ImagePath $imagePath -Index $index -ApplyPath "${osDrive}:\" | Out-Null

    Write-Output "Writing UEFI boot files to ${sysDrive}:..."
    & "$env:SystemRoot\System32\bcdboot.exe" "${osDrive}:\Windows" /s "${sysDrive}:" /f UEFI
    if ($LASTEXITCODE -ne 0) {
        throw "bcdboot failed with exit code $LASTEXITCODE."
    }

    $success = $true
    Write-Output "Golden image created successfully at $VhdxPath (edition '$($chosen.ImageName)')."
}
finally {
    if ($vhdMounted) {
        Dismount-VHD -Path $VhdxPath -ErrorAction SilentlyContinue
    }
    if ($isoMounted) {
        Dismount-DiskImage -ImagePath $IsoPath -ErrorAction SilentlyContinue | Out-Null
    }
    # Don't leave a half-built image behind - the orchestrator treats the mere
    # presence of the VHDX as "already built" and would skip a clean rebuild.
    if ($createdVhdx -and -not $success -and (Test-Path -LiteralPath $VhdxPath)) {
        Write-Warning "Removing incomplete golden image at $VhdxPath."
        Remove-Item -LiteralPath $VhdxPath -Force -ErrorAction SilentlyContinue
    }
}
