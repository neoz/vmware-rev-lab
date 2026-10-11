BeforeAll {
    Import-Module "$PSScriptRoot/../scripts/lib/LabCommon.psm1" -Force
}

Describe 'Invoke-LabPhases' {
    BeforeEach {
        $global:LabRan = [System.Collections.Generic.List[string]]::new()
        $state = Join-Path $TestDrive "state-$([guid]::NewGuid().ToString('N')).json"
        $phases = [ordered]@{
            A = { $global:LabRan.Add('A') }
            B = { $global:LabRan.Add('B') }
            C = { $global:LabRan.Add('C') }
        }
    }

    It 'runs all phases in order and records them' {
        Invoke-LabPhases -Phases $phases -StatePath $state
        $global:LabRan -join ',' | Should -Be 'A,B,C'
        (Get-Content $state -Raw | ConvertFrom-Json).Completed -join ',' | Should -Be 'A,B,C'
    }

    It 'skips completed phases on rerun' {
        Invoke-LabPhases -Phases $phases -StatePath $state
        $global:LabRan.Clear()
        Invoke-LabPhases -Phases $phases -StatePath $state
        $global:LabRan.Count | Should -Be 0
    }

    It 'reruns the -From phase and everything after it' {
        Invoke-LabPhases -Phases $phases -StatePath $state
        $global:LabRan.Clear()
        Invoke-LabPhases -Phases $phases -StatePath $state -From B
        $global:LabRan -join ',' | Should -Be 'B,C'
    }

    It 'stops at a failing phase and keeps earlier progress' {
        $phases.B = { throw 'boom' }
        { Invoke-LabPhases -Phases $phases -StatePath $state } | Should -Throw -ExpectedMessage '*boom*'
        $global:LabRan -join ',' | Should -Be 'A'
        (Get-Content $state -Raw | ConvertFrom-Json).Completed -join ',' | Should -Be 'A'
    }

    It 'rejects an unknown -From phase' {
        { Invoke-LabPhases -Phases $phases -StatePath $state -From Nope } |
            Should -Throw -ExpectedMessage "*Unknown phase 'Nope'*"
    }
}
