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

function Disable-LabStdHandleInheritance {
    # Process.Start with UseShellExecute = $false makes every inheritable handle of this
    # process visible to the child, including the stdout/stderr pipes our own caller reads.
    # A long-lived grandchild (vmware.exe from `vmrun start gui`) would then keep the
    # caller's pipe open after the script has finished. Children get their own pipes, so
    # ours never need to be inherited. Returns the previous flags for Restore-LabStdHandleInheritance:
    # when a script runs inside the interactive shell, that shell's later children need them.
    if (-not $IsWindows) { return }
    if (-not ('LabCommon.StdHandles' -as [type])) {
        Add-Type -Namespace LabCommon -Name StdHandles -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError = true)] public static extern System.IntPtr GetStdHandle(int nStdHandle);
[DllImport("kernel32.dll", SetLastError = true)] public static extern bool GetHandleInformation(System.IntPtr hObject, out uint lpdwFlags);
[DllImport("kernel32.dll", SetLastError = true)] public static extern bool SetHandleInformation(System.IntPtr hObject, uint dwMask, uint dwFlags);
'@
    }
    foreach ($id in -11, -12) {
        # STD_OUTPUT_HANDLE, STD_ERROR_HANDLE; HANDLE_FLAG_INHERIT = 1.
        $handle = [LabCommon.StdHandles]::GetStdHandle($id)
        $flags = [uint32]0
        if ($handle -ne [IntPtr]::Zero -and $handle -ne [IntPtr]::new(-1) -and
            [LabCommon.StdHandles]::GetHandleInformation($handle, [ref]$flags)) {
            [void][LabCommon.StdHandles]::SetHandleInformation($handle, 1, 0)
            [pscustomobject]@{ Handle = $handle; Flags = $flags }
        }
    }
}

function Restore-LabStdHandleInheritance {
    param([object[]]$Saved)
    foreach ($s in $Saved) { [void][LabCommon.StdHandles]::SetHandleInformation($s.Handle, 1, $s.Flags -band 1) }
}

function Invoke-LabProcess {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [int]$TimeoutSec = 300,
        # When set, logs a heartbeat every ProgressSec seconds so a long silent command does not look hung.
        [string]$ProgressLabel,
        [int]$ProgressSec = 30
    )
    $psi = [System.Diagnostics.ProcessStartInfo]::new($FilePath)
    foreach ($arg in $ArgumentList) { $psi.ArgumentList.Add($arg) }
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    # Handles are inherited only at creation time, so the flags can come back right after.
    $saved = @(Disable-LabStdHandleInheritance)
    try {
        $process = [System.Diagnostics.Process]::Start($psi)
    } finally {
        Restore-LabStdHandleInheritance -Saved $saved
    }
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    $step = if ($ProgressLabel) { $ProgressSec } else { $TimeoutSec }
    $elapsed = 0
    while (-not $process.WaitForExit([Math]::Min($step, $TimeoutSec - $elapsed) * 1000)) {
        $elapsed = [Math]::Min($elapsed + $step, $TimeoutSec)
        if ($elapsed -ge $TimeoutSec) {
            $process.Kill($true)
            # Arguments may carry the guest password; callers add a masked command line.
            throw "Timed out after $TimeoutSec s: $FilePath"
        }
        Write-LabLog ('  ... {0}: still running ({1}m{2:00}s)' -f $ProgressLabel, [Math]::Floor($elapsed / 60), ($elapsed % 60))
    }
    $process.WaitForExit()
    # Children such as vmware.exe (from `vmrun start gui`) inherit the pipes and keep them open.
    [void][System.Threading.Tasks.Task]::WaitAll(@($stdout, $stderr), 5000)
    [pscustomobject]@{
        ExitCode = $process.ExitCode
        StdOut   = if ($stdout.IsCompleted) { $stdout.Result.Trim() } else { '' }
        StdErr   = if ($stderr.IsCompleted) { $stderr.Result.Trim() } else { '' }
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
        [int]$RetryDelaySec = 15,
        [string]$ProgressLabel
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
            $result = Invoke-LabProcess -FilePath $Config.Vmrun -ArgumentList $argv -TimeoutSec $TimeoutSec -ProgressLabel $ProgressLabel
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
        # A recreated VM no longer has the IDA that add-ida.ps1 installed.
        if ('CreateVm' -in $rerun) { $rerun += 'AddIda' }
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
        Write-LabLog 'Starting the VM'
        Invoke-Vmrun -Config $Config -Command start -Arguments @('gui') | Out-Null
    }
}

