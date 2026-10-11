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
        # Arguments may carry the guest password; callers add a masked command line.
        throw "Timed out after $TimeoutSec s: $FilePath"
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
    'must be logged in interactively'
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
        try {
            $result = Invoke-LabProcess -FilePath $Config.Vmrun -ArgumentList $argv -TimeoutSec $TimeoutSec
        } catch {
            throw "vmrun $display failed: $($_.Exception.Message)"
        }
        $text = (@($result.StdOut, $result.StdErr) | Where-Object { $_ }) -join "`n"
        if ($text) { Write-LabLog "  -> $text" -Quiet }

        if ($result.ExitCode -eq 0) {
            return [pscustomobject]@{ Output = $result.StdOut; GuestExitCode = 0 }
        }
        if ($text -match 'Guest program exited with non-zero exit code: (-?\d+)') {
            return [pscustomobject]@{ Output = $result.StdOut; GuestExitCode = [int]$Matches[1] }
        }
        $transient = $script:TransientVmrunErrors | Where-Object { $text -like "*$_*" }
        # A cancelled runProgramInGuest may already have started the program; retrying would start it twice.
        if ($Command -eq 'runProgramInGuest' -and $text -like '*The operation was canceled*') { $transient = $null }
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
        'pciBridge0.present'            = 'TRUE'
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
        'vmci0.present'                 = 'TRUE'
    }
    # PCIe devices such as the e1000e NIC need root ports, or the VM stops at "No PCIe slot available".
    foreach ($i in 4..7) {
        $settings["pciBridge$i.present"] = 'TRUE'
        $settings["pciBridge$i.virtualDev"] = 'pcieRootPort'
        $settings["pciBridge$i.functions"] = '8'
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

$script:GuestPowerShell = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
$script:GuestTmp = 'C:\lab\tmp'

function Wait-LabCondition {
    param(
        [Parameter(Mandatory)][string]$Description,
        [Parameter(Mandatory)][scriptblock]$Condition,
        [int]$TimeoutSec = 600,
        [int]$PollSec = 10
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ($true) {
        if (& $Condition) { return }
        if ((Get-Date) -ge $deadline) { throw "Timed out after $TimeoutSec s waiting for: $Description" }
        Start-Sleep -Seconds $PollSec
    }
}

function Test-LabVmRunning {
    param([Parameter(Mandatory)][hashtable]$Config)
    $lines = (Invoke-Vmrun -Config $Config -Command list -NoVmx).Output -split "`r?`n"
    $lines -contains $Config.VmxPath
}

function Start-LabVm {
    param([Parameter(Mandatory)][hashtable]$Config)
    if (-not (Test-LabVmRunning -Config $Config)) {
        Invoke-Vmrun -Config $Config -Command start -Arguments @('gui') | Out-Null
    }
}

function Stop-LabVm {
    param([Parameter(Mandatory)][hashtable]$Config)
    if (Test-LabVmRunning -Config $Config) {
        Invoke-Vmrun -Config $Config -Command stop -Arguments @('soft') -TimeoutSec 600 | Out-Null
    }
    Wait-LabCondition -Description 'VM power off' -TimeoutSec 300 -Condition { -not (Test-LabVmRunning -Config $Config) }
}

function Wait-LabTools {
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [int]$TimeoutSec = 600,
        [int]$PollSec = 10
    )
    Wait-LabCondition -Description 'VMware Tools running' -TimeoutSec $TimeoutSec -PollSec $PollSec -Condition {
        try { (Invoke-Vmrun -Config $Config -Command checkToolsState -RetryCount 0).Output -match 'running' } catch { $false }
    }
}

function Test-LabGuestFile {
    param([Parameter(Mandatory)][hashtable]$Config, [Parameter(Mandatory)][string]$GuestPath)
    try {
        (Invoke-Vmrun -Config $Config -Command fileExistsInGuest -Arguments @($GuestPath) -Guest -RetryCount 0).Output -match 'The file exists'
    } catch { $false }
}

function New-LabGuestDirectory {
    param([Parameter(Mandatory)][hashtable]$Config, [Parameter(Mandatory)][string]$GuestPath)
    # vmrun exits non-zero when the directory is missing.
    try {
        $exists = (Invoke-Vmrun -Config $Config -Command directoryExistsInGuest -Arguments @($GuestPath) -Guest).Output
    } catch {
        if ($_.Exception.Message -notmatch 'The directory does not exist') { throw }
        $exists = ''
    }
    if ($exists -notmatch 'The directory exists') {
        Invoke-Vmrun -Config $Config -Command createDirectoryInGuest -Arguments @($GuestPath) -Guest | Out-Null
    }
}

function Copy-LabToGuest {
    param([Parameter(Mandatory)][hashtable]$Config, [Parameter(Mandatory)][string]$HostPath, [Parameter(Mandatory)][string]$GuestPath)
    Invoke-Vmrun -Config $Config -Command copyFileFromHostToGuest -Arguments @($HostPath, $GuestPath) -Guest -TimeoutSec 900 | Out-Null
}

function Copy-LabFromGuest {
    param([Parameter(Mandatory)][hashtable]$Config, [Parameter(Mandatory)][string]$GuestPath, [Parameter(Mandatory)][string]$HostPath)
    Invoke-Vmrun -Config $Config -Command copyFileFromGuestToHost -Arguments @($GuestPath, $HostPath) -Guest -TimeoutSec 900 | Out-Null
}

function Copy-LabGuestScript {
    # Copies a script and a wrapper that runs it with literal arguments and captures all output.
    param([hashtable]$Config, [string]$Path, [hashtable]$Arguments)
    $id = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $name = [System.IO.Path]::GetFileNameWithoutExtension($Path)
    $guest = @{
        Script  = "$script:GuestTmp\$name-$id.ps1"
        Wrapper = "$script:GuestTmp\wrap-$id.ps1"
        Output  = "$script:GuestTmp\$name-$id.out"
    }
    $argText = ($Arguments.Keys | ForEach-Object {
        # PowerShell treats U+2018..U+201B like ' inside single-quoted strings, so double those too.
        "-$_ '$(([string]$Arguments[$_]) -replace "['\u2018\u2019\u201A\u201B]", '$0$0')'"
    }) -join ' '
    $wrapper = @"
`$code = 0
try {
    & '$($guest.Script)' $argText *> '$($guest.Output)'
    if (`$LASTEXITCODE) { `$code = `$LASTEXITCODE }
} catch {
    `$_ | Out-String | Add-Content -Path '$($guest.Output)'
    `$code = 1
}
exit `$code
"@
    $hostWrapper = Join-Path ([System.IO.Path]::GetTempPath()) "wrap-$id.ps1"
    Set-Content -Path $hostWrapper -Value $wrapper -Encoding utf8BOM
    try {
        New-LabGuestDirectory -Config $Config -GuestPath $script:GuestTmp
        Copy-LabToGuest -Config $Config -HostPath $Path -GuestPath $guest.Script
        Copy-LabToGuest -Config $Config -HostPath $hostWrapper -GuestPath $guest.Wrapper
    } finally {
        Remove-Item -Path $hostWrapper -ErrorAction SilentlyContinue
    }
    $guest
}

function Invoke-LabGuestScript {
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][string]$Path,
        [hashtable]$Arguments = @{},
        [switch]$Interactive,
        [int]$TimeoutSec = 600
    )
    $guest = Copy-LabGuestScript -Config $Config -Path $Path -Arguments $Arguments
    $runArgs = @()
    if ($Interactive) { $runArgs += '-interactive' }
    $runArgs += @($script:GuestPowerShell, '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $guest.Wrapper)
    $result = Invoke-Vmrun -Config $Config -Command runProgramInGuest -Arguments $runArgs -Guest -TimeoutSec $TimeoutSec

    $localOut = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetFileName($guest.Output))
    try {
        Copy-LabFromGuest -Config $Config -GuestPath $guest.Output -HostPath $localOut
        $output = (Get-Content -Path $localOut -Raw)
    } catch {
        $output = "(no output captured: $($_.Exception.Message))"
    } finally {
        Remove-Item -Path $localOut -ErrorAction SilentlyContinue
    }
    [pscustomobject]@{ ExitCode = $result.GuestExitCode; Output = "$output".Trim() }
}

function Start-LabGuestScript {
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][string]$Path,
        [hashtable]$Arguments = @{}
    )
    $guest = Copy-LabGuestScript -Config $Config -Path $Path -Arguments $Arguments
    Invoke-Vmrun -Config $Config -Command runProgramInGuest -Guest -Arguments @(
        '-noWait', '-interactive', $script:GuestPowerShell, '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $guest.Wrapper
    ) | Out-Null
}

function Get-LabGuestBootTime {
    param([Parameter(Mandatory)][hashtable]$Config)
    $r = Invoke-LabGuestScript -Config $Config -Path (Join-Path $Config.Root 'templates/guest/get-boot-time.ps1')
    if ($r.ExitCode -ne 0) { throw "get-boot-time.ps1 failed: $($r.Output)" }
    $r.Output
}

function Restart-LabGuest {
    param([Parameter(Mandatory)][hashtable]$Config)
    $before = Get-LabGuestBootTime -Config $Config
    Write-LabLog "Restarting guest (booted $before)"
    Invoke-Vmrun -Config $Config -Command reset -Arguments @('soft') | Out-Null
    Wait-LabCondition -Description 'guest reboot' -TimeoutSec 900 -PollSec 15 -Condition {
        try { $now = Get-LabGuestBootTime -Config $Config; $now -and $now -ne $before } catch { $false }
    }
}

function Wait-LabDesktop {
    param([Parameter(Mandatory)][hashtable]$Config)
    Wait-LabCondition -Description 'user desktop (explorer.exe)' -TimeoutSec 600 -PollSec 10 -Condition {
        try { (Invoke-Vmrun -Config $Config -Command listProcessesInGuest -Guest -RetryCount 0).Output -match 'explorer\.exe' } catch { $false }
    }
}

function Get-LabSnapshots {
    param([Parameter(Mandatory)][hashtable]$Config)
    $lines = (Invoke-Vmrun -Config $Config -Command listSnapshots).Output -split "`r?`n"
    @($lines | Select-Object -Skip 1 | Where-Object { $_.Trim() })
}

function Update-LabSnapshot {
    # vmrun cannot rename snapshots, so take a new timestamped one first and delete the old one only after
    # that succeeded; a failure never leaves the lab without a clean snapshot.
    param([Parameter(Mandatory)][hashtable]$Config)
    $old = $Config.SnapshotName
    $new = '{0}-{1:yyyyMMddHHmmss}' -f ($old -replace '-\d{14}$', ''), (Get-Date)
    Invoke-Vmrun -Config $Config -Command snapshot -Arguments @($new) -TimeoutSec 1800 | Out-Null
    Save-LabLocalConfig -Root $Config.Root -Values @{ SnapshotName = $new }
    $Config.SnapshotName = $new
    if ($old -in (Get-LabSnapshots -Config $Config)) {
        Invoke-Vmrun -Config $Config -Command deleteSnapshot -Arguments @($old) -TimeoutSec 1800 | Out-Null
    }
    Write-LabLog "Snapshot '$new' taken (replaces '$old')"
}

function Restore-LabClean {
    param([Parameter(Mandatory)][hashtable]$Config)
    Invoke-Vmrun -Config $Config -Command revertToSnapshot -Arguments @($Config.SnapshotName) -TimeoutSec 600 | Out-Null
    $mode = Get-LabVmxNetworkMode -Config $Config
    if ($mode -ne 'Analysis') {
        throw "VM network is '$mode', not on the analysis LAN segment. Refusing to resume. Run .\scripts\net.ps1 -Mode Analysis first."
    }
    Start-LabVm -Config $Config
    Wait-LabTools -Config $Config -TimeoutSec 300 -PollSec 5
}

function Test-LabIsoHash {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Expected)
    $actual = (Get-FileHash -Path $Path -Algorithm SHA256).Hash
    if ($actual -ne $Expected.ToUpperInvariant()) {
        throw "SHA256 mismatch for ${Path}: got $actual, expected $Expected. If this ISO is intentional, set IsoSha256 in lab.config.psd1."
    }
}

function Assert-LabVmAbsent {
    param([Parameter(Mandatory)][hashtable]$Config)
    if (Test-Path $Config.VmxPath) {
        throw "A VM already exists at $($Config.VmxPath). Delete it in VMware (Manage > Delete from Disk) or change VmxPath, then rerun with -From CreateVm."
    }
}

function New-LabMcpJson {
    param([Parameter(Mandatory)][hashtable]$Config)
    $python = Join-Path $Config.Root 'tools\vmware-mcp\.venv\Scripts\python.exe'
    $bridge = Join-Path $Config.Root 'scripts\mcp\revlab_bridge.py'
    $local = Join-Path $Config.Root 'lab.local.psd1'
    $bridgeServer = {
        param([int]$Port, [string]$Task)
        [ordered]@{
            type    = 'stdio'
            command = $python
            args    = @('-I', $bridge, '--port', "$Port", '--task', $Task, '--vmx', $Config.VmxPath,
                        '--vmrun', $Config.Vmrun, '--guest-user', $Config.GuestUser, '--local-config', $local)
        }
    }
    [ordered]@{
        mcpServers = [ordered]@{
            'vmware-mcp'    = [ordered]@{
                type    = 'stdio'
                command = Join-Path $Config.Root 'tools\vmware-mcp\.venv\Scripts\vmware-mcp.exe'
                args    = @()
                env     = [ordered]@{
                    VMRUN_PATH      = $Config.Vmrun
                    VMCLI_PATH      = $Config.Vmcli
                    VMWARE_USERNAME = '${VMWARE_USERNAME:-}'
                    VMWARE_PASSWORD = '${VMWARE_PASSWORD:-}'
                }
            }
            'revlab-ghidra' = & $bridgeServer $Config.McpGhidraPort 'RevlabMcpGhidra'
            'revlab-windbg' = & $bridgeServer $Config.McpWindbgPort 'RevlabMcpWindbg'
        }
    } | ConvertTo-Json -Depth 5
}

function Get-LabHostIPv4 {
    @(Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -ne '127.0.0.1' } | ForEach-Object IPAddress)
}

function Set-LabGuestNetwork {
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][ValidateSet('Setup', 'Analysis')][string]$Mode
    )
    $r = Invoke-LabGuestScript -Config $Config -Path (Join-Path $Config.Root 'templates/guest/set-guest-net.ps1') -Arguments @{
        Mode = $Mode; Ip = $Config.GuestIp; Prefix = $Config.GuestPrefix; Gateway = $Config.GuestGateway
    }
    Write-LabLog $r.Output -Quiet
    if ($r.ExitCode -ne 0) { throw "set-guest-net.ps1 -Mode $Mode failed: $($r.Output)" }
}

function Assert-LabIsolation {
    param([Parameter(Mandatory)][hashtable]$Config)
    # The guest-side test also passes on NAT once the static IP is set, so check the VM's NIC first.
    $mode = Get-LabVmxNetworkMode -Config $Config
    if ($mode -ne 'Analysis') { throw "VM network is '$mode', not on the analysis LAN segment." }
    $r = Invoke-LabGuestScript -Config $Config -Path (Join-Path $Config.Root 'templates/guest/test-isolation.ps1') -Arguments @{
        HostIps = (Get-LabHostIPv4) -join ','
    } -TimeoutSec 300
    Write-LabLog $r.Output
    if ($r.ExitCode -ne 0) { throw "Isolation check failed: $($r.Output)" }
}

$script:SupportedSampleExtensions = @('.exe', '.dll', '.ps1', '.bat', '.cmd')

function Get-LabSampleEntry {
    # Reads only the zip directory (works for password-protected zips); never extracts.
    param(
        [Parameter(Mandatory)][string]$ZipPath,
        [string]$Sample,
        [string]$Export
    )
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::OpenRead((Resolve-Path $ZipPath).Path)
    try {
        $names = @($archive.Entries | Where-Object { $_.Name } | ForEach-Object Name)
    } finally {
        $archive.Dispose()
    }
    if ($Sample) {
        if ($Sample -notin $names) { throw "'$Sample' is not in $ZipPath. Files: $($names -join ', ')" }
        $count = @($names | Where-Object { $_ -eq $Sample }).Count
        if ($count -gt 1) { throw "'$Sample' appears $count times in $ZipPath (different folders); repack it with a unique name." }
        $entry = $Sample
    } elseif ($names.Count -eq 1) {
        $entry = $names[0]
    } else {
        throw "$ZipPath has $($names.Count) files; pass -Sample <name>. Files: $($names -join ', ')"
    }
    $extension = [System.IO.Path]::GetExtension($entry).ToLowerInvariant()
    if ($extension -notin $script:SupportedSampleExtensions) {
        throw "Unsupported sample type '$extension' for '$entry'. Supported: $($script:SupportedSampleExtensions -join ', '). Repack the zip and rename the file with the right extension."
    }
    if ($extension -eq '.dll' -and -not $Export) { throw "'$entry' is a DLL; pass -Export <function> to run it with rundll32" }
    $entry
}

function Assert-LabCaseName {
    # Case names become folders under cases/; refuse anything that could leave it.
    param([string]$Case)
    if ($Case -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$' -or $Case -match '\.\.') {
        throw "Invalid case name '$Case': use letters, digits, '.', '_' or '-', starting with a letter or digit."
    }
}

$script:TextFetchExtensions = @('.txt', '.log', '.json', '.csv', '.tsv', '.xml', '.md', '.yar', '.yara', '.c', '.cs', '.py', '.js', '.ini')

function Assert-LabTextFetchPath {
    param([Parameter(Mandatory)][string]$GuestPath)
    $extension = [System.IO.Path]::GetExtension($GuestPath).ToLowerInvariant()
    if ($extension -notin $script:TextFetchExtensions) {
        throw "'$GuestPath' is not a text file ($($script:TextFetchExtensions -join ' ')); fetch it without -Text so it is zipped."
    }
}

function Assert-LabNotPe {
    # A sample can write an executable under a text name; never leave one unzipped on the host.
    param([Parameter(Mandatory)][string]$Path)
    $stream = [System.IO.File]::OpenRead($Path)
    try {
        $head = [byte[]]::new(2)
        $read = $stream.Read($head, 0, 2)
    } finally {
        $stream.Dispose()
    }
    if ($read -eq 2 -and $head[0] -eq 0x4D -and $head[1] -eq 0x5A) {
        Remove-Item -Path $Path -Force
        throw "'$Path' is a PE file (MZ header); deleted. Fetch it without -Text."
    }
}

function Assert-LabFreshVmSlot {
    # Run from Preflight so an existing VM stops setup before any download; a VM this setup created is fine.
    param([Parameter(Mandatory)][hashtable]$Config)
    if ('CreateVm' -notin @(Get-LabState -Path $Config.StatePath)) { Assert-LabVmAbsent -Config $Config }
}

function New-LabVm {
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][string]$WindowsIso,
        [Parameter(Mandatory)][string]$AnswerIso
    )
    Assert-LabVmAbsent -Config $Config
    $vmDir = Split-Path -Parent $Config.VmxPath
    $createdDir = -not (Test-Path $vmDir)
    New-Item -ItemType Directory -Force -Path $vmDir | Out-Null
    $settings = Get-LabVmxSettings -Config $Config -WindowsIso $WindowsIso -AnswerIso $AnswerIso
    $disk = Join-Path $vmDir $settings['sata0:0.fileName']
    try {
        Write-LabVmx -Config $Config -Settings $settings
        $r = Invoke-LabProcess -FilePath $Config.VdiskManager -ArgumentList @('-c', '-s', "$($Config.DiskGB)GB", '-a', 'lsilogic', '-t', '0', $disk) -TimeoutSec 300
        if ($r.ExitCode -ne 0) { throw "vmware-vdiskmanager failed: $($r.StdOut) $($r.StdErr)" }
    } catch {
        # Leave nothing behind, so '-From CreateVm' can simply run again.
        if ($createdDir) { Remove-Item -Path $vmDir -Recurse -Force -ErrorAction SilentlyContinue }
        else { Remove-Item -Path $Config.VmxPath, $disk -Force -ErrorAction SilentlyContinue }
        throw
    }
}

function Save-LabIso {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Sha256
    )
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
    if ((Test-Path $Path) -and (Get-FileHash -Path $Path -Algorithm SHA256).Hash -eq $Sha256.ToUpperInvariant()) { return }
    $curlArgs = { @('-L', '--fail', '--retry', '3', '--no-progress-meter', '-C', '-', '-o', $Path, $Url) }
    $r = Invoke-LabProcess -FilePath 'curl.exe' -ArgumentList (& $curlArgs) -TimeoutSec 10800
    if ($r.ExitCode -ne 0 -and (Test-Path $Path)) {
        # Resuming a corrupt full-size file fails (HTTP 416); start over once.
        Write-LabLog "Resume failed (curl exit $($r.ExitCode)); downloading from scratch"
        Remove-Item -Path $Path -Force
        $r = Invoke-LabProcess -FilePath 'curl.exe' -ArgumentList (& $curlArgs) -TimeoutSec 10800
    }
    if ($r.ExitCode -ne 0) { throw "ISO download failed (curl exit $($r.ExitCode)): $($r.StdErr)" }
    try {
        Test-LabIsoHash -Path $Path -Expected $Sha256
    } catch {
        Remove-Item -Path $Path -Force
        throw
    }
}

function Update-LabToolsIndex {
    param([Parameter(Mandatory)][hashtable]$Config)
    $r = Invoke-LabGuestScript -Config $Config -Path (Join-Path $Config.Root 'templates/guest/index-tools.ps1')
    Write-LabLog $r.Output
    if ($r.ExitCode -ne 0) { throw "index-tools.ps1 failed: $($r.Output)" }
}
