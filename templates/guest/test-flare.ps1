# Reports FLARE-VM install state. 0 = done, 1 = in progress, 2 = not started,
# 4 = stalled (started, installer.vm not installed, and no installer process running).
param([string]$ChocoLib = 'C:\ProgramData\chocolatey\lib', [string]$VmDir = 'C:\ProgramData\_VM')
$lib = Join-Path $ChocoLib 'installer.vm'
$installed = Test-Path (Join-Path $lib 'installer.vm.nupkg')
$pending = Test-Path (Join-Path $lib '.chocolateyPending')
$processes = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='choco.exe'")
$boxstarter = @($processes | Where-Object { $_.CommandLine -match 'Boxstarter' }).Count -gt 0
$installerRunning = @($processes | Where-Object { $_.Name -eq 'choco.exe' -or $_.CommandLine -match 'install\.ps1' }).Count -gt 0
Write-Output "installed=$installed pending=$pending boxstarterRunning=$boxstarter installerRunning=$installerRunning"
Get-ChildItem -Path $VmDir -Filter '*fail*' -ErrorAction SilentlyContinue | ForEach-Object {
    Write-Output "--- $($_.Name)"
    Get-Content -Path $_.FullName
}
# Boxstarter keeps its console open ('Type ENTER to exit') after installer.vm finishes, so it is not a completion signal.
if ($installed -and -not $pending) { exit 0 }
if ((Test-Path $lib) -or $installerRunning) { exit 1 }
# Boxstarter is installed by FLARE's install.ps1 before installer.vm. With no installer process left it has died,
# or its console waits for ENTER after a failure; the host relaunches only after several stalled polls in a row.
if (Test-Path (Join-Path $ChocoLib 'Boxstarter')) { exit 4 }
exit 2
