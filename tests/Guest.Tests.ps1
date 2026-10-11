BeforeAll {
    Import-Module "$PSScriptRoot/../scripts/lib/LabCommon.psm1" -Force
    $script:ok = { param($out = '') [pscustomobject]@{ Output = $out; GuestExitCode = 0 } }
}

Describe 'Wait-LabCondition' {
    BeforeEach { Mock Start-Sleep -ModuleName LabCommon {} }

    It 'returns once the condition is true' {
        $global:Polls = 0
        Wait-LabCondition -Description 'x' -TimeoutSec 60 -PollSec 0 -Condition { $global:Polls++; $global:Polls -ge 3 }
        $global:Polls | Should -Be 3
    }

    It 'throws with the description on timeout' {
        { Wait-LabCondition -Description 'never' -TimeoutSec 0 -PollSec 0 -Condition { $false } } |
            Should -Throw -ExpectedMessage '*never*'
    }
}

Describe 'Snapshots' {
    BeforeAll { $cfg = @{ VmxPath = 'C:\vm\x.vmx'; SnapshotName = 'clean' } }

    It 'parses listSnapshots output' {
        Mock Invoke-Vmrun -ModuleName LabCommon { [pscustomobject]@{ Output = "Total snapshots: 2`r`nbase`r`nclean"; GuestExitCode = 0 } }
        Get-LabSnapshots -Config $cfg | Should -Be @('base', 'clean')
    }

    It 'deletes an existing snapshot before taking it again' {
        Mock Invoke-Vmrun -ModuleName LabCommon -ParameterFilter { $Command -eq 'listSnapshots' } { [pscustomobject]@{ Output = "Total snapshots: 1`nclean"; GuestExitCode = 0 } }
        Mock Invoke-Vmrun -ModuleName LabCommon -ParameterFilter { $Command -in 'deleteSnapshot', 'snapshot' } { [pscustomobject]@{ Output = ''; GuestExitCode = 0 } }
        Update-LabSnapshot -Config $cfg
        Should -Invoke Invoke-Vmrun -ModuleName LabCommon -Times 1 -Exactly -ParameterFilter { $Command -eq 'deleteSnapshot' -and $Arguments[0] -eq 'clean' }
        Should -Invoke Invoke-Vmrun -ModuleName LabCommon -Times 1 -Exactly -ParameterFilter { $Command -eq 'snapshot' -and $Arguments[0] -eq 'clean' }
    }

    It 'does not delete when the snapshot is absent' {
        Mock Invoke-Vmrun -ModuleName LabCommon -ParameterFilter { $Command -eq 'listSnapshots' } { [pscustomobject]@{ Output = 'Total snapshots: 0'; GuestExitCode = 0 } }
        Mock Invoke-Vmrun -ModuleName LabCommon -ParameterFilter { $Command -in 'deleteSnapshot', 'snapshot' } { [pscustomobject]@{ Output = ''; GuestExitCode = 0 } }
        Update-LabSnapshot -Config $cfg
        Should -Invoke Invoke-Vmrun -ModuleName LabCommon -Times 0 -Exactly -ParameterFilter { $Command -eq 'deleteSnapshot' }
    }
}

Describe 'Restore-LabClean' {
    BeforeEach {
        $vmx = Join-Path $TestDrive 'x.vmx'
        $cfg = @{ VmxPath = $vmx; SnapshotName = 'clean'; AnalysisPvnId = '52 01' }
        Mock Start-Sleep -ModuleName LabCommon {}
        Mock Invoke-Vmrun -ModuleName LabCommon -ParameterFilter { $Command -eq 'revertToSnapshot' } { [pscustomobject]@{ Output = ''; GuestExitCode = 0 } }
        Mock Invoke-Vmrun -ModuleName LabCommon -ParameterFilter { $Command -eq 'list' } { [pscustomobject]@{ Output = 'Total running VMs: 0'; GuestExitCode = 0 } }
        Mock Invoke-Vmrun -ModuleName LabCommon -ParameterFilter { $Command -eq 'start' } { [pscustomobject]@{ Output = ''; GuestExitCode = 0 } }
        Mock Invoke-Vmrun -ModuleName LabCommon -ParameterFilter { $Command -eq 'checkToolsState' } { [pscustomobject]@{ Output = 'running'; GuestExitCode = 0 } }
    }

    It 'reverts, starts the VM and waits for Tools on the analysis segment' {
        Set-Content $vmx @('ethernet0.connectionType = "pvn"', 'ethernet0.pvnID = "52 01"')
        Restore-LabClean -Config $cfg
        Should -Invoke Invoke-Vmrun -ModuleName LabCommon -Times 1 -Exactly -ParameterFilter { $Command -eq 'revertToSnapshot' -and $Arguments[0] -eq 'clean' }
        Should -Invoke Invoke-Vmrun -ModuleName LabCommon -Times 1 -Exactly -ParameterFilter { $Command -eq 'start' }
    }

    It 'refuses to start the VM when the VMX is on NAT' {
        Set-Content $vmx @('ethernet0.connectionType = "nat"')
        { Restore-LabClean -Config $cfg } | Should -Throw -ExpectedMessage '*not on the analysis LAN segment*'
        Should -Invoke Invoke-Vmrun -ModuleName LabCommon -Times 0 -Exactly -ParameterFilter { $Command -eq 'start' }
    }
}

