# Runs once at the first autologon: installs VMware Tools and desktop tweaks.
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force -Path 'C:\lab' | Out-Null
Start-Transcript -Path 'C:\lab\firstlogon.log' -Append

# The Windows ISO also has setup.exe at its root, so find the Tools CD by its volume label.
$toolsDrive = Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=5' |
    Where-Object { $_.VolumeName -like 'VMware Tools*' } |
    Select-Object -First 1
if (-not $toolsDrive) { throw 'VMware Tools CD (volume label "VMware Tools") not found' }
# Tools 13 ships a single setup.exe; older media had setup64.exe for 64-bit guests.
$installer = Join-Path "$($toolsDrive.DeviceID)\" 'setup64.exe'
if (-not (Test-Path $installer)) { $installer = Join-Path "$($toolsDrive.DeviceID)\" 'setup.exe' }
Start-Process -FilePath $installer -ArgumentList '/S /v "/qn REBOOT=R"' -Wait

powercfg /change standby-timeout-ac 0
powercfg /change monitor-timeout-ac 0
powercfg /change hibernate-timeout-ac 0
$advanced = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
Set-ItemProperty -Path $advanced -Name HideFileExt -Value 0
Set-ItemProperty -Path $advanced -Name Hidden -Value 1

Set-Content -Path 'C:\lab\firstlogon.done' -Value (Get-Date -Format o)
Stop-Transcript
exit 0
