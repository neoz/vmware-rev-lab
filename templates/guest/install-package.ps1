# Installs FLARE-VM or Chocolatey packages. Runs only while the guest is on NAT (net.ps1 -Mode Setup).
param([string]$Packages)
$ErrorActionPreference = 'Stop'
$sources = 'https://www.myget.org/F/vm-packages/api/v2;https://community.chocolatey.org/api/v2/'
foreach ($package in ($Packages -split ',' | Where-Object { $_ })) {
    & choco install $package -y --no-progress --source $sources
    if ($LASTEXITCODE -ne 0) { throw "choco install $package failed (exit $LASTEXITCODE)" }
}
exit 0
