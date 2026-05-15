<#
.SYNOPSIS
    Configures a Windows Server VM as an Active Directory Domain Controller for the AzureVMLabs demo environment.

.DESCRIPTION
    Follows the guidance in https://learn.microsoft.com/en-us/windows-server/identity/ad-ds/deploy/virtual-dc/adds-on-azure-vm:
      * Initializes the attached data disk and creates an NTFS volume mounted at F:.
      * Installs the AD-Domain-Services role and management tools.
      * Promotes the server to the first Domain Controller of a new forest, placing the
        AD DS database, log files and SYSVOL on F: so that they reside on a data disk
        whose host caching is set to None.

.PARAMETER DomainName
    FQDN of the Active Directory forest root domain to create (for example contoso.local).

.PARAMETER SafeModeAdminPassword
    Password to use as the Directory Services Restore Mode (DSRM) password.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$DomainName,

    [Parameter(Mandatory = $true)]
    [string]$SafeModeAdminPassword
)

$ErrorActionPreference = 'Stop'
Start-Transcript -Path "$env:SystemDrive\ConfigureDC.log" -Append

try {
    Write-Output "Initializing data disk for AD DS database, logs and SYSVOL..."
    $rawDisk = Get-Disk | Where-Object { $_.PartitionStyle -eq 'RAW' } | Select-Object -First 1
    if ($null -ne $rawDisk) {
        $rawDisk |
            Initialize-Disk -PartitionStyle GPT -PassThru |
            New-Partition -DriveLetter 'F' -UseMaximumSize |
            Format-Volume -FileSystem NTFS -NewFileSystemLabel 'ADDS' -Confirm:$false |
            Out-Null
    }
    else {
        Write-Output "No RAW disk found; assuming the data disk has already been initialized."
    }

    $dbPath      = 'F:\NTDS'
    $logPath     = 'F:\NTDS'
    $sysvolPath  = 'F:\SYSVOL'
    foreach ($p in @($dbPath, $sysvolPath)) {
        if (-not (Test-Path $p)) {
            New-Item -ItemType Directory -Path $p -Force | Out-Null
        }
    }

    Write-Output "Installing AD DS role..."
    Install-WindowsFeature -Name AD-Domain-Services -IncludeManagementTools | Out-Null

    Write-Output "Promoting server to a new forest root Domain Controller for $DomainName..."
    $securePassword = ConvertTo-SecureString -String $SafeModeAdminPassword -AsPlainText -Force
    Import-Module ADDSDeployment
    Install-ADDSForest `
        -DomainName $DomainName `
        -SafeModeAdministratorPassword $securePassword `
        -DatabasePath $dbPath `
        -LogPath $logPath `
        -SysvolPath $sysvolPath `
        -InstallDns:$true `
        -CreateDnsDelegation:$false `
        -NoRebootOnCompletion:$true `
        -Force:$true | Out-Null

    Write-Output "Domain Controller configuration complete. The VM will reboot to finalize the promotion."
}
finally {
    Stop-Transcript
}

# Schedule a reboot so the custom script extension can return success first.
shutdown.exe /r /t 30 /c "Rebooting to complete AD DS promotion" | Out-Null
