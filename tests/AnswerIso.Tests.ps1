BeforeAll {
    Import-Module "$PSScriptRoot/../scripts/lib/LabCommon.psm1" -Force
    $script:repo = Resolve-Path "$PSScriptRoot/.."
    function Test-IsoContainsName([string]$Path, [string]$Name) {
        $latin1 = [System.Text.Encoding]::Latin1
        $haystack = $latin1.GetString([System.IO.File]::ReadAllBytes($Path))
        $needle = $latin1.GetString([System.Text.Encoding]::BigEndianUnicode.GetBytes($Name))
        $haystack.Contains($needle)
    }
}

Describe 'ConvertTo-LabUnattendXml' {
    BeforeAll {
        $cfg = @{ GuestUser = 'analyst'; GuestPassword = 'Pa<ss>&"word'; ComputerName = 'REVLAB' }
        $xmlText = ConvertTo-LabUnattendXml -Config $cfg -TemplatePath (Join-Path $repo 'templates/autounattend.xml')
    }

    It 'produces valid XML' {
        { [xml]$xmlText } | Should -Not -Throw
    }

    It 'leaves no placeholders' {
        $xmlText | Should -Not -Match '\{\{'
    }

    It 'escapes the password and keeps its value' {
        $xml = [xml]$xmlText
        $ns = @{ u = 'urn:schemas-microsoft-com:unattend' }
        $values = Select-Xml -Xml $xml -XPath '//u:Password/u:Value' -Namespace $ns | ForEach-Object { $_.Node.InnerText }
        $values | Should -Not -BeNullOrEmpty
        $values | ForEach-Object { $_ | Should -Be 'Pa<ss>&"word' }
    }

    It 'creates the configured local admin and autologon user' {
        $xmlText | Should -Match '<Name>analyst</Name>'
        $xmlText | Should -Match '<Username>analyst</Username>'
        $xmlText | Should -Match '<ComputerName>REVLAB</ComputerName>'
    }
}

Describe 'New-LabIso' {
    It 'builds an ISO containing the staged files' {
        $src = Join-Path $TestDrive 'src'
        New-Item -ItemType Directory -Force (Join-Path $src 'guest') | Out-Null
        Set-Content (Join-Path $src 'autounattend.xml') '<x/>'
        Set-Content (Join-Path $src 'guest/firstlogon.ps1') 'exit 0'
        $iso = Join-Path $TestDrive 'answer.iso'
        New-LabIso -SourceDir $src -Path $iso
        (Get-Item $iso).Length | Should -BeGreaterThan 0
        Test-IsoContainsName $iso 'autounattend.xml' | Should -BeTrue
        Test-IsoContainsName $iso 'firstlogon.ps1' | Should -BeTrue
    }
}

Describe 'New-LabAnswerIso' {
    It 'stages the rendered answer file and guest scripts' {
        $cfg = @{ Root = "$repo"; LabDir = (Join-Path $TestDrive 'lab'); GuestUser = 'analyst'; GuestPassword = 'Abc123'; ComputerName = 'REVLAB' }
        $iso = Join-Path $TestDrive 'answer2.iso'
        New-LabAnswerIso -Config $cfg -Path $iso
        Test-IsoContainsName $iso 'autounattend.xml' | Should -BeTrue
        Test-IsoContainsName $iso 'specialize.cmd' | Should -BeTrue
        Test-IsoContainsName $iso 'firstlogon.ps1' | Should -BeTrue
    }
}
