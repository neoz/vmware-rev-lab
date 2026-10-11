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

function Get-LabVmxSettings {
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][string]$WindowsIso,
        [Parameter(Mandatory)][string]$AnswerIso
    )
    $name = [System.IO.Path]::GetFileNameWithoutExtension($Config.VmxPath)
    $settings = [ordered]@{
        '.encoding'                     = 'UTF-8'
        'config.version'                = '8'
        'virtualHW.version'             = '20'
        'displayName'                   = $name
        'guestOS'                       = 'windows9-64'
        'firmware'                      = 'bios'
        'numvcpus'                      = "$($Config.Cpu)"
        'cpuid.coresPerSocket'          = "$($Config.Cpu)"
        'memsize'                       = "$($Config.MemoryMB)"
        'sata0.present'                 = 'TRUE'
        'sata0:0.present'               = 'TRUE'
        'sata0:0.fileName'              = "$name.vmdk"
        'ethernet0.present'             = 'TRUE'
        'ethernet0.virtualDev'          = 'e1000e'
        'ethernet0.connectionType'      = 'nat'
        'ethernet0.addressType'         = 'generated'
        'ethernet0.startConnected'      = 'TRUE'
        'usb.present'                   = 'TRUE'
        'sound.present'                 = 'FALSE'
        'floppy0.present'               = 'FALSE'
        'isolation.tools.hgfs.disable'  = 'TRUE'
        'isolation.tools.dnd.disable'   = 'TRUE'
        'isolation.tools.copy.disable'  = 'TRUE'
        'isolation.tools.paste.disable' = 'TRUE'
        'sharedFolder.maxNum'           = '0'
        'tools.syncTime'                = 'FALSE'
    }
    $media = @($WindowsIso, $AnswerIso, $Config.ToolsIso)
    for ($i = 1; $i -le 3; $i++) {
        $settings["sata0:$i.present"] = 'TRUE'
        $settings["sata0:$i.deviceType"] = 'cdrom-image'
        $settings["sata0:$i.fileName"] = $media[$i - 1]
        $settings["sata0:$i.startConnected"] = 'TRUE'
    }
    $settings
}

function ConvertTo-VmxText {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Settings)
    ($Settings.Keys | ForEach-Object { '{0} = "{1}"' -f $_, $Settings[$_] }) -join "`r`n"
}

function ConvertFrom-VmxText {
    param([Parameter(Mandatory)][string]$Text)
    $settings = [ordered]@{}
    foreach ($line in $Text -split "`r?`n") {
        if ($line -match '^\s*([^=#\s][^=]*?)\s*=\s*"(.*)"\s*$') { $settings[$Matches[1]] = $Matches[2] }
    }
    $settings
}

function Read-LabVmx { param([hashtable]$Config) ConvertFrom-VmxText (Get-Content -Path $Config.VmxPath -Raw) }

function Write-LabVmx {
    param([hashtable]$Config, [System.Collections.IDictionary]$Settings)
    Set-Content -Path $Config.VmxPath -Value (ConvertTo-VmxText $Settings) -Encoding utf8
}

function Set-LabVmxNetwork {
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][ValidateSet('Setup', 'Analysis')][string]$Mode
    )
    $settings = Read-LabVmx $Config
    if ($Mode -eq 'Setup') {
        $settings['ethernet0.connectionType'] = 'nat'
        $settings.Remove('ethernet0.pvnID')
    } else {
        $settings['ethernet0.connectionType'] = 'pvn'
        $settings['ethernet0.pvnID'] = $Config.AnalysisPvnId
    }
    Write-LabVmx $Config $settings
}

function Get-LabVmxNetworkMode {
    param([Parameter(Mandatory)][hashtable]$Config)
    $settings = Read-LabVmx $Config
    $type = $settings['ethernet0.connectionType']
    if ($type -eq 'nat') { return 'Setup' }
    if ($type -eq 'pvn' -and $settings['ethernet0.pvnID'] -eq $Config.AnalysisPvnId) { return 'Analysis' }
    'Unknown'
}

function Remove-LabVmxInstallMedia {
    param([Parameter(Mandatory)][hashtable]$Config)
    $settings = Read-LabVmx $Config
    foreach ($key in @($settings.Keys | Where-Object { $_ -match '^sata0:[123]\.' })) { $settings.Remove($key) }
    Write-LabVmx $Config $settings
}

function ConvertTo-LabUnattendXml {
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][string]$TemplatePath
    )
    $escape = { param($v) [System.Security.SecurityElement]::Escape([string]$v) }
    $text = Get-Content -Path $TemplatePath -Raw
    $text = $text.Replace('{{GUEST_USER}}', (& $escape $Config.GuestUser))
    $text = $text.Replace('{{GUEST_PASSWORD}}', (& $escape $Config.GuestPassword))
    $text = $text.Replace('{{COMPUTER_NAME}}', (& $escape $Config.ComputerName))
    if ($text -match '\{\{[A-Z_]+\}\}') { throw "Unfilled placeholder in ${TemplatePath}: $($Matches[0])" }
    $text
}

function New-LabIso {
    param(
        [Parameter(Mandatory)][string]$SourceDir,
        [Parameter(Mandatory)][string]$Path,
        [string]$VolumeName = 'ANSWER'
    )
    if (-not ('LabIsoWriter' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;

public static class LabIsoWriter {
    public static void Write(object comStream, string path) {
        IStream stream = (IStream)comStream;
        byte[] buffer = new byte[65536];
        IntPtr readPtr = Marshal.AllocHGlobal(sizeof(int));
        try {
            using (FileStream file = File.Create(path)) {
                while (true) {
                    stream.Read(buffer, buffer.Length, readPtr);
                    int read = Marshal.ReadInt32(readPtr);
                    if (read == 0) break;
                    file.Write(buffer, 0, read);
                }
            }
        } finally {
            Marshal.FreeHGlobal(readPtr);
        }
    }
}
'@
    }
    $image = New-Object -ComObject IMAPI2FS.MsftFileSystemImage
    $image.FileSystemsToCreate = 3  # ISO9660 + Joliet
    $image.VolumeName = $VolumeName
    $image.Root.AddTree((Resolve-Path $SourceDir).Path, $false)
    $result = $image.CreateResultImage()
    if (Test-Path $Path) { Remove-Item $Path -Force }
    [LabIsoWriter]::Write($result.ImageStream, $Path)
}

function New-LabAnswerIso {
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][string]$Path
    )
    $staging = Join-Path $Config.LabDir 'answer-staging'
    if (Test-Path $staging) { Remove-Item $staging -Recurse -Force }
    New-Item -ItemType Directory -Force -Path (Join-Path $staging 'answer') | Out-Null
    $xml = ConvertTo-LabUnattendXml -Config $Config -TemplatePath (Join-Path $Config.Root 'templates/autounattend.xml')
    Set-Content -Path (Join-Path $staging 'autounattend.xml') -Value $xml -Encoding utf8
    Copy-Item -Path (Join-Path $Config.Root 'templates/answer/*') -Destination (Join-Path $staging 'answer')
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
    New-LabIso -SourceDir $staging -Path $Path
}
