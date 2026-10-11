# Extracts sample.zip inside the guest and prints the full path of the chosen file.
param([string]$Zip, [string]$Name)
$ErrorActionPreference = 'Stop'
$tools = Get-Content -Path 'C:\lab\tools.json' -Raw | ConvertFrom-Json
# Windows PowerShell turns stderr of a redirected native command into an error under 'Stop'; judge by exit code.
function Invoke-Native([string]$File, [string[]]$Arguments) {
    $ErrorActionPreference = 'Continue'
    $output = & $File @Arguments 2>&1 | Out-String
    [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output }
}
$dest = 'C:\lab\in\sample'
$r = Invoke-Native $tools.SevenZip @('x', '-y', '-pinfected', "-o$dest", $Zip)
if ($r.ExitCode -gt 1) { throw "7z extraction failed (exit $($r.ExitCode)):`n$($r.Output)" }
$file = Get-ChildItem -Path $dest -Recurse -File | Where-Object { $_.Name -eq $Name } | Select-Object -First 1
if (-not $file) { throw "'$Name' not found after extraction" }
Write-Output $file.FullName
exit 0
