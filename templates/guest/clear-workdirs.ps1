# Empties the per-case working folders so a snapshot never carries a previous case.
$ErrorActionPreference = 'Stop'
# This script and its wrapper/output live in C:\lab\tmp as <name>-<id>.ps1, wrap-<id>.ps1, <name>-<id>.out.
$id = ([System.IO.Path]::GetFileNameWithoutExtension($PSCommandPath) -split '-')[-1]
Get-ChildItem -Path 'C:\lab\in', 'C:\lab\out' -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force
Get-ChildItem -Path 'C:\lab\tmp' -Force -ErrorAction SilentlyContinue |
    Where-Object { $_.BaseName -notmatch "-$id$" } | Remove-Item -Recurse -Force
Remove-Item -Path 'C:\lab\current-case.txt' -Force -ErrorAction SilentlyContinue
exit 0
