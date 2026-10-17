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
    BeforeAll {
        $cfg = @{ Root = 'D:\lab'; Vmrun = 'C:\VMware\vmrun.exe'; Vmcli = 'C:\VMware\vmcli.exe'; VmxPath = 'D:\vm\revlab.vmx'
                  GuestUser = 'analyst'; McpGhidraPort = 5001; McpWindbgPort = 5002 }
        $json = New-LabMcpJson -Config $cfg | ConvertFrom-Json
    }

    It 'points vmware-mcp at the venv entry point and sets vmrun/vmcli paths' {
        $server = $json.mcpServers.'vmware-mcp'
        $server.command | Should -Be 'D:\lab\tools\vmware-mcp\.venv\Scripts\vmware-mcp.exe'
        $server.env.VMRUN_PATH | Should -Be 'C:\VMware\vmrun.exe'
        $server.env.VMCLI_PATH | Should -Be 'C:\VMware\vmcli.exe'
        $server.env.VMWARE_USERNAME | Should -Be '${VMWARE_USERNAME:-}'
    }

    It 'adds the two vSocket bridges with their port and relay task' {
        foreach ($case in @(@{ Name = 'revlab-ghidra'; Port = '5001'; Task = 'RevlabMcpGhidra' },
                            @{ Name = 'revlab-windbg'; Port = '5002'; Task = 'RevlabMcpWindbg' })) {
            $server = $json.mcpServers.($case.Name)
            $server.command | Should -Be 'D:\lab\tools\vmware-mcp\.venv\Scripts\python.exe'
            $server.args[0] | Should -Be '-I'
            $server.args[1] | Should -Be 'D:\lab\scripts\mcp\revlab_bridge.py'
            ($server.args -join ' ') | Should -Match "--port $($case.Port) --task $($case.Task) "
            ($server.args -join ' ') | Should -Match '--vmx D:\\vm\\revlab.vmx'
            ($server.args -join ' ') | Should -Match '--local-config D:\\lab\\lab.local.psd1'
        }
    }

    It 'leaves out revlab-ida until add-ida.ps1 has recorded AddIda' {
        $json.mcpServers.PSObject.Properties.Name | Should -Not -Contain 'revlab-ida'
        $state = Join-Path $TestDrive 'no-ida-state.json'
        '{"Completed":["Preflight","McpBridge"]}' | Set-Content $state
        $noIda = New-LabMcpJson -Config ($cfg + @{ StatePath = $state; McpIdaPort = 5003 }) | ConvertFrom-Json
        $noIda.mcpServers.PSObject.Properties.Name | Should -Not -Contain 'revlab-ida'
    }

    It 'adds revlab-ida on its own port once AddIda is recorded, keeping the other bridges' {
        $state = Join-Path $TestDrive 'ida-state.json'
        '{"Completed":["Preflight","McpBridge","AddIda"]}' | Set-Content $state
        $withIda = New-LabMcpJson -Config ($cfg + @{ StatePath = $state; McpIdaPort = 5003 }) | ConvertFrom-Json
        $server = $withIda.mcpServers.'revlab-ida'
        $server.args[1] | Should -Be 'D:\lab\scripts\mcp\revlab_bridge.py'
        ($server.args -join ' ') | Should -Match '--port 5003 --task RevlabMcpIda '
        $withIda.mcpServers.PSObject.Properties.Name | Should -Contain 'revlab-ghidra'
        $withIda.mcpServers.PSObject.Properties.Name | Should -Contain 'revlab-windbg'
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

Describe 'Get-LabIdaInputs' {
    BeforeEach {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path (Join-Path $root 'tools/ida') | Out-Null
    }

    It 'returns the installer, the license and every file under data/, sub-folders included' {
        foreach ($name in 'ida-pro_94_x64win.exe', 'idapro.hexlic') { 'x' | Set-Content (Join-Path $root "tools/ida/$name") }
        New-Item -ItemType Directory -Force -Path (Join-Path $root 'tools/ida/data/cfg') | Out-Null
        'note' | Set-Content (Join-Path $root 'tools/ida/data/IDA-MCP.md')
        'cfg' | Set-Content (Join-Path $root 'tools/ida/data/cfg/idauser.cfg')
        $inputs = Get-LabIdaInputs -Config @{ Root = $root }
        $inputs.Installer | Should -Be (Join-Path $root 'tools/ida/ida-pro_94_x64win.exe')
        $inputs.License | Should -Be (Join-Path $root 'tools/ida/idapro.hexlic')
        $inputs.DataDir | Should -Be (Join-Path $root 'tools/ida/data')
        @($inputs.Data | Sort-Object) | Should -Be @((Join-Path $root 'tools/ida/data/cfg/idauser.cfg'), (Join-Path $root 'tools/ida/data/IDA-MCP.md') | Sort-Object)
    }

    It 'returns no data files when data/ is absent' {
        foreach ($name in 'ida-pro_94_x64win.exe', 'idapro.hexlic') { 'x' | Set-Content (Join-Path $root "tools/ida/$name") }
        @((Get-LabIdaInputs -Config @{ Root = $root }).Data).Count | Should -Be 0
    }

    It 'takes the installer of any IDA version' {
        foreach ($name in 'ida-pro_95_x64win.exe', 'idapro.hexlic') { 'x' | Set-Content (Join-Path $root "tools/ida/$name") }
        (Get-LabIdaInputs -Config @{ Root = $root }).Installer | Should -Be (Join-Path $root 'tools/ida/ida-pro_95_x64win.exe')
    }

    It 'refuses several installers' {
        foreach ($name in 'ida-pro_94_x64win.exe', 'ida-pro_95_x64win.exe', 'idapro.hexlic') { 'x' | Set-Content (Join-Path $root "tools/ida/$name") }
        { Get-LabIdaInputs -Config @{ Root = $root } } | Should -Throw -ExpectedMessage '*ida-pro_94_x64win.exe, ida-pro_95_x64win.exe*'
    }

    It 'names the missing <Missing>' -ForEach @(
        @{ Present = 'idapro.hexlic'; Missing = 'ida-pro_*_x64win.exe' }
        @{ Present = 'ida-pro_94_x64win.exe'; Missing = 'idapro.hexlic' }
    ) {
        'x' | Set-Content (Join-Path $root "tools/ida/$Present")
        { Get-LabIdaInputs -Config @{ Root = $root } } | Should -Throw -ExpectedMessage "*$Missing*"
    }
}

Describe 'Set-LabIdaInstalled' {
    It 'adds AddIda once and keeps the setup phases' {
        $state = Join-Path $TestDrive 'state-ida.json'
        '{"Completed":["Preflight","McpBridge"]}' | Set-Content $state
        Set-LabIdaInstalled -Config @{ StatePath = $state }
        Set-LabIdaInstalled -Config @{ StatePath = $state }
        Get-LabState -Path $state | Should -Be @('Preflight', 'McpBridge', 'AddIda')
    }
}
