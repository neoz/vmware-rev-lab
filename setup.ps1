#Requires -Version 7.2
<#
.SYNOPSIS
    Builds the VMware reverse engineering lab end to end. Safe to rerun: completed phases are skipped.
.PARAMETER IsoPath
    Windows 10 22H2 x64 ISO. If omitted, the evaluation ISO is downloaded. The SHA256 must match IsoSha256.
.PARAMETER From
    Rerun starting at this phase.
#>
[CmdletBinding()]
param(
    [string]$IsoPath,
    [string]$From
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'scripts/lib/LabCommon.psm1') -Force

$script:config = Get-LabConfig
Start-LabLog -Config $script:config -Name setup | Out-Null
if (-not $script:config.ContainsKey('GuestPassword')) {
    Save-LabLocalConfig -Root $script:config.Root -Values @{ GuestPassword = New-LabPassword }
    $script:config = Get-LabConfig
}

function Invoke-PreflightPhase {
    $cfg = $script:config
    $problems = @()
    foreach ($key in 'Vmrun', 'Vmcli', 'VdiskManager', 'ToolsIso') {
        if (-not (Test-Path $cfg[$key])) { $problems += "$key not found at $($cfg[$key])" }
    }
    $vmwareExe = Join-Path $cfg.VmwareDir 'vmware.exe'
    if (Test-Path $vmwareExe) {
        $version = [version]((Get-Item $vmwareExe).VersionInfo.ProductVersion -split ' ')[0]
        if ($version.Major -lt 17) { $problems += "VMware Workstation $version found; 17 or newer is required" }
    } else {
        $problems += "vmware.exe not found in $($cfg.VmwareDir)"
    }
    $drive = [System.IO.Path]::GetPathRoot($cfg.VmxPath).Substring(0, 1)
    $freeGB = [math]::Floor((Get-PSDrive -Name $drive).Free / 1GB)
    if ($freeGB -lt 120) { $problems += "Only $freeGB GB free on ${drive}:; 120 GB needed" }
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { $problems += 'git not found on PATH' }
    if (Get-Command python -ErrorAction SilentlyContinue) {
        $pyVersion = [version](& python -c "import sys; print('%d.%d' % sys.version_info[:2])")
        if ($pyVersion -lt [version]'3.10') { $problems += "Python $pyVersion found; 3.10 or newer is required" }
    } else {
        $problems += 'python not found on PATH'
    }
    if ($problems) { throw "Preflight failed:`n - $($problems -join "`n - ")" }
    Write-LabLog 'Preflight OK'
}

function Invoke-McpPhase {
    $cfg = $script:config
    $dir = Join-Path $cfg.Root 'tools/vmware-mcp'
    if (-not (Test-Path (Join-Path $dir '.git'))) {
        git clone --quiet $cfg.VmwareMcpRepo $dir
        if ($LASTEXITCODE) { throw 'git clone vmware-mcp failed' }
    }
    git -C $dir fetch --quiet origin
    git -C $dir checkout --quiet $cfg.VmwareMcpCommit
    if ($LASTEXITCODE) { throw "git checkout $($cfg.VmwareMcpCommit) failed" }
    $python = Join-Path $dir '.venv/Scripts/python.exe'
    if (-not (Test-Path $python)) {
        python -m venv (Join-Path $dir '.venv')
        if ($LASTEXITCODE) { throw 'python -m venv failed' }
    }
    # vmware-mcp declares mcp>=1.0.0 but uses the 1.x low-level Server API removed in mcp 2.x.
    & $python -m pip install --quiet "mcp==$($cfg.McpVersion)" -e $dir
    if ($LASTEXITCODE) { throw 'pip install vmware-mcp failed' }
    & $python -I -c 'import vmware_mcp.server'
    if ($LASTEXITCODE) { throw 'vmware_mcp does not import in its venv' }
    Set-Content -Path (Join-Path $cfg.Root '.mcp.json') -Value (New-LabMcpJson -Config $cfg) -Encoding utf8
    Write-LabLog 'vmware-mcp installed and .mcp.json written'
}

function Invoke-IsoPhase {
    $cfg = $script:config
    if ($IsoPath) {
        $iso = (Resolve-Path $IsoPath).Path
    } else {
        $iso = Join-Path $cfg.LabDir 'iso/win10-22h2-eval-x64.iso'
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $iso) | Out-Null
        $complete = (Test-Path $iso) -and ((Get-FileHash $iso -Algorithm SHA256).Hash -eq $cfg.IsoSha256)
        if (-not $complete) {
            Write-LabLog "Downloading Windows 10 evaluation ISO to $iso"
            curl.exe -L --fail --retry 3 -C - -o $iso $cfg.IsoUrl
            if ($LASTEXITCODE) { throw "ISO download failed (curl exit $LASTEXITCODE)" }
        }
    }
    Test-LabIsoHash -Path $iso -Expected $cfg.IsoSha256
    Save-LabLocalConfig -Root $cfg.Root -Values @{ IsoPath = $iso }
    $script:config = Get-LabConfig
    Write-LabLog "ISO verified: $iso"
}

function Invoke-AnswerIsoPhase {
    New-LabAnswerIso -Config $script:config -Path (Join-Path $script:config.LabDir 'answer.iso')
}

function Invoke-CreateVmPhase {
    $cfg = $script:config
    Assert-LabVmAbsent -Config $cfg
    $vmDir = Split-Path -Parent $cfg.VmxPath
    New-Item -ItemType Directory -Force -Path $vmDir | Out-Null
    $settings = Get-LabVmxSettings -Config $cfg -WindowsIso $cfg.IsoPath -AnswerIso (Join-Path $cfg.LabDir 'answer.iso')
    Write-LabVmx -Config $cfg -Settings $settings
    $disk = Join-Path $vmDir $settings['sata0:0.fileName']
    $r = Invoke-LabProcess -FilePath $cfg.VdiskManager -ArgumentList @('-c', '-s', "$($cfg.DiskGB)GB", '-a', 'lsilogic', '-t', '0', $disk) -TimeoutSec 300
    if ($r.ExitCode -ne 0) { throw "vmware-vdiskmanager failed: $($r.StdOut) $($r.StdErr)" }
    Invoke-Vmrun -Config $cfg -Command start -Arguments @('gui') | Out-Null
    Write-LabLog "VM created and started: $($cfg.VmxPath)"
}

function Invoke-WindowsInstallPhase {
    $cfg = $script:config
    Write-LabLog 'Waiting for unattended Windows install and VMware Tools (up to 60 min)'
    Wait-LabCondition -Description 'Windows install + VMware Tools + first logon' -TimeoutSec 3600 -PollSec 30 -Condition {
        try {
            ((Invoke-Vmrun -Config $cfg -Command checkToolsState -RetryCount 0).Output -match 'running') -and
            (Test-LabGuestFile -Config $cfg -GuestPath 'C:\lab\firstlogon.done')
        } catch { $false }
    }
    Restart-LabGuest -Config $cfg
    Write-LabLog 'Windows installed, Tools running'
}

function Invoke-GuestPrepPhase {
    $cfg = $script:config
    $prep = Join-Path $cfg.Root 'templates/guest/guest-prep.ps1'
    $r = Invoke-LabGuestScript -Config $cfg -Path $prep
    if ($r.ExitCode -eq 3) {
        Write-LabLog "Defender still active ($($r.Output)); restarting the guest once so the policies apply"
        Restart-LabGuest -Config $cfg
        $r = Invoke-LabGuestScript -Config $cfg -Path $prep
    }
    Write-LabLog $r.Output
    if ($r.ExitCode -eq 3) {
        throw @'
Defender or Tamper Protection is still enabled in the guest.
In the VM console open Windows Security > Virus & threat protection > Manage settings,
turn off Tamper Protection, then run: .\setup.ps1 -From GuestPrep
'@
    }
    if ($r.ExitCode -ne 0) { throw "guest-prep.ps1 failed (exit $($r.ExitCode)): $($r.Output)" }
}

function Start-FlareVmInstall {
    $cfg = $script:config
    $installer = Join-Path $cfg.LabDir 'flare-install.ps1'
    Invoke-WebRequest -Uri "https://raw.githubusercontent.com/mandiant/flare-vm/$($cfg.FlareVmCommit)/install.ps1" -OutFile $installer
    New-LabGuestDirectory -Config $cfg -GuestPath 'C:\lab\setup'
    Copy-LabToGuest -Config $cfg -HostPath $installer -GuestPath 'C:\lab\setup\install.ps1'
    # FLARE's install.ps1 moves the custom config to Desktop\config.xml, so copy it again on every launch.
    Copy-LabToGuest -Config $cfg -HostPath (Join-Path $cfg.Root 'templates/flare-config.xml') -GuestPath 'C:\lab\setup\flare-config.xml'
    Write-LabLog 'Starting FLARE-VM install (reboots several times)'
    Invoke-Vmrun -Config $cfg -Command runProgramInGuest -Guest -Arguments @(
        '-noWait', '-interactive', 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe',
        '-NoProfile', '-ExecutionPolicy', 'Unrestricted', '-File', 'C:\lab\setup\install.ps1',
        '-password', $cfg.GuestPassword, '-noWait', '-noGui', '-noChecks',
        '-customConfig', 'C:\lab\setup\flare-config.xml'
    ) | Out-Null
}

function Invoke-FlareVmPhase {
    $cfg = $script:config
    $check = Join-Path $cfg.Root 'templates/guest/test-flare.ps1'
    $state = Invoke-LabGuestScript -Config $cfg -Path $check
    if ($state.ExitCode -eq 2) { Start-FlareVmInstall } else { Write-LabLog "FLARE-VM already started: $($state.Output)" }

    # test-flare.ps1 exit 4 = stalled; relaunch after 3 stalled polls in a row (6 min), at most twice.
    # A hashtable, because the condition block runs in its own scope on every poll.
    $poll = @{ Stalled = 0; Relaunches = 0 }
    Wait-LabCondition -Description 'FLARE-VM install' -TimeoutSec (4 * 3600) -PollSec 120 -Condition {
        try { $r = Invoke-LabGuestScript -Config $cfg -Path $check } catch { return $false }
        Write-LabLog "  $(($r.Output -split "`r?`n")[0])" -Quiet
        if ($r.ExitCode -ne 4) { $poll.Stalled = 0; return $r.ExitCode -eq 0 }
        $poll.Stalled++
        if ($poll.Stalled -lt 3) { return $false }
        if ($poll.Relaunches -ge 2) { throw "FLARE-VM install stalled after $($poll.Relaunches) relaunches:`n$($r.Output)" }
        $poll.Relaunches++
        $poll.Stalled = 0
        Write-LabLog "FLARE-VM install stalled; relaunching ($($poll.Relaunches)/2)"
        Start-FlareVmInstall
        $false
    }
    $final = Invoke-LabGuestScript -Config $cfg -Path $check
    Write-LabLog "FLARE-VM finished: $($final.Output)"
}

