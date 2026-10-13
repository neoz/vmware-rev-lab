#Requires -Version 7.2
<#
.SYNOPSIS
    Installs IDA Pro and ida-mcp (MCP server revlab-ida) into the clean snapshot.
.DESCRIPTION
    Needs tools/ida/ida-pro_94_x64win.exe and tools/ida/idapro.hexlic on the host; files under tools/ida/data
    (no executables) are copied next to ida.exe. Reverts to clean, switches the guest to NAT, installs IDA and
    ida-mcp, switches back to the isolated network and retakes the clean snapshot once all three MCP relays run.
    Only a human runs this: it gives the guest Internet.
.EXAMPLE
    .\scripts\add-ida.ps1
#>
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib/LabCommon.psm1') -Force
$config = Get-LabConfig
$inputs = Get-LabIdaInputs -Config $config

& (Join-Path $PSScriptRoot 'net.ps1') -Mode Setup
Start-LabLog -Config $config -Name 'add-ida' | Out-Null
try {
    New-LabGuestDirectory -Config $config -GuestPath 'C:\lab\tmp\ida'
    Copy-LabToGuest -Config $config -HostPath $inputs.Installer -GuestPath 'C:\lab\tmp\ida\ida-pro_94_x64win.exe'
    Copy-LabToGuest -Config $config -HostPath $inputs.License -GuestPath 'C:\lab\tmp\ida\idapro.hexlic'
    if ($inputs.Data) {
        # One zip keeps data/'s sub-folders; the guest expands it over C:\Tools\IDA.
        $zip = Join-Path $config.LabDir 'ida-data.zip'
        Compress-Archive -Path (Join-Path $inputs.DataDir '*') -DestinationPath $zip -Force
        Copy-LabToGuest -Config $config -HostPath $zip -GuestPath 'C:\lab\tmp\ida\data.zip'
        Remove-Item -Path $zip
    }
    $r = Invoke-LabGuestScript -Config $config -Path (Join-Path $config.Root 'templates/guest/ida-install.ps1') -Interactive -TimeoutSec 3600 -Arguments @{
        IdaMcpVersion = $config.IdaMcpVersion; IdaPort = "$($config.McpIdaPort)"; User = $config.GuestUser
    }
    Write-LabLog $r.Output
    if ($r.ExitCode -ne 0) { throw "ida-install.ps1 exited $($r.ExitCode)" }
    Update-LabToolsIndex -Config $config
} catch {
    throw "IDA install failed ($($_.Exception.Message)); the guest is still on NAT. Fix it or run .\scripts\net.ps1 -Mode Analysis (without -UpdateSnapshot to discard)."
}

# net.ps1 -UpdateSnapshot does not wait for the relays; the clean snapshot must have revlab-ida running.
& (Join-Path $PSScriptRoot 'net.ps1') -Mode Analysis
# net.ps1 started its own log; keep the rest of the install in an add-ida log.
Start-LabLog -Config $config -Name 'add-ida' | Out-Null
Restart-LabGuest -Config $config
Wait-LabDesktop -Config $config
Wait-LabCondition -Description 'MCP relays running' -TimeoutSec 300 -PollSec 10 -Condition { Test-LabRelaysRunning -Config $config -Count 3 }
Update-LabSnapshot -Config $config

Set-LabIdaInstalled -Config $config
Set-Content -Path (Join-Path $config.Root '.mcp.json') -Value (New-LabMcpJson -Config $config) -Encoding utf8
$count = Test-LabMcpBridge -Config $config -Server 'revlab-ida'
if ($count -lt 1) { throw "revlab-ida lists no tools; see C:\lab\mcp\relay-$($config.McpIdaPort).log and child-$($config.McpIdaPort).log in the guest." }
Write-LabLog "Installed IDA Pro and revlab-ida ($count tools) and retook the clean snapshot. Reconnect revlab-ida in /mcp."
