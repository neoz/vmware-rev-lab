# Zips a guest file or directory with password 'infected' so host antivirus leaves it alone.
param([string]$Source, [string]$Destination)
$ErrorActionPreference = 'Stop'
if (-not (Test-Path $Source)) { throw "Not found: $Source" }
$tools = Get-Content -Path 'C:\lab\tools.json' -Raw | ConvertFrom-Json
if (Test-Path $Destination) { Remove-Item $Destination -Force }
# Windows PowerShell turns stderr of a redirected native command into an error under 'Stop'; judge by exit code.
function Invoke-Native([string]$File, [string[]]$Arguments) {
    $ErrorActionPreference = 'Continue'
    $output = & $File @Arguments 2>&1 | Out-String
    [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output }
}
# 7-Zip exit 1 is a warning (for example a file in use); the archive is still written.
$r = Invoke-Native $tools.SevenZip @('a', '-tzip', '-pinfected', $Destination, $Source)
if ($r.ExitCode -gt 1) { throw "7z failed (exit $($r.ExitCode)):`n$($r.Output)" }
exit 0
