#Requires -Version 7.2
<#
.SYNOPSIS
    Starts cases/<case>'s sample under 'cdb -server' (no monitors) for revlab-windbg. End with .\scripts\reset.ps1.
#>
param(
    [Parameter(Mandatory)][string]$Case,
    [string]$Sample, [string]$SampleArgs, [string]$Export
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib/LabCommon.psm1') -Force
$config = Get-LabConfig
Start-LabLog -Config $config -Name "debug-$Case" | Out-Null
Assert-LabCaseName $Case
$caseDir = Join-Path $config.Root "cases/$Case"
$entry = Get-LabSampleEntry -ZipPath (Join-Path $caseDir 'sample.zip') -Sample $Sample -Export $Export
$runDir = Join-Path $caseDir ('runs/{0:yyyyMMdd-HHmmss}-debug' -f (Get-Date))
New-Item -ItemType Directory -Force -Path $runDir | Out-Null
Restore-LabClean -Config $config -SaveCase
$samplePath = Open-LabCase -Config $config -Case $Case -Name $entry
Set-LabCaseNetwork -Config $config -Case $Case | Out-Null
Start-LabSample -Config $config -SamplePath $samplePath -RunDir $runDir -Export $Export -SampleArgs $SampleArgs -Debugger (Get-LabGuestTools -Config $config).Cdb
Write-LabLog "Sample is stopped under cdb. Attach with revlab-windbg open_cdb_remote 'npipe:server=.,pipe=revlab-dbg'. End with .\scripts\reset.ps1"
