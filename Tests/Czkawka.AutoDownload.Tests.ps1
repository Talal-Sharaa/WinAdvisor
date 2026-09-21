BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    [void](Import-WaForTest)
}

Describe 'Czkawka automatic dependency setup' -Tag 'Czkawka', 'Dependencies' {
    BeforeEach {
        $script:sandbox = New-WaTestSandbox
        $script:session = New-WaTestSession -Mode DryRun
        $script:session.Config.AllowExternalTools = $true
        $script:session.Config.DeepScanPaths = @((Join-Path $script:sandbox 'cache'))
        Mock -ModuleName WinAdvisor Resolve-WaCzkawkaExecutable { $null }
        Mock -ModuleName WinAdvisor Install-WaCzkawka { 'C:\fixture\windows_czkawka_cli.exe' }
        Mock -ModuleName WinAdvisor Invoke-WaCatalogProbe { [pscustomobject]@{ Available=$true; ExitCode=0; Output='czkawka 12.0.2' } }
    }
    AfterEach { Remove-WaTestSandbox $script:sandbox }

    It 'automatically installs a missing CLI in an enabled dry run without deleting scan targets' {
        $before = @(Get-ChildItem -LiteralPath $script:session.Config.DeepScanPaths[0] -File).Count
        Invoke-WaInternal { param($s) Initialize-WaCzkawkaScan $s } $script:session
        Should -Invoke Install-WaCzkawka -ModuleName WinAdvisor -Times 1 -Exactly -ParameterFilter { $DestinationDirectory -like '*\Tools\Czkawka' }
        Should -Invoke Invoke-WaCatalogProbe -ModuleName WinAdvisor -Times 1 -Exactly -ParameterFilter { $CommandId -eq 'czkawka.version' }
        $script:session.ReadOnly | Should -BeTrue
        @(Get-ChildItem -LiteralPath $script:session.Config.DeepScanPaths[0] -File).Count | Should -Be $before
    }

    It 'reuses an installed CLI without downloading' {
        Mock -ModuleName WinAdvisor Resolve-WaCzkawkaExecutable { 'C:\fixture\czkawka_cli.exe' }
        Invoke-WaInternal { param($s) Initialize-WaCzkawkaScan $s } $script:session
        Should -Invoke Install-WaCzkawka -ModuleName WinAdvisor -Times 0 -Exactly
    }

    It 'does not download while external tools are disabled' {
        $script:session.Config.AllowExternalTools = $false
        { Invoke-WaInternal { param($s) Initialize-WaCzkawkaScan $s } $script:session } | Should -Throw '*AllowExternalTools*'
        Should -Invoke Install-WaCzkawka -ModuleName WinAdvisor -Times 0 -Exactly
    }

    It 'does not download while the provider is disabled' {
        $script:session.Config.DisabledProviders = @('External.Czkawka')
        { Invoke-WaInternal { param($s) Initialize-WaCzkawkaScan $s } $script:session } | Should -Throw '*provider is disabled*'
        Should -Invoke Install-WaCzkawka -ModuleName WinAdvisor -Times 0 -Exactly
    }

    It 'does not download without explicit or default scan folders' {
        $script:session.Config.DeepScanPaths = @()
        $script:session.Config.ProviderConfig['External.Czkawka'].Settings['DefaultScanPaths'] = @()
        { Invoke-WaInternal { param($s) Initialize-WaCzkawkaScan $s } $script:session } | Should -Throw '*no eligible scan folders*'
        Should -Invoke Install-WaCzkawka -ModuleName WinAdvisor -Times 0 -Exactly
    }

    It 'downloads and enables all six scans using default folders without a deep-scan argument' {
        $script:session.Config.EnabledProviders = @('External.Czkawka')
        $script:session.Config.ProviderConfig['External.Czkawka'].Settings['DefaultScanPaths'] = $script:session.Config.DeepScanPaths
        $script:session.Config.DeepScanPaths = @()
        $availability = Invoke-WaInternal { param($s) Get-WaActiveProvider $s } $script:session
        @($availability.Active.Name) | Should -Contain 'External.Czkawka'
        @($script:session.ProviderState['External.Czkawka'].Roots).Count | Should -Be 1
        @($script:session.ProviderState['External.Czkawka'].Modes).Count | Should -Be 6
        Should -Invoke Install-WaCzkawka -ModuleName WinAdvisor -Times 1 -Exactly
    }

    It 'expands default path tokens and skips missing default folders' {
        $script:session.Config.DeepScanPaths = @()
        $script:session.Config.ProviderConfig['External.Czkawka'].Settings['DefaultScanPaths'] = @(
            ('{Temp}\' + (Split-Path -Leaf $script:sandbox) + '\cache'),
            (Join-Path $script:sandbox 'absent')
        )
        $roots = @(Invoke-WaInternal { param($s) Get-WaCzkawkaScanRoots $s } $script:session)
        $roots.Count | Should -Be 1
        $roots[0] | Should -Be (Get-Item -LiteralPath (Join-Path $script:sandbox 'cache')).FullName
    }

    It 'uses explicit paths instead of adding the default folders' {
        $script:session.Config.ProviderConfig['External.Czkawka'].Settings['DefaultScanPaths'] = @($script:sandbox)
        $roots = @(Invoke-WaInternal { param($s) Get-WaCzkawkaScanRoots $s } $script:session)
        $roots.Count | Should -Be 1
        $roots[0] | Should -Be (Get-Item -LiteralPath $script:session.Config.DeepScanPaths[0]).FullName
    }

    It 'skips protected and excluded default folders while retaining eligible ones' {
        $excluded = Join-Path $script:sandbox 'excluded'
        [void](New-Item -ItemType Directory -Path $excluded)
        $script:session.Config.ExcludedPaths = @($excluded)
        $script:session.Config.ProviderConfig['External.Czkawka'].Settings['DefaultScanPaths'] = @(
            $script:session.Config.DeepScanPaths[0], $excluded, '{Windows}'
        )
        $script:session.Config.DeepScanPaths = @()
        $roots = @(Invoke-WaInternal { param($s) Get-WaCzkawkaScanRoots $s } $script:session)
        $roots.Count | Should -Be 1
        $roots[0] | Should -Be (Get-Item -LiteralPath (Join-Path $script:sandbox 'cache')).FullName
    }

    It 'rejects an invalid explicit folder instead of falling back to personal folders' {
        $script:session.Config.DeepScanPaths = @((Join-Path $script:sandbox 'absent'))
        { Invoke-WaInternal { param($s) Initialize-WaCzkawkaScan $s } $script:session } | Should -Throw '*Missing*'
        Should -Invoke Install-WaCzkawka -ModuleName WinAdvisor -Times 0 -Exactly
    }

    It 'skips a protected explicit folder and still scans the other named folders' {
        $script:session.Config.DeepScanPaths += ($env:SystemDrive + '\')
        Invoke-WaInternal { param($s) Initialize-WaCzkawkaScan $s } $script:session
        $state = $script:session.ProviderState['External.Czkawka']
        @($state.Roots).Count | Should -Be 1
        $state.Roots[0] | Should -Be (Get-Item -LiteralPath $script:session.Config.DeepScanPaths[0]).FullName
        @($state.SkippedRoots).Count | Should -Be 1
        $state.SkippedRoots[0] | Should -BeLike 'Protected path:*'
    }

    It 'names every rejected explicit folder when none is left to scan' {
        $script:session.Config.DeepScanPaths = @(($env:SystemDrive + '\'), (Join-Path $script:sandbox 'absent'))
        { Invoke-WaInternal { param($s) Initialize-WaCzkawkaScan $s } $script:session } | Should -Throw '*no eligible scan folders (Protected path:*; Missing*'
        Should -Invoke Install-WaCzkawka -ModuleName WinAdvisor -Times 0 -Exactly
    }

    It 'honours the automatic download opt-out' {
        $script:session.Config.ProviderConfig['External.Czkawka'].Settings['AutoDownload'] = $false
        { Invoke-WaInternal { param($s) Initialize-WaCzkawkaScan $s } $script:session } | Should -Throw '*AutoDownload is disabled*'
        Should -Invoke Install-WaCzkawka -ModuleName WinAdvisor -Times 0 -Exactly
    }

    It 'reports download failure and never attempts to run an unverified executable' {
        Mock -ModuleName WinAdvisor Install-WaCzkawka { throw 'Connection timed out' }
        $availability = Invoke-WaInternal { param($s) & (Get-WaProvider 'External.Czkawka').TestAvailable $s } $script:session
        $availability.Available | Should -BeFalse
        $availability.Reason | Should -Match 'automatic download failed.*Connection timed out'
        Should -Invoke Invoke-WaCatalogProbe -ModuleName WinAdvisor -Times 0 -Exactly
    }

    It 'still verifies the CLI version after installation' {
        Mock -ModuleName WinAdvisor Invoke-WaCatalogProbe { [pscustomobject]@{ Available=$true; ExitCode=0; Output='czkawka 11.0.0' } }
        { Invoke-WaInternal { param($s) Initialize-WaCzkawkaScan $s } $script:session } | Should -Throw '*requires Czkawka CLI 12.0.2*'
        Should -Invoke Install-WaCzkawka -ModuleName WinAdvisor -Times 1 -Exactly
    }
}

Describe 'Czkawka pinned download verification' -Tag 'Czkawka', 'Dependencies' {
    BeforeEach {
        $script:sandbox = New-WaTestSandbox -OldFileCount 0 -NewFileCount 0
        $script:destination = Join-Path $script:sandbox 'tool'
        $script:binary = Join-Path $script:destination 'windows_czkawka_cli.exe'
        Mock -ModuleName WinAdvisor Invoke-WebRequest {
            param($Uri, $OutFile)
            [IO.File]::WriteAllText($OutFile, 'download fixture')
        }
    }
    AfterEach { Remove-WaTestSandbox $script:sandbox }

    It 'installs only after successful SHA-256 verification of the pinned release URL' {
        Mock -ModuleName WinAdvisor Get-FileHash { [pscustomobject]@{ Hash='eb7c2009d2dd49cf5202acbd65370caece0a3f819b9515e727cedb1ec088ed1a' } }
        $installed = Invoke-WaInternal { param($d) Install-WaCzkawka -DestinationDirectory $d } $script:destination
        $installed | Should -Be $script:binary
        Test-Path -LiteralPath $installed | Should -BeTrue
        Should -Invoke Invoke-WebRequest -ModuleName WinAdvisor -Times 1 -Exactly -ParameterFilter {
            $Uri -eq 'https://github.com/qarmin/czkawka/releases/download/12.0.2/windows_czkawka_cli.exe' -and $TimeoutSec -eq 180
        }
        Should -Invoke Get-FileHash -ModuleName WinAdvisor -Times 1 -Exactly -ParameterFilter { $Algorithm -eq 'SHA256' -and $LiteralPath -like '*.download' }
        @(Get-ChildItem -LiteralPath $script:destination -Filter '*.download').Count | Should -Be 0
    }

    It 'does not redownload an already verified local binary' {
        [void](New-Item -ItemType Directory -Path $script:destination)
        [IO.File]::WriteAllText($script:binary, 'installed fixture')
        Mock -ModuleName WinAdvisor Get-FileHash { [pscustomobject]@{ Hash='eb7c2009d2dd49cf5202acbd65370caece0a3f819b9515e727cedb1ec088ed1a' } }
        Invoke-WaInternal { param($d) Install-WaCzkawka -DestinationDirectory $d } $script:destination | Should -Be $script:binary
        Should -Invoke Invoke-WebRequest -ModuleName WinAdvisor -Times 0 -Exactly
        [IO.File]::ReadAllText($script:binary) | Should -Be 'installed fixture'
    }

    It 'rejects a real checksum mismatch, removes the download and preserves an existing binary' {
        [void](New-Item -ItemType Directory -Path $script:destination)
        [IO.File]::WriteAllText($script:binary, 'previous executable')
        $protocol = [Net.ServicePointManager]::SecurityProtocol
        { Invoke-WaInternal { param($d) Install-WaCzkawka -DestinationDirectory $d } $script:destination } | Should -Throw '*checksum mismatch*'
        [IO.File]::ReadAllText($script:binary) | Should -Be 'previous executable'
        @(Get-ChildItem -LiteralPath $script:destination -Filter '*.download').Count | Should -Be 0
        [Net.ServicePointManager]::SecurityProtocol | Should -Be $protocol
    }

    It 'removes incomplete downloads after a network failure' {
        Mock -ModuleName WinAdvisor Invoke-WebRequest {
            param($OutFile)
            [IO.File]::WriteAllText($OutFile, 'incomplete download')
            throw 'Network disconnected'
        }
        { Invoke-WaInternal { param($d) Install-WaCzkawka -DestinationDirectory $d } $script:destination } | Should -Throw '*Network disconnected*'
        Test-Path -LiteralPath $script:binary | Should -BeFalse
        @(Get-ChildItem -LiteralPath $script:destination -Filter '*.download').Count | Should -Be 0
    }
}
