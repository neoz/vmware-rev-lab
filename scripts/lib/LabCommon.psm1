#Requires -Version 7.2
# Shared host-side functions for the VMware reverse engineering lab.

Set-StrictMode -Version 3.0

function Get-LabConfig {
    param([string]$Root = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))

    $config = Import-PowerShellDataFile -Path (Join-Path $Root 'lab.config.psd1')
    $localPath = Join-Path $Root 'lab.local.psd1'
    if (Test-Path $localPath) {
        $local = Import-PowerShellDataFile -Path $localPath
        foreach ($key in $local.Keys) { $config[$key] = $local[$key] }
    }
    $config.Root = $Root
    $config.LabDir = Join-Path $Root '.lab'
    $config.StatePath = Join-Path $config.LabDir 'state.json'
    $config.Vmrun = Join-Path $config.VmwareDir 'vmrun.exe'
    $config.Vmcli = Join-Path $config.VmwareDir 'vmcli.exe'
    $config.VdiskManager = Join-Path $config.VmwareDir 'vmware-vdiskmanager.exe'
    $config
}

function Save-LabLocalConfig {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][hashtable]$Values
    )
    $path = Join-Path $Root 'lab.local.psd1'
    $merged = if (Test-Path $path) { Import-PowerShellDataFile -Path $path } else { @{} }
    foreach ($key in $Values.Keys) { $merged[$key] = $Values[$key] }
    $lines = foreach ($key in ($merged.Keys | Sort-Object)) {
        $escaped = ([string]$merged[$key]) -replace "'", "''"
        "    $key = '$escaped'"
    }
    Set-Content -Path $path -Value (@('@{') + $lines + @('}')) -Encoding utf8
}

function New-LabPassword {
    param([int]$Length = 20)
    $alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789'
    do {
        $chars = foreach ($i in 1..$Length) {
            $alphabet[[System.Security.Cryptography.RandomNumberGenerator]::GetInt32($alphabet.Length)]
        }
        $password = -join $chars
    } until ($password -cmatch '[A-Z]' -and $password -cmatch '[a-z]' -and $password -match '[0-9]')
    $password
}

$script:LogFile = $null

function Start-LabLog {
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][string]$Name
    )
    $dir = Join-Path $Config.LabDir 'logs'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $script:LogFile = Join-Path $dir ('{0}-{1:yyyyMMdd-HHmmss}.log' -f $Name, (Get-Date))
    $script:LogFile
}

function Get-LabLogPath { $script:LogFile }

function Write-LabLog {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Message,
        [switch]$Quiet
    )
    $line = '[{0:HH:mm:ss}] {1}' -f (Get-Date), $Message
    if ($script:LogFile) { Add-Content -Path $script:LogFile -Value $line }
    if (-not $Quiet) { Write-Host $line }
}

function Invoke-LabProcess {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [int]$TimeoutSec = 300
    )
    $psi = [System.Diagnostics.ProcessStartInfo]::new($FilePath)
    foreach ($arg in $ArgumentList) { $psi.ArgumentList.Add($arg) }
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $process = [System.Diagnostics.Process]::Start($psi)
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit($TimeoutSec * 1000)) {
        $process.Kill($true)
        throw "Timed out after $TimeoutSec s: $FilePath $($ArgumentList -join ' ')"
    }
    $process.WaitForExit()
    [pscustomobject]@{
        ExitCode = $process.ExitCode
        StdOut   = $stdout.Result.Trim()
        StdErr   = $stderr.Result.Trim()
    }
}

$script:TransientVmrunErrors = @(
    'VMware Tools are not running'
    'The guest operations agent'
    'The operation was canceled'
)

function Invoke-Vmrun {
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][string]$Command,
        [string[]]$Arguments = @(),
        [switch]$Guest,
        [switch]$NoVmx,
        [int]$TimeoutSec = 300,
        [int]$RetryCount = 5,
        [int]$RetryDelaySec = 15
    )
    $argv = @('-T', 'ws')
    if ($Guest) { $argv += @('-gu', $Config.GuestUser, '-gp', $Config.GuestPassword) }
    $argv += $Command
    if (-not $NoVmx) { $argv += $Config.VmxPath }
    $argv += $Arguments

    $display = $argv -join ' '
    if ($Config.GuestPassword) { $display = $display.Replace($Config.GuestPassword, '***') }

    for ($attempt = 1; ; $attempt++) {
        Write-LabLog "vmrun $display" -Quiet
        $result = Invoke-LabProcess -FilePath $Config.Vmrun -ArgumentList $argv -TimeoutSec $TimeoutSec
        $text = (@($result.StdOut, $result.StdErr) | Where-Object { $_ }) -join "`n"
        if ($text) { Write-LabLog "  -> $text" -Quiet }

        if ($result.ExitCode -eq 0) {
            return [pscustomobject]@{ Output = $result.StdOut; GuestExitCode = 0 }
        }
        if ($text -match 'Guest program exited with non-zero exit code: (-?\d+)') {
            return [pscustomobject]@{ Output = $result.StdOut; GuestExitCode = [int]$Matches[1] }
        }
        $transient = $script:TransientVmrunErrors | Where-Object { $text -like "*$_*" }
        if (-not $transient -or $attempt -gt $RetryCount) {
            throw "vmrun $Command failed (exit $($result.ExitCode)): $text"
        }
        Start-Sleep -Seconds $RetryDelaySec
    }
}

function Get-LabState {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path $Path)) { return @() }
    @((Get-Content $Path -Raw | ConvertFrom-Json).Completed)
}

function Set-LabState {
    param(
        [Parameter(Mandatory)][string]$Path,
        [string[]]$Completed = @()
    )
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
    @{ Completed = @($Completed) } | ConvertTo-Json | Set-Content -Path $Path -Encoding utf8
}

function Invoke-LabPhases {
    param(
        [Parameter(Mandatory)][System.Collections.Specialized.OrderedDictionary]$Phases,
        [Parameter(Mandatory)][string]$StatePath,
        [string]$From
    )
    $names = @($Phases.Keys)
    if ($From -and $From -notin $names) {
        throw "Unknown phase '$From'. Phases: $($names -join ', ')"
    }
    $completed = [System.Collections.Generic.List[string]]::new([string[]]@(Get-LabState -Path $StatePath))
    if ($From) {
        $rerun = $names[[array]::IndexOf($names, $From)..($names.Count - 1)]
        $completed.RemoveAll([Predicate[string]] { param($n) $n -in $rerun }) | Out-Null
        Set-LabState -Path $StatePath -Completed $completed
    }
    foreach ($name in $names) {
        if ($name -in $completed) {
            Write-LabLog "== $name (already done, skipping)"
            continue
        }
        Write-LabLog "== $name"
        try {
            & $Phases[$name]
        } catch {
            Write-LabLog "!! Phase $name failed: $($_.Exception.Message)"
            Write-LabLog "   Log: $(Get-LabLogPath)"
            Write-LabLog "   Resume with: .\setup.ps1 -From $name"
            throw
        }
        $completed.Add($name)
        Set-LabState -Path $StatePath -Completed $completed
    }
}
