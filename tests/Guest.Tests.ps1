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

    It 'takes the new snapshot before deleting the old one and records its name' {
        $global:SnapOps = [System.Collections.Generic.List[string]]::new()
        $c = @{ VmxPath = 'C:\vm\x.vmx'; SnapshotName = 'clean'; Root = $TestDrive }
        Mock Save-LabLocalConfig -ModuleName LabCommon {}
        Mock Invoke-LabGuestScript -ModuleName LabCommon {
            $global:SnapOps.Add("guest $([System.IO.Path]::GetFileName($Path))")
            [pscustomobject]@{ ExitCode = 0; Output = '' }
        }
        Mock Invoke-Vmrun -ModuleName LabCommon -ParameterFilter { $Command -eq 'listSnapshots' } { [pscustomobject]@{ Output = "Total snapshots: 1`nclean"; GuestExitCode = 0 } }
        Mock Invoke-Vmrun -ModuleName LabCommon -ParameterFilter { $Command -in 'deleteSnapshot', 'snapshot' } {
            $global:SnapOps.Add("$Command $($Arguments[0])")
            [pscustomobject]@{ Output = ''; GuestExitCode = 0 }
        }
        Update-LabSnapshot -Config $c
        $global:SnapOps.Count | Should -Be 3
        $global:SnapOps[0] | Should -Be 'guest clear-workdirs.ps1'
        $global:SnapOps[1] | Should -Match '^snapshot clean-\d{14}$'
        $global:SnapOps[2] | Should -Be 'deleteSnapshot clean'
        $c.SnapshotName | Should -Match '^clean-\d{14}$'
        Should -Invoke Save-LabLocalConfig -ModuleName LabCommon -Times 1 -Exactly -ParameterFilter { $Values.SnapshotName -eq $c.SnapshotName }
    }

    It 'keeps the old snapshot when taking the new one fails' {
        $c = @{ VmxPath = 'C:\vm\x.vmx'; SnapshotName = 'clean-20260101000000'; Root = $TestDrive }
        Mock Save-LabLocalConfig -ModuleName LabCommon {}
        Mock Invoke-LabGuestScript -ModuleName LabCommon { [pscustomobject]@{ ExitCode = 0; Output = '' } }
        Mock Invoke-Vmrun -ModuleName LabCommon -ParameterFilter { $Command -eq 'listSnapshots' } { [pscustomobject]@{ Output = "Total snapshots: 1`nclean-20260101000000"; GuestExitCode = 0 } }
        Mock Invoke-Vmrun -ModuleName LabCommon -ParameterFilter { $Command -eq 'snapshot' } { throw 'disk full' }
        Mock Invoke-Vmrun -ModuleName LabCommon -ParameterFilter { $Command -eq 'deleteSnapshot' } { [pscustomobject]@{ Output = ''; GuestExitCode = 0 } }
        { Update-LabSnapshot -Config $c } | Should -Throw -ExpectedMessage '*disk full*'
        Should -Invoke Invoke-Vmrun -ModuleName LabCommon -Times 0 -Exactly -ParameterFilter { $Command -eq 'deleteSnapshot' }
        $c.SnapshotName | Should -Be 'clean-20260101000000'
    }

    It 'takes no snapshot when the guest working folders cannot be cleared' {
        $c = @{ VmxPath = 'C:\vm\x.vmx'; SnapshotName = 'clean'; Root = $TestDrive }
        Mock Invoke-LabGuestScript -ModuleName LabCommon { [pscustomobject]@{ ExitCode = 1; Output = 'access denied' } }
        Mock Invoke-Vmrun -ModuleName LabCommon {}
        { Update-LabSnapshot -Config $c } | Should -Throw -ExpectedMessage '*clear-workdirs*access denied*'
        Should -Invoke Invoke-Vmrun -ModuleName LabCommon -Times 0 -Exactly
        $c.SnapshotName | Should -Be 'clean'
    }
}

