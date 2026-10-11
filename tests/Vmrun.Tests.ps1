BeforeAll {
    Import-Module "$PSScriptRoot/../scripts/lib/LabCommon.psm1" -Force
    $script:cfg = @{ Vmrun = 'vmrun.exe'; VmxPath = 'C:\vm\x.vmx'; GuestUser = 'u'; GuestPassword = 'S3cretPw'; LabDir = $TestDrive }
}

Describe 'Invoke-LabProcess' {
    It 'captures stdout and exit code' {
        $r = Invoke-LabProcess -FilePath 'cmd.exe' -ArgumentList @('/c', 'echo hi & exit 7')
        $r.StdOut | Should -Be 'hi'
        $r.ExitCode | Should -Be 7
    }

    It 'kills and throws on timeout without echoing the arguments' {
        $err = { Invoke-LabProcess -FilePath 'ping.exe' -ArgumentList @('-n', '30', 'S3cretArg') -TimeoutSec 1 } |
            Should -Throw -ExpectedMessage '*Timed out*' -PassThru
        $err.Exception.Message | Should -Not -Match 'S3cretArg'
    }
}

Describe 'Invoke-Vmrun' {
    BeforeEach {
        Mock Start-Sleep -ModuleName LabCommon {}
    }

    It 'passes -T ws, the command and the vmx path' {
        Mock Invoke-LabProcess -ModuleName LabCommon { [pscustomobject]@{ ExitCode = 0; StdOut = 'ok'; StdErr = '' } }
        (Invoke-Vmrun -Config $cfg -Command listSnapshots).Output | Should -Be 'ok'
        Should -Invoke Invoke-LabProcess -ModuleName LabCommon -Times 1 -Exactly -ParameterFilter {
            ($ArgumentList -join ' ') -eq '-T ws listSnapshots C:\vm\x.vmx'
        }
    }

    It 'omits the vmx path with -NoVmx' {
        Mock Invoke-LabProcess -ModuleName LabCommon { [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' } }
        Invoke-Vmrun -Config $cfg -Command list -NoVmx | Out-Null
        Should -Invoke Invoke-LabProcess -ModuleName LabCommon -ParameterFilter { ($ArgumentList -join ' ') -eq '-T ws list' }
    }

    It 'puts guest credentials before the command with -Guest' {
        Mock Invoke-LabProcess -ModuleName LabCommon { [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' } }
        Invoke-Vmrun -Config $cfg -Command listProcessesInGuest -Guest | Out-Null
        Should -Invoke Invoke-LabProcess -ModuleName LabCommon -ParameterFilter {
            ($ArgumentList -join ' ') -eq '-T ws -gu u -gp S3cretPw listProcessesInGuest C:\vm\x.vmx'
        }
    }

    It 'retries transient errors then succeeds' {
        $global:VmrunCalls = 0
        Mock Invoke-LabProcess -ModuleName LabCommon {
            $global:VmrunCalls++
            if ($global:VmrunCalls -lt 3) {
                [pscustomobject]@{ ExitCode = 255; StdOut = 'Error: VMware Tools are not running in the virtual machine'; StdErr = '' }
            } else {
                [pscustomobject]@{ ExitCode = 0; StdOut = 'done'; StdErr = '' }
            }
        }
        (Invoke-Vmrun -Config $cfg -Command checkToolsState).Output | Should -Be 'done'
        Should -Invoke Invoke-LabProcess -ModuleName LabCommon -Times 3 -Exactly
    }

    It 'retries while autologon has not reached the desktop yet' {
        $global:VmrunCalls = 0
        Mock Invoke-LabProcess -ModuleName LabCommon {
            $global:VmrunCalls++
            if ($global:VmrunCalls -lt 2) {
                [pscustomobject]@{ ExitCode = 255; StdOut = 'Error: The specified guest user must be logged in interactively to perform this operation'; StdErr = '' }
            } else {
                [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' }
            }
        }
        Invoke-Vmrun -Config $cfg -Command runProgramInGuest -Guest -Arguments @('-interactive', 'x.exe') | Out-Null
        Should -Invoke Invoke-LabProcess -ModuleName LabCommon -Times 2 -Exactly
    }

    It 'gives up after RetryCount retries' {
        Mock Invoke-LabProcess -ModuleName LabCommon {
            [pscustomobject]@{ ExitCode = 255; StdOut = 'Error: The guest operations agent could not be contacted'; StdErr = '' }
        }
        { Invoke-Vmrun -Config $cfg -Command listProcessesInGuest -Guest -RetryCount 2 } |
            Should -Throw -ExpectedMessage '*guest operations agent*'
        Should -Invoke Invoke-LabProcess -ModuleName LabCommon -Times 3 -Exactly
    }

    It 'fails immediately on a non-transient error' {
        Mock Invoke-LabProcess -ModuleName LabCommon {
            [pscustomobject]@{ ExitCode = 255; StdOut = 'Error: Cannot open VM: C:\vm\x.vmx'; StdErr = '' }
        }
        { Invoke-Vmrun -Config $cfg -Command start } | Should -Throw -ExpectedMessage '*Cannot open VM*'
        Should -Invoke Invoke-LabProcess -ModuleName LabCommon -Times 1 -Exactly
    }

    It 'returns the guest exit code instead of throwing' {
        Mock Invoke-LabProcess -ModuleName LabCommon {
            [pscustomobject]@{ ExitCode = 255; StdOut = 'Guest program exited with non-zero exit code: 3'; StdErr = '' }
        }
        (Invoke-Vmrun -Config $cfg -Command runProgramInGuest -Guest).GuestExitCode | Should -Be 3
    }

    It 'reports a timeout with the masked command line' {
        Mock Invoke-LabProcess -ModuleName LabCommon { throw 'Timed out after 1 s: vmrun.exe' }
        $err = { Invoke-Vmrun -Config $cfg -Command runProgramInGuest -Guest -Arguments @('x.exe', '-password', 'S3cretPw') } |
            Should -Throw -ExpectedMessage '*Timed out*' -PassThru
        $err.Exception.Message | Should -Match '-gp \*\*\*'
        $err.Exception.Message | Should -Not -Match 'S3cretPw'
    }

    It 'masks the guest password everywhere in the log' {
        Mock Invoke-LabProcess -ModuleName LabCommon { [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' } }
        $log = Start-LabLog -Config $cfg -Name test
        Invoke-Vmrun -Config $cfg -Command runProgramInGuest -Guest -Arguments @('x.exe', '-password', 'S3cretPw') | Out-Null
        $text = Get-Content $log -Raw
        $text | Should -Match '-gp \*\*\*'
        $text | Should -Not -Match 'S3cretPw'
    }
}
