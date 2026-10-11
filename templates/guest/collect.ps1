# Stops monitors, exports logs, and packs artefacts.zip (password) and text.zip (text only, no password).
param([string]$Start)
$ErrorActionPreference = 'Stop'
$tools = Get-Content -Path 'C:\lab\tools.json' -Raw | ConvertFrom-Json
$out = 'C:\lab\out'

New-Item -ItemType File -Force -Path "$out\fakenet\stop.flag" | Out-Null
$deadline = (Get-Date).AddSeconds(30)
while ((Get-Process -Name fakenet -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 1 }
Get-Process -Name fakenet -ErrorAction SilentlyContinue | Stop-Process -Force

Start-Process -FilePath $tools.Procmon -ArgumentList '/Terminate' -Wait
$deadline = (Get-Date).AddSeconds(60)
while ((Get-Process -Name Procmon64 -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 1 }
Start-Process -FilePath $tools.Procmon -ArgumentList '/AcceptEula', '/Quiet', '/OpenLog', "$out\procmon.pml", '/SaveAs', "$out\procmon.csv" -Wait

$query = "*[System[TimeCreated[@SystemTime>='$Start']]]"
wevtutil epl Microsoft-Windows-Sysmon/Operational "$out\sysmon.evtx" "/q:$query" /ow:true
Get-WinEvent -LogName 'Microsoft-Windows-Sysmon/Operational' -FilterXPath $query -ErrorAction SilentlyContinue |
    Select-Object TimeCreated, Id, Message | ConvertTo-Json -Depth 3 | Set-Content -Path "$out\sysmon.json" -Encoding UTF8

Get-CimInstance Win32_Process | Select-Object ProcessId, ParentProcessId, Name, CommandLine |
    Format-Table -AutoSize | Out-String -Width 4096 | Set-Content -Path "$out\processes.txt"

$fakenetDir = Split-Path -Parent $tools.Fakenet
$pcap = Get-ChildItem -Path $fakenetDir, "$out\fakenet" -Filter '*.pcap' -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime | Select-Object -Last 1
if ($pcap -and $pcap.DirectoryName -ne "$out\fakenet") { Move-Item -Path $pcap.FullName -Destination "$out\fakenet\" -Force }

Remove-Item -Path 'C:\lab\artefacts.zip', 'C:\lab\text.zip' -ErrorAction SilentlyContinue
& $tools.SevenZip a -tzip '-pinfected' 'C:\lab\artefacts.zip' "$out\*" | Out-Null
if ($LASTEXITCODE -ne 0) { throw "7z artefacts.zip failed (exit $LASTEXITCODE)" }
Push-Location $out
try {
    & $tools.SevenZip a -tzip 'C:\lab\text.zip' -r '*.csv' '*.log' '*.json' '*.txt' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "7z text.zip failed (exit $LASTEXITCODE)" }
} finally {
    Pop-Location
}
Get-ChildItem -Path $out -Recurse -File | ForEach-Object { Write-Output "$($_.Length)`t$($_.FullName)" }
exit 0