function Get-LabSessionNotice {
    # SessionStart hook output: warns the user and Claude when the VM is off, since the guest MCP bridges cannot connect
    # then, and when the guest is off the analysis segment, so Claude knows anything it runs there may reach the network.
    param([Parameter(Mandatory)][hashtable]$Config)
    try {
        if (Test-LabVmRunning -Config $Config) {
            $mode = Get-LabVmxNetworkMode -Config $Config
            if ($mode -eq 'Analysis') { return $null }
            if ($mode -eq 'Setup') {
                $netCase = Get-LabNetCase -Config $Config
                $online = if ($netCase) { "The guest is on NAT with Internet: the user set an Internet policy for case '$netCase'." }
                          else { 'The guest is on NAT with Internet: a manual net.ps1 -Mode Setup session is in progress.' }
                $reach = 'Anything run in the guest reaches the Internet, the host and its LAN.'
            } else {
                $online = 'The guest NIC is not on the analysis segment (unknown network type, e.g. bridged or host-only).'
                $reach = 'Anything run in the guest may reach the host, its LAN or the Internet.'
            }
            return @{
                systemMessage      = $online
                hookSpecificOutput = @{
                    hookEventName     = 'SessionStart'
                    additionalContext = "$online $reach"
                }
            } | ConvertTo-Json -Compress
        }
        $problem = "Lab VM is not running, so the revlab-* MCP servers cannot connect."
    } catch {
        $problem = "Could not check the lab VM state: $($_.Exception.Message)"
    }
    $fix = 'Run: pwsh -File scripts/reset.ps1, then reconnect the revlab-* servers in /mcp.'
    @{
        systemMessage      = "$problem $fix"
        hookSpecificOutput = @{
            hookEventName     = 'SessionStart'
            additionalContext = "$problem Before using a revlab-* server, ask the user to run 'pwsh -File scripts/reset.ps1' and reconnect the servers in /mcp."
        }
    } | ConvertTo-Json -Compress
}

function Stop-LabVm {
    param([Parameter(Mandatory)][hashtable]$Config)
    if (Test-LabVmRunning -Config $Config) {
        Write-LabLog 'Shutting down the VM'
        Invoke-Vmrun -Config $Config -Command stop -Arguments @('soft') -TimeoutSec 600 -ProgressLabel 'shutdown' | Out-Null
    }
    Wait-LabCondition -Description 'VM power off' -TimeoutSec 300 -Condition { -not (Test-LabVmRunning -Config $Config) }
}

function Wait-LabTools {
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [int]$TimeoutSec = 600,
        [int]$PollSec = 10
    )
    Write-LabLog 'Waiting for VMware Tools in the guest'
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
    Write-LabLog 'Waiting for the guest desktop'
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
    # Setup phases can run on a guest that still holds a case (e.g. after the smoke test); never bake it in.
    Write-LabLog 'Clearing guest working folders before the snapshot'
    $r = Invoke-LabGuestScript -Config $Config -Path (Join-Path $Config.Root 'templates/guest/clear-workdirs.ps1')
    if ($r.ExitCode -ne 0) { throw "clear-workdirs.ps1 failed: $($r.Output)" }
    $old = $Config.SnapshotName
    $new = '{0}-{1:yyyyMMddHHmmss}' -f ($old -replace '-\d{14}$', ''), (Get-Date)
    Write-LabLog "Taking snapshot '$new' (a running VM can take several minutes)"
    Invoke-Vmrun -Config $Config -Command snapshot -Arguments @($new) -TimeoutSec 1800 -ProgressLabel "snapshot '$new'" | Out-Null
    Save-LabLocalConfig -Root $Config.Root -Values @{ SnapshotName = $new }
    $Config.SnapshotName = $new
    if ($old -in (Get-LabSnapshots -Config $Config)) {
        Write-LabLog "Deleting old snapshot '$old' (VMware merges its disk; can take several minutes)"
        Invoke-Vmrun -Config $Config -Command deleteSnapshot -Arguments @($old) -TimeoutSec 1800 -ProgressLabel "delete snapshot '$old'" | Out-Null
    }
    Write-LabLog "Snapshot '$new' taken (replaces '$old')"
}

