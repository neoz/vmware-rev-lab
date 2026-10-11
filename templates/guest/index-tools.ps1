# Lists every runnable tool under C:\Tools (FLARE-VM layout) so tools added later can be found by path.
param([string]$ToolsRoot = 'C:\Tools', [string]$OutFile = 'C:\lab\tools-index.txt')
$ErrorActionPreference = 'Stop'
Get-ChildItem -Path $ToolsRoot -Recurse -File -Include '*.exe', '*.bat', '*.cmd', '*.py', '*.jar' -ErrorAction SilentlyContinue |
    ForEach-Object FullName | Sort-Object | Set-Content -Path $OutFile -Encoding UTF8
Write-Output "$((Get-Content $OutFile | Measure-Object).Count) tools indexed in $OutFile"
exit 0
