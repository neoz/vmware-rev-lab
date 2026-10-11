BeforeAll {
    Import-Module "$PSScriptRoot/../scripts/lib/LabCommon.psm1" -Force
}

Describe 'Get-LabConfig' {
    BeforeEach {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $root | Out-Null
        Copy-Item "$PSScriptRoot/../lab.config.psd1" $root
    }

    It 'loads committed defaults and derived paths' {
        $c = Get-LabConfig -Root $root
        $c.SnapshotName | Should -Be 'clean'
        $c.Root | Should -Be $root
        $c.StatePath | Should -Be (Join-Path $root '.lab' 'state.json')
        $c.Vmrun | Should -Be (Join-Path $c.VmwareDir 'vmrun.exe')
        $c.Vmcli | Should -Be (Join-Path $c.VmwareDir 'vmcli.exe')
        $c.VdiskManager | Should -Be (Join-Path $c.VmwareDir 'vmware-vdiskmanager.exe')
    }

    It 'overlays lab.local.psd1 on the defaults' {
        Save-LabLocalConfig -Root $root -Values @{ SnapshotName = 'other'; GuestPassword = 'Abc123' }
        $c = Get-LabConfig -Root $root
        $c.SnapshotName | Should -Be 'other'
        $c.GuestPassword | Should -Be 'Abc123'
    }

    It 'merges new local values with existing ones' {
        Save-LabLocalConfig -Root $root -Values @{ GuestPassword = 'Abc123' }
        Save-LabLocalConfig -Root $root -Values @{ IsoPath = 'D:\x.iso' }
        $c = Get-LabConfig -Root $root
        $c.GuestPassword | Should -Be 'Abc123'
        $c.IsoPath | Should -Be 'D:\x.iso'
    }

    It 'round-trips values containing single quotes' {
        Save-LabLocalConfig -Root $root -Values @{ IsoPath = "D:\it's.iso" }
        (Get-LabConfig -Root $root).IsoPath | Should -Be "D:\it's.iso"
    }
}

Describe 'New-LabPassword' {
    It 'returns 20 alphanumeric chars with upper, lower and digit' {
        foreach ($i in 1..50) {
            $p = New-LabPassword
            $p | Should -MatchExactly '^[A-Za-z0-9]{20}$'
            $p | Should -MatchExactly '[A-Z]'
            $p | Should -MatchExactly '[a-z]'
            $p | Should -MatchExactly '[0-9]'
        }
    }
}