function Restore-LabClean {
    param([Parameter(Mandatory)][hashtable]$Config, [switch]$SaveCase)
    # A manual net.ps1 -Mode Setup session (NAT without a case marker) is the user's; never revert it away.
    Assert-LabNetworkOwned -Config $Config | Out-Null
    # Saving first means a failed save stops here, before any work in the guest is lost.
    if ($SaveCase -and (Test-LabVmRunning -Config $Config)) {
        try {
            Save-LabCase -Config $Config | Out-Null
        } catch {
            throw "Saving the open case failed, so the VM was not reverted: $($_.Exception.Message). Fix the guest and retry, or run .\scripts\reset.ps1 -NoSave to discard the guest state."
        }
    }
    Invoke-Vmrun -Config $Config -Command revertToSnapshot -Arguments @($Config.SnapshotName) -TimeoutSec 600 | Out-Null
    Clear-LabRunState -Config $Config
    $mode = Get-LabVmxNetworkMode -Config $Config
    $netCase = Get-LabNetCase -Config $Config
    if ($mode -ne 'Analysis' -and -not ($mode -eq 'Setup' -and $netCase)) {
        throw "VM network is '$mode', not on the analysis LAN segment. Refusing to resume. Run .\scripts\net.ps1 -Mode Analysis first."
    }
    Start-LabVm -Config $Config
    Wait-LabTools -Config $Config -TimeoutSec 300 -PollSec 5
    if ($mode -eq 'Setup') {
        # A case's Internet policy left the VM on NAT; the clean guest holds no sample yet.
        Write-LabLog "Leaving NAT (Internet policy of case '$netCase')"
        Switch-LabNetwork -Config $Config -Mode Analysis
    } elseif ($netCase) {
        Remove-Item -Path (Join-Path $Config.LabDir 'case-net.txt') -ErrorAction SilentlyContinue
    }
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
    $servers = [ordered]@{
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
    # revlab-ida exists only after the user ran add-ida.ps1, which records AddIda in the state.
    if (Test-LabIdaInstalled -Config $Config) {
        $servers['revlab-ida'] = & $bridgeServer $Config.McpIdaPort 'RevlabMcpIda'
    }
    [ordered]@{ mcpServers = $servers } | ConvertTo-Json -Depth 5
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
    Write-LabLog 'Checking guest isolation (about 1-2 minutes)'
    $r = Invoke-LabGuestScript -Config $Config -Path (Join-Path $Config.Root 'templates/guest/test-isolation.ps1') -Arguments @{
        HostIps = (Get-LabHostIPv4) -join ','
    } -TimeoutSec 300
    Write-LabLog $r.Output
    if ($r.ExitCode -ne 0) { throw "Isolation check failed: $($r.Output)" }
}

function Get-LabNetCase {
    # The case whose Internet policy put the VM on NAT. Absent during the user's manual 'net.ps1 -Mode Setup'.
    param([Parameter(Mandatory)][hashtable]$Config)
    $path = Join-Path $Config.LabDir 'case-net.txt'
    if (-not (Test-Path $path)) { return $null }
    $case = (Get-Content -Path $path -Raw).Trim()
    Assert-LabCaseName $case
    $case
}

function Switch-LabNetwork {
    # Power cycles the VM onto the other network. The guest disk is kept (no revert); running processes are not.
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][ValidateSet('Setup', 'Analysis')][string]$Mode
    )
    try {
        Stop-LabVm -Config $Config
        Set-LabVmxNetwork -Config $Config -Mode $Mode
        Start-LabVm -Config $Config
        Wait-LabTools -Config $Config
        Set-LabGuestNetwork -Config $Config -Mode $Mode
        if ($Mode -eq 'Analysis') { Assert-LabIsolation -Config $Config }
    } catch {
        if ($Mode -ne 'Analysis') { throw }
        throw "Switching back to the analysis segment failed: $($_.Exception.Message) The VM may still be online; run .\scripts\net.ps1 -Mode Analysis."
    }
    if ($Mode -eq 'Analysis') { Remove-Item -Path (Join-Path $Config.LabDir 'case-net.txt') -ErrorAction SilentlyContinue }
}

