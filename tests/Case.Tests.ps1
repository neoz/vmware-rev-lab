BeforeAll {
    Import-Module "$PSScriptRoot/../scripts/lib/LabCommon.psm1" -Force
}

Describe 'Save-LabCase' {
    BeforeEach {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $root | Out-Null
        $cfg = @{ Root = $root; LabDir = (Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))); VmxPath = 'C:\vm\x.vmx'; GuestUser = 'u'; GuestPassword = 'p' }
    }

    It 'returns false when no case is open' {
        Mock Get-LabCurrentCase -ModuleName LabCommon { $null }
        Save-LabCase -Config $cfg | Should -BeFalse
    }

    It 'packs the guest sample dir into cases/<case>/static/ghidra.zip' {
        Mock Get-LabCurrentCase -ModuleName LabCommon { 'emotet1' }
        Mock Test-LabGuestDirectory -ModuleName LabCommon { $true }
        Mock Invoke-LabGuestScript -ModuleName LabCommon { [pscustomobject]@{ ExitCode = 0; Output = '' } }
        Mock Copy-LabFromGuest -ModuleName LabCommon { Set-Content -Path $HostPath -Value 'zip' }
        Save-LabCase -Config $cfg | Should -BeTrue
        Test-Path (Join-Path $root 'cases/emotet1/static/ghidra.zip') | Should -BeTrue
        Should -Invoke Invoke-LabGuestScript -ModuleName LabCommon -ParameterFilter { $Arguments.Source -eq 'C:\lab\in\sample' }
    }

    It 'throws when packing fails' {
        Mock Get-LabCurrentCase -ModuleName LabCommon { 'emotet1' }
        Mock Test-LabGuestDirectory -ModuleName LabCommon { $true }
        Mock Invoke-LabGuestScript -ModuleName LabCommon { [pscustomobject]@{ ExitCode = 1; Output = 'disk full' } }
        { Save-LabCase -Config $cfg } | Should -Throw -ExpectedMessage '*disk full*'
    }
}

Describe 'Restore-LabClean -SaveCase' {
    BeforeEach {
        $vmx = Join-Path $TestDrive 'x.vmx'
        Set-Content $vmx @('ethernet0.connectionType = "pvn"', 'ethernet0.pvnID = "52 01"')
        $cfg = @{ LabDir = (Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))); VmxPath = $vmx; SnapshotName = 'clean'; AnalysisPvnId = '52 01' }
        Mock Start-Sleep -ModuleName LabCommon {}
        Mock Test-LabVmRunning -ModuleName LabCommon { $true }
        Mock Invoke-Vmrun -ModuleName LabCommon { [pscustomobject]@{ Output = 'running'; GuestExitCode = 0 } }
    }

    It 'saves the open case before reverting' {
        Mock Save-LabCase -ModuleName LabCommon { $true }
        Restore-LabClean -Config $cfg -SaveCase
        Should -Invoke Save-LabCase -ModuleName LabCommon -Times 1 -Exactly
        Should -Invoke Invoke-Vmrun -ModuleName LabCommon -ParameterFilter { $Command -eq 'revertToSnapshot' }
    }

    It 'does not revert when saving fails' {
        Mock Save-LabCase -ModuleName LabCommon { throw 'pack failed' }
        { Restore-LabClean -Config $cfg -SaveCase } | Should -Throw -ExpectedMessage '*pack failed*'
        Should -Invoke Invoke-Vmrun -ModuleName LabCommon -Times 0 -Exactly -ParameterFilter { $Command -eq 'revertToSnapshot' }
    }

    It 'reverts normally when no case is open' {
        Mock Save-LabCase -ModuleName LabCommon { $false }
        Restore-LabClean -Config $cfg -SaveCase
        Should -Invoke Invoke-Vmrun -ModuleName LabCommon -ParameterFilter { $Command -eq 'revertToSnapshot' }
    }
}

Describe 'Open-LabCase' {
    It 'restores a saved Ghidra zip when one exists' {
        $root = Join-Path $TestDrive 'open'
        New-Item -ItemType Directory -Force (Join-Path $root 'cases/c1/static') | Out-Null
        Set-Content (Join-Path $root 'cases/c1/static/ghidra.zip') 'z'
        Set-Content (Join-Path $root 'cases/c1/sample.zip') 's'
        $cfg = @{ Root = $root; LabDir = (Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))); VmxPath = 'C:\vm\x.vmx' }
        Mock Copy-LabToGuest -ModuleName LabCommon {}
        Mock Invoke-LabGuestScript -ModuleName LabCommon { [pscustomobject]@{ ExitCode = 0; Output = 'C:\lab\in\sample\a.exe' } }
        Open-LabCase -Config $cfg -Case 'c1' -Name 'a.exe' | Should -Be 'C:\lab\in\sample\a.exe'
        Should -Invoke Copy-LabToGuest -ModuleName LabCommon -ParameterFilter { $HostPath -like '*ghidra.zip' }
        Should -Invoke Invoke-LabGuestScript -ModuleName LabCommon -ParameterFilter { $Arguments.Destination -eq 'C:\lab\in' -and $Arguments.Case -eq 'c1' }
    }
}
