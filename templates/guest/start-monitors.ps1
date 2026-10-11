# Starts Procmon and FakeNet-NG, waits until both run, prints the UTC start time for Sysmon filtering.
$ErrorActionPreference = 'Stop'
$tools = Get-Content -Path 'C:\lab\tools.json' -Raw | ConvertFrom-Json
$out = 'C:\lab\out'
New-Item -ItemType Directory -Force -Path "$out\fakenet" | Out-Null
Remove-Item -Path "$out\fakenet\stop.flag" -ErrorAction SilentlyContinue
$start = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')

Start-Process -FilePath $tools.Procmon -ArgumentList '/AcceptEula', '/Quiet', '/Minimized', '/BackingFile', "$out\procmon.pml"
Start-Process -FilePath $tools.Fakenet -WorkingDirectory "$out\fakenet" -WindowStyle Minimized `
    -ArgumentList '-l', "$out\fakenet\fakenet.log", '-f', "$out\fakenet\stop.flag"

$deadline = (Get-Date).AddSeconds(60)
while ((Get-Date) -lt $deadline) {
    $ready = (Get-Process -Name Procmon64 -ErrorAction SilentlyContinue) -and
             (Get-Process -Name fakenet -ErrorAction SilentlyContinue) -and
             (Test-Path "$out\procmon.pml") -and (Test-Path "$out\fakenet\fakenet.log")
    if ($ready) { Write-Output $start; exit 0 }
    Start-Sleep -Seconds 1
}
Write-Output 'Monitors did not start within 60 s'
exit 1
