#Requires -Version 7.2
<# .SYNOPSIS Saves the guest's C:\lab\in\sample (sample + Ghidra databases) to cases/<case>/static/ghidra.zip. #>
param([string]$Case)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib/LabCommon.psm1') -Force
$config = Get-LabConfig
Start-LabLog -Config $config -Name 'case-save' | Out-Null
if (-not (Save-LabCase -Config $config -Case $Case)) { Write-LabLog 'No open case to save.' }
