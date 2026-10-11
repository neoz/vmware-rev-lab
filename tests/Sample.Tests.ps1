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
