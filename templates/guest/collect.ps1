# Stops monitors, exports logs, and packs artefacts.zip (password) and text.zip (text only, no password).
param([string]$Start)
$ErrorActionPreference = 'Stop'
$tools = Get-Content -Path 'C:\lab\tools.json' -Raw | ConvertFrom-Json
$out = 'C:\lab\out'

# Windows PowerShell turns stderr of a redirected native command into an error under 'Stop'; judge by exit code.
function Invoke-Native([string]$File, [string[]]$Arguments) {
    $ErrorActionPreference = 'Continue'
    $output = & $File @Arguments 2>&1 | Out-String
    [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output }
}

New-Item -ItemType File -Force -Path "$out\fakenet\stop.flag" | Out-Null
$deadline = (Get-Date).AddSeconds(30)
while ((Get-Process -Name fakenet -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 1 }
Get-Process -Name fakenet -ErrorAction SilentlyContinue | Stop-Process -Force

# Internet case: start-monitors.ps1 ran pktmon instead of FakeNet-NG.
if (Test-Path "$out\net") {
    $r = Invoke-Native 'pktmon.exe' @('stop')
    if ($r.ExitCode -ne 0) { Write-Output "WARN pktmon stop exit $($r.ExitCode): $($r.Output)" }
    $r = Invoke-Native 'pktmon.exe' @('etl2pcap', "$out\net\capture.etl", '--out', "$out\net\capture.pcapng")
    if ($r.ExitCode -ne 0) {
        Write-Output "WARN pktmon etl2pcap exit $($r.ExitCode): $($r.Output)"
    } else {
        $r = Invoke-Native $tools.Tshark @('-r', "$out\net\capture.pcapng")
        Set-Content -Path "$out\net\capture.txt" -Value $r.Output -Encoding UTF8
    }
}

Start-Process -FilePath $tools.Procmon -ArgumentList '/Terminate' -Wait
$deadline = (Get-Date).AddSeconds(60)
while ((Get-Process -Name Procmon64 -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 1 }
Start-Process -FilePath $tools.Procmon -ArgumentList '/AcceptEula', '/Quiet', '/OpenLog', "$out\procmon.pml", '/SaveAs', "$out\procmon.csv" -Wait

$query = "*[System[TimeCreated[@SystemTime>='$Start']]]"
$r = Invoke-Native 'wevtutil.exe' @('epl', 'Microsoft-Windows-Sysmon/Operational', "$out\sysmon.evtx", "/q:$query", '/ow:true')
if ($r.ExitCode -ne 0) { Write-Output "WARN wevtutil exit $($r.ExitCode): $($r.Output)" }
Get-WinEvent -LogName 'Microsoft-Windows-Sysmon/Operational' -FilterXPath $query -ErrorAction SilentlyContinue |
    Select-Object TimeCreated, Id, Message | ConvertTo-Json -Depth 3 | Set-Content -Path "$out\sysmon.json" -Encoding UTF8

Get-CimInstance Win32_Process | Select-Object ProcessId, ParentProcessId, Name, CommandLine |
    Format-Table -AutoSize | Out-String -Width 4096 | Set-Content -Path "$out\processes.txt"

$fakenetDir = Split-Path -Parent $tools.Fakenet
$pcap = Get-ChildItem -Path $fakenetDir, "$out\fakenet" -Filter '*.pcap' -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime | Select-Object -Last 1
if ($pcap -and $pcap.DirectoryName -ne "$out\fakenet") { Move-Item -Path $pcap.FullName -Destination "$out\fakenet\" -Force }

Remove-Item -Path 'C:\lab\artefacts.zip', 'C:\lab\text.zip' -ErrorAction SilentlyContinue
# 7-Zip exit 1 is a warning (for example a file still locked); the archive is still written.
$r = Invoke-Native $tools.SevenZip @('a', '-tzip', '-pinfected', 'C:\lab\artefacts.zip', "$out\*")
if ($r.ExitCode -gt 1) { throw "7z artefacts.zip failed (exit $($r.ExitCode)):`n$($r.Output)" }
# Only the monitor outputs go out unencrypted; the sample can write anything else under C:\lab\out.
$textFiles = @('procmon.csv', 'fakenet\fakenet.log', 'net\capture.txt', 'sysmon.json', 'processes.txt') |
    Where-Object { Test-Path (Join-Path $out $_) }
Push-Location $out
try {
    $r = Invoke-Native $tools.SevenZip (@('a', '-tzip', 'C:\lab\text.zip') + $textFiles)
    if ($r.ExitCode -gt 1) { throw "7z text.zip failed (exit $($r.ExitCode)):`n$($r.Output)" }
} finally {
    Pop-Location
}
Get-ChildItem -Path $out -Recurse -File | ForEach-Object { Write-Output "$($_.Length)`t$($_.FullName)" }
exit 0
