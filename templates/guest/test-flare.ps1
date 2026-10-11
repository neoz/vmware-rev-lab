# Reports FLARE-VM install state. 0 = done, 1 = in progress, 2 = not started.
$lib = 'C:\ProgramData\chocolatey\lib\installer.vm'
$installed = Test-Path (Join-Path $lib 'installer.vm.nupkg')
$pending = Test-Path (Join-Path $lib '.chocolateyPending')
$boxstarter = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -match 'Boxstarter' }).Count -gt 0
Write-Output "installed=$installed pending=$pending boxstarterRunning=$boxstarter"
Get-ChildItem -Path 'C:\ProgramData\_VM' -Filter '*fail*' -ErrorAction SilentlyContinue | ForEach-Object {
    Write-Output "--- $($_.Name)"
    Get-Content -Path $_.FullName
}
# Boxstarter keeps its console open ('Type ENTER to exit') after installer.vm finishes, so it is not a completion signal.
if ($installed -and -not $pending) { exit 0 }
# Boxstarter is installed by FLARE's install.ps1 before installer.vm, so its presence means the install has started.
if ((Test-Path $lib) -or $boxstarter -or (Test-Path 'C:\ProgramData\chocolatey\lib\Boxstarter')) { exit 1 }
exit 2
