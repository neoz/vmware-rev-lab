# Installs IDA Pro from C:\lab\tmp\ida, sets up ida-mcp on idalib and registers the RevlabMcpIda relay logon task.
param([string]$IdaMcpVersion, [string]$IdaPort, [string]$User)
$ErrorActionPreference = 'Stop'
# Windows PowerShell turns stderr of a redirected native command into an error under 'Stop'; judge by exit code.
function Invoke-Native([string]$File, [string[]]$Arguments) {
    $ErrorActionPreference = 'Continue'
    $output = & $File @Arguments 2>&1 | Out-String
    [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output }
}
function Assert-Native($r, [string]$What) { if ($r.ExitCode -ne 0) { throw "$What failed (exit $($r.ExitCode)):`n$($r.Output)" } }

$mcp = 'C:\lab\mcp'
$staging = 'C:\lab\tmp\ida'
$idaDir = 'C:\Tools\IDA'
$toolsPath = 'C:\lab\tools.json'

# Piping the output (Invoke-Native) makes PowerShell wait for the installer to exit.
if (-not (Test-Path "$idaDir\ida.exe")) {
    Assert-Native (Invoke-Native "$staging\ida-pro_94_x64win.exe" @('--mode', 'unattended', '--prefix', $idaDir, '--install_python', '0')) 'IDA installer'
    if (-not (Test-Path "$idaDir\ida.exe")) { throw "IDA installer exited but $idaDir\ida.exe is missing" }
} else {
    Write-Output "IDA is already installed in $idaDir; installer skipped (uninstall it in the guest to install a newer one)."
}
Copy-Item -Path "$staging\idapro.hexlic" -Destination $idaDir -Force
# The host's tools/ida/data goes next to ida.exe; add-ida.ps1 has already refused executables in it.
if (Test-Path "$staging\data.zip") { Expand-Archive -Path "$staging\data.zip" -DestinationPath $idaDir -Force }
Remove-Item -Path $staging -Recurse -Force

$python = "$mcp\venv-ida\Scripts\python.exe"
if (-not (Test-Path $python)) { Assert-Native (Invoke-Native 'py' @('-3.13', '-m', 'venv', "$mcp\venv-ida")) 'venv venv-ida' }
# IDA ships the idalib bindings as a wheel (idapro-<ver>-py3-none-any.whl) under idalib\python.
$idaproWheel = Get-ChildItem -Path "$idaDir\idalib\python" -Filter 'idapro-*.whl' | Select-Object -First 1
if (-not $idaproWheel) { throw "No idapro wheel in $idaDir\idalib\python" }
Assert-Native (Invoke-Native $python @('-m', 'pip', 'install', '--disable-pip-version-check', '--quiet', "ida-mcp==$IdaMcpVersion", 'ida-hcli==0.26.3', $idaproWheel.FullName)) 'pip ida-mcp ida-hcli idapro'
$env:IDADIR = $idaDir
Assert-Native (Invoke-Native "$mcp\venv-ida\Scripts\hcli.exe" @('ida', 'accept-eula')) 'hcli ida accept-eula'
Assert-Native (Invoke-Native $python @("$idaDir\idalib\python\py-activate-idalib.py", '-d', $idaDir)) 'activate idalib'
# Loading idalib checks the license, so a bad license fails here instead of in Claude's first open_database.
Assert-Native (Invoke-Native $python @('-c', 'import idapro')) 'import idapro'

$tools = Get-Content $toolsPath -Raw | ConvertFrom-Json
$tools | Add-Member -NotePropertyName Ida -NotePropertyValue "$idaDir\ida.exe" -Force
$tools | Add-Member -NotePropertyName IdaDir -NotePropertyValue $idaDir -Force
$tools | ConvertTo-Json | Set-Content $toolsPath -Encoding UTF8

$argLine = "`"$mcp\relay.py`" --port $IdaPort --log `"$mcp\relay-$IdaPort.log`" --child-log `"$mcp\child-$IdaPort.log`" " +
           "--env IDADIR=`"$idaDir`" -- `"$mcp\venv-ida\Scripts\ida-mcp.exe`" stdio --agent=revlab"
$action = New-ScheduledTaskAction -Execute $tools.Pythonw -Argument $argLine -WorkingDirectory $mcp
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $User
$principal = New-ScheduledTaskPrincipal -UserId $User -LogonType Interactive -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName 'RevlabMcpIda' -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
Start-ScheduledTask -TaskName 'RevlabMcpIda'
Start-Sleep -Seconds 5
Get-CimInstance Win32_Process -Filter "Name='pythonw.exe'" | ForEach-Object { Write-Output "$($_.ProcessId) $($_.CommandLine)" }
exit 0
