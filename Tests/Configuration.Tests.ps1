<#
    Tests/Configuration.Tests.ps1 - configuration and policy loading.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    [void](Import-WaForTest)
}

Describe 'Default configuration' -Tag 'Configuration' {

    BeforeAll { $script:config = Invoke-WaInternal { Get-WaConfiguration } }

    It 'loads and validates' {
        $script:config | Should -Not -BeNullOrEmpty
        $script:config.SchemaVersion | Should -BeGreaterThan 0
    }

    It 'ships conservative defaults' {
        $script:config.MaximumAutoApprovableRisk | Should -Be 'LOW'
        $script:config.RequireIndividualApprovalAtOrAbove | Should -Be 'HIGH'
        $script:config.AllowManualOnlyExecution | Should -BeFalse
        $script:config.AllowExternalTools | Should -BeFalse -Because 'external tools are opt-in'
    }

    It 'never implies a deep scan' {
        @($script:config.DeepScanPaths).Count | Should -Be 0 -Because 'recursion must be requested explicitly'
    }

    It 'applies a non-zero age threshold to temp and cache files' {
        $script:config.MinimumTempAgeDays | Should -BeGreaterThan 0
        $script:config.MinimumCacheAgeDays | Should -BeGreaterThan 0
    }

    It 'bounds every scan' {
        $script:config.MaxEntriesPerRoot | Should -BeGreaterThan 0
        $script:config.MaxScanSecondsPerRoot | Should -BeGreaterThan 0
    }
}

Describe 'Configuration validation' -Tag 'Configuration' {

    BeforeEach {
        $script:configFile = Join-Path ([IO.Path]::GetTempPath()) ('wa-config-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.json')
    }
    AfterEach {
        Remove-Item -LiteralPath $script:configFile -Force -ErrorAction SilentlyContinue
    }

    It 'rejects an unknown risk level rather than falling back to something permissive' {
        Set-Content -LiteralPath $script:configFile -Encoding UTF8 -Value '{ "Risk": { "MaximumAutoApprovableRisk": "WHATEVER" } }'
        { Invoke-WaInternal { param($p) Get-WaConfiguration -Path $p } $script:configFile } | Should -Throw
    }

    It 'rejects an unknown logging verbosity' {
        Set-Content -LiteralPath $script:configFile -Encoding UTF8 -Value '{ "Logging": { "Verbosity": "Shouty" } }'
        { Invoke-WaInternal { param($p) Get-WaConfiguration -Path $p } $script:configFile } | Should -Throw
    }

    It 'rejects an unknown report format' {
        Set-Content -LiteralPath $script:configFile -Encoding UTF8 -Value '{ "Reporting": { "Formats": ["Html", "Fax"] } }'
        { Invoke-WaInternal { param($p) Get-WaConfiguration -Path $p } $script:configFile } | Should -Throw
    }

    It 'rejects a negative age threshold' {
        Set-Content -LiteralPath $script:configFile -Encoding UTF8 -Value '{ "Scanning": { "MinimumTempAgeDays": -5 } }'
        { Invoke-WaInternal { param($p) Get-WaConfiguration -Path $p } $script:configFile } | Should -Throw
    }

    It 'reports a missing configuration file rather than silently using defaults' {
        { Invoke-WaInternal { Get-WaConfiguration -Path 'C:\nope\missing-config.json' } } | Should -Throw
    }

    It 'merges a partial user file over the defaults' {
        Set-Content -LiteralPath $script:configFile -Encoding UTF8 -Value '{ "Scanning": { "MinimumTempAgeDays": 30 } }'
        $merged = Invoke-WaInternal { param($p) Get-WaConfiguration -Path $p } $script:configFile
        $merged.MinimumTempAgeDays | Should -Be 30
        # Untouched keys keep their default value.
        $merged.MaximumAutoApprovableRisk | Should -Be 'LOW'
    }
}

Describe 'Policy is not user-overridable' -Tag 'Configuration', 'Safety' {

    BeforeEach {
        $script:configFile = Join-Path ([IO.Path]::GetTempPath()) ('wa-policy-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.json')
    }
    AfterEach { Remove-Item -LiteralPath $script:configFile -Force -ErrorAction SilentlyContinue }

    It 'ignores an attempt to relax protected paths from a user config file' {
        Set-Content -LiteralPath $script:configFile -Encoding UTF8 -Value '{ "ProtectedPaths": { "Paths": [] }, "OperationPolicy": {} }'
        $config = Invoke-WaInternal { param($p) Get-WaConfiguration -Path $p } $script:configFile
        @($config.Policy.ProtectedPaths).Count | Should -BeGreaterThan 5 -Because 'policy comes from policies.json only'
    }

    It 'still refuses MANUAL-ONLY execution when configuration asks for it' {
        Set-Content -LiteralPath $script:configFile -Encoding UTF8 -Value '{ "Risk": { "AllowManualOnlyExecution": true } }'
        $config = Invoke-WaInternal { param($p) Get-WaConfiguration -Path $p } $script:configFile
        $config.AllowManualOnlyExecution | Should -BeTrue -Because 'the setting loads'

        $advisory = Invoke-WaInternal {
            New-WaAdvisoryRecommendation -Id 'm' -Title 't' -Category 'c' -Provider 'p' -Description 'd'
        }
        # ... but the engine refuses regardless of the setting.
        Invoke-WaInternal { param($r) Test-WaExecutableRecommendation -Recommendation $r } $advisory |
            Should -BeFalse -Because 'the setting is deliberately not honoured'
    }
}

