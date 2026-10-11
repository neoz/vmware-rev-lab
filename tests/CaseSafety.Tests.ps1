BeforeAll {
    Import-Module "$PSScriptRoot/../scripts/lib/LabCommon.psm1" -Force
    function New-TestConfig {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force (Join-Path $root '.lab') | Out-Null
        @{ Root = $root; LabDir = (Join-Path $root '.lab'); VmxPath = 'C:\vm\x.vmx'; GuestUser = 'u'; GuestPassword = 'p' }
    }
}

Describe 'Host-side case state' {
    It 'keeps the open case on the host, not in a guest file' {
        $cfg = New-TestConfig
        Get-LabCurrentCase -Config $cfg | Should -BeNullOrEmpty
        Set-LabCurrentCase -Config $cfg -Case 'c1'
        Get-LabCurrentCase -Config $cfg | Should -Be 'c1'
    }

    It 'refuses to open a second case over an open one' {
        $cfg = New-TestConfig
        Set-LabCurrentCase -Config $cfg -Case 'a1'
        { Open-LabCase -Config $cfg -Case 'b1' } | Should -Throw -ExpectedMessage "*'a1' is open*reset.ps1*"
    }
}

Describe 'Save-LabCase after a sample ran' {
    BeforeEach {
        $cfg = New-TestConfig
        $static = Join-Path $cfg.Root 'cases/c1/static'
        New-Item -ItemType Directory -Force $static | Out-Null
        Set-Content (Join-Path $static 'ghidra.zip') 'analyst work'
        Set-LabCurrentCase -Config $cfg -Case 'c1'
        Mock Test-LabGuestDirectory -ModuleName LabCommon { $true }
        Mock Invoke-LabGuestScript -ModuleName LabCommon { [pscustomobject]@{ ExitCode = 0; Output = '' } }
        Mock Copy-LabFromGuest -ModuleName LabCommon { Set-Content -Path $HostPath -Value 'guest state' }
    }

    It 'never overwrites ghidra.zip once a sample has run; saves a post-run copy instead' {
        Set-Content (Join-Path $cfg.LabDir 'sample-ran.txt') 'x'
        Save-LabCase -Config $cfg | Should -BeTrue
        Get-Content (Join-Path $static 'ghidra.zip') -Raw | Should -Match 'analyst work'
        @(Get-ChildItem $static -Filter 'ghidra-postrun-*.zip').Count | Should -Be 1
    }

    It 'keeps the previous ghidra.zip as ghidra.prev.zip on a normal save' {
        Save-LabCase -Config $cfg | Should -BeTrue
        Get-Content (Join-Path $static 'ghidra.zip') -Raw | Should -Match 'guest state'
        Get-Content (Join-Path $static 'ghidra.prev.zip') -Raw | Should -Match 'analyst work'
    }
}

Describe 'Restore-LabClean case handling' {
    BeforeEach {
        $cfg = New-TestConfig
        $vmx = Join-Path $cfg.Root 'x.vmx'
        Set-Content $vmx @('ethernet0.connectionType = "pvn"', 'ethernet0.pvnID = "52 01"')
        $cfg.VmxPath = $vmx; $cfg.SnapshotName = 'clean'; $cfg.AnalysisPvnId = '52 01'
        Mock Start-Sleep -ModuleName LabCommon {}
        Mock Test-LabVmRunning -ModuleName LabCommon { $true }
        Mock Invoke-Vmrun -ModuleName LabCommon { [pscustomobject]@{ Output = 'running'; GuestExitCode = 0 } }
    }

    It 'points to -NoSave when saving fails' {
        Mock Save-LabCase -ModuleName LabCommon { throw 'pack failed' }
        { Restore-LabClean -Config $cfg -SaveCase } | Should -Throw -ExpectedMessage '*pack failed*reset.ps1 -NoSave*'
    }

    It 'clears the open case and the sample-ran marker after reverting' {
        Mock Save-LabCase -ModuleName LabCommon { $true }
        Set-LabCurrentCase -Config $cfg -Case 'c1'
        Set-Content (Join-Path $cfg.LabDir 'sample-ran.txt') 'x'
        Restore-LabClean -Config $cfg -SaveCase
        Get-LabCurrentCase -Config $cfg | Should -BeNullOrEmpty
        Test-Path (Join-Path $cfg.LabDir 'sample-ran.txt') | Should -BeFalse
    }
}

Describe 'Start-LabSample marks that a sample ran' {
    It 'writes the host marker before launching' {
        $cfg = New-TestConfig
        $cfg.Root = (Resolve-Path "$PSScriptRoot/..").Path
        $runDir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $runDir | Out-Null
        Mock Copy-LabToGuest -ModuleName LabCommon {}
        Mock Invoke-LabGuestScript -ModuleName LabCommon { [pscustomobject]@{ ExitCode = 0; Output = '' } }
        Start-LabSample -Config $cfg -SamplePath 'C:\x.exe' -RunDir $runDir
        Test-Path (Join-Path $cfg.LabDir 'sample-ran.txt') | Should -BeTrue
    }
}

Describe 'Test-LabGuestDirectory' {
    It 'returns false only for a missing directory and surfaces other errors' {
        $cfg = New-TestConfig
        Mock Invoke-Vmrun -ModuleName LabCommon { throw 'vmrun directoryExistsInGuest failed (exit -1): The directory does not exist.' }
        Test-LabGuestDirectory -Config $cfg -GuestPath 'C:\x' | Should -BeFalse
        Mock Invoke-Vmrun -ModuleName LabCommon { throw 'vmrun directoryExistsInGuest failed (exit -1): VMware Tools are not running' }
        { Test-LabGuestDirectory -Config $cfg -GuestPath 'C:\x' } | Should -Throw -ExpectedMessage '*Tools are not running*'
    }
}
