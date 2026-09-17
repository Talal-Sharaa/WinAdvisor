<#
    Tests/Rollback.Tests.ps1 - rollback capture, serialisation and restoration.

    The registry tests use a scratch key under HKCU that the test creates and removes.
    Nothing outside that key is touched.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    [void](Import-WaForTest)
}

Describe 'Rollback records' -Tag 'Rollback' {

    It 'captures prior state with everything needed to restore it' {
        $record = Invoke-WaInternal {
            $session = New-WaSession -Mode 'Cleanup'
            Add-WaRollbackRecord -Session $session -ActionId 'a1' -Kind 'RegistryValueSet' `
                -Target 'HKCU:\Software\WaTest\Value' -BeforeValue 1 -AfterValue 0 -Existed $true `
                -RestoreDescription 'Write the previous value back.' `
                -RestoreParameters ([ordered]@{ Path = 'HKCU:\Software\WaTest'; Name = 'Value'; Type = 'DWord' })
        }

        $record.Kind | Should -Be 'RegistryValueSet'
        $record.BeforeValue | Should -Be 1
        $record.Existed | Should -BeTrue
        $record.Restored | Should -BeFalse
        $record.Id | Should -Match '^RB-'
    }

    It 'writes state to disk as soon as it is captured' {
        $result = Invoke-WaInternal {
            $session = New-WaSession -Mode 'Cleanup'
            [void](Add-WaRollbackRecord -Session $session -ActionId 'a1' -Kind 'StartupItemState' `
                -Target 'Thing' -BeforeValue $true -AfterValue $false `
                -RestoreParameters ([ordered]@{ Name = 'Thing'; Scope = 'Run'; Hive = 'User' }))
            [pscustomobject]@{ Directory = $session.RollbackDirectory; SessionId = $session.Id }
        }

        # Persisted immediately so an interrupted run is still reversible.
        Test-Path -LiteralPath (Join-Path $result.Directory 'state.json') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $result.Directory 'metadata.json') | Should -BeTrue

        $state = Get-Content -LiteralPath (Join-Path $result.Directory 'state.json') -Raw | ConvertFrom-Json
        @($state).Count | Should -Be 1

        Remove-Item -LiteralPath $result.Directory -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'round-trips through JSON without losing the fields needed to restore' {
        $result = Invoke-WaInternal {
            $session = New-WaSession -Mode 'Cleanup'
            [void](Add-WaRollbackRecord -Session $session -ActionId 'a1' -Kind 'ServiceStartupSet' `
                -Target 'TestService' -BeforeValue 'Automatic' -AfterValue 'Manual' `
                -RestoreDescription 'Set it back to Automatic.' `
                -RestoreParameters ([ordered]@{ ServiceName = 'TestService' }))
            [pscustomobject]@{ Directory = $session.RollbackDirectory; SessionId = $session.Id }
        }

        $state = @(Get-Content -LiteralPath (Join-Path $result.Directory 'state.json') -Raw | ConvertFrom-Json)
        $state[0].Kind | Should -Be 'ServiceStartupSet'
        $state[0].BeforeValue | Should -Be 'Automatic'
        $state[0].RestoreParameters.ServiceName | Should -Be 'TestService'

        Remove-Item -LiteralPath $result.Directory -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Deleted files are never claimed to be restorable' -Tag 'Rollback', 'Safety' {

    It 'says so plainly when asked to restore a FileDelete record' {
        $outcome = Invoke-WaInternal {
            $session = New-WaSession -Mode 'Rollback'
            $record = [pscustomobject]@{
                Id = 'RB-1'; Kind = 'FileDelete'; Target = 'C:\Temp\cache'
                BeforeValue = $null; AfterValue = $null; Existed = $true
                RestoreParameters = @{}; Restored = $false
            }
            Restore-WaRollbackRecord -Session $session -Record $record
        }

        $outcome.Status | Should -Be 'Skipped'
        $outcome.Message | Should -Match 'Rollback unavailable'
        $outcome.Message | Should -Match 'regenerable'
    }

    It 'describes cache cleanup as regenerable rather than reversible' {
        $session = New-WaTestSession -Mode 'DryRun'
        $sandbox = New-WaTestSandbox
        try {
            $recommendation = Invoke-WaInternal {
                param($CachePath)
                $s = New-WaSession -Mode 'DryRun'
                $candidate = Get-WaCacheRootCandidate -Session $s -Provider 'Test' -Key 'rb.cache' `
                    -Title 'Sandbox' -Category 'Test' -Path $CachePath -AgeDays 7 `
                    -Risk 'LOW' -Confidence 'HIGH' -Explanation 'Sandbox.' -MinimumBytes 0
                New-WaFileCleanupRecommendation -Session $s -Candidate $candidate
            } (Join-Path $sandbox 'cache')

            $recommendation.Reversibility | Should -Be 'RegenerableOnly'
            $recommendation.RollbackNote | Should -Match 'Not available'
        } finally {
            Remove-WaTestSandbox -Path $sandbox
        }
    }
}