Describe 'Source encoding' -Tag 'Configuration', 'Safety' {

    It 'keeps every PowerShell source file 7-bit ASCII' {
        # Windows PowerShell 5.1 reads a BOM-less UTF-8 script as ANSI. A non-ASCII
        # character therefore arrives as mojibake on 5.1, and if it lands near a quote it
        # can break the surrounding string literal badly enough to leak source into the
        # console. Keeping the sources ASCII removes the whole class of problem.
        # Extension filtered explicitly rather than with -Include: on Windows PowerShell
        # 5.1, -Include combined with -LiteralPath is unreliable and silently matched every
        # file, sweeping in the Markdown docs and runtime logs. Only source files need to be
        # ASCII; the documentation is UTF-8 on purpose.
        $root = Split-Path -Parent $PSScriptRoot
        $sourceExtensions = @('.ps1', '.psm1', '.psd1')
        $excludedDirectories = @('TestResults', 'Data', '.git')

        $files = Get-ChildItem -LiteralPath $root -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object {
                $sourceExtensions -contains $_.Extension -and
                -not ($_.FullName.Substring($root.Length).Split([char]92) | Where-Object { $excludedDirectories -contains $_ })
            }

        # Array.FindIndex rather than piping bytes through Where-Object: the pipeline
        # version pushes every byte of every source file through the PowerShell pipeline,
        # which took over 13 minutes on Windows PowerShell 5.1. This runs in well under a
        # second.
        $isNonAscii = [Predicate[byte]] { param($b) $b -gt 127 }

        $offenders = foreach ($file in $files) {
            $bytes = [IO.File]::ReadAllBytes($file.FullName)
            if ([Array]::FindIndex($bytes, $isNonAscii) -ge 0) {
                $file.FullName.Substring($root.Length).TrimStart([char]92)
            }
        }

        @($offenders) -join ', ' | Should -BeNullOrEmpty
    }
}

Describe 'Path token expansion' -Tag 'Configuration' {

    It 'expands known tokens against this machine' {
        $expanded = Invoke-WaInternal { Expand-WaPathToken -Path '{Windows}\Temp' }
        $expanded | Should -Match '^[A-Za-z]:\\'
        $expanded | Should -Match 'Temp$'
    }

    It 'keeps the separator on a bare drive root' {
        # Trimming C:\ to C: would produce a path that normalisation rejects, silently
        # dropping the protection that entry exists to provide.
        Invoke-WaInternal { Expand-WaPathToken -Path '{SystemDrive}' } | Should -Match '^[A-Za-z]:\\$'
    }

    It 'refuses an unknown token rather than leaving it unexpanded' {
        { Invoke-WaInternal { Expand-WaPathToken -Path '{Nowhere}\x' } } | Should -Throw
    }
}

Describe 'Provider enablement' -Tag 'Configuration' {

    BeforeAll { $script:config = Invoke-WaInternal { Get-WaConfiguration } }

    It 'enables the safe default providers' {
        Invoke-WaInternal { param($c) Test-WaProviderEnabled -Config $c -Provider 'Windows.Temp' } $script:config | Should -BeTrue
    }

    It 'disables external-tool providers by default' {
        Invoke-WaInternal { param($c) Test-WaProviderEnabled -Config $c -Provider 'External.Czkawka' } $script:config | Should -BeFalse
    }

    It 'lets an explicit disable win over everything' {
        $config = Invoke-WaInternal { Get-WaConfiguration }
        $config.DisabledProviders = @('Windows.Temp')
        Invoke-WaInternal { param($c) Test-WaProviderEnabled -Config $c -Provider 'Windows.Temp' } $config | Should -BeFalse
    }

    It 'treats a non-empty allow-list as exclusive' {
        $config = Invoke-WaInternal { Get-WaConfiguration }
        $config.EnabledProviders = @('Windows.Temp')
        Invoke-WaInternal { param($c) Test-WaProviderEnabled -Config $c -Provider 'Windows.Temp' } $config | Should -BeTrue
        Invoke-WaInternal { param($c) Test-WaProviderEnabled -Config $c -Provider 'Browsers.Chromium' } $config | Should -BeFalse
    }
}
