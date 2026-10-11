# Installs FLARE-VM or Chocolatey packages. Runs only while the guest is on NAT (net.ps1 -Mode Setup).
param([string]$Packages)
$ErrorActionPreference = 'Stop'
$sources = 'https://www.myget.org/F/vm-packages/api/v2;https://community.chocolatey.org/api/v2/'
# Windows PowerShell turns stderr of a redirected native command into an error under 'Stop'; judge by exit code.
function Invoke-Native([string]$File, [string[]]$Arguments) {
    $ErrorActionPreference = 'Continue'
    $output = & $File @Arguments 2>&1 | Out-String
    [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output }
}
foreach ($package in ($Packages -split ',' | Where-Object { $_ })) {
    $r = Invoke-Native 'choco' @('install', $package, '-y', '--no-progress', '--source', $sources)
    Write-Output $r.Output
    if ($r.ExitCode -ne 0) { throw "choco install $package failed (exit $($r.ExitCode))" }
}
exit 0
