BeforeDiscovery {
    $script:serverPy = Join-Path $PSScriptRoot '../tools/vmware-mcp/src/vmware_mcp/server.py'
    $script:hasServer = Test-Path $script:serverPy
}

BeforeAll {
    $settings = Get-Content (Join-Path $PSScriptRoot '../.claude/settings.json') -Raw | ConvertFrom-Json
    $prefix = 'mcp__vmware-mcp__'
    $deny = @($settings.permissions.deny | Where-Object { $_.StartsWith($prefix) } | ForEach-Object { $_.Substring($prefix.Length) })
    $allow = @($settings.permissions.allow | Where-Object { $_.StartsWith($prefix) } | ForEach-Object { $_.Substring($prefix.Length) })
    $serverPy = Join-Path $PSScriptRoot '../tools/vmware-mcp/src/vmware_mcp/server.py'
    $tools = if (Test-Path $serverPy) {
        @([regex]::Matches((Get-Content $serverPy -Raw), 'T\("([a-z0-9_]+)"') | ForEach-Object { $_.Groups[1].Value })
    } else { @() }
}

Describe '.claude/settings.json' {
    It 'denies the user-only network scripts, direct VM config, the vmrun binary and its risky verbs' {
        $verbs = 'copyFileFromGuestToHost', 'SharedFolder', 'deleteSnapshot', 'deleteVM', 'writeVariable', 'NamedDevice'
        $rules = @('Bash(*net.ps1*Setup*)', 'PowerShell(*net.ps1*Setup*)', 'Bash(*add-tool.ps1*)', 'PowerShell(*add-tool.ps1*)', 'Edit(**/*.vmx)')
        foreach ($tool in 'Bash', 'PowerShell') {
            $rules += "$tool(vmrun)", "$tool(vmrun *)", "$tool(*vmrun.exe*)", "$tool(*vmrun -T*)", "$tool(*vmrun*.vmx*)",
                      "$tool(*vmrun`"*)", "$tool(*vmrun'*)"
            $rules += $verbs | ForEach-Object { "$tool(*$_*)" }
        }
        foreach ($rule in $rules) { $settings.permissions.deny | Should -Contain $rule }
    }

    It 'does not deny every command that merely mentions vmrun' {
        $settings.permissions.deny | Should -Not -Contain 'Bash(*vmrun*)'
        $settings.permissions.deny | Should -Not -Contain 'PowerShell(*vmrun*)'
    }

    Context 'shell deny rules, matched the way Claude Code documents (* is any text, case-insensitive)' {
        BeforeAll {
            function Test-Denied([string]$Tool, [string]$Command) {
                foreach ($rule in $settings.permissions.deny) {
                    if ($rule -notmatch "^$Tool\((.*)\)$") { continue }
                    $pattern = '^' + ([regex]::Escape($Matches[1]) -replace '\\\*', '.*') + '$'
                    if ($Command -match $pattern) { return $true }
                }
                $false
            }
        }

        It 'denies <Command>' -ForEach @(
            @{ Command = 'vmrun -T ws list' }
            @{ Command = 'vmrun' }
            @{ Command = "& 'C:\Program Files (x86)\VMware\VMware Workstation\vmrun.exe' -T ws list" }
            @{ Command = 'vmrun.exe -T ws listSnapshots C:\vm\x.vmx' }
            @{ Command = 'tool -T ws copyFileFromGuestToHost x.vmx a b' }
            @{ Command = 'tool -T ws enableSharedFolders x.vmx' }
            @{ Command = 'tool -T ws deleteSnapshot x.vmx clean' }
            @{ Command = 'tool -T ws writeVariable x.vmx runtimeConfig a b' }
            @{ Command = '& "C:\Program Files (x86)\VMware\VMware Workstation\vmrun" -T ws list' }
            @{ Command = 'cmd /c vmrun -T ws snapshot C:\vm\x.vmx before' }
            @{ Command = 'pwsh -NoProfile -Command "vmrun -T ws clone C:\vm\x.vmx C:\vm\y.vmx full"' }
            @{ Command = "'vmrun' list" }
            @{ Command = 'Start-Process vmrun -ArgumentList start,C:\vm\x.vmx' }
        ) {
            Test-Denied 'PowerShell' $Command | Should -BeTrue
            Test-Denied 'Bash' $Command | Should -BeTrue
        }

        It 'allows <Command>' -ForEach @(
            @{ Command = 'Invoke-Pester -Path tests/Vmrun.Tests.ps1 -Output Detailed' }
            @{ Command = 'git commit -m "fix: vmrun start gui hang"' }
            @{ Command = 'git log -S vmrun -- .claude/settings.json' }
            @{ Command = 'pwsh -File scripts/reset.ps1' }
        ) {
            Test-Denied 'PowerShell' $Command | Should -BeFalse
            Test-Denied 'Bash' $Command | Should -BeFalse
        }
    }

    It 'uses only Edit(path) for file rules (Claude Code ignores Write(path) and warns on start)' {
        $settings.permissions.deny + $settings.permissions.allow | Where-Object { $_ -like 'Write(*' } | Should -BeNullOrEmpty
    }

    It 'runs check-vm.ps1 at session start' {
        $hook = $settings.hooks.SessionStart.hooks | Where-Object { $_.command -like '*scripts/check-vm.ps1*' }
        $hook | Should -Not -BeNullOrEmpty
        Test-Path (Join-Path $PSScriptRoot '../scripts/check-vm.ps1') | Should -BeTrue
    }

    It 'never allows and denies the same tool' {
        $allow | Where-Object { $_ -in $deny } | Should -BeNullOrEmpty
    }

    It 'only names tools that exist in the pinned vmware-mcp' -Skip:(-not $hasServer) {
        @($allow + $deny) | Where-Object { $_ -notin $tools } | Should -BeNullOrEmpty
    }

    It 'denies every tool that changes networking, sharing, VM config or deletes things' -Skip:(-not $hasServer) {
        $patterns = @(
            '^ethernet_(set_|purge)', '^vm_nic_(create|delete)$', '^network_(create|portforward_set|portforward_delete)$',
            '^vmrun_portforward_(set|delete)$', '^vmrun_shared_(enable|add|set)$', '^hgfs_set_', '^vm_folder_(create|delete)$',
            '^(vm_delete|vmrun_delete|snapshot_delete|vmrun_snapshot_delete)$', '^(vmrun_var_write|config_set|vmrun_device_connect)$',
            '^(vmrun_copy_from|guest_copy_from)$', '^(vmrun_snapshot_take|snapshot_take|snapshot_clone|vmrun_clone)$',
            '^(template_create|template_deploy|vm_create)$', '^serial_(set_present|purge)$'
        )
        $mustDeny = $tools | Where-Object { $t = $_; $patterns | Where-Object { $t -match $_ } }
        $mustDeny | Should -Not -BeNullOrEmpty
        $mustDeny | Where-Object { $_ -notin $deny } | Should -BeNullOrEmpty
    }
}
