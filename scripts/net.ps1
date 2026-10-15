#Requires -Version 7.2
<#
.SYNOPSIS
    Switches the lab VM between Setup (NAT, Internet) and Analysis (isolated LAN segment).
.DESCRIPTION
    Setup always reverts to the clean snapshot first, so no sample can be present while the guest has Internet.
    Only a human runs -Mode Setup.
.PARAMETER UpdateSnapshot
    With -Mode Analysis: retake the clean snapshot after the switch (use after updating tools).
#>
param(
    [Parameter(Mandatory)][ValidateSet('Setup', 'Analysis')][string]$Mode,
    [switch]$UpdateSnapshot
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib/LabCommon.psm1') -Force
$config = Get-LabConfig
Start-LabLog -Config $config -Name "net-$Mode" | Out-Null

if ($Mode -eq 'Setup') {
    Restore-LabClean -Config $config
    Switch-LabNetwork -Config $config -Mode Setup
    Write-LabLog 'Guest is on NAT with Internet. When done: .\scripts\net.ps1 -Mode Analysis -UpdateSnapshot'
} else {
    Switch-LabNetwork -Config $config -Mode Analysis
    if ($UpdateSnapshot) {
        Restart-LabGuest -Config $config
        Wait-LabDesktop -Config $config
        Update-LabSnapshot -Config $config
    }
    Write-LabLog 'Guest is isolated (Analysis).'
}
