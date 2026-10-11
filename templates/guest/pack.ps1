# Zips a guest file or directory with password 'infected' so host antivirus leaves it alone.
param([string]$Source, [string]$Destination)
$ErrorActionPreference = 'Stop'
if (-not (Test-Path $Source)) { throw "Not found: $Source" }
$tools = Get-Content -Path 'C:\lab\tools.json' -Raw | ConvertFrom-Json
if (Test-Path $Destination) { Remove-Item $Destination -Force }
& $tools.SevenZip a -tzip '-pinfected' $Destination $Source | Out-Null
if ($LASTEXITCODE -ne 0) { throw "7z failed (exit $LASTEXITCODE)" }
exit 0
