<#
    Tests/Execution.Tests.ps1 - the execution engine.

    These run against real files in a temporary sandbox. Deletion is genuinely performed,
    so the tests prove the engine both does its job and refuses when it should.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    [void](Import-WaForTest)
}

Describe 'File deletion in a sandbox' -Tag 'Execution' {

    BeforeEach {
        $script:sandbox = New-WaTestSandbox
        $script:cachePath = Join-Path $script:sandbox 'cache'
    }
    AfterEach { Remove-WaTestSandbox -Path $script:sandbox }

    It 'deletes only files older than the age threshold' {
        $outcome = Invoke-WaInternal {
            param($CachePath)
            $session = New-WaSession -Mode 'Cleanup'
            $candidate = Get-WaCacheRootCandidate -Session $session -Provider 'Test' -Key 'exec.age' `
                -Title 'Sandbox' -Category 'Test' -Path $CachePath -AgeDays 7 `
                -Risk 'LOW' -Confidence 'HIGH' -Explanation 'Sandbox files.' -MinimumBytes 0
            $recommendation = New-WaFileCleanupRecommendation -Session $session -Candidate $candidate
            $action = New-WaPlannedAction -Recommendation $recommendation -Order 1
            Invoke-WaFileDeleteOperation -Session $session -Action $action -Operation $recommendation.Operations[0]
        } $script:cachePath

        $outcome.Status | Should -Be 'Succeeded'
        $outcome.Detail.Deleted | Should -Be 3

        $remaining = @(Get-ChildItem -LiteralPath $script:cachePath -File)
        $remaining.Count | Should -Be 2
        @($remaining | Where-Object { $_.Name -like 'new-*' }).Count | Should -Be 2 -Because 'recent files must survive'
        @($remaining | Where-Object { $_.Name -like 'old-*' }).Count | Should -Be 0
    }

    It 'never removes the directory itself, only files' {
        Invoke-WaInternal {
            param($CachePath)
            $session = New-WaSession -Mode 'Cleanup'
            $candidate = Get-WaCacheRootCandidate -Session $session -Provider 'Test' -Key 'exec.dir' `
                -Title 'Sandbox' -Category 'Test' -Path $CachePath -AgeDays 7 `
                -Risk 'LOW' -Confidence 'HIGH' -Explanation 'Sandbox files.' -MinimumBytes 0
            $recommendation = New-WaFileCleanupRecommendation -Session $session -Candidate $candidate
            $action = New-WaPlannedAction -Recommendation $recommendation -Order 1
            Invoke-WaFileDeleteOperation -Session $session -Action $action -Operation $recommendation.Operations[0]
        } $script:cachePath | Out-Null

        Test-Path -LiteralPath $script:cachePath -PathType Container | Should -BeTrue
    }

    It 'skips a reviewed file that an application has written to since' {
        # Writing to the file also makes it recent, so the age rule catches it first. Both
        # are correct refusals; what matters is that the file survives.
        $result = Invoke-WaInternal {
            param($CachePath)
            $session = New-WaSession -Mode 'Cleanup'
            $candidate = Get-WaCacheRootCandidate -Session $session -Provider 'Test' -Key 'exec.changed' `
                -Title 'Sandbox' -Category 'Test' -Path $CachePath -AgeDays 7 `
                -Risk 'LOW' -Confidence 'HIGH' -Explanation 'Sandbox files.' -MinimumBytes 0
            $recommendation = New-WaFileCleanupRecommendation -Session $session -Candidate $candidate
            $action = New-WaPlannedAction -Recommendation $recommendation -Order 1

            $target = $recommendation.Operations[0].Parameters['Files'][0].Path
            Add-Content -LiteralPath $target -Value 'the application wrote more data'

            $preview = Get-WaFileDeletePreview -Session $session -Action $action -Operation $recommendation.Operations[0]
            [pscustomobject]@{ Preview = $preview; Target = $target }
        } $script:cachePath

        $result.Preview.SkippedCount | Should -Be 1
        $result.Preview.EligibleCount | Should -Be 2
        Test-Path -LiteralPath $result.Target | Should -BeTrue -Because 'a file in use must survive'
    }

    It 'skips a reviewed file whose size no longer matches the manifest' {
        # Isolates the manifest check: the content changes but the timestamp is restored,
        # so the age rule passes and only the size comparison can catch it.
        $result = Invoke-WaInternal {
            param($CachePath)
            $session = New-WaSession -Mode 'Cleanup'
            $candidate = Get-WaCacheRootCandidate -Session $session -Provider 'Test' -Key 'exec.size' `
                -Title 'Sandbox' -Category 'Test' -Path $CachePath -AgeDays 7 `
                -Risk 'LOW' -Confidence 'HIGH' -Explanation 'Sandbox files.' -MinimumBytes 0
            $recommendation = New-WaFileCleanupRecommendation -Session $session -Candidate $candidate
            $action = New-WaPlannedAction -Recommendation $recommendation -Order 1

            $entry = $recommendation.Operations[0].Parameters['Files'][0]
            $target = $entry.Path
            $originalWrite = (Get-Item -LiteralPath $target).LastWriteTimeUtc

            Add-Content -LiteralPath $target -Value 'grew since review'
            $item = Get-Item -LiteralPath $target
            $item.LastWriteTimeUtc = $originalWrite
            $item.CreationTimeUtc = $originalWrite

            $decision = Test-WaFileDeleteAllowed -Path $target -Root $CachePath `
                -Config $session.Config -Policy $session.Config.Policy `
                -CutoffUtc ([datetime]::UtcNow.AddDays(-7)) -Manifest $entry

            [pscustomobject]@{ Decision = $decision; Target = $target }
        } $script:cachePath

        $result.Decision.Allowed | Should -BeFalse
        $result.Decision.Reason | Should -Match 'size|in use'
        Test-Path -LiteralPath $result.Target | Should -BeTrue
    }

    It 'refuses a manifest pointing outside the approved root' {
        $decision = Invoke-WaInternal {
            param($CachePath)
            $session = New-WaSession -Mode 'Cleanup'
            Test-WaFileDeleteAllowed -Path 'C:\Windows\System32\kernel32.dll' -Root $CachePath `
                -Config $session.Config -Policy $session.Config.Policy
        } $script:cachePath

        $decision.Allowed | Should -BeFalse
        $decision.Reason | Should -Match 'Outside the approved cleanup root'
    }

    It 'refuses a protected file type even inside an approved root' {
        $virtualDisk = Join-Path $script:cachePath 'machine.vhdx'
        Set-Content -LiteralPath $virtualDisk -Value 'not really a disk' -Encoding ASCII
        $item = Get-Item -LiteralPath $virtualDisk
        $item.LastWriteTimeUtc = [datetime]::UtcNow.AddDays(-90)

        $decision = Invoke-WaInternal {
            param($CachePath, $Target)
            $session = New-WaSession -Mode 'Cleanup'
            Test-WaFileDeleteAllowed -Path $Target -Root $CachePath -Config $session.Config -Policy $session.Config.Policy
        } $script:cachePath $virtualDisk

        $decision.Allowed | Should -BeFalse
        $decision.Reason | Should -Match 'never deleted'
        Test-Path -LiteralPath $virtualDisk | Should -BeTrue
    }

    It 'excludes protected file types from the manifest in the first place' {
        $virtualDisk = Join-Path $script:cachePath 'machine.vhdx'
        Set-Content -LiteralPath $virtualDisk -Value 'not really a disk' -Encoding ASCII
        $item = Get-Item -LiteralPath $virtualDisk
        $item.LastWriteTimeUtc = [datetime]::UtcNow.AddDays(-90)
        $item.CreationTimeUtc = [datetime]::UtcNow.AddDays(-90)

        $inventory = Invoke-WaInternal {
            param($CachePath)
            $session = New-WaSession -Mode 'Cleanup'
            Get-WaFileInventory -Root $CachePath -Config $session.Config -CutoffUtc ([datetime]::UtcNow.AddDays(-7))
        } $script:cachePath

        @($inventory.Files | Where-Object { $_.Path -like '*.vhdx' }).Count | Should -Be 0
        $inventory.ProtectedBytes | Should -BeGreaterThan 0
    }

    It 'is idempotent: a second run finds nothing left to do' {
        $second = Invoke-WaInternal {
            param($CachePath)
            $session = New-WaSession -Mode 'Cleanup'

            $first = Get-WaCacheRootCandidate -Session $session -Provider 'Test' -Key 'exec.idem1' `
                -Title 'Sandbox' -Category 'Test' -Path $CachePath -AgeDays 7 `
                -Risk 'LOW' -Confidence 'HIGH' -Explanation 'Sandbox files.' -MinimumBytes 0
            $recommendation = New-WaFileCleanupRecommendation -Session $session -Candidate $first
            $action = New-WaPlannedAction -Recommendation $recommendation -Order 1
            [void](Invoke-WaFileDeleteOperation -Session $session -Action $action -Operation $recommendation.Operations[0])

            # Re-measure after the delete. Nothing aged should remain.
            Get-WaCacheRootCandidate -Session $session -Provider 'Test' -Key 'exec.idem2' `
                -Title 'Sandbox' -Category 'Test' -Path $CachePath -AgeDays 7 `
                -Risk 'LOW' -Confidence 'HIGH' -Explanation 'Sandbox files.' -MinimumBytes 0
        } $script:cachePath

        $second | Should -BeNullOrEmpty -Because 'there is nothing left that qualifies'
    }
}

Describe 'Full execute path end to end' -Tag 'Execution' {

    BeforeEach {
        $script:sandbox = New-WaTestSandbox
        $script:cachePath = Join-Path $script:sandbox 'cache'
    }
    AfterEach { Remove-WaTestSandbox -Path $script:sandbox }

    It 'runs analysis, approval, execution and verification against real files' {
        $outcome = Invoke-WaInternal {
            param($CachePath)

            $session = New-WaSession -Mode 'Cleanup'
            $session.MachineProfile = [pscustomobject]@{
                Support     = [pscustomobject]@{ SupportedForExecution = $true; Reasons = @() }
                Hibernation = $null
                Startup     = @()
                Storage     = [pscustomobject]@{ Volumes = @(Get-WaVolumeFreeSpace | Select-Object -First 1) }
                Identity    = [pscustomobject]@{ MachineName = 'TEST'; UserSid = $null }
                OperatingSystem = [pscustomobject]@{ FullBuild = '26100.0' }
            }

            $candidate = Get-WaCacheRootCandidate -Session $session -Provider 'Test' -Key 'e2e.cache' `
                -Title 'Sandbox cache' -Category 'Test' -Path $CachePath -AgeDays 7 `
                -Risk 'LOW' -Confidence 'HIGH' -Explanation 'Sandbox files.' -MinimumBytes 0
            $recommendation = New-WaFileCleanupRecommendation -Session $session -Candidate $candidate

            $plan = [pscustomobject]@{
                Id = 'PLAN-E2E'; SessionId = $session.Id; CreatedUtc = (Get-WaUtcTimestamp); Mode = 'Cleanup'
                Actions = @(New-WaPlannedAction -Recommendation $recommendation -Order 1)
                Questions = @(); Summary = $null
            }
            $plan.Summary = Get-WaPlanSummary -Plan $plan
            $session.Plan = $plan

            [void](Grant-WaApproval -Session $session -Plan $plan -ActionId $recommendation.Id `
                -Decision 'Approved' -Scope 'Batch')

            $results = Invoke-WaPlan -Session $session -Plan $plan

            [pscustomobject]@{
                Results      = $results
                Verification = $session.Verification
                Rollback     = $session.RollbackDirectory
                Measured     = $plan.Actions[0].Recommendation.MeasuredBytes
                Estimated    = $plan.Actions[0].Recommendation.EstimatedBytes
            }
        } $script:cachePath

        $result = @($outcome.Results | Where-Object { $_.ActionId -eq 'e2e.cache' }) | Select-Object -First 1
        $result.Status | Should -Be 'Succeeded'
        $result.BytesReclaimed | Should -BeGreaterThan 0

        # The three aged files are gone; the two recent ones remain.
        @(Get-ChildItem -LiteralPath $script:cachePath -File).Count | Should -Be 2

        # Verification ran and recorded a measured figure distinct from the estimate.
        $outcome.Verification | Should -Not -BeNullOrEmpty
        $outcome.Verification.ReportedBytesReclaimed | Should -BeGreaterThan 0
        $outcome.Measured | Should -Not -BeNullOrEmpty
        $outcome.Estimated | Should -Not -BeNullOrEmpty

        # A rollback session directory exists even though file deletion is not reversible.
        Test-Path -LiteralPath $outcome.Rollback -PathType Container | Should -BeTrue
        Remove-Item -LiteralPath $outcome.Rollback -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'produces an HTML report containing no external resources' {
        $report = Invoke-WaInternal {
            param($CachePath)
            $session = New-WaSession -Mode 'DryRun'
            $session.MachineProfile = [pscustomobject]@{
                Support = [pscustomobject]@{ SupportedForExecution = $true; Reasons = @() }
                Identity = [pscustomobject]@{ MachineName = 'TEST' }
                OperatingSystem = [pscustomobject]@{ ProductName = 'Windows 11 Pro'; DisplayVersion = '24H2'; FullBuild = '26100.0' }
                Hardware = [pscustomobject]@{ Manufacturer = 'TEST' }
                Processor = @(); Graphics = @(); Memory = $null
                Storage = [pscustomobject]@{ Volumes = @(); PhysicalDisks = @(); BitLocker = @(); BitLockerNote = '' }
                Pagefile = $null; Hibernation = $null; Power = $null; SystemProtection = $null
                Update = $null; ComponentStore = $null; OptionalFeatures = @()
                DeliveryOptimization = $null; Workloads = @(); Startup = @(); Processes = $null
            }
            New-WaHtmlReport -Session $session
        } $script:cachePath

        $report | Should -Match '<!DOCTYPE html>'
        # No network fetches: a report about your machine must not phone anywhere.
        $report | Should -Not -Match '<script'
        $report | Should -Not -Match 'https?://(?!schema)[^"'']*\.(js|css|woff)'
        $report | Should -Not -Match 'cdn\.'
        $report | Should -Match 'prefers-color-scheme'
    }
}