function Assert-LabNetworkOwned {
    # Returns the VMX network mode, refusing one no case policy explains: the user's manual net.ps1 -Mode Setup
    # session (NAT without a case marker) or a hand-edited VMX. Lab scripts must not touch either.
    param([Parameter(Mandatory)][hashtable]$Config)
    $mode = Get-LabVmxNetworkMode -Config $Config
    if ($mode -eq 'Unknown' -or ($mode -eq 'Setup' -and -not (Get-LabNetCase -Config $Config))) {
        throw "VM network is '$mode', not on the analysis LAN segment, and no case policy put it there (a manual net.ps1 -Mode Setup session or a hand-edited VMX). Finish it with .\scripts\net.ps1 -Mode Analysis first."
    }
    $mode
}

function Assert-LabGuestUnused {
    # Retaking the clean snapshot after a case, a sample run or a case-driven NAT would bake that state in.
    param([Parameter(Mandatory)][hashtable]$Config)
    $used = @('current-case.txt', 'sample-ran.txt', 'case-net.txt') | Where-Object { Test-Path (Join-Path $Config.LabDir $_) }
    if ($used) {
        throw "The guest held a case or a run since the last revert ($($used -join ', ')). Run .\scripts\reset.ps1 first, then .\scripts\net.ps1 -Mode Setup to make the change on a clean guest."
    }
}

function Set-LabCaseNetwork {
    # Puts the running VM on the network the case's policy asks for and returns that policy.
    param([Parameter(Mandatory)][hashtable]$Config, [Parameter(Mandatory)][string]$Case)
    $network = Get-LabCaseNetwork -Config $Config -Case $Case
    $mode = Assert-LabNetworkOwned -Config $Config
    $netCase = Get-LabNetCase -Config $Config
    if ($network -eq 'Internet' -and $netCase -ne $Case -and (Test-Path (Join-Path $Config.LabDir 'sample-ran.txt'))) {
        # Whatever ran (possibly another case's sample, with persistence) must not come up online, or stay online
        # under this case's name. Only this case's own online run keeps the guest.
        throw "A sample ran in the guest since the last revert, so it is not taken online. Run .\scripts\reset.ps1 first, then open case '$Case' again."
    }
    if ($network -eq 'Internet') {
        if ($netCase -and $netCase -ne $Case) { Write-LabLog "NAT left by case '$netCase' now belongs to case '$Case'" }
        # Written before the VMX changes, so an interrupted switch is still undone by the next revert.
        New-Item -ItemType Directory -Force -Path $Config.LabDir | Out-Null
        Set-Content -Path (Join-Path $Config.LabDir 'case-net.txt') -Value $Case -Encoding ascii
        if ($mode -eq 'Analysis') { Switch-LabNetwork -Config $Config -Mode Setup }
        Write-LabLog "Case '$Case' policy is Internet: the guest is on NAT and reaches the Internet, the host and its LAN."
    } elseif ($mode -eq 'Setup') {
        Switch-LabNetwork -Config $Config -Mode Analysis
        Write-LabLog "Case '$Case' policy is Isolated: the guest is back on the analysis segment."
    }
    $network
}

function Test-LabCaseLive {
    # True when the case is open in the running VM, or its Internet policy put the running VM on NAT
    # (a detonate -KeepRunning / -UnderDebugger run does not mark the case open).
    param([Parameter(Mandatory)][hashtable]$Config, [Parameter(Mandatory)][string]$Case)
    $owns = (Get-LabCurrentCase -Config $Config) -eq $Case -or (Get-LabNetCase -Config $Config) -eq $Case
    $owns -and (Test-LabVmRunning -Config $Config)
}

