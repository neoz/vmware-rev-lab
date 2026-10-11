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