Describe 'Execution gating' -Tag 'Execution', 'Safety' {

    It 'refuses to execute on an unsupported machine' {
        { Invoke-WaInternal {
            $session = New-WaSession -Mode 'Cleanup'
            $session.MachineProfile = [pscustomobject]@{
                Support = [pscustomobject]@{ SupportedForExecution = $false; Reasons = @('Not Windows 11.') }
            }
            $plan = [pscustomobject]@{ Id = 'P'; Actions = @(); Questions = @(); Summary = $null }
            Invoke-WaPlan -Session $session -Plan $plan
        } } | Should -Throw -ExpectedMessage '*not supported for changes*'
    }

    It 'refuses an unknown operation kind at the dispatcher' {
        { Invoke-WaInternal {
            $session = New-WaSession -Mode 'Cleanup'
            $operation = [pscustomobject]@{ Kind = 'ReformatEverything'; Description = 'no'; Parameters = @{}; RequiresAdmin = $false }
            $action = [pscustomobject]@{ Id = 'x'; Recommendation = $null }
            Invoke-WaOperation -Session $session -Action $action -Operation $operation
        } } | Should -Throw
    }

    It 'refuses a registry write outside HKLM and HKCU' {
        { Invoke-WaInternal {
            $session = New-WaSession -Mode 'Cleanup'
            $operation = New-WaOperation -Kind 'RegistryValueSet' -Description 'test' `
                -Parameters ([ordered]@{ Path = 'HKCR:\.txt'; Name = 'Value'; Value = 1; Type = 'DWord' })
            $action = [pscustomobject]@{ Id = 'x'; Recommendation = $null }
            Invoke-WaRegistryValueSetOperation -Session $session -Action $action -Operation $operation
        } } | Should -Throw -ExpectedMessage '*HKLM*'
    }

    It 'refuses to modify a protected service' {
        { Invoke-WaInternal {
            $session = New-WaSession -Mode 'Cleanup'
            $operation = New-WaOperation -Kind 'ServiceStartupSet' -Description 'test' -RequiresAdmin $true `
                -Parameters ([ordered]@{ ServiceName = 'WinDefend'; StartupType = 'Disabled' })
            $action = [pscustomobject]@{ Id = 'x'; Recommendation = $null }
            Invoke-WaServiceStartupSetOperation -Session $session -Action $action -Operation $operation
        } } | Should -Throw -ExpectedMessage '*protected list*'
    }

    It 'refuses to modify a Windows servicing scheduled task' {
        { Invoke-WaInternal {
            $session = New-WaSession -Mode 'Cleanup'
            $operation = New-WaOperation -Kind 'ScheduledTaskState' -Description 'test' -RequiresAdmin $true `
                -Parameters ([ordered]@{ TaskPath = '\Microsoft\Windows\Servicing\'; TaskName = 'StartComponentCleanup'; Enabled = $false })
            $action = [pscustomobject]@{ Id = 'x'; Recommendation = $null }
            Invoke-WaScheduledTaskStateOperation -Session $session -Action $action -Operation $operation
        } } | Should -Throw -ExpectedMessage '*Windows servicing*'
    }

    It 'refuses to disable a protected startup item' {
        { Invoke-WaInternal {
            $session = New-WaSession -Mode 'Cleanup'
            $operation = New-WaOperation -Kind 'StartupItemState' -Description 'test' `
                -Parameters ([ordered]@{ Name = 'SecurityHealthSystray'; Scope = 'Run'; Hive = 'User'; Enabled = $false })
            $action = [pscustomobject]@{ Id = 'x'; Recommendation = $null }
            Invoke-WaStartupItemStateOperation -Session $session -Action $action -Operation $operation
        } } | Should -Throw -ExpectedMessage '*protected by policy*'
    }
}

Describe 'Reclaimed-space parsing' -Tag 'Execution' {

    It 'reads a reported figure from tool output' {
        Invoke-WaInternal { Get-WaReclaimedBytesFromOutput -Text 'Total reclaimed space: 21.4GB' } |
            Should -BeGreaterThan 21000000000
    }

    It 'returns nothing when the tool reported nothing, rather than guessing' {
        Invoke-WaInternal { Get-WaReclaimedBytesFromOutput -Text 'Done.' } | Should -BeNullOrEmpty
    }
}
