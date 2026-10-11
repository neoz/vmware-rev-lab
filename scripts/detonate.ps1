#Requires -Version 7.2
<#
.SYNOPSIS
    Detonates cases/<case>/sample.zip in the clean VM with Procmon, FakeNet-NG and Sysmon, then collects artefacts.
.PARAMETER Sample
    File to run when the zip holds several.
.PARAMETER SampleArgs
    Command-line arguments for the sample.
.PARAMETER Export
    DLL export to call through rundll32.
.PARAMETER UnderDebugger
    Run the sample under cdb -server and return immediately; finish with .\scripts\collect.ps1 -Case <case>.
.PARAMETER KeepRunning
    Leave the VM running after collection (for manual debugging); run .\scripts\reset.ps1 afterwards.
#>
param(
    [Parameter(Mandatory)][string]$Case,
    [int]$Timeout = 120,
    [string]$Sample,
    [string]$SampleArgs,
    [string]$Export,
    [switch]$KeepRunning,
    [switch]$UnderDebugger
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib/LabCommon.psm1') -Force
$config = Get-LabConfig
Start-LabLog -Config $config -Name "detonate-$Case" | Out-Null

Assert-LabCaseName $Case
$caseDir = Join-Path $config.Root "cases/$Case"
$zip = Join-Path $caseDir 'sample.zip'
if (-not (Test-Path $zip)) { throw "Missing $zip (zip the sample with password 'infected')" }
$entry = Get-LabSampleEntry -ZipPath $zip -Sample $Sample -Export $Export
$runDir = Join-Path $caseDir ('runs/{0:yyyyMMdd-HHmmss}' -f (Get-Date))
New-Item -ItemType Directory -Force -Path $runDir | Out-Null
$guest = Join-Path $config.Root 'templates/guest'

$sampleStarted = $false
$collected = $false
Restore-LabClean -Config $config -SaveCase
try {
    Copy-LabToGuest -Config $config -HostPath $zip -GuestPath 'C:\lab\in\sample.zip'
    $prep = Invoke-LabGuestScript -Config $config -Path (Join-Path $guest 'prepare-sample.ps1') -Arguments @{ Zip = 'C:\lab\in\sample.zip'; Name = $entry }
    if ($prep.ExitCode -ne 0) { throw "prepare-sample.ps1 failed: $($prep.Output)" }
    $samplePath = ($prep.Output -split "`r?`n")[-1].Trim()

    $monitors = Invoke-LabGuestScript -Config $config -Path (Join-Path $guest 'start-monitors.ps1') -Interactive
    if ($monitors.ExitCode -ne 0) { throw "start-monitors.ps1 failed: $($monitors.Output)" }
    $start = ($monitors.Output -split "`r?`n")[-1].Trim()

    $debugger = if ($UnderDebugger) { (Get-LabGuestTools -Config $config).Cdb } else { '' }
    Start-LabSample -Config $config -SamplePath $samplePath -RunDir $runDir -Export $Export -SampleArgs $SampleArgs -Debugger $debugger
    $sampleStarted = $true
    if ($UnderDebugger) {
        Set-Content -Path (Join-Path $runDir 'monitor-start.txt') -Value $start
        Set-Content -Path (Join-Path $caseDir 'runs/pending.txt') -Value $runDir
        Write-LabLog "Sample is stopped under cdb. Attach with revlab-windbg open_cdb_remote 'npipe:server=.,pipe=revlab-dbg'."
        Write-LabLog "When done: .\scripts\collect.ps1 -Case $Case"
        $KeepRunning = $true
        return
    }
    Write-LabLog "Running $entry for $Timeout s"
    Start-Sleep -Seconds $Timeout
    Invoke-LabCollect -Config $config -RunDir $runDir -Start $start
    $collected = $true
} finally {
    if ($KeepRunning) {
        Write-LabLog 'VM left running (-KeepRunning). Run .\scripts\reset.ps1 when done.'
    } elseif ($sampleStarted -and -not $collected) {
        # Reverting now would destroy the guest-side Procmon/FakeNet/Sysmon data of this run.
        Write-LabLog 'Collection failed; VM left as is (still isolated) so artefacts under C:\lab\out can be recovered. Run .\scripts\reset.ps1 afterwards.'
    } else {
        Restore-LabClean -Config $config
    }
}
