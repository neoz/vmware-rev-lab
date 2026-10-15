#Requires -Version 7.2
<# .SYNOPSIS Stages cases/<case> in the guest (saved Ghidra/IDA zip if any, else sample.zip) and marks it as the open case. #>
param([Parameter(Mandatory)][string]$Case, [string]$Sample)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib/LabCommon.psm1') -Force
$config = Get-LabConfig
Start-LabLog -Config $config -Name "case-open-$Case" | Out-Null
Assert-LabNetworkOwned -Config $config | Out-Null
Get-LabCaseNetwork -Config $config -Case $Case | Out-Null   # a bad policy stops here, before anything is staged
$path = Open-LabCase -Config $config -Case $Case -Name $Sample
$network = Set-LabCaseNetwork -Config $config -Case $Case
Write-LabLog "Case '$Case' open in the guest ($network): $path"