Describe 'Restore-LabClean' {
    BeforeEach {
        $vmx = Join-Path $TestDrive 'x.vmx'
        $cfg = @{ LabDir = (Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))); VmxPath = $vmx; SnapshotName = 'clean'; AnalysisPvnId = '52 01' }
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

    It 'does not revert at all during a manual Setup session (NAT without a case marker)' {
        Set-Content $vmx @('ethernet0.connectionType = "nat"')
        { Restore-LabClean -Config $cfg } | Should -Throw -ExpectedMessage '*net.ps1 -Mode Analysis*'
        Should -Invoke Invoke-Vmrun -ModuleName LabCommon -Times 0 -Exactly -ParameterFilter { $Command -eq 'revertToSnapshot' }
    }

    It 'leaves a case-driven NAT for the analysis segment after the revert' {
        Set-Content $vmx @('ethernet0.connectionType = "nat"')
        New-Item -ItemType Directory -Force -Path $cfg.LabDir | Out-Null
        Set-Content (Join-Path $cfg.LabDir 'case-net.txt') 'ctf'
        Mock Write-LabLog -ModuleName LabCommon {}
        Mock Switch-LabNetwork -ModuleName LabCommon {}
        Restore-LabClean -Config $cfg
        Should -Invoke Invoke-Vmrun -ModuleName LabCommon -Times 1 -Exactly -ParameterFilter { $Command -eq 'revertToSnapshot' }
        Should -Invoke Switch-LabNetwork -ModuleName LabCommon -Times 1 -Exactly -ParameterFilter { $Mode -eq 'Analysis' }
    }

    It 'drops a stale marker when the revert already restored the analysis segment' {
        Set-Content $vmx @('ethernet0.connectionType = "pvn"', 'ethernet0.pvnID = "52 01"')
        New-Item -ItemType Directory -Force -Path $cfg.LabDir | Out-Null
        Set-Content (Join-Path $cfg.LabDir 'case-net.txt') 'ctf'
        Mock Switch-LabNetwork -ModuleName LabCommon {}
        Restore-LabClean -Config $cfg
        Should -Invoke Switch-LabNetwork -ModuleName LabCommon -Times 0 -Exactly
        Test-Path (Join-Path $cfg.LabDir 'case-net.txt') | Should -BeFalse
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

    It 'escapes Unicode single quotes that PowerShell also treats as delimiters' {
        $name = "it$([char]0x2019);Write-Output INJECTED;$([char]0x2018)x.exe"
        Invoke-LabGuestScript -Config $cfg -Path $probe -Arguments @{ Name = $name } | Out-Null
        $line = ($global:WrapText -split "`r?`n" | Where-Object { $_ -match '-Name' })
        $parsed = [System.Management.Automation.Language.Parser]::ParseInput($line.Trim(), [ref]$null, [ref]$null)
        $commands = $parsed.FindAll({ param($a) $a -is [System.Management.Automation.Language.CommandAst] }, $true)
        @($commands).Count | Should -Be 1
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

Describe 'Assert-LabIsolation' {
    It 'fails without running the guest check when the VMX is on NAT' {
        $vmx = Join-Path $TestDrive 'nat.vmx'
        Set-Content $vmx 'ethernet0.connectionType = "nat"'
        $c = @{ VmxPath = $vmx; AnalysisPvnId = '52 01'; Root = $TestDrive }
        Mock Invoke-LabGuestScript -ModuleName LabCommon { [pscustomobject]@{ ExitCode = 0; Output = 'Isolation OK' } }
        { Assert-LabIsolation -Config $c } | Should -Throw -ExpectedMessage '*not on the analysis LAN segment*'
        Should -Invoke Invoke-LabGuestScript -ModuleName LabCommon -Times 0 -Exactly
    }
}

Describe 'Test-LabRelaysRunning' {
    BeforeAll { $cfg = @{ VmxPath = 'C:\vm\x.vmx'; GuestUser = 'u'; GuestPassword = 'p' } }

    It 'needs both relay processes' {
        Mock Invoke-Vmrun -ModuleName LabCommon -ParameterFilter { $Command -eq 'listProcessesInGuest' } {
            [pscustomobject]@{ GuestExitCode = 0; Output = "pid=1, owner=REVLAB\analyst, cmd=pythonw.exe`npid=2, owner=x, cmd=explorer.exe" }
        }
        Test-LabRelaysRunning -Config $cfg | Should -BeFalse
        Mock Invoke-Vmrun -ModuleName LabCommon -ParameterFilter { $Command -eq 'listProcessesInGuest' } {
            [pscustomobject]@{ GuestExitCode = 0; Output = "pid=1, owner=REVLAB\analyst, cmd=pythonw.exe`npid=3, owner=REVLAB\analyst, cmd=pythonw.exe" }
        }
        Test-LabRelaysRunning -Config $cfg | Should -BeTrue
    }
}

Describe 'Get-LabSessionNotice' {
    BeforeAll { $cfg = @{ VmxPath = 'C:\vm\x.vmx' } }

    It 'says nothing when the VM is running isolated' {
        Mock Test-LabVmRunning -ModuleName LabCommon { $true }
        Mock Get-LabVmxNetworkMode -ModuleName LabCommon { 'Analysis' }
        Get-LabSessionNotice -Config $cfg | Should -BeNullOrEmpty
    }

    It 'tells Claude the guest is online for <Why>' -ForEach @(
        @{ Why = 'a case policy'; NetCase = 'ctf'; Expected = "*NAT*Internet*case 'ctf'*" }
        @{ Why = 'a manual Setup session'; NetCase = $null; Expected = '*NAT*Internet*net.ps1 -Mode Setup*' }
    ) {
        Mock Test-LabVmRunning -ModuleName LabCommon { $true }
        Mock Get-LabVmxNetworkMode -ModuleName LabCommon { 'Setup' }
        Mock Get-LabNetCase -ModuleName LabCommon { $NetCase }
        $notice = Get-LabSessionNotice -Config $cfg | ConvertFrom-Json
        $notice.systemMessage | Should -BeLike $Expected
        $notice.hookSpecificOutput.hookEventName | Should -Be 'SessionStart'
        $notice.hookSpecificOutput.additionalContext | Should -BeLike '*host and its LAN*'
    }

    It 'warns when the NIC is on a network the lab does not know (e.g. bridged)' {
        Mock Test-LabVmRunning -ModuleName LabCommon { $true }
        Mock Get-LabVmxNetworkMode -ModuleName LabCommon { 'Unknown' }
        $notice = Get-LabSessionNotice -Config $cfg | ConvertFrom-Json
        $notice.systemMessage | Should -BeLike '*not on the analysis segment*'
        $notice.hookSpecificOutput.additionalContext | Should -BeLike '*may reach*'
    }

    It 'warns the user and Claude when the VM is off' {
        Mock Test-LabVmRunning -ModuleName LabCommon { $false }
        $notice = Get-LabSessionNotice -Config $cfg | ConvertFrom-Json
        $notice.systemMessage | Should -BeLike '*not running*reset.ps1*/mcp*'
        $notice.hookSpecificOutput.hookEventName | Should -Be 'SessionStart'
        $notice.hookSpecificOutput.additionalContext | Should -BeLike '*not running*reset.ps1*'
    }

    It 'reports a failed check instead of failing the hook' {
        Mock Test-LabVmRunning -ModuleName LabCommon { throw 'vmrun.exe not found' }
        (Get-LabSessionNotice -Config $cfg | ConvertFrom-Json).systemMessage | Should -BeLike '*Could not check*vmrun.exe not found*'
    }
}
