# Starts Procmon plus FakeNet-NG (isolated case) or a pktmon capture (Internet case: FakeNet-NG would divert
# the real traffic), waits until they run, prints the UTC start time for Sysmon filtering.
param([string]$Network = 'Isolated')
$ErrorActionPreference = 'Stop'
$tools = Get-Content -Path 'C:\lab\tools.json' -Raw | ConvertFrom-Json
$out = 'C:\lab\out'

# Windows PowerShell turns stderr of a redirected native command into an error under 'Stop'; judge by exit code.
function Invoke-Native([string]$File, [string[]]$Arguments) {
    $ErrorActionPreference = 'Continue'
    $output = & $File @Arguments 2>&1 | Out-String
    [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output }
}

$internet = $Network -eq 'Internet'
if ($internet) {
    New-Item -ItemType Directory -Force -Path "$out\net" | Out-Null
} else {
    New-Item -ItemType Directory -Force -Path "$out\fakenet" | Out-Null
    Remove-Item -Path "$out\fakenet\stop.flag" -ErrorAction SilentlyContinue
}
$start = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')

Start-Process -FilePath $tools.Procmon -ArgumentList '/AcceptEula', '/Quiet', '/Minimized', '/BackingFile', "$out\procmon.pml"
if ($internet) {
    # pktmon ships with Windows 10 2004+, so the capture needs no extra driver.
    Invoke-Native 'pktmon.exe' @('stop') | Out-Null
    $r = Invoke-Native 'pktmon.exe' @('start', '--capture', '--comp', 'nics', '--pkt-size', '0', '--file-name', "$out\net\capture.etl")
    if ($r.ExitCode -ne 0) { Write-Output "pktmon start failed (exit $($r.ExitCode)): $($r.Output)"; exit 1 }
} else {
    Start-Process -FilePath $tools.Fakenet -WorkingDirectory "$out\fakenet" -WindowStyle Minimized `
        -ArgumentList '-l', "$out\fakenet\fakenet.log", '-f', "$out\fakenet\stop.flag"
}

$deadline = (Get-Date).AddSeconds(60)
while ((Get-Date) -lt $deadline) {
    $ready = (Get-Process -Name Procmon64 -ErrorAction SilentlyContinue) -and (Test-Path "$out\procmon.pml")
    if (-not $internet) {
        $ready = $ready -and (Get-Process -Name fakenet -ErrorAction SilentlyContinue) -and (Test-Path "$out\fakenet\fakenet.log")
    }
    if ($ready) { Write-Output $start; exit 0 }
    Start-Sleep -Seconds 1
}
Write-Output 'Monitors did not start within 60 s'
exit 1
