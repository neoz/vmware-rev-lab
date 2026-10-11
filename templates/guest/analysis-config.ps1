# Locates analysis tools, installs Sysmon, prepares C:\lab. Runs while the guest still has NAT.
param([string]$SysmonConfig)
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force -Path 'C:\lab\in', 'C:\lab\out', 'C:\lab\setup' | Out-Null

$roots = @('C:\Tools', 'C:\ProgramData\chocolatey\lib', 'C:\Program Files', 'C:\Program Files (x86)', 'C:\lab\setup')
function Find-Tool([string]$Name) {
    foreach ($root in $roots) {
        if (-not (Test-Path $root)) { continue }
        $hit = Get-ChildItem -Path $root -Filter $Name -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }
    return $null
}

$sysmon = Find-Tool 'Sysmon64.exe'
if (-not $sysmon) {
    $sysmon = 'C:\lab\setup\Sysmon64.exe'
    Invoke-WebRequest -Uri 'https://live.sysinternals.com/Sysmon64.exe' -OutFile $sysmon -UseBasicParsing
}
$tools = [ordered]@{
    Procmon  = Find-Tool 'Procmon64.exe'
    Fakenet  = Find-Tool 'fakenet.exe'
    Sysmon   = $sysmon
    SevenZip = Find-Tool '7z.exe'
}
$missing = @($tools.Keys | Where-Object { -not $tools[$_] })
if ($missing) { throw "Tools not found: $($missing -join ', ')" }
$tools | ConvertTo-Json | Set-Content -Path 'C:\lab\tools.json' -Encoding UTF8

if (Get-Service -Name Sysmon64 -ErrorAction SilentlyContinue) {
    & $tools.Sysmon -accepteula -c $SysmonConfig
} else {
    & $tools.Sysmon -accepteula -i $SysmonConfig
}
if ($LASTEXITCODE -ne 0) { throw "Sysmon configuration failed (exit $LASTEXITCODE)" }

$tools.GetEnumerator() | ForEach-Object { Write-Output "$($_.Key)=$($_.Value)" }
exit 0
