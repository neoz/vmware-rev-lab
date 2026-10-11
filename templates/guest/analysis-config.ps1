# Installs Frida and ilspycmd, locates analysis tools, installs Sysmon, prepares C:\lab.
# Runs while the guest still has NAT.
param([string]$SysmonConfig, [string]$FridaToolsVersion, [string]$DotnetSdkVersion, [string]$IlspyCmdVersion)
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force -Path 'C:\lab\in', 'C:\lab\out', 'C:\lab\setup' | Out-Null

# .NET 3.5 (for old .NET samples) comes from the Windows ISO, still attached at this point;
# the choco package needs Windows Update, which is disabled.
if ((Get-WindowsOptionalFeature -Online -FeatureName NetFx3).State -ne 'Enabled') {
    $sxs = Get-PSDrive -PSProvider FileSystem | ForEach-Object { Join-Path $_.Root 'sources\sxs' } |
        Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $sxs) { throw 'Windows ISO (sources\sxs) not found for NetFx3' }
    & dism.exe /Online /Enable-Feature /FeatureName:NetFx3 /All /LimitAccess /Source:$sxs /NoRestart | Out-Null
    if ($LASTEXITCODE -notin 0, 3010) { throw "DISM NetFx3 failed (exit $LASTEXITCODE)" }
}

& py -3.13 -m pip install --disable-pip-version-check --quiet "frida-tools==$FridaToolsVersion"
if ($LASTEXITCODE -ne 0) { throw "pip install frida-tools failed (exit $LASTEXITCODE)" }
$pythonDir = & py -3.13 -c "import os, sys; print(os.path.dirname(sys.executable))"

& choco install dotnet-sdk --version $DotnetSdkVersion -y --no-progress | Out-Null
if ($LASTEXITCODE -ne 0) { throw "choco install dotnet-sdk failed (exit $LASTEXITCODE)" }
$dotnetTools = 'C:\Tools\dotnet-tools'
if (-not (Test-Path (Join-Path $dotnetTools 'ilspycmd.exe'))) {
    & 'C:\Program Files\dotnet\dotnet.exe' tool install ilspycmd --version $IlspyCmdVersion --tool-path $dotnetTools
    if ($LASTEXITCODE -ne 0) { throw "dotnet tool install ilspycmd failed (exit $LASTEXITCODE)" }
}

# WinDbg ships as an MSIX package; cdb.exe lives in its install location, which cannot be searched recursively.
$winDbg = Get-AppxPackage -Name 'Microsoft.WinDbg*' | Select-Object -First 1
$cdb = if ($winDbg) { Join-Path $winDbg.InstallLocation 'amd64\cdb.exe' } else { $null }

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
    Procmon         = Find-Tool 'Procmon64.exe'
    Fakenet         = Find-Tool 'fakenet.exe'
    Sysmon          = $sysmon
    SevenZip        = Find-Tool '7z.exe'
    AnalyzeHeadless = Find-Tool 'analyzeHeadless.bat'
    Cdb             = if ($cdb -and (Test-Path $cdb)) { $cdb } else { $null }
    Frida           = Join-Path $pythonDir 'Scripts\frida.exe'
    FridaTrace      = Join-Path $pythonDir 'Scripts\frida-trace.exe'
    Ilspycmd        = Join-Path $dotnetTools 'ilspycmd.exe'
    Capa            = Find-Tool 'capa.exe'
    Floss           = Find-Tool 'floss.exe'
    Diec            = Find-Tool 'diec.exe'
    Tshark          = Find-Tool 'tshark.exe'
    PeSieve         = Find-Tool 'pe-sieve64.exe'
    HollowsHunter   = Find-Tool 'hollows_hunter64.exe'
    De4dot          = Find-Tool 'de4dot.exe'
}
$missing = @($tools.Keys | Where-Object { -not $tools[$_] -or -not (Test-Path $tools[$_]) })
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
