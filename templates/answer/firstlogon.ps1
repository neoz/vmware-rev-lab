# Runs once at the first autologon: installs VMware Tools and desktop tweaks.
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force -Path 'C:\lab' | Out-Null
Start-Transcript -Path 'C:\lab\firstlogon.log' -Append

$toolsDrive = Get-PSDrive -PSProvider FileSystem |
    Where-Object { Test-Path (Join-Path $_.Root 'setup64.exe') } |
    Select-Object -First 1
if (-not $toolsDrive) { throw 'VMware Tools media (setup64.exe) not found on any drive' }
Start-Process -FilePath (Join-Path $toolsDrive.Root 'setup64.exe') -ArgumentList '/S /v "/qn REBOOT=R"' -Wait

powercfg /change standby-timeout-ac 0
powercfg /change monitor-timeout-ac 0
powercfg /change hibernate-timeout-ac 0
$advanced = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
Set-ItemProperty -Path $advanced -Name HideFileExt -Value 0
Set-ItemProperty -Path $advanced -Name Hidden -Value 1

Set-Content -Path 'C:\lab\firstlogon.done' -Value (Get-Date -Format o)
Stop-Transcript
exit 0
