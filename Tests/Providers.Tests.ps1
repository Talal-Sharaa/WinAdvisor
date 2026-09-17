<#
    Tests/Providers.Tests.ps1 - the provider contract and failure isolation.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    [void](Import-WaForTest)
    $script:providers = Invoke-WaInternal { Get-WaProvider }
    $script:contract = Invoke-WaInternal { Test-WaProviderContract }
}

Describe 'Provider registration' -Tag 'Providers' {

    It 'registers the expected providers' {
        @($script:providers).Count | Should -BeGreaterThan 15
    }

    It 'gives every provider a unique name' {
        $names = @($script:providers | ForEach-Object { $_.Name })
        ($names | Select-Object -Unique).Count | Should -Be $names.Count
    }

    It 'implements the required contract members on every provider' {
        foreach ($row in $script:contract) {
            $row.TestAvailable | Should -BeTrue -Because "$($row.Name) must declare availability"
            $row.GetInventory  | Should -BeTrue -Because "$($row.Name) must declare an inventory"
            $row.GetAnalysis   | Should -BeTrue -Because "$($row.Name) must declare an analysis"
            $row.Complete      | Should -BeTrue
        }
    }

    It 'routes execution through the core engine for every provider' {
        foreach ($row in $script:contract) {
            $row.InvokeCleanup | Should -Be 'Core/Execution.ps1::Invoke-WaPlannedAction' -Because 'providers never execute anything themselves'
        }
    }

    It 'never registers a provider that produces candidates without a plan stage' {
        foreach ($row in $script:contract) {
            if ($row.GetCleanupCandidates) {
                $row.GetCleanupPlan | Should -BeTrue -Because "$($row.Name) surfaces candidates and must be able to explain them"
            }
        }
    }

    It 'documents every provider with a description' {
        foreach ($provider in $script:providers) {
            $provider.Description | Should -Not -BeNullOrEmpty
        }
    }

    It 'marks advisory-only providers as such' {
        foreach ($name in @('Windows.Services', 'Windows.RestorePoints', 'Containers.Wsl', 'Windows.RecycleBin', 'Storage.LargeFiles')) {
            ($script:providers | Where-Object { $_.Name -eq $name }).AdvisoryOnly |
                Should -BeTrue -Because "$name reports but does not act"
        }
    }

    It 'declares the external dependency for providers that need one' {
        ($script:providers | Where-Object { $_.Name -eq 'External.Czkawka' }).ExternalDependency | Should -Be 'czkawka_cli'
    }

    It 'rejects a duplicate registration' {
        { Invoke-WaInternal {
            Register-WaProvider -Name 'Windows.Temp' -Title 'dup' -Category 'x' -Description 'd' `
                -TestAvailable {} -GetInventory {} -GetAnalysis {}
        } } | Should -Throw -ExpectedMessage '*already registered*'
    }

    It 'rejects a provider with candidates but no plan stage' {
        { Invoke-WaInternal {
            Register-WaProvider -Name 'Test.Incomplete' -Title 't' -Category 'x' -Description 'd' `
                -TestAvailable {} -GetInventory {} -GetAnalysis {} -GetCleanupCandidates {}
        } } | Should -Throw -ExpectedMessage '*no GetCleanupPlan*'
    }
}

Describe 'Advisory providers propose nothing executable' -Tag 'Providers', 'Safety' {

    It 'produces only MANUAL-ONLY recommendations from the WSL provider' {
        $session = New-WaTestSession -Mode 'DryRun'
        $recommendations = Invoke-WaInternal {
            param($s)
            $provider = Get-WaProvider -Name 'Containers.Wsl'
            $s.ProviderState['Containers.Wsl'] = @(
                [pscustomobject]@{ Name = 'Test'; BasePath = 'C:\Temp'; Version = 2; DiskPath = 'C:\Temp\ext4.vhdx'; DiskBytes = 1GB }
            )
            & $provider.GetCleanupPlan $s @()
        } $session

        @($recommendations).Count | Should -BeGreaterThan 0
        foreach ($recommendation in $recommendations) {
            $recommendation.Risk | Should -Be 'MANUAL-ONLY'
            @($recommendation.Operations).Count | Should -Be 0
        }
    }
}

Describe 'Provider failure isolation' -Tag 'Providers' {

    It 'records a throwing provider as degraded instead of ending the run' {
        $outcome = Invoke-WaInternal {
            $session = New-WaSession -Mode 'DryRun'
            $provider = [pscustomobject]@{
                Name = 'Test.Exploding'
                TestAvailable = { param($s) throw 'the tool changed its output format' }
            }
            Invoke-WaProviderStage -Session $session -Provider $provider -Stage 'TestAvailable' -Arguments @($session)
        }

        $outcome.Succeeded | Should -BeFalse
        $outcome.Error | Should -Match 'output format'
    }

    It 'treats a missing optional stage as a no-op rather than a failure' {
        $outcome = Invoke-WaInternal {
            $session = New-WaSession -Mode 'DryRun'
            $provider = [pscustomobject]@{ Name = 'Test.Partial'; GetCleanupPlan = $null }
            Invoke-WaProviderStage -Session $session -Provider $provider -Stage 'GetCleanupPlan' -Arguments @($session)
        }

        $outcome.Succeeded | Should -BeTrue
        $outcome.Skipped | Should -BeTrue
    }
}