Describe 'Restoration is conservative' -Tag 'Rollback', 'Safety' {

    BeforeEach {
        $script:testKey = 'HKCU:\Software\WinAdvisorTest'
        if (Test-Path -LiteralPath $script:testKey) { Remove-Item -LiteralPath $script:testKey -Recurse -Force }
        [void](New-Item -Path $script:testKey -Force)
        New-ItemProperty -LiteralPath $script:testKey -Name 'Setting' -Value 42 -PropertyType DWord -Force | Out-Null
    }
    AfterEach {
        Remove-Item -LiteralPath $script:testKey -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'restores a registry value that WinAdvisor changed' {
        Set-ItemProperty -LiteralPath $script:testKey -Name 'Setting' -Value 99 -Force

        $outcome = Invoke-WaInternal {
            param($Key)
            $session = New-WaSession -Mode 'Rollback'
            $record = [pscustomobject]@{
                Id = 'RB-1'; Kind = 'RegistryValueSet'; Target = "$Key\Setting"
                BeforeValue = 42; AfterValue = 99; Existed = $true
                RestoreParameters = [pscustomobject]@{ Path = $Key; Name = 'Setting'; Type = 'DWord' }
                Restored = $false
            }
            Restore-WaRollbackRecord -Session $session -Record $record
        } $script:testKey

        $outcome.Status | Should -Be 'Restored'
        (Get-ItemProperty -LiteralPath $script:testKey -Name 'Setting').Setting | Should -Be 42
    }

    It 'removes a value that did not exist before the change' {
        New-ItemProperty -LiteralPath $script:testKey -Name 'Added' -Value 7 -PropertyType DWord -Force | Out-Null

        $outcome = Invoke-WaInternal {
            param($Key)
            $session = New-WaSession -Mode 'Rollback'
            $record = [pscustomobject]@{
                Id = 'RB-2'; Kind = 'RegistryValueSet'; Target = "$Key\Added"
                BeforeValue = $null; AfterValue = 7; Existed = $false
                RestoreParameters = [pscustomobject]@{ Path = $Key; Name = 'Added'; Type = 'DWord' }
                Restored = $false
            }
            Restore-WaRollbackRecord -Session $session -Record $record
        } $script:testKey

        $outcome.Status | Should -Be 'Restored'
        (Get-Item -LiteralPath $script:testKey).GetValue('Added', $null) | Should -BeNullOrEmpty
    }

    It 'skips a service that no longer exists rather than failing the whole restore' {
        $outcome = Invoke-WaInternal {
            $session = New-WaSession -Mode 'Rollback'
            $record = [pscustomobject]@{
                Id = 'RB-3'; Kind = 'ServiceStartupSet'; Target = 'NoSuchServiceWinAdvisorTest'
                BeforeValue = 'Automatic'; AfterValue = 'Disabled'; Existed = $true
                RestoreParameters = [pscustomobject]@{ ServiceName = 'NoSuchServiceWinAdvisorTest' }
                Restored = $false
            }
            Restore-WaRollbackRecord -Session $session -Record $record
        }

        $outcome.Status | Should -Be 'Skipped'
        $outcome.Message | Should -Match 'no longer exists'
    }

    It 'refuses a restore in a read-only session' {
        # Restoration writes to the machine and obeys the same gate as execution.
        { Invoke-WaInternal {
            param($Key)
            $session = New-WaSession -Mode 'DryRun'
            $record = [pscustomobject]@{
                Id = 'RB-RO'; Kind = 'RegistryValueSet'; Target = "$Key\Setting"
                BeforeValue = 42; AfterValue = 99; Existed = $true
                RestoreParameters = [pscustomobject]@{ Path = $Key; Name = 'Setting'; Type = 'DWord' }
                Restored = $false
            }
            Restore-WaRollbackRecord -Session $session -Record $record
        } $script:testKey } | Should -Throw -ExpectedMessage '*read-only*'
    }

    It 'refuses a crafted record pointing at a registry hive outside HKLM and HKCU' {
        # state.json is an ordinary file on disk and is treated as untrusted input.
        $outcome = Invoke-WaInternal {
            $session = New-WaSession -Mode 'Rollback'
            $record = [pscustomobject]@{
                Id = 'RB-EVIL'; Kind = 'RegistryValueSet'; Target = 'HKCR:\.txt'
                BeforeValue = 'x'; AfterValue = 'y'; Existed = $true
                RestoreParameters = [pscustomobject]@{ Path = 'HKCR:\.txt'; Name = 'Value'; Type = 'String' }
                Restored = $false
            }
            Restore-WaRollbackRecord -Session $session -Record $record
        }

        $outcome.Status | Should -Be 'Skipped'
        $outcome.Message | Should -Match 'limited to HKLM'
    }

    It 'refuses a crafted record naming a protected service' {
        $outcome = Invoke-WaInternal {
            $session = New-WaSession -Mode 'Rollback'
            $record = [pscustomobject]@{
                Id = 'RB-EVIL2'; Kind = 'ServiceStartupSet'; Target = 'WinDefend'
                BeforeValue = 'Disabled'; AfterValue = 'Automatic'; Existed = $true
                RestoreParameters = [pscustomobject]@{ ServiceName = 'WinDefend' }
                Restored = $false
            }
            Restore-WaRollbackRecord -Session $session -Record $record
        }

        $outcome.Status | Should -Be 'Skipped'
        $outcome.Message | Should -Match 'protected list'
    }

    It 'refuses a crafted record naming a Windows servicing task' {
        $outcome = Invoke-WaInternal {
            $session = New-WaSession -Mode 'Rollback'
            $record = [pscustomobject]@{
                Id = 'RB-EVIL3'; Kind = 'ScheduledTaskState'; Target = 'StartComponentCleanup'
                BeforeValue = $false; AfterValue = $true; Existed = $true
                RestoreParameters = [pscustomobject]@{ TaskPath = '\Microsoft\Windows\Servicing\'; TaskName = 'StartComponentCleanup' }
                Restored = $false
            }
            Restore-WaRollbackRecord -Session $session -Record $record
        }

        $outcome.Status | Should -Be 'Skipped'
        $outcome.Message | Should -Match 'Windows servicing'
    }

    It 'refuses a crafted record naming a protected startup item' {
        $outcome = Invoke-WaInternal {
            $session = New-WaSession -Mode 'Rollback'
            $record = [pscustomobject]@{
                Id = 'RB-EVIL4'; Kind = 'StartupItemState'; Target = 'SecurityHealthSystray'
                BeforeValue = $false; AfterValue = $true; Existed = $true
                RestoreParameters = [pscustomobject]@{ Name = 'SecurityHealthSystray'; Scope = 'Run'; Hive = 'User' }
                Restored = $false
            }
            Restore-WaRollbackRecord -Session $session -Record $record
        }

        $outcome.Status | Should -Be 'Skipped'
        $outcome.Message | Should -Match 'protected by policy'
    }

    It 'refuses to restore a record kind it does not understand' {
        $outcome = Invoke-WaInternal {
            $session = New-WaSession -Mode 'Rollback'
            $record = [pscustomobject]@{
                Id = 'RB-4'; Kind = 'SomethingNew'; Target = 'x'
                BeforeValue = $null; AfterValue = $null; Existed = $true
                RestoreParameters = @{}; Restored = $false
            }
            Restore-WaRollbackRecord -Session $session -Record $record
        }

        $outcome.Status | Should -Be 'Skipped'
        $outcome.Message | Should -Match 'No restore procedure'
    }

    It 'lists recorded rollback sessions' {
        $result = Invoke-WaInternal {
            $session = New-WaSession -Mode 'Cleanup'
            [void](Add-WaRollbackRecord -Session $session -ActionId 'a' -Kind 'StartupItemState' -Target 'T' `
                -BeforeValue $true -AfterValue $false -RestoreParameters ([ordered]@{ Name = 'T'; Scope = 'Run'; Hive = 'User' }))
            [pscustomobject]@{ Id = $session.Id; Directory = $session.RollbackDirectory }
        }

        $sessions = Invoke-WaInternal { param($id) Get-WaRollbackSession -SessionId $id } $result.Id
        @($sessions).Count | Should -Be 1
        $sessions[0].RecordCount | Should -Be 1
        $sessions[0].PendingCount | Should -Be 1

        Remove-Item -LiteralPath $result.Directory -Recurse -Force -ErrorAction SilentlyContinue
    }
}