function Sync-LabCaseNetwork {
    # case-net.ps1: a changed policy takes effect at once for a live case (Test-LabCaseLive).
    param([Parameter(Mandatory)][hashtable]$Config, [Parameter(Mandatory)][string]$Case)
    if (-not (Test-LabCaseLive -Config $Config -Case $Case)) {
        Write-LabLog "Case '$Case' is not open in the running VM; the policy applies at its next case-open, detonate or debug."
        return $false
    }
    Set-LabCaseNetwork -Config $Config -Case $Case | Out-Null
    $true
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

$script:CaseNetworks = @('Isolated', 'Internet')

function Get-LabCaseNetwork {
    # cases/<case>/case.psd1 is written only by the user (case-net.ps1); a missing file means isolated.
    # An Internet policy holds the hash of the sample.zip the user approved, so swapping the sample voids it.
    param([Parameter(Mandatory)][hashtable]$Config, [Parameter(Mandatory)][string]$Case)
    Assert-LabCaseName $Case
    $dir = Join-Path $Config.Root "cases/$Case"
    $path = Join-Path $dir 'case.psd1'
    if (-not (Test-Path $path)) { return 'Isolated' }
    $invalid = "Invalid ${path}: expected @{ Network = 'Isolated' } or @{ Network = 'Internet' }. Rewrite it with .\scripts\case-net.ps1 -Case $Case -Network <Isolated|Internet>."
    try { $policy = Import-PowerShellDataFile -Path $path -ErrorAction Stop } catch { throw "$invalid ($($_.Exception.Message))" }
    if ($policy -isnot [hashtable]) { throw $invalid }
    $network = $script:CaseNetworks | Where-Object { $_ -eq $policy['Network'] }
    if (-not $network -or @($policy.Keys | Where-Object { $_ -notin 'Network', 'SampleSha256' }).Count) { throw $invalid }
    if ($network -eq 'Internet') {
        $zip = Join-Path $dir 'sample.zip'
        $hash = if (Test-Path $zip) { (Get-FileHash -Path $zip -Algorithm SHA256).Hash } else { '' }
        if (-not $policy['SampleSha256'] -or $policy['SampleSha256'] -ne $hash) {
            throw "Case '$Case' sample.zip changed since the Internet policy was set (or the policy has no sample hash). Only the user re-approves it: .\scripts\case-net.ps1 -Case $Case -Network Internet."
        }
    }
    $network
}

function Set-LabCaseNetworkPolicy {
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][string]$Case,
        [Parameter(Mandatory)][ValidateSet('Isolated', 'Internet')][string]$Network
    )
    Assert-LabCaseName $Case
    $dir = Join-Path $Config.Root "cases/$Case"
    $zip = Join-Path $dir 'sample.zip'
    if (-not (Test-Path $zip)) { throw "Missing ${zip}: add the case's sample before setting its network policy." }
    $text = if ($Network -eq 'Internet') {
        "@{ Network = 'Internet'; SampleSha256 = '$((Get-FileHash -Path $zip -Algorithm SHA256).Hash)' }"
    } else { "@{ Network = 'Isolated' }" }
    Set-Content -Path (Join-Path $dir 'case.psd1') -Value $text -Encoding utf8
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

function Test-LabRelaysRunning {
    param([Parameter(Mandatory)][hashtable]$Config, [int]$Count)
    # One relay each for Ghidra and WinDbg, plus IDA once add-ida.ps1 has run.
    if (-not $PSBoundParameters.ContainsKey('Count')) { $Count = if (Test-LabIdaInstalled -Config $Config) { 3 } else { 2 } }
    try {
        $out = (Invoke-Vmrun -Config $Config -Command listProcessesInGuest -Guest -RetryCount 0).Output
    } catch { return $false }
    # listProcessesInGuest shows image names only; the relays are the only pythonw.exe in the clean guest.
    @($out -split "`r?`n" | Where-Object { $_ -match 'cmd=pythonw\.exe' }).Count -ge $Count
}

