Describe 'index-tools.ps1' {
    It 'lists runnable tools under the tools root, one path per line' {
        $root = Join-Path $TestDrive 'Tools'
        New-Item -ItemType Directory -Force (Join-Path $root 'goresym'), (Join-Path $root 'docs') | Out-Null
        Set-Content (Join-Path $root 'goresym/GoReSym.exe') 'x'
        Set-Content (Join-Path $root 'goresym/run.bat') 'x'
        Set-Content (Join-Path $root 'docs/readme.txt') 'x'
        $out = Join-Path $TestDrive 'tools-index.txt'
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$PSScriptRoot/../templates/guest/index-tools.ps1" -ToolsRoot $root -OutFile $out | Out-Null
        $LASTEXITCODE | Should -Be 0
        $lines = Get-Content $out
        $lines | Should -Contain (Join-Path $root 'goresym\GoReSym.exe')
        $lines | Should -Contain (Join-Path $root 'goresym\run.bat')
        $lines | Where-Object { $_ -like '*readme.txt' } | Should -BeNullOrEmpty
    }
}
