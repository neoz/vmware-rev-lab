BeforeAll {
    Import-Module "$PSScriptRoot/../scripts/lib/LabCommon.psm1" -Force
}

Describe 'Case network policy file' {
    BeforeEach {
        $cfg = @{ Root = (Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))) }
        New-Item -ItemType Directory -Force -Path $cfg.Root | Out-Null
        $writePolicy = { param($text) $dir = Join-Path $cfg.Root 'cases/ctf'; New-Item -ItemType Directory -Force -Path $dir | Out-Null; Set-Content (Join-Path $dir 'case.psd1') $text }
    }

    It 'is Isolated when the case has no policy file' {
        Get-LabCaseNetwork -Config $cfg -Case 'ctf' | Should -Be 'Isolated'
    }

    It 'round trips both values and creates the case folder' {
        Set-LabCaseNetworkPolicy -Config $cfg -Case 'ctf' -Network Internet
        Get-LabCaseNetwork -Config $cfg -Case 'ctf' | Should -BeExactly 'Internet'
        Set-LabCaseNetworkPolicy -Config $cfg -Case 'ctf' -Network Isolated
        Get-LabCaseNetwork -Config $cfg -Case 'ctf' | Should -BeExactly 'Isolated'
    }

    It 'normalises the casing of a hand-written value' {
        & $writePolicy "@{ Network = 'internet' }"
        Get-LabCaseNetwork -Config $cfg -Case 'ctf' | Should -BeExactly 'Internet'
    }

    It 'refuses <Text>' -ForEach @(
        @{ Text = "@{ Network = 'Online' }" }
        @{ Text = "@{ Network = 'Internet'; Proxy = 'x' }" }
        @{ Text = '@{ }' }
    ) {
        & $writePolicy $Text
        { Get-LabCaseNetwork -Config $cfg -Case 'ctf' } | Should -Throw -ExpectedMessage "*case.psd1*'Isolated'*'Internet'*case-net.ps1*"
    }

    It 'rejects a case name that leaves cases/' {
        { Set-LabCaseNetworkPolicy -Config $cfg -Case '..\x' -Network Internet } | Should -Throw -ExpectedMessage '*Invalid case name*'
        { Get-LabCaseNetwork -Config $cfg -Case '..\x' } | Should -Throw -ExpectedMessage '*Invalid case name*'
    }
}
