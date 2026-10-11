BeforeAll {
    Import-Module "$PSScriptRoot/../scripts/lib/LabCommon.psm1" -Force
}

Describe 'Test-LabIsoHash' {
    BeforeAll {
        $file = Join-Path $TestDrive 'fake.iso'
        Set-Content -Path $file -Value 'not an iso' -NoNewline
        $hash = (Get-FileHash $file -Algorithm SHA256).Hash
    }

    It 'accepts a matching hash, case-insensitively' {
        { Test-LabIsoHash -Path $file -Expected $hash.ToLower() } | Should -Not -Throw
    }

    It 'names both hashes and the config key on mismatch' {
        { Test-LabIsoHash -Path $file -Expected ('0' * 64) } |
            Should -Throw -ExpectedMessage "*$hash*$('0' * 64)*IsoSha256*"
    }
}

Describe 'Assert-LabVmAbsent' {
    It 'passes when no VM exists' {
        { Assert-LabVmAbsent -Config @{ VmxPath = (Join-Path $TestDrive 'none.vmx') } } | Should -Not -Throw
    }

    It 'refuses when a VM already exists and leaves it untouched' {
        $vmx = Join-Path $TestDrive 'exists.vmx'
        Set-Content $vmx 'displayName = "keep"'
        { Assert-LabVmAbsent -Config @{ VmxPath = $vmx } } | Should -Throw -ExpectedMessage '*already exists*'
        Get-Content $vmx -Raw | Should -Match 'keep'
    }
}

Describe 'New-LabMcpJson' {
    It 'points at the venv entry point and sets vmrun/vmcli paths' {
        $cfg = @{ Root = 'D:\lab'; Vmrun = 'C:\VMware\vmrun.exe'; Vmcli = 'C:\VMware\vmcli.exe' }
        $json = New-LabMcpJson -Config $cfg | ConvertFrom-Json
        $server = $json.mcpServers.'vmware-mcp'
        $server.command | Should -Be 'D:\lab\tools\vmware-mcp\.venv\Scripts\vmware-mcp.exe'
        $server.env.VMRUN_PATH | Should -Be 'C:\VMware\vmrun.exe'
        $server.env.VMCLI_PATH | Should -Be 'C:\VMware\vmcli.exe'
        $server.env.VMWARE_USERNAME | Should -Be '${VMWARE_USERNAME:-}'
    }
}

Describe 'New-LabVm' {
    BeforeEach {
        $vmDir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $c = @{ VmxPath = (Join-Path $vmDir 'revlab.vmx'); Cpu = 2; MemoryMB = 2048; DiskGB = 10; ToolsIso = 'C:\t.iso'; VdiskManager = 'vdisk.exe' }
    }

    It 'writes the VMX and creates the disk' {
        Mock Invoke-LabProcess -ModuleName LabCommon { [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' } }
        New-LabVm -Config $c -WindowsIso 'C:\w.iso' -AnswerIso 'C:\a.iso'
        Test-Path $c.VmxPath | Should -BeTrue
        Should -Invoke Invoke-LabProcess -ModuleName LabCommon -Times 1 -Exactly -ParameterFilter { $ArgumentList[-1] -like '*revlab.vmdk' }
    }

    It 'removes what it created when the disk cannot be created' {
        Mock Invoke-LabProcess -ModuleName LabCommon { [pscustomobject]@{ ExitCode = 1; StdOut = 'no space'; StdErr = '' } }
        { New-LabVm -Config $c -WindowsIso 'C:\w.iso' -AnswerIso 'C:\a.iso' } | Should -Throw -ExpectedMessage '*no space*'
        Test-Path $vmDir | Should -BeFalse
    }

    It 'refuses to touch an existing VM' {
        New-Item -ItemType Directory -Force $vmDir | Out-Null
        Set-Content $c.VmxPath 'displayName = "keep"'
        { New-LabVm -Config $c -WindowsIso 'C:\w.iso' -AnswerIso 'C:\a.iso' } | Should -Throw -ExpectedMessage '*already exists*'
        Get-Content $c.VmxPath -Raw | Should -Match 'keep'
    }
}

Describe 'Assert-LabFreshVmSlot' {
    It 'refuses an existing VM before CreateVm has run' {
        $vmx = Join-Path $TestDrive 'old.vmx'
        Set-Content $vmx 'x'
        $c = @{ VmxPath = $vmx; StatePath = (Join-Path $TestDrive 'none.json') }
        { Assert-LabFreshVmSlot -Config $c } | Should -Throw -ExpectedMessage '*already exists*'
    }

    It 'accepts the VM once CreateVm is recorded' {
        $vmx = Join-Path $TestDrive 'mine.vmx'
        Set-Content $vmx 'x'
        $state = Join-Path $TestDrive 'state.json'
        '{"Completed":["Preflight","CreateVm"]}' | Set-Content $state
        { Assert-LabFreshVmSlot -Config @{ VmxPath = $vmx; StatePath = $state } } | Should -Not -Throw
    }
}

Describe 'Save-LabIso' {
    BeforeEach {
        $iso = Join-Path $TestDrive "dl-$([guid]::NewGuid().ToString('N')).iso"
        $global:CurlCalls = 0
    }

    It 'deletes a broken partial file and downloads again from scratch' {
        Set-Content $iso 'corrupt but full size'
        Mock Invoke-LabProcess -ModuleName LabCommon {
            $global:CurlCalls++
            if ($global:CurlCalls -eq 1) { return [pscustomobject]@{ ExitCode = 22; StdOut = ''; StdErr = '416' } }
            Set-Content -Path $ArgumentList[-2] -Value 'good' -NoNewline
            [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' }
        }
        $hash = (Get-FileHash -InputStream ([IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes('good')))).Hash
        Save-LabIso -Url 'https://x/y.iso' -Path $iso -Sha256 $hash
        $global:CurlCalls | Should -Be 2
        Get-Content $iso -Raw | Should -Be 'good'
    }

    It 'deletes a downloaded file whose hash does not match' {
        Mock Invoke-LabProcess -ModuleName LabCommon {
            Set-Content -Path $ArgumentList[-2] -Value 'evil' -NoNewline
            [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' }
        }
        { Save-LabIso -Url 'https://x/y.iso' -Path $iso -Sha256 ('0' * 64) } | Should -Throw -ExpectedMessage '*SHA256 mismatch*'
        Test-Path $iso | Should -BeFalse
    }

    It 'skips the download when the file already matches' {
        Set-Content $iso 'good' -NoNewline
        Mock Invoke-LabProcess -ModuleName LabCommon { throw 'should not download' }
        $hash = (Get-FileHash $iso).Hash
        { Save-LabIso -Url 'https://x/y.iso' -Path $iso -Sha256 $hash } | Should -Not -Throw
    }
}
