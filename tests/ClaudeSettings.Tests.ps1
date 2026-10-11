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
            '^(vm_delete|vmrun_delete|snapshot_delete|vmrun_snapshot_delete)$', '^(vmrun_var_write|config_set|vmrun_device_connect)$'
        )
        $mustDeny = $tools | Where-Object { $t = $_; $patterns | Where-Object { $t -match $_ } }
        $mustDeny | Should -Not -BeNullOrEmpty
        $mustDeny | Where-Object { $_ -notin $deny } | Should -BeNullOrEmpty
    }
}
