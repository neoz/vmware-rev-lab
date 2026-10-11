#Requires -Version 7.2
<#
.SYNOPSIS
    Installs extra FLARE-VM / Chocolatey packages into the clean snapshot.
.DESCRIPTION
    Reverts to clean, switches the guest to NAT, installs the packages, switches back to the
    isolated network and retakes the clean snapshot. Only a human runs this: it gives the guest Internet.
.EXAMPLE
    .\scripts\add-tool.ps1 -Package goresym.vm, pycdc.vm
#>
param(
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]*$')][string[]]$Package
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib/LabCommon.psm1') -Force
$config = Get-LabConfig

& (Join-Path $PSScriptRoot 'net.ps1') -Mode Setup
Start-LabLog -Config $config -Name 'add-tool' | Out-Null
$r = Invoke-LabGuestScript -Config $config -Path (Join-Path $config.Root 'templates/guest/install-package.ps1') -Arguments @{
    Packages = $Package -join ','
} -TimeoutSec 3600
Write-LabLog $r.Output
if ($r.ExitCode -ne 0) {
    throw "Package install failed; the guest is still on NAT. Fix it or run .\scripts\net.ps1 -Mode Analysis (without -UpdateSnapshot to discard)."
}
Update-LabToolsIndex -Config $config
& (Join-Path $PSScriptRoot 'net.ps1') -Mode Analysis -UpdateSnapshot
Write-LabLog "Installed $($Package -join ', ') and retook '$($config.SnapshotName)'"