function Test-LabMcpBridge {
    # Starts the bridge as Claude Code would (from .mcp.json) and returns the server's tool count.
    param([Parameter(Mandatory)][hashtable]$Config, [Parameter(Mandatory)][string]$Server)
    $python = Join-Path $Config.Root 'tools\vmware-mcp\.venv\Scripts\python.exe'
    $r = Invoke-LabProcess -FilePath $python -ArgumentList @('-I', (Join-Path $Config.Root 'tests\mcp_client.py'),
        (Join-Path $Config.Root '.mcp.json'), $Server, 'count') -TimeoutSec 300
    if ($r.ExitCode -ne 0 -or $r.StdOut -notmatch 'tools=(\d+)') { throw "MCP bridge '$Server' failed: $($r.StdOut) $($r.StdErr)" }
    [int]$Matches[1]
}

function Get-LabIdaInputs {
    # The host files add-ida.ps1 copies into the guest; checked before the guest goes on NAT.
    param([Parameter(Mandatory)][hashtable]$Config)
    $dir = Join-Path $Config.Root 'tools/ida'
    $inputs = [ordered]@{
        Installer = Join-Path $dir 'ida-pro_94_x64win.exe'
        License   = Join-Path $dir 'idapro.hexlic'
        DataDir   = Join-Path $dir 'data'
        Data      = @()
    }
    foreach ($path in $inputs.Installer, $inputs.License) {
        if (-not (Test-Path $path)) { throw "Missing $path; put the IDA Pro installer and license in tools/ida/." }
    }
    if (Test-Path $inputs.DataDir) { $inputs.Data = @(Get-ChildItem -Path $inputs.DataDir -File -Recurse | ForEach-Object FullName) }
    $inputs
}

function Test-LabIdaInstalled {
    param([Parameter(Mandatory)][hashtable]$Config)
    $Config.ContainsKey('StatePath') -and 'AddIda' -in @(Get-LabState -Path $Config.StatePath)
}

function Set-LabIdaInstalled {
    # Records that add-ida.ps1 finished, so New-LabMcpJson adds revlab-ida.
    param([Parameter(Mandatory)][hashtable]$Config)
    $completed = @(Get-LabState -Path $Config.StatePath)
    if ('AddIda' -notin $completed) { Set-LabState -Path $Config.StatePath -Completed ($completed + 'AddIda') }
}

function Test-LabGuestDirectory {
    # vmrun exits non-zero when the directory is missing; any other failure (Tools down, ...) is not "missing".
    param([Parameter(Mandatory)][hashtable]$Config, [Parameter(Mandatory)][string]$GuestPath)
    try {
        (Invoke-Vmrun -Config $Config -Command directoryExistsInGuest -Arguments @($GuestPath) -Guest -RetryCount 0).Output -match 'The directory exists'
    } catch {
        if ($_.Exception.Message -match 'The directory does not exist') { return $false }
        throw
    }
}

function Get-LabCurrentCase {
    # Kept on the host: a sample in the guest must not be able to choose which case gets overwritten.
    param([Parameter(Mandatory)][hashtable]$Config)
    $path = Join-Path $Config.LabDir 'current-case.txt'
    if (-not (Test-Path $path)) { return $null }
    $case = (Get-Content -Path $path -Raw).Trim()
    Assert-LabCaseName $case
    $case
}

function Set-LabCurrentCase {
    param([Parameter(Mandatory)][hashtable]$Config, [Parameter(Mandatory)][string]$Case)
    Assert-LabCaseName $Case
    New-Item -ItemType Directory -Force -Path $Config.LabDir | Out-Null
    Set-Content -Path (Join-Path $Config.LabDir 'current-case.txt') -Value $Case -Encoding ascii
}

function Clear-LabRunState {
    param([Parameter(Mandatory)][hashtable]$Config)
    Remove-Item -Path (Join-Path $Config.LabDir 'current-case.txt'), (Join-Path $Config.LabDir 'sample-ran.txt'),
        (Join-Path $Config.LabDir 'debug-run.txt') -ErrorAction SilentlyContinue
}

