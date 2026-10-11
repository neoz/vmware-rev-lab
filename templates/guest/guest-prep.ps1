# Applies analysis-friendly settings, then verifies Defender is off. Exit 3 means it is still on.
$ErrorActionPreference = 'Stop'

function Set-Reg([string]$Path, [string]$Name, [int]$Value) {
    if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
    New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType DWord -Force | Out-Null
}

$def = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender'
Set-Reg $def 'DisableAntiSpyware' 1
Set-Reg "$def\Real-Time Protection" 'DisableRealtimeMonitoring' 1
Set-Reg "$def\Real-Time Protection" 'DisableBehaviorMonitoring' 1
Set-Reg "$def\Real-Time Protection" 'DisableOnAccessProtection' 1
Set-Reg "$def\Real-Time Protection" 'DisableScanOnRealtimeEnable' 1
Set-Reg "$def\Spynet" 'SpynetReporting' 0
Set-Reg "$def\Spynet" 'SubmitSamplesConsent' 2
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'EnableSmartScreen' 0
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' 'NoAutoUpdate' 1
Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' 'EnableLUA' 0
Set-Service -Name wuauserv -StartupType Disabled
Stop-Service -Name wuauserv -Force -ErrorAction SilentlyContinue
# Throws ExecutionPolicyOverride when the current process runs with -ExecutionPolicy Bypass, yet the machine policy is set.
try { Set-ExecutionPolicy -ExecutionPolicy Unrestricted -Scope LocalMachine -Force -ErrorAction Stop } catch { }
try { Set-MpPreference -DisableRealtimeMonitoring $true -ErrorAction Stop } catch { }

$service = Get-Service -Name WinDefend -ErrorAction SilentlyContinue
$tamper = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows Defender\Features' -Name TamperProtection -ErrorAction SilentlyContinue).TamperProtection
$realtime = $null
try { $realtime = (Get-MpComputerStatus -ErrorAction Stop).RealTimeProtectionEnabled } catch { }
Write-Output "WinDefend=$($service.Status) TamperProtection=$tamper RealTimeProtection=$realtime"
if ($tamper -eq 5 -or $realtime -eq $true) { exit 3 }
exit 0
