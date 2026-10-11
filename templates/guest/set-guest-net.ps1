# Analysis: static IP on the isolated segment. Setup: DHCP for NAT.
param([string]$Mode, [string]$Ip, [string]$Prefix, [string]$Gateway)
$ErrorActionPreference = 'Stop'

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
} elseif ($Mode -eq 'Setup') {
    Get-NetIPAddress -InterfaceIndex $index -AddressFamily IPv4 -ErrorAction SilentlyContinue | Remove-NetIPAddress -Confirm:$false
    Set-NetIPInterface -InterfaceIndex $index -Dhcp Enabled
    Set-DnsClientServerAddress -InterfaceIndex $index -ResetServerAddresses
    ipconfig /renew | Out-Null
} else {
    throw "Unknown mode '$Mode'"
}
Get-NetIPConfiguration -InterfaceIndex $index | Out-String | Write-Output
exit 0
