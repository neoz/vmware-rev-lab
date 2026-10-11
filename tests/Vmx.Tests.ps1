BeforeAll {
    Import-Module "$PSScriptRoot/../scripts/lib/LabCommon.psm1" -Force
}

Describe 'Get-LabVmxSettings' {
    BeforeAll {
        $cfg = @{ VmxPath = 'D:\vms\revlab\revlab.vmx'; Cpu = 4; MemoryMB = 8192; ToolsIso = 'C:\tools\windows.iso'; AnalysisPvnId = '52 00' }
        $s = Get-LabVmxSettings -Config $cfg -WindowsIso 'D:\iso\win.iso' -AnswerIso 'D:\iso\answer.iso'
    }

    It 'uses BIOS firmware and Windows 10 x64 guest type' {
        $s['firmware'] | Should -Be 'bios'
        $s['guestOS'] | Should -Be 'windows9-64'
        $s['virtualHW.version'] | Should -Be '20'
    }

    It 'sizes CPU and memory from config' {
        $s['numvcpus'] | Should -Be '4'
        $s['memsize'] | Should -Be '8192'
    }

    It 'attaches the disk and three CD images on SATA' {
        $s['sata0:0.fileName'] | Should -Be 'revlab.vmdk'
        $s['sata0:1.fileName'] | Should -Be 'D:\iso\win.iso'
        $s['sata0:2.fileName'] | Should -Be 'D:\iso\answer.iso'
        $s['sata0:3.fileName'] | Should -Be 'C:\tools\windows.iso'
        foreach ($i in 1..3) { $s["sata0:$i.deviceType"] | Should -Be 'cdrom-image' }
    }

    It 'declares PCIe root ports so the e1000e NIC gets a slot' {
        $s['pciBridge0.present'] | Should -Be 'TRUE'
        foreach ($i in 4..7) {
            $s["pciBridge$i.present"] | Should -Be 'TRUE'
            $s["pciBridge$i.virtualDev"] | Should -Be 'pcieRootPort'
            $s["pciBridge$i.functions"] | Should -Be '8'
        }
    }

    It 'starts on NAT for setup' {
        $s['ethernet0.connectionType'] | Should -Be 'nat'
    }

    It 'disables every host-guest sharing channel' {
        foreach ($k in 'hgfs', 'dnd', 'copy', 'paste') { $s["isolation.tools.$k.disable"] | Should -Be 'TRUE' }
        $s['sharedFolder.maxNum'] | Should -Be '0'
    }
}

Describe 'VMX text round trip and edits' {
    BeforeEach {
        $vmx = Join-Path $TestDrive 'x.vmx'
        Set-Content $vmx @(
            '.encoding = "UTF-8"'
            '# comment'
            ''
            'uuid.bios = "56 4d 12 34-56 78 9a bc"'
            'ethernet0.connectionType = "nat"'
            'sata0:0.fileName = "x.vmdk"'
            'sata0:1.present = "TRUE"'
            'sata0:1.fileName = "D:\iso\win.iso"'
            'sata0:2.fileName = "D:\iso\answer.iso"'
            'sata0:3.fileName = "C:\tools\windows.iso"'
        )
        $cfg = @{ VmxPath = $vmx; AnalysisPvnId = '52 9a 0c 61 9b 3d 4e 5f-8a 21 7c 3d 9e 4b 1a 01' }
    }

    It 'parses keys and ignores comments and blank lines' {
        $d = ConvertFrom-VmxText (Get-Content $vmx -Raw)
        $d.Count | Should -Be 8
        $d['uuid.bios'] | Should -Be '56 4d 12 34-56 78 9a bc'
    }

    It 'switches to the analysis LAN segment and back' {
        Set-LabVmxNetwork -Config $cfg -Mode Analysis
        $d = ConvertFrom-VmxText (Get-Content $vmx -Raw)
        $d['ethernet0.connectionType'] | Should -Be 'pvn'
        $d['ethernet0.pvnID'] | Should -Be $cfg.AnalysisPvnId
        Get-LabVmxNetworkMode -Config $cfg | Should -Be 'Analysis'

        Set-LabVmxNetwork -Config $cfg -Mode Setup
        $d = ConvertFrom-VmxText (Get-Content $vmx -Raw)
        $d['ethernet0.connectionType'] | Should -Be 'nat'
        $d.Contains('ethernet0.pvnID') | Should -BeFalse
        $d['uuid.bios'] | Should -Be '56 4d 12 34-56 78 9a bc'
        Get-LabVmxNetworkMode -Config $cfg | Should -Be 'Setup'
    }

    It 'reports Unknown for a different pvnID' {
        Set-LabVmxNetwork -Config $cfg -Mode Analysis
        $cfg.AnalysisPvnId = '52 00'
        Get-LabVmxNetworkMode -Config $cfg | Should -Be 'Unknown'
    }

    It 'removes install media but keeps the disk' {
        Remove-LabVmxInstallMedia -Config $cfg
        $d = ConvertFrom-VmxText (Get-Content $vmx -Raw)
        $d.Keys | Where-Object { $_ -match '^sata0:[123]\.' } | Should -BeNullOrEmpty
        $d['sata0:0.fileName'] | Should -Be 'x.vmdk'
    }
}
