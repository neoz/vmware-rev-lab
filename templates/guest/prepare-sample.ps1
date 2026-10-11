# Extracts sample.zip inside the guest and prints the full path of the chosen file.
param([string]$Zip, [string]$Name)
$ErrorActionPreference = 'Stop'
$tools = Get-Content -Path 'C:\lab\tools.json' -Raw | ConvertFrom-Json
$dest = 'C:\lab\in\sample'
& $tools.SevenZip x -y '-pinfected' "-o$dest" $Zip | Out-Null
if ($LASTEXITCODE -ne 0) { throw "7z extraction failed (exit $LASTEXITCODE)" }
$file = Get-ChildItem -Path $dest -Recurse -File | Where-Object { $_.Name -eq $Name } | Select-Object -First 1
if (-not $file) { throw "'$Name' not found after extraction" }
Write-Output $file.FullName
exit 0
