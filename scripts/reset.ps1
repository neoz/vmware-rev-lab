#Requires -Version 7.2
<# .SYNOPSIS Reverts the lab VM to the clean snapshot and waits for VMware Tools. #>
param([switch]$NoSave)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib/LabCommon.psm1') -Force
$config = Get-LabConfig
Start-LabLog -Config $config -Name reset | Out-Null
Restore-LabClean -Config $config -SaveCase:(-not $NoSave)
Write-LabLog "Reverted to '$($config.SnapshotName)'"
