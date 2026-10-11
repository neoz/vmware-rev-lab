#Requires -Version 7.2
<# .SYNOPSIS End-to-end checks against the real lab VM. Exits 0 when every check passes. #>
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'scripts/lib/LabCommon.psm1') -Force
$config = Get-LabConfig
Start-LabLog -Config $config -Name smoke | Out-Null
$failures = [System.Collections.Generic.List[string]]::new()

function Test-Step([string]$Name, [scriptblock]$Check) {
    try {
        & $Check
        Write-LabLog "PASS $Name"
    } catch {
        Write-LabLog "FAIL ${Name}: $($_.Exception.Message)"
        $failures.Add($Name)
    }
}

Test-Step '1. clean snapshot exists and Tools come up after revert' {
    if ($config.SnapshotName -notin (Get-LabSnapshots -Config $config)) { throw "snapshot '$($config.SnapshotName)' missing" }
    $elapsed = Measure-Command { Restore-LabClean -Config $config }
    if ($elapsed.TotalSeconds -gt 60) { throw "revert + Tools took $([int]$elapsed.TotalSeconds) s (limit 60)" }
}

Test-Step '2. guest is isolated' {
    Assert-LabIsolation -Config $config
}

Test-Step '3. copy round trip keeps the hash' {
    $src = Join-Path ([System.IO.Path]::GetTempPath()) 'revlab-roundtrip.bin'
    $back = "$src.back"
    [System.IO.File]::WriteAllBytes($src, [byte[]](1..255 * 64))
    Copy-LabToGuest -Config $config -HostPath $src -GuestPath 'C:\lab\tmp\roundtrip.bin'
    Copy-LabFromGuest -Config $config -GuestPath 'C:\lab\tmp\roundtrip.bin' -HostPath $back
    if ((Get-FileHash $src).Hash -ne (Get-FileHash $back).Hash) { throw 'hash mismatch' }
    Remove-Item $src, $back
}

Test-Step '4. benign detonation produces the expected artefacts and reverts' {
    $case = 'smoke-test'
    $caseDir = Join-Path $config.Root "cases/$case"
    if (Test-Path $caseDir) { Remove-Item $caseDir -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $caseDir | Out-Null
    Compress-Archive -Path (Join-Path $root 'tests/fixtures/benign.ps1') -DestinationPath (Join-Path $caseDir 'sample.zip')
    & (Join-Path $root 'scripts/detonate.ps1') -Case $case -Timeout 45
    $run = Get-ChildItem (Join-Path $caseDir 'runs') -Directory | Select-Object -Last 1
    $procmon = Get-Content (Join-Path $run.FullName 'text/procmon.csv') -Raw
    if ($procmon -notmatch 'revlab-benign\.txt') { throw 'procmon.csv has no file write' }
    if ($procmon -notmatch 'RevlabBenign') { throw 'procmon.csv has no Run key' }
    $fakenet = Get-Content (Join-Path $run.FullName 'text/fakenet/fakenet.log') -Raw
    if ($fakenet -notmatch 'c2\.revlab\.example') { throw 'fakenet.log has no DNS query' }
    if ($fakenet -notmatch 'GET /beacon') { throw 'fakenet.log has no HTTP GET' }
    if (-not (Test-Path (Join-Path $run.FullName 'screenshot.png'))) { throw 'screenshot missing' }
    if (Test-LabGuestFile -Config $config -GuestPath 'C:\Users\Public\revlab-benign.txt') { throw 'guest not reverted' }
    Remove-Item $caseDir -Recurse -Force
}

Test-Step '5. vmware-mcp answers over MCP' {
    $venvPython = Join-Path $config.Root 'tools/vmware-mcp/.venv/Scripts/python.exe'
    $serverExe = Join-Path $config.Root 'tools/vmware-mcp/.venv/Scripts/vmware-mcp.exe'
    $out = & $venvPython -I (Join-Path $root 'tests/mcp_probe.py') $serverExe $config.Vmrun $config.Vmcli 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw "mcp_probe.py failed: $out" }
    if ($out -notmatch [regex]::Escape([System.IO.Path]::GetFileName($config.VmxPath))) { throw "vmrun_list did not list the VM: $out" }
    $list = claude mcp list 2>&1 | Out-String
    if ($list -notmatch 'vmware-mcp.*Connected') {
        Write-LabLog "NOTE: 'claude mcp list' does not show vmware-mcp as Connected; approve the project server in Claude Code (/mcp). Output: $list"
    }
}

if ($failures.Count) {
    Write-LabLog "Smoke test FAILED: $($failures -join '; ')"
    exit 1
}
Write-LabLog 'Smoke test PASSED'
exit 0