function Set-LabDebugRun {
    # A 'detonate.ps1 -UnderDebugger' run waiting for collect.ps1; cleared by every revert.
    param([Parameter(Mandatory)][hashtable]$Config, [Parameter(Mandatory)][string]$Case,
        [Parameter(Mandatory)][string]$RunDir, [Parameter(Mandatory)][string]$Start)
    Assert-LabCaseName $Case
    New-Item -ItemType Directory -Force -Path $Config.LabDir | Out-Null
    # Plain lines, not JSON: ConvertFrom-Json on 7.2 turns the Start timestamp into a DateTime.
    Set-Content -Path (Join-Path $Config.LabDir 'debug-run.txt') -Value @($Case, $RunDir, $Start) -Encoding utf8
}

function Get-LabDebugRun {
    param([Parameter(Mandatory)][hashtable]$Config, [Parameter(Mandatory)][string]$Case)
    $path = Join-Path $Config.LabDir 'debug-run.txt'
    if (-not (Test-Path $path)) {
        throw "No pending debug run: none was started, or the VM was reverted since (its monitor data is gone)."
    }
    $owner, $runDir, $start = Get-Content -Path $path
    if ($owner -ne $Case) { throw "The pending debug run belongs to case '$owner', not '$Case'." }
    [pscustomobject]@{ Case = $owner; RunDir = $runDir; Start = $start }
}

function Save-LabCase {
    # Zips the guest's C:\lab\in\sample (sample + Ghidra and IDA databases) into cases/<case>/static/ghidra.zip.
    param([Parameter(Mandatory)][hashtable]$Config, [string]$Case)
    if (-not $Case) { $Case = Get-LabCurrentCase -Config $Config }
    if (-not $Case) { return $false }
    Assert-LabCaseName $Case
    if (-not (Test-LabGuestDirectory -Config $Config -GuestPath 'C:\lab\in\sample')) {
        Write-LabLog "Case '$Case' has no C:\lab\in\sample in the guest; nothing to save"
        return $false
    }
    $r = Invoke-LabGuestScript -Config $Config -Path (Join-Path $Config.Root 'templates/guest/pack.ps1') -Arguments @{
        Source = 'C:\lab\in\sample'; Destination = 'C:\lab\tmp\case.zip'
    }
    if ($r.ExitCode -ne 0) { throw "Saving case '$Case' failed: $($r.Output)" }
    $dest = Join-Path $Config.Root "cases/$Case/static"
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    $tmp = Join-Path $dest 'ghidra.zip.part'
    Copy-LabFromGuest -Config $Config -GuestPath 'C:\lab\tmp\case.zip' -HostPath $tmp
    $main = Join-Path $dest 'ghidra.zip'
    if (Test-Path (Join-Path $Config.LabDir 'sample-ran.txt')) {
        # A sample ran next to the databases: it may have encrypted, deleted or replaced them. Keep the
        # analyst's ghidra.zip and store the post-run state separately as evidence.
        $target = Join-Path $dest ('ghidra-postrun-{0:yyyyMMdd-HHmmss}.zip' -f (Get-Date))
    } else {
        if (Test-Path $main) { Copy-Item -Path $main -Destination (Join-Path $dest 'ghidra.prev.zip') -Force }
        $target = $main
    }
    Move-Item -Path $tmp -Destination $target -Force
    Write-LabLog "Saved case '$Case' to $target"
    $true
}

