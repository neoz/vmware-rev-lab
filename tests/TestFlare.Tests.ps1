BeforeAll {
    $script = (Resolve-Path "$PSScriptRoot/../templates/guest/test-flare.ps1").Path
    function Invoke-TestFlare([string]$Lib) {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script -ChocoLib $Lib -VmDir (Join-Path $TestDrive 'vm') | Out-Null
        $LASTEXITCODE
    }
    function New-Lib([string[]]$Paths) {
        $lib = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $lib | Out-Null
        foreach ($p in $Paths) {
            $full = Join-Path $lib $p
            New-Item -ItemType Directory -Force -Path (Split-Path $full) | Out-Null
            Set-Content -Path $full -Value 'x'
        }
        $lib
    }
}

Describe 'test-flare.ps1' {
    It 'reports not started (2) on an empty chocolatey lib' {
        Invoke-TestFlare (New-Lib @()) | Should -Be 2
    }

    It 'reports done (0) when installer.vm is installed and not pending' {
        Invoke-TestFlare (New-Lib @('installer.vm\installer.vm.nupkg')) | Should -Be 0
    }

    It 'reports in progress (1) while installer.vm is pending' {
        Invoke-TestFlare (New-Lib @('installer.vm\installer.vm.nupkg', 'installer.vm\.chocolateyPending')) | Should -Be 1
    }

    It 'reports stalled (4) when Boxstarter is installed but nothing runs and installer.vm is absent' {
        Invoke-TestFlare (New-Lib @('Boxstarter\Boxstarter.nupkg')) | Should -Be 4
    }
}
