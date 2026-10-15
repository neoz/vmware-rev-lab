#Requires -Version 7.2
<#
.SYNOPSIS
    Sets whether a case runs isolated or on NAT with Internet (cases/<case>/case.psd1). Only a human runs this.
.DESCRIPTION
    Without -Network, prints the case's policy. With it, writes the policy. If the case is open in the running VM,
    the VM is power cycled onto that network at once (guest files stay, running processes are lost); otherwise the
    policy applies at the case's next case-open, detonate or debug. Every revert returns the VM to the isolated segment.
    NAT reaches the Internet, this host and its LAN: use Internet only for binaries you trust that far (CTF, not live malware).
.EXAMPLE
    .\scripts\case-net.ps1 -Case ctf-foo -Network Internet
#>
param(
    [Parameter(Mandatory)][string]$Case,
    [ValidateSet('Isolated', 'Internet')][string]$Network
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib/LabCommon.psm1') -Force
$config = Get-LabConfig
Assert-LabCaseName $Case

if (-not $Network) {
    "Case '$Case' network: $(Get-LabCaseNetwork -Config $config -Case $Case)"
    return
}
Start-LabLog -Config $config -Name "case-net-$Case" | Out-Null
Set-LabCaseNetworkPolicy -Config $config -Case $Case -Network $Network
Write-LabLog "Case '$Case' network policy: $Network"
Sync-LabCaseNetwork -Config $config -Case $Case | Out-Null