Describe 'New-LabGuestDirectory' {
    BeforeAll { $cfg = @{ VmxPath = 'C:\vm\x.vmx'; GuestUser = 'u'; GuestPassword = 'p' } }

    It 'creates the directory when vmrun reports it missing with a non-zero exit' {
        Mock Invoke-Vmrun -ModuleName LabCommon -ParameterFilter { $Command -eq 'directoryExistsInGuest' } {
            throw 'vmrun directoryExistsInGuest failed (exit -1): The directory does not exist.'
        }
        Mock Invoke-Vmrun -ModuleName LabCommon -ParameterFilter { $Command -eq 'createDirectoryInGuest' } { [pscustomobject]@{ Output = ''; GuestExitCode = 0 } }
        New-LabGuestDirectory -Config $cfg -GuestPath 'C:\lab\tmp'
        Should -Invoke Invoke-Vmrun -ModuleName LabCommon -Times 1 -Exactly -ParameterFilter { $Command -eq 'createDirectoryInGuest' -and $Arguments[0] -eq 'C:\lab\tmp' }
    }

    It 'does nothing when the directory exists' {
        Mock Invoke-Vmrun -ModuleName LabCommon -ParameterFilter { $Command -eq 'directoryExistsInGuest' } { [pscustomobject]@{ Output = 'The directory exists.'; GuestExitCode = 0 } }
        Mock Invoke-Vmrun -ModuleName LabCommon -ParameterFilter { $Command -eq 'createDirectoryInGuest' } { [pscustomobject]@{ Output = ''; GuestExitCode = 0 } }
        New-LabGuestDirectory -Config $cfg -GuestPath 'C:\lab\tmp'
        Should -Invoke Invoke-Vmrun -ModuleName LabCommon -Times 0 -Exactly -ParameterFilter { $Command -eq 'createDirectoryInGuest' }
    }

    It 'still surfaces other errors' {
        Mock Invoke-Vmrun -ModuleName LabCommon -ParameterFilter { $Command -eq 'directoryExistsInGuest' } { throw 'vmrun directoryExistsInGuest failed (exit -1): Invalid user name or password' }
        { New-LabGuestDirectory -Config $cfg -GuestPath 'C:\lab\tmp' } | Should -Throw -ExpectedMessage '*Invalid user name*'
    }
}

Describe 'Invoke-LabGuestScript' {
    BeforeEach {
        $cfg = @{ VmxPath = 'C:\vm\x.vmx'; GuestUser = 'u'; GuestPassword = 'p' }
        $global:WrapText = $null
        Mock Invoke-Vmrun -ModuleName LabCommon -ParameterFilter { $Command -eq 'directoryExistsInGuest' } { [pscustomobject]@{ Output = 'The directory exists.'; GuestExitCode = 0 } }
        Mock Invoke-Vmrun -ModuleName LabCommon -ParameterFilter { $Command -eq 'copyFileFromHostToGuest' } {
            if ($Arguments[1] -like '*\wrap-*') { $global:WrapText = Get-Content -Path $Arguments[0] -Raw }
            [pscustomobject]@{ Output = ''; GuestExitCode = 0 }
        }
        Mock Invoke-Vmrun -ModuleName LabCommon -ParameterFilter { $Command -eq 'runProgramInGuest' } { [pscustomobject]@{ Output = ''; GuestExitCode = 3 } }
        Mock Invoke-Vmrun -ModuleName LabCommon -ParameterFilter { $Command -eq 'copyFileFromGuestToHost' } {
            Set-Content -Path $Arguments[1] -Value "line1`r`nline2"
            [pscustomobject]@{ Output = ''; GuestExitCode = 0 }
        }
        $probe = Join-Path $TestDrive 'probe.ps1'
        Set-Content $probe 'exit 3'
    }

    It 'returns the guest exit code and captured output' {
        $r = Invoke-LabGuestScript -Config $cfg -Path $probe
        $r.ExitCode | Should -Be 3
        $r.Output | Should -Be "line1`r`nline2"
    }

    It 'passes arguments with quotes and spaces intact' {
        Invoke-LabGuestScript -Config $cfg -Path $probe -Arguments @{ Name = "it's a file.exe" } | Out-Null
        $global:WrapText | Should -Match ([regex]::Escape("-Name 'it''s a file.exe'"))
    }

    It 'runs the wrapper through Windows PowerShell, interactive when asked' {
        Invoke-LabGuestScript -Config $cfg -Path $probe -Interactive | Out-Null
        Should -Invoke Invoke-Vmrun -ModuleName LabCommon -ParameterFilter {
            $Command -eq 'runProgramInGuest' -and $Arguments[0] -eq '-interactive' -and
            $Arguments[1] -eq 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -and
            $Arguments[-1] -like 'C:\lab\tmp\wrap-*.ps1'
        }
    }
}
