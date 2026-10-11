#Requires -Version 7.2
<# .SYNOPSIS Finishes a 'detonate.ps1 -UnderDebugger' run: collects artefacts, then reverts to the clean snapshot. #>
param([Parameter(Mandatory)][string]$Case)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib/LabCommon.psm1') -Force
$config = Get-LabConfig
Start-LabLog -Config $config -Name "collect-$Case" | Out-Null
Assert-LabCaseName $Case
$pending = Join-Path $config.Root "cases/$Case/runs/pending.txt"
if (-not (Test-Path $pending)) { throw "No pending debug run for '$Case' ($pending missing)" }
$runDir = (Get-Content $pending -Raw).Trim()
$start = (Get-Content (Join-Path $runDir 'monitor-start.txt') -Raw).Trim()
Invoke-LabCollect -Config $config -RunDir $runDir -Start $start
Remove-Item $pending
Restore-LabClean -Config $config -SaveCase
