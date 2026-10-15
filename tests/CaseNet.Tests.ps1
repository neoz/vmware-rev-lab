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

Describe 'Switch-LabNetwork' {
    BeforeEach {
        $cfg = @{ LabDir = (Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))) }
        New-Item -ItemType Directory -Force -Path $cfg.LabDir | Out-Null
        $global:NetOps = [System.Collections.Generic.List[string]]::new()
        Mock Stop-LabVm -ModuleName LabCommon { $global:NetOps.Add('stop') }
        Mock Set-LabVmxNetwork -ModuleName LabCommon { $global:NetOps.Add("vmx $Mode") }
        Mock Start-LabVm -ModuleName LabCommon { $global:NetOps.Add('start') }
        Mock Wait-LabTools -ModuleName LabCommon { $global:NetOps.Add('tools') }
        Mock Set-LabGuestNetwork -ModuleName LabCommon { $global:NetOps.Add("guest $Mode") }
        Mock Assert-LabIsolation -ModuleName LabCommon { $global:NetOps.Add('isolation') }
    }

    It 'power cycles onto NAT without an isolation check and keeps the marker' {
        Set-Content (Join-Path $cfg.LabDir 'case-net.txt') 'ctf'
        Switch-LabNetwork -Config $cfg -Mode Setup
        $global:NetOps -join ',' | Should -Be 'stop,vmx Setup,start,tools,guest Setup'
        Get-LabNetCase -Config $cfg | Should -Be 'ctf'
    }

    It 'checks isolation after going back and only then removes the marker' {
        Set-Content (Join-Path $cfg.LabDir 'case-net.txt') 'ctf'
        Switch-LabNetwork -Config $cfg -Mode Analysis
        $global:NetOps -join ',' | Should -Be 'stop,vmx Analysis,start,tools,guest Analysis,isolation'
        Get-LabNetCase -Config $cfg | Should -BeNullOrEmpty
    }

    It 'keeps the marker when the isolation check fails' {
        Set-Content (Join-Path $cfg.LabDir 'case-net.txt') 'ctf'
        Mock Assert-LabIsolation -ModuleName LabCommon { throw 'Isolation check failed: 8.8.8.8 reachable' }
        { Switch-LabNetwork -Config $cfg -Mode Analysis } | Should -Throw -ExpectedMessage '*8.8.8.8*'
        Get-LabNetCase -Config $cfg | Should -Be 'ctf'
    }
}

Describe 'Set-LabCaseNetwork' {
    BeforeEach {
        $cfg = @{ Root = (Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))) }
        $cfg.LabDir = Join-Path $cfg.Root '.lab'
        New-Item -ItemType Directory -Force -Path $cfg.LabDir | Out-Null
        $marker = Join-Path $cfg.LabDir 'case-net.txt'
        Mock Write-LabLog -ModuleName LabCommon {}
        Mock Switch-LabNetwork -ModuleName LabCommon {}
    }

    It 'leaves an isolated case on the analysis segment alone' {
        Mock Get-LabVmxNetworkMode -ModuleName LabCommon { 'Analysis' }
        Set-LabCaseNetwork -Config $cfg -Case 'ctf' | Should -Be 'Isolated'
        Should -Invoke Switch-LabNetwork -ModuleName LabCommon -Times 0 -Exactly
        Test-Path $marker | Should -BeFalse
    }

    It 'writes the marker before switching an Internet case to NAT' {
        Set-LabCaseNetworkPolicy -Config $cfg -Case 'ctf' -Network Internet
        Mock Get-LabVmxNetworkMode -ModuleName LabCommon { 'Analysis' }
        Mock Switch-LabNetwork -ModuleName LabCommon { (Get-Content $marker -Raw).Trim() | Should -Be 'ctf' }
        Set-LabCaseNetwork -Config $cfg -Case 'ctf' | Should -Be 'Internet'
        Should -Invoke Switch-LabNetwork -ModuleName LabCommon -Times 1 -Exactly -ParameterFilter { $Mode -eq 'Setup' }
    }

    It 'does not power cycle an Internet case that is already on NAT' {
        Set-LabCaseNetworkPolicy -Config $cfg -Case 'ctf' -Network Internet
        Set-Content $marker 'ctf'
        Mock Get-LabVmxNetworkMode -ModuleName LabCommon { 'Setup' }
        Set-LabCaseNetwork -Config $cfg -Case 'ctf' | Should -Be 'Internet'
        Should -Invoke Switch-LabNetwork -ModuleName LabCommon -Times 0 -Exactly
    }

    It 'brings an isolated case back from a case-driven NAT' {
        Set-Content $marker 'ctf'
        Mock Get-LabVmxNetworkMode -ModuleName LabCommon { 'Setup' }
        Set-LabCaseNetwork -Config $cfg -Case 'ctf' | Should -Be 'Isolated'
        Should -Invoke Switch-LabNetwork -ModuleName LabCommon -Times 1 -Exactly -ParameterFilter { $Mode -eq 'Analysis' }
    }

    It 'refuses <Mode> without a marker (manual Setup session or hand-edited VMX)' -ForEach @(
        @{ Mode = 'Setup' }
        @{ Mode = 'Unknown' }
    ) {
        Set-LabCaseNetworkPolicy -Config $cfg -Case 'ctf' -Network Internet
        Mock Get-LabVmxNetworkMode -ModuleName LabCommon { $Mode }
        { Set-LabCaseNetwork -Config $cfg -Case 'ctf' } | Should -Throw -ExpectedMessage '*net.ps1 -Mode Analysis*'
        Should -Invoke Switch-LabNetwork -ModuleName LabCommon -Times 0 -Exactly
        Test-Path $marker | Should -BeFalse
    }
}
