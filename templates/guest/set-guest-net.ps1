# Analysis: static IP on the isolated segment. Setup: DHCP for NAT.
param([string]$Mode, [string]$Ip, [string]$Prefix, [string]$Gateway)
$ErrorActionPreference = 'Stop'
# Windows PowerShell turns stderr of a redirected native command into an error under 'Stop'; judge by exit code.
function Invoke-Native([string]$File, [string[]]$Arguments) {
    $ErrorActionPreference = 'Continue'
    $output = & $File @Arguments 2>&1 | Out-String
    [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output }
}

$nic = $null
foreach ($i in 1..30) {
    $nic = Get-NetAdapter -Physical | Where-Object Status -eq 'Up' | Select-Object -First 1
    if ($nic) { break }
    Start-Sleep -Seconds 2
}
if (-not $nic) { throw 'No connected network adapter found' }
$index = $nic.ifIndex

Get-NetRoute -InterfaceIndex $index -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Remove-NetRoute -Confirm:$false
if ($Mode -eq 'Analysis') {
    Set-NetIPInterface -InterfaceIndex $index -Dhcp Disabled
    Get-NetIPAddress -InterfaceIndex $index -AddressFamily IPv4 -ErrorAction SilentlyContinue | Remove-NetIPAddress -Confirm:$false
    New-NetIPAddress -InterfaceIndex $index -IPAddress $Ip -PrefixLength ([int]$Prefix) -DefaultGateway $Gateway | Out-Null
    Set-DnsClientServerAddress -InterfaceIndex $index -ServerAddresses $Gateway
    # Nobody owns the gateway address, so without an ARP entry Windows drops off-subnet traffic
    # (ICMP host unreachable) before FakeNet-NG can divert it. A static entry lets packets leave.
    Get-NetNeighbor -InterfaceIndex $index -IPAddress $Gateway -ErrorAction SilentlyContinue | Remove-NetNeighbor -Confirm:$false
    New-NetNeighbor -InterfaceIndex $index -IPAddress $Gateway -LinkLayerAddress '02-00-00-66-06-01' -State Permanent | Out-Null
} elseif ($Mode -eq 'Setup') {
    Get-NetNeighbor -InterfaceIndex $index -State Permanent -ErrorAction SilentlyContinue |
        Where-Object LinkLayerAddress -eq '02-00-00-66-06-01' | Remove-NetNeighbor -Confirm:$false
    Get-NetIPAddress -InterfaceIndex $index -AddressFamily IPv4 -ErrorAction SilentlyContinue | Remove-NetIPAddress -Confirm:$false
    Set-NetIPInterface -InterfaceIndex $index -Dhcp Enabled
    Set-DnsClientServerAddress -InterfaceIndex $index -ResetServerAddresses
    $r = Invoke-Native 'ipconfig.exe' @('/renew')
    if ($r.ExitCode -ne 0) { throw "ipconfig /renew failed (exit $($r.ExitCode)):`n$($r.Output)" }
} else {
    throw "Unknown mode '$Mode'"
}
Get-NetIPConfiguration -InterfaceIndex $index | Out-String | Write-Output
exit 0
