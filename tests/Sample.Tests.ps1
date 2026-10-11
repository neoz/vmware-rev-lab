BeforeAll {
    Import-Module "$PSScriptRoot/../scripts/lib/LabCommon.psm1" -Force
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    function New-TestZip([string[]]$Names) {
        $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir | Out-Null
        foreach ($n in $Names) { Set-Content -Path (Join-Path $dir $n) -Value 'x' }
        $zip = "$dir.zip"
        Compress-Archive -Path (Join-Path $dir '*') -DestinationPath $zip
        $zip
    }
}

Describe 'Get-LabSampleEntry' {
    It 'returns the only file' {
        Get-LabSampleEntry -ZipPath (New-TestZip 'a.exe') | Should -Be 'a.exe'
    }

    It 'requires -Sample when the zip has several files and lists them' {
        $zip = New-TestZip 'a.exe', 'b.dll'
        { Get-LabSampleEntry -ZipPath $zip } | Should -Throw -ExpectedMessage '*2 files*a.exe*b.dll*'
    }

    It 'picks the named file' {
        Get-LabSampleEntry -ZipPath (New-TestZip 'a.exe', 'b.ps1') -Sample 'b.ps1' | Should -Be 'b.ps1'
    }

    It 'rejects a -Sample name that is not in the zip' {
        { Get-LabSampleEntry -ZipPath (New-TestZip 'a.exe') -Sample 'zzz.exe' } | Should -Throw -ExpectedMessage "*'zzz.exe' is not in*"
    }

    It 'rejects a file without a supported extension' {
        { Get-LabSampleEntry -ZipPath (New-TestZip 'deadbeef') } | Should -Throw -ExpectedMessage '*Unsupported sample type*rename*'
    }

    It 'requires -Export for a DLL' {
        { Get-LabSampleEntry -ZipPath (New-TestZip 'x.dll') } | Should -Throw -ExpectedMessage '*-Export*'
        Get-LabSampleEntry -ZipPath (New-TestZip 'x.dll') -Export 'DllRegisterServer' | Should -Be 'x.dll'
    }

    It 'rejects an empty archive' {
        $empty = Join-Path $TestDrive 'empty.zip'
        [System.IO.Compression.ZipFile]::Open($empty, 'Create').Dispose()
        { Get-LabSampleEntry -ZipPath $empty } | Should -Throw -ExpectedMessage '*0 files*'
    }
}

Describe 'Get-LabSampleEntry duplicates' {
    It 'rejects a name that appears in more than one folder of the zip' {
        $dir = Join-Path $TestDrive 'dup'
        New-Item -ItemType Directory -Force (Join-Path $dir 'a'), (Join-Path $dir 'b') | Out-Null
        Set-Content (Join-Path $dir 'a/x.exe') 'x'
        Set-Content (Join-Path $dir 'b/x.exe') 'y'
        $zip = Join-Path $TestDrive 'dup.zip'
        Compress-Archive -Path (Join-Path $dir '*') -DestinationPath $zip
        { Get-LabSampleEntry -ZipPath $zip -Sample 'x.exe' } | Should -Throw -ExpectedMessage "*'x.exe' appears 2 times*"
    }
}

Describe 'Assert-LabCaseName' {
    It 'accepts simple case names' {
        { Assert-LabCaseName 'emotet_2026-10.v1' } | Should -Not -Throw
    }

    It 'rejects names that leave cases/' {
        foreach ($bad in '..', '..\x', 'a/b', 'a\b', '', '.hidden') {
            { Assert-LabCaseName $bad } | Should -Throw -ExpectedMessage '*Invalid case name*'
        }
    }
}

Describe 'Text fetch guards' {
    It 'allows known text extensions only' {
        { Assert-LabTextFetchPath 'C:\lab\out\static\capa.json' } | Should -Not -Throw
        foreach ($bad in 'C:\lab\in\sample\x.exe', 'C:\lab\out\dump.bin', 'C:\lab\out\noext') {
            { Assert-LabTextFetchPath $bad } | Should -Throw -ExpectedMessage '*not a text file*'
        }
    }

    It 'rejects a fetched file that is really a PE' {
        $pe = Join-Path $TestDrive 'fake.txt'
        [System.IO.File]::WriteAllBytes($pe, [byte[]](0x4D, 0x5A, 0x90, 0x00))
        { Assert-LabNotPe $pe } | Should -Throw -ExpectedMessage '*PE file*'
        $txt = Join-Path $TestDrive 'real.txt'
        Set-Content $txt 'hello'
        { Assert-LabNotPe $txt } | Should -Not -Throw
    }
}

Describe 'Start-LabSample' {
    BeforeEach {
        $runDir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $runDir | Out-Null
        $cfg = @{ Root = (Resolve-Path "$PSScriptRoot/..").Path; LabDir = (Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))) }
        Mock Copy-LabToGuest -ModuleName LabCommon {}
        Mock Invoke-LabGuestScript -ModuleName LabCommon { [pscustomobject]@{ ExitCode = 0; Output = '' } }
    }

    It 'writes a run file that launches under cdb -server when a debugger is given' {
        Start-LabSample -Config $cfg -SamplePath 'C:\lab\in\sample\a b.exe' -RunDir $runDir -SampleArgs '-x' -Debugger 'C:\dbg\cdb.exe'
        $run = Get-Content (Join-Path $runDir 'run.json') -Raw | ConvertFrom-Json
        $run.Path | Should -Be 'C:\lab\in\sample\a b.exe'
        $run.Debugger | Should -Be 'C:\dbg\cdb.exe'
        $run.Pipe | Should -Be 'revlab-dbg'
    }

    It 'throws when the guest launch fails' {
        Mock Invoke-LabGuestScript -ModuleName LabCommon { [pscustomobject]@{ ExitCode = 1; Output = 'not a valid Win32 application' } }
        { Start-LabSample -Config $cfg -SamplePath 'C:\x.exe' -RunDir $runDir } | Should -Throw -ExpectedMessage '*did not start*Win32*'
    }
}
