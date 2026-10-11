# Launches the sample in the interactive session. Parameters come from a JSON file to avoid quoting issues.
param([string]$RunFile)
$ErrorActionPreference = 'Stop'
$run = Get-Content -Path $RunFile -Raw | ConvertFrom-Json
$path = $run.Path
$dir = Split-Path -Parent $path
$extension = [System.IO.Path]::GetExtension($path).ToLowerInvariant()

function Test-Pe32([string]$File) {
    $bytes = [System.IO.File]::ReadAllBytes($File)
    $peOffset = [BitConverter]::ToInt32($bytes, 0x3C)
    [BitConverter]::ToUInt16($bytes, $peOffset + 4) -eq 0x14C
}

switch ($extension) {
    '.exe' { $file = $path; $argList = $run.Arguments }
    '.dll' {
        $file = if (Test-Pe32 $path) { 'C:\Windows\SysWOW64\rundll32.exe' } else { 'C:\Windows\System32\rundll32.exe' }
        $argList = "`"$path`",$($run.Export) $($run.Arguments)"
    }
    '.ps1' { $file = 'powershell.exe'; $argList = "-NoProfile -ExecutionPolicy Bypass -File `"$path`" $($run.Arguments)" }
    { $_ -in '.bat', '.cmd' } { $file = 'cmd.exe'; $argList = "/c `"`"$path`" $($run.Arguments)`"" }
    default { throw "Unsupported sample type '$extension'" }
}
$params = @{ FilePath = $file; WorkingDirectory = $dir; PassThru = $true }
if ("$argList".Trim()) { $params.ArgumentList = "$argList".Trim() }
$process = Start-Process @params
Set-Content -Path 'C:\lab\out\sample.pid' -Value $process.Id
exit 0
