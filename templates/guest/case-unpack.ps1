# Extracts a case zip, records the open case and prints the path of -Name (or the sample dir).
param([string]$Zip, [string]$Destination, [string]$Case, [string]$Name)
$ErrorActionPreference = 'Stop'
function Invoke-Native([string]$File, [string[]]$Arguments) {
    $ErrorActionPreference = 'Continue'
    $output = & $File @Arguments 2>&1 | Out-String
    [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output }
}
$tools = Get-Content 'C:\lab\tools.json' -Raw | ConvertFrom-Json
$r = Invoke-Native $tools.SevenZip @('x', '-y', '-pinfected', "-o$Destination", $Zip)
if ($r.ExitCode -gt 1) { throw "7z failed (exit $($r.ExitCode)):`n$($r.Output)" }
Set-Content -Path 'C:\lab\current-case.txt' -Value $Case -Encoding ASCII
$sampleDir = 'C:\lab\in\sample'
if ($Name) {
    $file = Get-ChildItem -Path $sampleDir -Recurse -File | Where-Object { $_.Name -eq $Name } | Select-Object -First 1
    if (-not $file) { throw "'$Name' not found under $sampleDir" }
    Write-Output $file.FullName
} else {
    Write-Output $sampleDir
}
exit 0
