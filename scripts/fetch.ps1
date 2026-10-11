#Requires -Version 7.2
<#
.SYNOPSIS
    Copies a guest file or directory into cases/<case>/fetched/.
.PARAMETER Text
    Copy a single text file as is. Without it, the path is zipped in the guest with password 'infected'.
#>
param(
    [Parameter(Mandatory)][string]$Case,
    [Parameter(Mandatory)][string]$GuestPath,
    [switch]$Text
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib/LabCommon.psm1') -Force
$config = Get-LabConfig
Start-LabLog -Config $config -Name "fetch-$Case" | Out-Null

Assert-LabCaseName $Case
$dest = Join-Path $config.Root "cases/$Case/fetched"
New-Item -ItemType Directory -Force -Path $dest | Out-Null
$leaf = Split-Path -Leaf $GuestPath
if ($Text) {
    Assert-LabTextFetchPath $GuestPath
    Copy-LabFromGuest -Config $config -GuestPath $GuestPath -HostPath (Join-Path $dest $leaf)
    Assert-LabNotPe (Join-Path $dest $leaf)
    Write-LabLog "Fetched $GuestPath -> $(Join-Path $dest $leaf)"
} else {
    $guestZip = "C:\lab\tmp\fetch-$([guid]::NewGuid().ToString('N').Substring(0, 8)).zip"
    $r = Invoke-LabGuestScript -Config $config -Path (Join-Path $config.Root 'templates/guest/pack.ps1') -Arguments @{
        Source = $GuestPath; Destination = $guestZip
    }
    if ($r.ExitCode -ne 0) { throw "pack.ps1 failed: $($r.Output)" }
    Copy-LabFromGuest -Config $config -GuestPath $guestZip -HostPath (Join-Path $dest "$leaf.zip")
    Write-LabLog "Fetched $GuestPath -> $(Join-Path $dest "$leaf.zip") (password: infected)"
}
