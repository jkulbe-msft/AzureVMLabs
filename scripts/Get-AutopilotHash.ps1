<#
.SYNOPSIS
    Captures the Windows Autopilot hardware hash from the machine it runs on.

.DESCRIPTION
    Reads the device's hardware hash straight from WMI/CIM
    (MDM_DevDetail_Ext01.DeviceHardwareData) and the serial number from
    Win32_BIOS, then writes a strict, Intune-importable CSV
    (Device Serial Number,Windows Product ID,Hardware Hash) and echoes it to the
    console.

    Designed to be copy/pasted into a lab VM that is sitting at OOBE: press
    Shift+F10 to open a command prompt, run `powershell`, then paste this
    script's contents (or run the staged copy if you have a way to get the file
    in). No internet, sign-in or active user account is required for the default
    offline capture - it reads the same WMI data the official
    Get-WindowsAutopilotInfo script uses.

    Pass -Online to instead download and run the official Get-WindowsAutopilotInfo
    script and upload the hash directly to Intune (this path needs internet and an
    interactive Entra sign-in with sufficient rights).

.PARAMETER OutputFolder
    Folder to write the CSV into. Defaults to C:\HWID.

.PARAMETER OutputFile
    Full path to the CSV. Overrides -OutputFolder when supplied. Defaults to
    <OutputFolder>\<serial>.csv.

.PARAMETER GroupTag
    Optional Autopilot group tag. Adds a 'Group Tag' column.

.PARAMETER AssignedUser
    Optional assigned user UPN. Adds an 'Assigned User' column (Intune direct
    import only).

.PARAMETER Online
    Use the official Get-WindowsAutopilotInfo script to upload the hash to Intune
    instead of writing a local CSV.

.EXAMPLE
    .\Get-AutopilotHash.ps1

.EXAMPLE
    .\Get-AutopilotHash.ps1 -OutputFile C:\HWID\LabVM1.csv -GroupTag 'AVDLab'

.EXAMPLE
    .\Get-AutopilotHash.ps1 -Online
#>
[CmdletBinding()]
param(
    [string]$OutputFolder = 'C:\HWID',
    [string]$OutputFile,
    [string]$GroupTag,
    [string]$AssignedUser,
    [switch]$Online
)

$ErrorActionPreference = 'Stop'

if ($Online) {
    Write-Output 'Uploading the hardware hash to Intune via Get-WindowsAutopilotInfo...'
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force | Out-Null
    }
    Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
    Install-Script -Name Get-WindowsAutopilotInfo -Force | Out-Null
    $scriptCmd = Join-Path "$env:ProgramFiles\WindowsPowerShell\Scripts" 'Get-WindowsAutopilotInfo.ps1'

    $online = @{ Online = $true }
    if ($GroupTag)     { $online['GroupTag']     = $GroupTag }
    if ($AssignedUser) { $online['AssignedUser'] = $AssignedUser }
    & $scriptCmd @online
    return
}

# --- Offline capture (default) ---------------------------------------------
$devDetail = Get-CimInstance -Namespace 'root/cimv2/mdm/dmmap' `
    -ClassName 'MDM_DevDetail_Ext01' `
    -Filter "InstanceID='Ext' AND ParentID='./DevDetail'" -ErrorAction Stop
$hash = $devDetail.DeviceHardwareData
if ([string]::IsNullOrWhiteSpace($hash)) {
    throw "DeviceHardwareData was empty; this device did not return an Autopilot hardware hash."
}

$serial = (Get-CimInstance -ClassName Win32_BIOS).SerialNumber
if ($serial) { $serial = $serial.Trim() }
if ([string]::IsNullOrWhiteSpace($serial)) { $serial = 'UNKNOWN' }

if (-not $OutputFile) {
    # Strip any characters that aren't valid in a file name from the serial.
    $safeSerial = ($serial -replace '[^0-9A-Za-z._-]', '_')
    $OutputFile = Join-Path $OutputFolder "$safeSerial.csv"
}

$outDir = Split-Path -Parent $OutputFile
if ($outDir -and -not (Test-Path -LiteralPath $outDir)) {
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
}

# Build the strict CSV the Intune importer requires: case-sensitive headers, no
# quotation marks, plain ASCII (ANSI) text. The Windows Product ID column is left
# empty (not needed for admin-direct import).
$headerColumns = @('Device Serial Number', 'Windows Product ID', 'Hardware Hash')
$valueColumns  = @($serial, '', $hash)
if ($PSBoundParameters.ContainsKey('GroupTag')) {
    $headerColumns += 'Group Tag'
    $valueColumns  += $GroupTag
}
if ($PSBoundParameters.ContainsKey('AssignedUser')) {
    $headerColumns += 'Assigned User'
    $valueColumns  += $AssignedUser
}

$lines = @(
    ($headerColumns -join ',')
    ($valueColumns  -join ',')
)
[System.IO.File]::WriteAllLines($OutputFile, $lines, [System.Text.Encoding]::ASCII)

Write-Output "Autopilot hardware hash written to $OutputFile"
Write-Output ''
Write-Output '----- CSV contents -----'
$lines | ForEach-Object { Write-Output $_ }
Write-Output '------------------------'
