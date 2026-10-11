# Installs re-mcp-ghidra and mcp-windbg into their own venvs and registers the relay logon tasks.
param([string]$ReMcpGhidraVersion, [string]$McpWindbgVersion, [string]$GhidraPort, [string]$WindbgPort, [string]$User)
$ErrorActionPreference = 'Stop'
# Windows PowerShell turns stderr of a redirected native command into an error under 'Stop'; judge by exit code.
function Invoke-Native([string]$File, [string[]]$Arguments) {
    $ErrorActionPreference = 'Continue'
    $output = & $File @Arguments 2>&1 | Out-String
    [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output }
}
function Assert-Native($r, [string]$What) { if ($r.ExitCode -ne 0) { throw "$What failed (exit $($r.ExitCode)):`n$($r.Output)" } }

$mcp = 'C:\lab\mcp'
$toolsPath = 'C:\lab\tools.json'
$tools = Get-Content $toolsPath -Raw | ConvertFrom-Json
# Executables inside the WinDbg MSIX package cannot be started directly (Access is denied); run a copy.
$cdbDir = 'C:\Tools\cdb'
if (-not (Test-Path "$cdbDir\cdb.exe")) {
    New-Item -ItemType Directory -Force -Path $cdbDir | Out-Null
    Copy-Item -Path (Join-Path (Split-Path $tools.Cdb) '*') -Destination $cdbDir -Recurse -Force
}
$tools.Cdb = "$cdbDir\cdb.exe"

$base = (& py -3.13 -c "import sys; print(sys.executable)").Trim()
$pythonw = Join-Path (Split-Path $base) 'pythonw.exe'

foreach ($venv in 'venv-ghidra', 'venv-windbg') {
    if (-not (Test-Path "$mcp\$venv\Scripts\python.exe")) { Assert-Native (Invoke-Native 'py' @('-3.13', '-m', 'venv', "$mcp\$venv")) "venv $venv" }
}
Assert-Native (Invoke-Native "$mcp\venv-ghidra\Scripts\python.exe" @('-m', 'pip', 'install', '--disable-pip-version-check', '--quiet', "re-mcp-ghidra==$ReMcpGhidraVersion")) 'pip re-mcp-ghidra'
Assert-Native (Invoke-Native "$mcp\venv-windbg\Scripts\python.exe" @('-m', 'pip', 'install', '--disable-pip-version-check', '--quiet', "mcp-windbg==$McpWindbgVersion")) 'pip mcp-windbg'

# analyzeHeadless.bat lives in <ghidra>\support; the FLARE OpenJDK provides java.exe.
$ghidraDir = Split-Path (Split-Path $tools.AnalyzeHeadless)
$java = Get-ChildItem 'C:\Program Files', 'C:\ProgramData\chocolatey\lib' -Recurse -Filter java.exe -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -match 'jdk|openjdk' } | Select-Object -First 1
if (-not $java) { throw 'java.exe (OpenJDK) not found' }
$javaHome = Split-Path (Split-Path $java.FullName)
$tools | Add-Member -NotePropertyName GhidraInstallDir -NotePropertyValue $ghidraDir -Force
$tools | Add-Member -NotePropertyName JavaHome -NotePropertyValue $javaHome -Force
$tools | Add-Member -NotePropertyName Pythonw -NotePropertyValue $pythonw -Force
$tools | ConvertTo-Json | Set-Content $toolsPath -Encoding UTF8

$relays = @(
    @{ Task = 'RevlabMcpGhidra'; Port = $GhidraPort
       Args = "--env GHIDRA_INSTALL_DIR=`"$ghidraDir`" --env JAVA_HOME=`"$javaHome`" --env GHIDRA_MCP_DISABLE_EXECUTE=1 -- `"$mcp\venv-ghidra\Scripts\re-mcp-ghidra.exe`"" },
    @{ Task = 'RevlabMcpWindbg'; Port = $WindbgPort
       Args = "-- `"$mcp\venv-windbg\Scripts\python.exe`" -m mcp_windbg --cdb-path `"$($tools.Cdb)`"" }
)
foreach ($r in $relays) {
    $argLine = "`"$mcp\relay.py`" --port $($r.Port) --log `"$mcp\relay-$($r.Port).log`" --child-log `"$mcp\child-$($r.Port).log`" $($r.Args)"
    $action = New-ScheduledTaskAction -Execute $pythonw -Argument $argLine -WorkingDirectory $mcp
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $User
    $principal = New-ScheduledTaskPrincipal -UserId $User -LogonType Interactive -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskName $r.Task -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
    Start-ScheduledTask -TaskName $r.Task
}
Start-Sleep -Seconds 5
Get-CimInstance Win32_Process -Filter "Name='pythonw.exe'" | ForEach-Object { Write-Output "$($_.ProcessId) $($_.CommandLine)" }
exit 0
