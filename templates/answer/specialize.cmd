@echo off
rem Applied in the specialize pass, before the first logon.
set DEF=HKLM\SOFTWARE\Policies\Microsoft\Windows Defender
reg add "%DEF%" /v DisableAntiSpyware /t REG_DWORD /d 1 /f
reg add "%DEF%\Real-Time Protection" /v DisableRealtimeMonitoring /t REG_DWORD /d 1 /f
reg add "%DEF%\Real-Time Protection" /v DisableBehaviorMonitoring /t REG_DWORD /d 1 /f
reg add "%DEF%\Real-Time Protection" /v DisableOnAccessProtection /t REG_DWORD /d 1 /f
reg add "%DEF%\Real-Time Protection" /v DisableScanOnRealtimeEnable /t REG_DWORD /d 1 /f
reg add "%DEF%\Spynet" /v SpynetReporting /t REG_DWORD /d 0 /f
reg add "%DEF%\Spynet" /v SubmitSamplesConsent /t REG_DWORD /d 2 /f
reg add "HKLM\SOFTWARE\Microsoft\Windows Defender\Features" /v TamperProtection /t REG_DWORD /d 4 /f
for %%s in (WinDefend WdNisSvc WdNisDrv WdFilter WdBoot Sense) do reg add "HKLM\SYSTEM\CurrentControlSet\Services\%%s" /v Start /t REG_DWORD /d 4 /f
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" /v EnableLUA /t REG_DWORD /d 0 /f
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" /v NoAutoUpdate /t REG_DWORD /d 1 /f
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\System" /v EnableSmartScreen /t REG_DWORD /d 0 /f
exit /b 0
