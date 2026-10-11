BeforeAll {
    $path = Join-Path $PSScriptRoot '../templates/flare-config.xml'
    [xml]$xml = Get-Content $path -Raw
    $packages = @($xml.config.packages.package | ForEach-Object name)
}

Describe 'templates/flare-config.xml' {
    It 'keeps the FLARE environment settings' {
        @($xml.config.envs.env | ForEach-Object name) | Should -Contain 'VM_COMMON_DIR'
    }

    It 'contains the packages detonate.ps1 depends on' {
        foreach ($required in 'sysinternals.vm', 'fakenet-ng.vm', '7zip.vm') {
            $packages | Should -Contain $required
        }
    }

    It 'contains the static, debug and dynamic analysis core' {
        foreach ($core in 'ghidra.vm', 'windbg.vm', 'libraries.python3.vm', 'capa.vm', 'floss.vm', 'die.vm') {
            $packages | Should -Contain $core
        }
    }

    It 'lists each package once' {
        $packages.Count | Should -Be (@($packages | Sort-Object -Unique).Count)
    }

    It 'leaves out GUI-only tools' {
        foreach ($gui in 'x64dbg.vm', 'dnspyex.vm', 'pebear.vm', 'hxd.vm', 'cyberchef.vm', 'idafree.vm') {
            $packages | Should -Not -Contain $gui
        }
    }
}
