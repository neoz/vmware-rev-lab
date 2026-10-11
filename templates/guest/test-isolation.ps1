# Verifies the guest cannot reach the Internet or the host. FakeNet must be stopped. 0 = isolated.
param([string]$HostIps)
$ErrorActionPreference = 'Continue'
if (Get-Process -Name fakenet -ErrorAction SilentlyContinue) {
    Write-Output 'FakeNet is running; stop it before testing isolation'
    exit 2
}

function Test-Tcp([string]$Address, [int]$Port) {
    $client = New-Object System.Net.Sockets.TcpClient
    try { return $client.ConnectAsync($Address, $Port).Wait(3000) } catch { return $false } finally { $client.Dispose() }
}

$failures = @()
try {
    Resolve-DnsName -Name 'example.com' -Server '1.1.1.1' -DnsOnly -QuickTimeout -ErrorAction Stop | Out-Null
    $failures += 'DNS query to 1.1.1.1 succeeded'
} catch { }
if (Test-Tcp '1.1.1.1' 443) { $failures += 'TCP 1.1.1.1:443 reachable' }
foreach ($ip in ($HostIps -split ',' | Where-Object { $_ })) {
    if (Test-Connection -ComputerName $ip -Count 1 -Quiet) { $failures += "host $ip answers ping" }
    if (Test-Tcp $ip 445) { $failures += "host ${ip}:445 reachable" }
}
if ($failures) { $failures | Write-Output; exit 1 }
Write-Output 'Isolation OK'
exit 0
