<#
    Tests/CommandCatalog.Tests.ps1 - the external command allow-list.

    The catalog is what stops a provider running an arbitrary command line. These tests
    cover its integrity and its resistance to argument injection through placeholders.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    [void](Import-WaForTest)
    $script:catalog = Invoke-WaInternal { Get-WaCommandCatalog }
}

Describe 'Catalog integrity' -Tag 'Catalog', 'Safety' {

    It 'contains entries' {
        @($script:catalog).Count | Should -BeGreaterThan 20
    }

    It 'gives every entry a valid minimum risk level' {
        foreach ($entry in $script:catalog) {
            { Invoke-WaInternal { param($r) Get-WaRiskRank -Risk $r } $entry.MinimumRisk } |
                Should -Not -Throw -Because "$($entry.Id) must declare a known risk level"
        }
    }

    It 'documents every entry with a reference' {
        foreach ($entry in $script:catalog) {
            $entry.Reference | Should -Not -BeNullOrEmpty -Because "$($entry.Id) must cite its documentation"
        }
    }

    It 'resolves Windows tools through System32, never through PATH' {
        foreach ($entry in ($script:catalog | Where-Object { $_.Resolution -eq 'System' })) {
            $entry.Executable | Should -Match '\.exe$'
        }
        # A writable PATH entry ahead of System32 must not be able to decide which binary
        # an elevated servicing command actually runs.
        $dism = $script:catalog | Where-Object { $_.Id -eq 'dism.startcomponentcleanup' }
        $dism.Resolution | Should -Be 'System'
    }

    It 'marks every mutating entry as not read-only' {
        foreach ($id in @('dism.startcomponentcleanup', 'powercfg.hibernate.off', 'docker.builder.prune', 'npm.cache.clean')) {
            $entry = $script:catalog | Where-Object { $_.Id -eq $id }
            $entry.ReadOnly | Should -BeFalse -Because "$id changes state"
        }
    }

    It 'states a consequence for every mutating entry' {
        foreach ($entry in ($script:catalog | Where-Object { -not $_.ReadOnly })) {
            $entry.Consequence | Should -Not -BeNullOrEmpty -Because "$($entry.Id) must say what it does to the machine"
        }
    }

    It 'declares a valid busy pattern and advice together, or neither' {
        foreach ($entry in $script:catalog) {
            if ($entry.BusyPattern) {
                { [void][regex]::new($entry.BusyPattern) } | Should -Not -Throw -Because "$($entry.Id) busy pattern must be a valid regex"
                $entry.BusyAdvice | Should -Not -BeNullOrEmpty -Because "$($entry.Id) must say what usually holds the resource"
            } else {
                $entry.BusyAdvice | Should -BeNullOrEmpty -Because "$($entry.Id) advice without a pattern would never be shown"
            }
        }
    }

    It 'uses only plain identifiers for environment variable names' {
        foreach ($entry in $script:catalog) {
            foreach ($name in @($entry.Environment.Keys)) {
                $name | Should -Match '^[A-Za-z_][A-Za-z0-9_]*$' -Because "$($entry.Id) sets '$name'"
                [string]$entry.Environment[$name] | Should -Not -Match '[\r\n]'
            }
        }
    }

    It 'contains no Docker volume removal command' {
        @($script:catalog | Where-Object { $_.Id -match 'volume' -and -not $_.ReadOnly }).Count |
            Should -Be 0 -Because 'volumes hold container data and are never pruned by this toolkit'
    }

    It 'contains no WSL mutation command' {
        @($script:catalog | Where-Object { $_.Tool -eq 'WSL' -and -not $_.ReadOnly }).Count |
            Should -Be 0 -Because 'Microsoft documents no supported in-place WSL shrink'
    }

    It 'contains no Czkawka deletion command' {
        # Compared per argument, so a substring such as the 'd' in --directories cannot
        # make this pass or fail by accident.
        $deletionFlags = @('-D', '--delete-files', '--delete-method', '-d')
        foreach ($entry in ($script:catalog | Where-Object { $_.Tool -eq 'Czkawka' })) {
            $entry.ReadOnly | Should -BeTrue
            foreach ($argument in $entry.Arguments) {
                $deletionFlags | Should -Not -Contain $argument -Because 'duplicate resolution is the user''s decision'
            }
        }
    }

    It 'never terminates a servicing operation mid-flight' {
        foreach ($entry in ($script:catalog | Where-Object { $_.Tool -eq 'DISM' })) {
            $entry.NeverKill | Should -BeTrue -Because 'killing DISM can leave the component store needing repair'
        }
    }

    It 'requires administrator for entries that service Windows' {
        foreach ($id in @('dism.startcomponentcleanup', 'dism.startcomponentcleanup.resetbase', 'powercfg.hibernate.off')) {
            ($script:catalog | Where-Object { $_.Id -eq $id }).RequiresAdmin | Should -BeTrue
        }
    }

    It 'classifies ResetBase as HIGH risk' {
        ($script:catalog | Where-Object { $_.Id -eq 'dism.startcomponentcleanup.resetbase' }).MinimumRisk | Should -Be 'HIGH'
    }
}

