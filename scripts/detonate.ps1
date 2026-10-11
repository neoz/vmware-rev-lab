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
.PARAMETER KeepRunning
    Leave the VM running after collection (for manual debugging); run .\scripts\reset.ps1 afterwards.
#>
param(
    [Parameter(Mandatory)][string]$Case,
    [int]$Timeout = 120,
    [string]$Sample,
    [string]$SampleArgs,
    [string]$Export,
    [switch]$KeepRunning
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib/LabCommon.psm1') -Force
$config = Get-LabConfig
Start-LabLog -Config $config -Name "detonate-$Case" | Out-Null

$caseDir = Join-Path $config.Root "cases/$Case"
$zip = Join-Path $caseDir 'sample.zip'
if (-not (Test-Path $zip)) { throw "Missing $zip (zip the sample with password 'infected')" }
$entry = Get-LabSampleEntry -ZipPath $zip -Sample $Sample -Export $Export
$runDir = Join-Path $caseDir ('runs/{0:yyyyMMdd-HHmmss}' -f (Get-Date))
New-Item -ItemType Directory -Force -Path $runDir | Out-Null
$guest = Join-Path $config.Root 'templates/guest'

Restore-LabClean -Config $config
try {
    Copy-LabToGuest -Config $config -HostPath $zip -GuestPath 'C:\lab\in\sample.zip'
    $prep = Invoke-LabGuestScript -Config $config -Path (Join-Path $guest 'prepare-sample.ps1') -Arguments @{ Zip = 'C:\lab\in\sample.zip'; Name = $entry }
    if ($prep.ExitCode -ne 0) { throw "prepare-sample.ps1 failed: $($prep.Output)" }
    $samplePath = ($prep.Output -split "`r?`n")[-1].Trim()

    $monitors = Invoke-LabGuestScript -Config $config -Path (Join-Path $guest 'start-monitors.ps1') -Interactive
    if ($monitors.ExitCode -ne 0) { throw "start-monitors.ps1 failed: $($monitors.Output)" }
    $start = ($monitors.Output -split "`r?`n")[-1].Trim()

    $runFile = Join-Path $runDir 'run.json'
    @{ Path = $samplePath; Export = $Export; Arguments = $SampleArgs } | ConvertTo-Json | Set-Content -Path $runFile -Encoding utf8
    Copy-LabToGuest -Config $config -HostPath $runFile -GuestPath 'C:\lab\in\run.json'
    Start-LabGuestScript -Config $config -Path (Join-Path $guest 'run-sample.ps1') -Arguments @{ RunFile = 'C:\lab\in\run.json' }
    Write-LabLog "Running $entry for $Timeout s"
    Start-Sleep -Seconds $Timeout

    Invoke-Vmrun -Config $config -Command captureScreen -Arguments @((Join-Path $runDir 'screenshot.png')) -Guest | Out-Null
    $collect = Invoke-LabGuestScript -Config $config -Path (Join-Path $guest 'collect.ps1') -Arguments @{ Start = $start } -Interactive -TimeoutSec 1200
    Write-LabLog $collect.Output -Quiet
    if ($collect.ExitCode -ne 0) { throw "collect.ps1 failed: $($collect.Output)" }

    Copy-LabFromGuest -Config $config -GuestPath 'C:\lab\artefacts.zip' -HostPath (Join-Path $runDir 'artefacts.zip')
    $textZip = Join-Path $runDir 'text.zip'
    Copy-LabFromGuest -Config $config -GuestPath 'C:\lab\text.zip' -HostPath $textZip
    Expand-Archive -Path $textZip -DestinationPath (Join-Path $runDir 'text')
    Remove-Item -Path $textZip
    Write-LabLog "Artefacts: $runDir"
} finally {
    if ($KeepRunning) {
        Write-LabLog 'VM left running (-KeepRunning). Run .\scripts\reset.ps1 when done.'
    } else {
        Restore-LabClean -Config $config
    }
}