Describe 'Docker size parsing' -Tag 'Providers' {

    It 'reads base-1000 units as Docker writes them' {
        # Docker prints human sizes in base 1000; treating GB as 2^30 would overstate by 7%.
        Invoke-WaInternal { ConvertFrom-WaDockerSize -Text '21.4GB' } | Should -Be 21400000000
        Invoke-WaInternal { ConvertFrom-WaDockerSize -Text '1.5MB' } | Should -Be 1500000
    }

    It 'reads binary units when Docker uses them' {
        Invoke-WaInternal { ConvertFrom-WaDockerSize -Text '1GiB' } | Should -Be 1073741824
    }

    It 'reads the value out of a reclaimable string' {
        Invoke-WaInternal { ConvertFrom-WaDockerSize -Text '1.87GB (100%)' } | Should -Be 1870000000
    }

    It 'returns nothing for unparseable text rather than guessing' {
        Invoke-WaInternal { ConvertFrom-WaDockerSize -Text 'N/A' } | Should -BeNullOrEmpty
        Invoke-WaInternal { ConvertFrom-WaDockerSize -Text '' } | Should -BeNullOrEmpty
    }
}

Describe 'Startup classification' -Tag 'Providers', 'Safety' {

    It 'classifies security software as Security' {
        Invoke-WaInternal { Get-WaStartupCategory -Name 'SecurityHealthSystray' -Command 'C:\Windows\System32\SecurityHealthSystray.exe' } |
            Should -Be 'Security'
    }

    It 'classifies unknown software as Unknown, not as clutter' {
        Invoke-WaInternal { Get-WaStartupCategory -Name 'AcmeWidget' -Command 'C:\Program Files\Acme\widget.exe' } |
            Should -Be 'Unknown'
    }

    It 'refuses to propose disabling an unclassified item' {
        $session = New-WaTestSession -Mode 'DryRun'
        $item = [pscustomobject]@{
            Name = 'AcmeWidget'; Command = 'C:\acme.exe'; Executable = 'C:\acme.exe'
            Source = 'User Run key'; SourceKind = 'RegistryRun'; ApprovalScope = 'Run'; ApprovalHive = 'User'
            Enabled = $true; StateKnown = $true; Category = 'Unknown'; Protected = $false; RequiresAdmin = $false
        }
        Invoke-WaInternal { param($s, $i) New-WaStartupDisableRecommendation -Session $s -Item $i } $session $item |
            Should -BeNullOrEmpty
    }

    It 'refuses to propose disabling a cloud synchronisation client' {
        $session = New-WaTestSession -Mode 'DryRun'
        $item = [pscustomobject]@{
            Name = 'OneDrive'; Command = 'C:\OneDrive.exe'; Executable = 'C:\OneDrive.exe'
            Source = 'User Run key'; SourceKind = 'RegistryRun'; ApprovalScope = 'Run'; ApprovalHive = 'User'
            Enabled = $true; StateKnown = $true; Category = 'Cloud synchronization'; Protected = $false; RequiresAdmin = $false
        }
        Invoke-WaInternal { param($s, $i) New-WaStartupDisableRecommendation -Session $s -Item $i } $session $item |
            Should -BeNullOrEmpty -Because 'silently stopping sync looks fine until something is lost'
    }

    It 'does propose disabling an optional application, reversibly' {
        $session = New-WaTestSession -Mode 'DryRun'
        $item = [pscustomobject]@{
            Name = 'Spotify'; Command = 'C:\Spotify.exe'; Executable = 'C:\Spotify.exe'
            Source = 'User Run key'; SourceKind = 'RegistryRun'; ApprovalScope = 'Run'; ApprovalHive = 'User'
            Enabled = $true; StateKnown = $true; Category = 'Optional user application'; Protected = $false; RequiresAdmin = $false
        }
        $recommendation = Invoke-WaInternal { param($s, $i) New-WaStartupDisableRecommendation -Session $s -Item $i } $session $item

        $recommendation | Should -Not -BeNullOrEmpty
        $recommendation.Risk | Should -Be 'MODERATE'
        $recommendation.Reversibility | Should -Be 'Reversible'
        $recommendation.EstimatedBytes | Should -BeNullOrEmpty -Because 'no storage figure may be claimed for a startup change'
    }
}

Describe 'Storage categorisation' -Tag 'Providers' {

    It 'attributes by location before extension' {
        Invoke-WaInternal { Get-WaStorageCategory -Path 'C:\Users\x\.nuget\packages\thing\1.0\thing.zip' } |
            Should -Be 'Package-manager caches'
    }

    It 'reports an unrecognised path as Unknown rather than guessing' {
        Invoke-WaInternal { Get-WaStorageCategory -Path 'C:\Data\thing.xyz' } | Should -Be 'Unknown'
    }

    It 'recognises virtual machine disks' {
        Invoke-WaInternal { Get-WaStorageCategory -Path 'C:\VMs\machine.vhdx' } | Should -Be 'Virtual machines'
    }
}