function Invoke-AnalysisConfigPhase {
    $cfg = $script:config
    $sysmonConfig = Join-Path $cfg.LabDir 'sysmonconfig.xml'
    Invoke-WebRequest -Uri $cfg.SysmonConfigUrl -OutFile $sysmonConfig
    New-LabGuestDirectory -Config $cfg -GuestPath 'C:\lab\setup'
    Copy-LabToGuest -Config $cfg -HostPath $sysmonConfig -GuestPath 'C:\lab\setup\sysmonconfig.xml'
    $r = Invoke-LabGuestScript -Config $cfg -Path (Join-Path $cfg.Root 'templates/guest/analysis-config.ps1') -Arguments @{
        SysmonConfig       = 'C:\lab\setup\sysmonconfig.xml'
        FridaToolsVersion  = $cfg.FridaToolsVersion
        DotnetSdkVersion   = $cfg.DotnetSdkVersion
        IlspyCmdVersion    = $cfg.IlspyCmdVersion
    } -TimeoutSec 3600
    Write-LabLog $r.Output
    if ($r.ExitCode -ne 0) { throw 'analysis-config.ps1 failed' }

    Stop-LabVm -Config $cfg
    Set-LabVmxNetwork -Config $cfg -Mode Analysis
    Remove-LabVmxInstallMedia -Config $cfg
    Start-LabVm -Config $cfg
    Wait-LabTools -Config $cfg -TimeoutSec 900
    Set-LabGuestNetwork -Config $cfg -Mode Analysis
    Assert-LabIsolation -Config $cfg
}

function Invoke-SnapshotPhase {
    $cfg = $script:config
    Restart-LabGuest -Config $cfg
    Wait-LabDesktop -Config $cfg
    Update-LabSnapshot -Config $cfg
}

$phases = [ordered]@{
    Preflight      = { Invoke-PreflightPhase }
    Mcp            = { Invoke-McpPhase }
    Iso            = { Invoke-IsoPhase }
    AnswerIso      = { Invoke-AnswerIsoPhase }
    CreateVm       = { Invoke-CreateVmPhase }
    WindowsInstall = { Invoke-WindowsInstallPhase }
    GuestPrep      = { Invoke-GuestPrepPhase }
    FlareVm        = { Invoke-FlareVmPhase }
    AnalysisConfig = { Invoke-AnalysisConfigPhase }
    Snapshot       = { Invoke-SnapshotPhase }
}

Invoke-LabPhases -Phases $phases -StatePath $script:config.StatePath -From $From
Write-LabLog 'Setup complete.'
