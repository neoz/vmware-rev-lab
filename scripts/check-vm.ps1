#Requires -Version 7.2
<# .SYNOPSIS SessionStart hook for Claude Code: prints a warning (hook JSON) when the lab VM is not running. #>
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib/LabCommon.psm1') -Force
$notice = Get-LabSessionNotice -Config (Get-LabConfig)
if ($notice) { $notice }