Describe 'Command resolution' -Tag 'Catalog', 'Safety' {

    It 'refuses an unknown command id' {
        { Invoke-WaInternal { Resolve-WaCommand -CommandId 'rm.-rf.slash' } } | Should -Throw -ExpectedMessage '*not in the command catalog*'
    }

    It 'produces the documented argument vector' {
        $resolved = Invoke-WaInternal { Resolve-WaCommand -CommandId 'dotnet.nuget.locals.clear.global-packages' }
        $resolved.Arguments | Should -Be @('nuget', 'locals', 'global-packages', '--clear')
    }

    It 'refuses a placeholder value that does not match its pattern' {
        # An attempt to smuggle a second argument through a placeholder.
        { Invoke-WaInternal {
            Resolve-WaCommand -CommandId 'czkawka.duplicates' -Values @{
                Directory  = 'C:\Temp" --delete-files "'
                ReportFile = 'C:\Temp\report.txt'
            }
        } } | Should -Throw -ExpectedMessage '*does not match its required pattern*'
    }

    It 'refuses a placeholder value containing a newline' {
        { Invoke-WaInternal {
            Resolve-WaCommand -CommandId 'czkawka.duplicates' -Values @{
                Directory  = "C:\Temp`nC:\Windows"
                ReportFile = 'C:\Temp\report.txt'
            }
        } } | Should -Throw
    }

    It 'refuses a value for a placeholder the command does not declare' {
        { Invoke-WaInternal {
            Resolve-WaCommand -CommandId 'docker.systemdf' -Values @{ Sneaky = 'value' }
        } } | Should -Throw -ExpectedMessage '*does not declare a placeholder*'
    }

    It 'refuses when a required placeholder value is missing' {
        { Invoke-WaInternal { Resolve-WaCommand -CommandId 'czkawka.duplicates' -Values @{ Directory = 'C:\Temp' } } } |
            Should -Throw -ExpectedMessage '*requires a value for placeholder*'
    }

    It 'accepts a well-formed placeholder value' {
        $resolved = Invoke-WaInternal {
            Resolve-WaCommand -CommandId 'czkawka.duplicates' -Values @{
                Directory  = 'C:\Users\Someone\Pictures'
                ReportFile = 'C:\Temp\report.txt'
            }
        }
        $resolved.Arguments | Should -Contain 'C:\Users\Someone\Pictures'
    }
}

Describe 'Native process argument validation' -Tag 'Catalog', 'Safety' {

    It 'refuses an argument containing a quote' {
        { Invoke-WaInternal {
            Invoke-WaNativeProcess -FilePath (Get-WaSystemExecutable -Name 'powercfg.exe') -Arguments @('/a"; del *')
        } } | Should -Throw -ExpectedMessage '*quote or newline*'
    }

    It 'refuses an argument containing a newline' {
        { Invoke-WaInternal {
            Invoke-WaNativeProcess -FilePath (Get-WaSystemExecutable -Name 'powercfg.exe') -Arguments @("/a`nshutdown")
        } } | Should -Throw -ExpectedMessage '*quote or newline*'
    }

    It 'refuses a relative executable path' {
        { Invoke-WaInternal { Invoke-WaNativeProcess -FilePath 'powercfg.exe' -Arguments @('/a') } } |
            Should -Throw -ExpectedMessage '*must be rooted*'
    }

    It 'refuses an executable that does not exist' {
        { Invoke-WaInternal { Invoke-WaNativeProcess -FilePath 'C:\nope\missing.exe' -Arguments @() } } |
            Should -Throw -ExpectedMessage '*not found*'
    }
}

Describe 'Read-only probe gate' -Tag 'Catalog', 'Safety' {

    It 'refuses every mutating command through the probe path' {
        foreach ($entry in ($script:catalog | Where-Object { -not $_.ReadOnly })) {
            { Invoke-WaInternal { param($id) Invoke-WaCatalogProbe -CommandId $id } $entry.Id } |
                Should -Throw -Because "$($entry.Id) is not a probe"
        }
    }
}
