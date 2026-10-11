#Requires -Version 7.2
<# .SYNOPSIS Finishes a 'detonate.ps1 -UnderDebugger' run: collects artefacts, then reverts to the clean snapshot. #>
param([Parameter(Mandatory)][string]$Case)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib/LabCommon.psm1') -Force
$config = Get-LabConfig
Start-LabLog -Config $config -Name "collect-$Case" | Out-Null
Assert-LabCaseName $Case
$run = Get-LabDebugRun -Config $config -Case $Case
Invoke-LabCollect -Config $config -RunDir $run.RunDir -Start $run.Start
Restore-LabClean -Config $config -SaveCase