function Open-LabCase {
    param([Parameter(Mandatory)][hashtable]$Config, [Parameter(Mandatory)][string]$Case, [string]$Name)
    Assert-LabCaseName $Case
    $open = Get-LabCurrentCase -Config $Config
    if ($open -and $open -ne $Case) {
        throw "Case '$open' is open in the guest; run .\scripts\reset.ps1 (saves it) before opening '$Case'."
    }
    $caseDir = Join-Path $Config.Root "cases/$Case"
    $saved = Join-Path $caseDir 'static/ghidra.zip'
    if (Test-Path $saved) {
        $zip = $saved; $destination = 'C:\lab\in'            # holds sample\... from pack.ps1
    } else {
        $zip = Join-Path $caseDir 'sample.zip'; $destination = 'C:\lab\in\sample'
        if (-not (Test-Path $zip)) { throw "Missing $zip (zip the sample with password 'infected')" }
    }
    Copy-LabToGuest -Config $Config -HostPath $zip -GuestPath 'C:\lab\in\case.zip'
    $r = Invoke-LabGuestScript -Config $Config -Path (Join-Path $Config.Root 'templates/guest/case-unpack.ps1') -Arguments @{
        Zip = 'C:\lab\in\case.zip'; Destination = $destination; Case = $Case; Name = "$Name"
    }
    if ($r.ExitCode -ne 0) { throw "Opening case '$Case' failed: $($r.Output)" }
    Set-LabCurrentCase -Config $Config -Case $Case
    ($r.Output -split "`r?`n")[-1].Trim()
}

$script:DebugPipe = 'revlab-dbg'
$script:DebugConnect = "npipe:server=.,pipe=$script:DebugPipe"

function Start-LabSample {
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][string]$SamplePath,
        [Parameter(Mandatory)][string]$RunDir,
        [string]$Export, [string]$SampleArgs, [string]$Debugger
    )
    $run = [ordered]@{ Path = $SamplePath; Export = $Export; Arguments = $SampleArgs; Debugger = $Debugger; Pipe = $script:DebugPipe }
    $runFile = Join-Path $RunDir 'run.json'
    # BOM so Windows PowerShell 5.1 reads non-ASCII sample names and arguments as UTF-8.
    $run | ConvertTo-Json | Set-Content -Path $runFile -Encoding utf8BOM
    Copy-LabToGuest -Config $Config -HostPath $runFile -GuestPath 'C:\lab\in\run.json'
    New-Item -ItemType Directory -Force -Path $Config.LabDir | Out-Null
    Set-Content -Path (Join-Path $Config.LabDir 'sample-ran.txt') -Value (Get-Date -Format o)
    $launch = Invoke-LabGuestScript -Config $Config -Path (Join-Path $Config.Root 'templates/guest/run-sample.ps1') -Arguments @{ RunFile = 'C:\lab\in\run.json' } -Interactive
    if ($launch.ExitCode -ne 0) { throw "Sample did not start: $($launch.Output)" }
}

function Invoke-LabCollect {
    param([Parameter(Mandatory)][hashtable]$Config, [Parameter(Mandatory)][string]$RunDir, [Parameter(Mandatory)][string]$Start)
    try {
        Invoke-Vmrun -Config $Config -Command captureScreen -Arguments @((Join-Path $RunDir 'screenshot.png')) -Guest | Out-Null
    } catch {
        Write-LabLog "Screenshot failed (continuing): $($_.Exception.Message)"
    }
    $collect = Invoke-LabGuestScript -Config $Config -Path (Join-Path $Config.Root 'templates/guest/collect.ps1') -Arguments @{ Start = $Start } -Interactive -TimeoutSec 1200
    Write-LabLog $collect.Output -Quiet
    if ($collect.ExitCode -ne 0) { throw "collect.ps1 failed: $($collect.Output)" }
    Copy-LabFromGuest -Config $Config -GuestPath 'C:\lab\artefacts.zip' -HostPath (Join-Path $RunDir 'artefacts.zip')
    $textZip = Join-Path $RunDir 'text.zip'
    Copy-LabFromGuest -Config $Config -GuestPath 'C:\lab\text.zip' -HostPath $textZip
    Expand-Archive -Path $textZip -DestinationPath (Join-Path $RunDir 'text')
    Remove-Item -Path $textZip
    Write-LabLog "Artefacts: $RunDir"
}

function Get-LabGuestTools {
    param([Parameter(Mandatory)][hashtable]$Config)
    $local = Join-Path ([System.IO.Path]::GetTempPath()) "tools-$([guid]::NewGuid().ToString('N')).json"
    try {
        Copy-LabFromGuest -Config $Config -GuestPath 'C:\lab\tools.json' -HostPath $local
        Get-Content $local -Raw | ConvertFrom-Json
    } finally { Remove-Item $local -ErrorAction SilentlyContinue }
}
