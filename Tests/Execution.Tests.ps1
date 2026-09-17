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

    It 'leaves a file an application has open in place and still succeeds' {
        $locked = Join-Path $script:cachePath 'old-1.tmp'
        $handle = [IO.File]::Open($locked, 'Open', 'Read', 'None')
        try {
            $outcome = Invoke-WaInternal {
                param($CachePath)
                $session = New-WaSession -Mode 'Cleanup'
                $candidate = Get-WaCacheRootCandidate -Session $session -Provider 'Test' -Key 'exec.lock1' `
                    -Title 'Sandbox' -Category 'Test' -Path $CachePath -AgeDays 7 `
                    -Risk 'LOW' -Confidence 'HIGH' -Explanation 'Sandbox files.' -MinimumBytes 0
                $recommendation = New-WaFileCleanupRecommendation -Session $session -Candidate $candidate
                $action = New-WaPlannedAction -Recommendation $recommendation -Order 1
                Invoke-WaFileDeleteOperation -Session $session -Action $action -Operation $recommendation.Operations[0]
            } $script:cachePath
        } finally { $handle.Dispose() }

        $outcome.Status | Should -Be 'Succeeded'
        $outcome.Detail.Deleted | Should -Be 2
        $outcome.Detail.InUse | Should -Be 1
        $outcome.Detail.Errors | Should -Be 0
        $outcome.Messages -join ' ' | Should -Match 'left in place'
        Test-Path -LiteralPath $locked | Should -BeTrue
    }

    It 'reports a folder whose every candidate is in use as skipped, not failed' {
        # This is the everyday temp-folder case: a handful of files, all held open by
        # running applications. Nothing went wrong, so nothing is painted red.
        $handles = @(Get-ChildItem -LiteralPath $script:cachePath -Filter 'old-*.tmp' |
            ForEach-Object { [IO.File]::Open($_.FullName, 'Open', 'Read', 'None') })
        try {
            $outcome = Invoke-WaInternal {
                param($CachePath)
                $session = New-WaSession -Mode 'Cleanup'
                $candidate = Get-WaCacheRootCandidate -Session $session -Provider 'Test' -Key 'exec.lockall' `
                    -Title 'Sandbox' -Category 'Test' -Path $CachePath -AgeDays 7 `
                    -Risk 'LOW' -Confidence 'HIGH' -Explanation 'Sandbox files.' -MinimumBytes 0
                $recommendation = New-WaFileCleanupRecommendation -Session $session -Candidate $candidate
                $action = New-WaPlannedAction -Recommendation $recommendation -Order 1
                [pscustomobject]@{
                    Operation = Invoke-WaFileDeleteOperation -Session $session -Action $action -Operation $recommendation.Operations[0]
                    Action    = Invoke-WaPlannedAction -Session $session -Action $action
                }
            } $script:cachePath
        } finally { $handles | ForEach-Object { $_.Dispose() } }

        $outcome.Operation.Status | Should -Be 'Skipped'
        $outcome.Operation.Detail.Deleted | Should -Be 0
        $outcome.Operation.Detail.InUse | Should -Be 3
        $outcome.Operation.Messages[0] | Should -Match 'Nothing was deleted'
        $outcome.Operation.Messages -join ' ' | Should -Not -Match 'fail'

        $outcome.Action.Status | Should -Be 'Skipped' -Because 'an action whose only operation changed nothing is not a success'
        $outcome.Action.BytesReclaimed | Should -BeNullOrEmpty
        @(Get-ChildItem -LiteralPath $script:cachePath -Filter 'old-*.tmp').Count | Should -Be 3
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

    It 'leads the report with what the run recovered, not with the machine inventory' {
        $report = Invoke-WaInternal {
            $session = New-WaSession -Mode 'Cleanup'
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
            $session.Verification = [pscustomobject]@{
                ReportedBytesReclaimed = 8823250944
                VolumeFreeSpaceDelta   = 20937965568
                EstimatedBytes         = 35786780672
                Succeeded = 23; Failed = 0; Skipped = 2
                Metrics = @([pscustomobject]@{ Name = 'Free space on C:'; BeforeText = '147.07 GiB'; AfterText = '154.61 GiB'; Changed = $true })
                Notes = @('Reported reclaimed space is the sum of what each action measured.')
            }
            New-WaHtmlReport -Session $session
        }

        $recovered = $report.IndexOf('What this run recovered')
        $overview  = $report.IndexOf('Machine overview')
        $recovered | Should -BeGreaterThan 0
        $recovered | Should -BeLessThan $overview -Because 'the outcome is the headline, not a footnote'

        # The three figures stay distinct, and the per-action detail is one click away.
        $report | Should -Match '8\.22 GiB'
        $report | Should -Match '19\.5 GiB'
        $report | Should -Match '23 / 0 / 2'
        $report | Should -Match 'href="#what-was-done"'
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

Describe 'Execution progress' -Tag 'Execution' {

    BeforeEach {
        $script:sandbox = New-WaTestSandbox
        $script:cachePath = Join-Path $script:sandbox 'cache'
    }
    AfterEach { Remove-WaTestSandbox -Path $script:sandbox }

    It 'reports every phase of a simulated run, in order, with an action counter' {
        $phases = Invoke-WaInternal {
            param($CachePath)

            $session = New-WaSession -Mode 'DryRun'
            $session.MachineProfile = [pscustomobject]@{
                Support = [pscustomobject]@{ SupportedForExecution = $true; Reasons = @() }
                Hibernation = $null; Startup = @(); Storage = [pscustomobject]@{ Volumes = @() }
            }

            $candidate = Get-WaCacheRootCandidate -Session $session -Provider 'Test' -Key 'progress.phases' `
                -Title 'Sandbox cache' -Category 'Test' -Path $CachePath -AgeDays 7 `
                -Risk 'LOW' -Confidence 'HIGH' -Explanation 'Sandbox files.' -MinimumBytes 0
            $recommendation = New-WaFileCleanupRecommendation -Session $session -Candidate $candidate
            $plan = [pscustomobject]@{
                Id = 'PLAN-PROGRESS'; SessionId = $session.Id; CreatedUtc = (Get-WaUtcTimestamp); Mode = 'DryRun'
                Actions = @(New-WaPlannedAction -Recommendation $recommendation -Order 1)
                Questions = @(); Summary = $null
            }

            $seen = New-Object 'System.Collections.Generic.List[object]'
            [void](Invoke-WaPlan -Session $session -Plan $plan -OnProgress {
                param($ProgressEvent)
                $seen.Add($ProgressEvent)
            })
            $seen.ToArray()
        } $script:cachePath

        @($phases | ForEach-Object { $_.Phase }) | Should -Be @('Start', 'Action', 'ActionComplete', 'Complete')

        $started = @($phases | Where-Object { $_.Phase -eq 'Action' })[0]
        $started.Index | Should -Be 1
        $started.Total | Should -Be 1
        $started.Title | Should -Be 'Sandbox cache'

        # The finished event carries what the results table will later show.
        $finished = @($phases | Where-Object { $_.Phase -eq 'ActionComplete' })[0]
        $finished.Status | Should -Be 'Simulated'
        $finished.ActionId | Should -Be 'progress.phases'
    }

    It 'reports the slow steps of a real run, including progress within a deletion' {
        $phases = Invoke-WaInternal {
            param($CachePath)

            $session = New-WaSession -Mode 'Cleanup'
            $session.MachineProfile = [pscustomobject]@{
                Support  = [pscustomobject]@{ SupportedForExecution = $true; Reasons = @() }
                Hibernation = $null
                Startup  = @()
                Storage  = [pscustomobject]@{ Volumes = @(Get-WaVolumeFreeSpace | Select-Object -First 1) }
                Identity = [pscustomobject]@{ MachineName = 'TEST'; UserSid = $null }
                OperatingSystem = [pscustomobject]@{ FullBuild = '26100.0' }
            }

            $candidate = Get-WaCacheRootCandidate -Session $session -Provider 'Test' -Key 'progress.execute' `
                -Title 'Sandbox cache' -Category 'Test' -Path $CachePath -AgeDays 7 `
                -Risk 'LOW' -Confidence 'HIGH' -Explanation 'Sandbox files.' -MinimumBytes 0
            $recommendation = New-WaFileCleanupRecommendation -Session $session -Candidate $candidate
            $plan = [pscustomobject]@{
                Id = 'PLAN-PROGRESS-RUN'; SessionId = $session.Id; CreatedUtc = (Get-WaUtcTimestamp); Mode = 'Cleanup'
                Actions = @(New-WaPlannedAction -Recommendation $recommendation -Order 1)
                Questions = @(); Summary = $null
            }
            $plan.Summary = Get-WaPlanSummary -Plan $plan
            $session.Plan = $plan
            [void](Grant-WaApproval -Session $session -Plan $plan -ActionId 'progress.execute' -Decision 'Approved' -Scope 'Batch')

            $seen = New-Object 'System.Collections.Generic.List[object]'
            [void](Invoke-WaPlan -Session $session -Plan $plan -OnProgress {
                param($ProgressEvent)
                $seen.Add($ProgressEvent)
            })
            if ($session.RollbackDirectory) {
                Remove-Item -LiteralPath $session.RollbackDirectory -Recurse -Force -ErrorAction SilentlyContinue
            }
            $seen.ToArray()
        } $script:cachePath

        $names = @($phases | ForEach-Object { $_.Phase })

        # Measuring the before and after state walks the filesystem: slow enough to announce.
        $names | Should -Contain 'Baseline'
        $names | Should -Contain 'Verify'
        $names | Should -Contain 'Operation'
        $names[-1] | Should -Be 'Complete'

        # A sub-step inherits the action it belongs to, so it is never reported orphaned.
        $operation = @($phases | Where-Object { $_.Phase -eq 'Operation' })[0]
        $operation.Title | Should -Be 'Sandbox cache'
        $operation.Message | Should -Not -BeNullOrEmpty
    }

    It 'finishes the work when the display fails' {
        $results = Invoke-WaInternal {
            param($CachePath)

            $session = New-WaSession -Mode 'Cleanup'
            $session.MachineProfile = [pscustomobject]@{
                Support  = [pscustomobject]@{ SupportedForExecution = $true; Reasons = @() }
                Hibernation = $null
                Startup  = @()
                Storage  = [pscustomobject]@{ Volumes = @(Get-WaVolumeFreeSpace | Select-Object -First 1) }
                Identity = [pscustomobject]@{ MachineName = 'TEST'; UserSid = $null }
                OperatingSystem = [pscustomobject]@{ FullBuild = '26100.0' }
            }

            $candidate = Get-WaCacheRootCandidate -Session $session -Provider 'Test' -Key 'progress.broken' `
                -Title 'Sandbox cache' -Category 'Test' -Path $CachePath -AgeDays 7 `
                -Risk 'LOW' -Confidence 'HIGH' -Explanation 'Sandbox files.' -MinimumBytes 0
            $recommendation = New-WaFileCleanupRecommendation -Session $session -Candidate $candidate
            $plan = [pscustomobject]@{
                Id = 'PLAN-PROGRESS-BROKEN'; SessionId = $session.Id; CreatedUtc = (Get-WaUtcTimestamp); Mode = 'Cleanup'
                Actions = @(New-WaPlannedAction -Recommendation $recommendation -Order 1)
                Questions = @(); Summary = $null
            }
            $plan.Summary = Get-WaPlanSummary -Plan $plan
            $session.Plan = $plan
            [void](Grant-WaApproval -Session $session -Plan $plan -ActionId 'progress.broken' -Decision 'Approved' -Scope 'Batch')

            $outcome = Invoke-WaPlan -Session $session -Plan $plan -OnProgress {
                param($ProgressEvent)
                throw 'the display is broken'
            }
            if ($session.RollbackDirectory) {
                Remove-Item -LiteralPath $session.RollbackDirectory -Recurse -Force -ErrorAction SilentlyContinue
            }
            $outcome
        } $script:cachePath

        @($results | Where-Object { $_.ActionId -eq 'progress.broken' })[0].Status | Should -Be 'Succeeded'
        @(Get-ChildItem -LiteralPath $script:cachePath -File | Where-Object { $_.Name -like 'old-*' }).Count |
            Should -Be 0 -Because 'a broken display must not stop work that is under way'
    }

    It 'reports nothing, and throws nothing, when no run is in progress' {
        { Invoke-WaInternal { Write-WaExecutionProgress -Phase 'Action' -Message 'nobody is listening' } } |
            Should -Not -Throw
    }

    It 'renders a finished action as one line carrying its title, size and outcome' {
        # 6>&1 redirects the information stream, which is where Write-Host writes.
        $line = Invoke-WaInternal {
            $progressEvent = [pscustomobject]@{
                Phase = 'ActionComplete'; Index = 2; Total = 9; PercentComplete = 22
                ActionId = 'x'; Title = 'Clear user temp files'; Provider = 'Windows.Temp'
                Status = 'Succeeded'; Message = ''; BytesReclaimed = 1258291200; ElapsedMs = 12400
            }
            (Show-WaExecutionProgress -ProgressEvent $progressEvent 6>&1 | Out-String)
        }

        $line | Should -Match '\[2/9\]'
        $line | Should -Match 'Clear user temp files'
        $line | Should -Match 'done'
        $line | Should -Match '12\.4s'
        $line | Should -Match 'GiB'
    }

    It 'rewrites one transient line rather than scrolling, when the console allows it' {
        $output = Invoke-WaInternal {
            $progressEvent = [pscustomobject]@{
                Phase = 'Operation'; Index = 1; Total = 3; PercentComplete = 33
                ActionId = 'x'; Title = 'Clear user temp files'; Provider = 'Windows.Temp'
                Status = ''; Message = 'deleting file 1,200 of 4,312'; BytesReclaimed = $null; ElapsedMs = 0
            }
            (Show-WaExecutionProgress -ProgressEvent $progressEvent -InPlace 6>&1 | Out-String)
        }

        $output | Should -Match 'deleting file 1,200 of 4,312'
        $output | Should -Match "`r" -Because 'the line is rewritten in place rather than appended'
    }
}

Describe 'Native command outcome' -Tag 'Execution' {

    # Recorded verbatim from a run where uvx-hosted tools (MCP servers) held the uv cache
    # lock. uv exits 2 after waiting UV_LOCK_TIMEOUT seconds and changes nothing.
    BeforeAll {
        $script:uvBusyError = @'
Cache is currently in-use, waiting for other uv processes to finish (use `--force` to override)
error: Timeout (30s) when waiting for lock on `D:\DeveloperCaches\uv` at `D:\DeveloperCaches\uv\.lock`, is another uv process running? You can set `UV_LOCK_TIMEOUT` to increase the timeout.
'@
    }

    It 'reports a tool that found its data held by another process as skipped, not failed' {
        $outcome = Invoke-WaInternal {
            param($ErrorText)
            $resolved = Resolve-WaCommand -CommandId 'uv.cache.prune'
            $result = [pscustomobject]@{ ExitCode = 2; Output = ''; Error = $ErrorText; DurationMs = 30000 }
            Get-WaNativeCommandOutcome -Resolved $resolved -Result $result
        } $script:uvBusyError

        $outcome.Status | Should -Be 'Skipped'
        $outcome.BytesReclaimed | Should -BeNullOrEmpty
        $outcome.Messages[0] | Should -Match 'stopped without changing anything'
        $outcome.Messages[0] | Should -Match 'uvx' -Because 'the advice names what usually holds the lock'
        $outcome.Messages[0] | Should -Match 'does not force'
        $outcome.Messages -join ' ' | Should -Match 'Exit code: 2'
    }

    It 'keeps a genuine non-zero exit as a failure' {
        $outcome = Invoke-WaInternal {
            $resolved = Resolve-WaCommand -CommandId 'uv.cache.prune'
            $result = [pscustomobject]@{ ExitCode = 2; Output = ''; Error = 'error: No such file or directory (os error 2)'; DurationMs = 10 }
            Get-WaNativeCommandOutcome -Resolved $resolved -Result $result
        }

        $outcome.Status | Should -Be 'Failed'
        $outcome.Messages -join ' ' | Should -Match 'Error output: error: No such file'
    }

    It 'does not treat a busy message as a skip for a command that declares no busy pattern' {
        $outcome = Invoke-WaInternal {
            param($ErrorText)
            $resolved = Resolve-WaCommand -CommandId 'npm.cache.clean'
            $result = [pscustomobject]@{ ExitCode = 1; Output = ''; Error = $ErrorText; DurationMs = 10 }
            Get-WaNativeCommandOutcome -Resolved $resolved -Result $result
        } $script:uvBusyError

        $outcome.Status | Should -Be 'Failed'
    }

    It 'flattens multi-line error output onto one indented line' {
        $outcome = Invoke-WaInternal {
            param($ErrorText)
            $resolved = Resolve-WaCommand -CommandId 'uv.cache.prune'
            $result = [pscustomobject]@{ ExitCode = 2; Output = ''; Error = $ErrorText; DurationMs = 10 }
            Get-WaNativeCommandOutcome -Resolved $resolved -Result $result
        } $script:uvBusyError

        $errorLine = @($outcome.Messages | Where-Object { $_ -like 'Error output:*' })
        $errorLine.Count | Should -Be 1
        $errorLine[0] | Should -Not -Match "`n"
        $errorLine[0] | Should -Match 'in-use.*\|.*Timeout'
    }

    It 'gives uv a short lock timeout instead of its five-minute default' {
        $resolved = Invoke-WaInternal { Resolve-WaCommand -CommandId 'uv.cache.prune' }
        $resolved.Environment['UV_LOCK_TIMEOUT'] | Should -Be '30'
        $resolved.Arguments | Should -Not -Contain '--force' -Because 'overriding another process''s lock is never acceptable'
    }
}

Describe 'Native process environment' -Tag 'Execution' {

    It 'passes declared variables to the child process' {
        $result = Invoke-WaInternal {
            Invoke-WaNativeProcess -FilePath (Join-Path $env:SystemRoot 'System32\cmd.exe') `
                -Arguments @('/c', 'echo', '%WA_TEST_SETTING%') -TimeoutSeconds 30 `
                -Environment @{ WA_TEST_SETTING = 'from-the-catalog' }
        }
        $result.ExitCode | Should -Be 0
        $result.Output.Trim() | Should -Be 'from-the-catalog'
    }

    It 'rejects a variable name that is not a plain identifier' {
        { Invoke-WaInternal {
            Invoke-WaNativeProcess -FilePath (Join-Path $env:SystemRoot 'System32\cmd.exe') `
                -Arguments @('/c', 'echo', 'x') -Environment @{ 'WA=BAD' = '1' }
        } } | Should -Throw -ExpectedMessage '*rejected*'
    }

    It 'rejects a value containing a newline' {
        { Invoke-WaInternal {
            Invoke-WaNativeProcess -FilePath (Join-Path $env:SystemRoot 'System32\cmd.exe') `
                -Arguments @('/c', 'echo', 'x') -Environment @{ WA_TEST = "one`ntwo" }
        } } | Should -Throw -ExpectedMessage '*newline*'
    }
}

Describe 'Native command heartbeat' -Tag 'Execution' {

    # ping.exe is resolved directly rather than through Get-WaSystemExecutable: it is not in
    # the catalog's allow-list, and should not be. It is used here only as a process that
    # reliably takes a few seconds.

    It 'reports that a slow command is still running, without changing its outcome' {
        $outcome = Invoke-WaInternal {
            $beats = New-Object 'System.Collections.Generic.List[object]'
            $result = Invoke-WaNativeProcess -FilePath (Join-Path $env:SystemRoot 'System32\ping.exe') `
                -Arguments @('-n', '4', '127.0.0.1') -TimeoutSeconds 60 -HeartbeatSeconds 1 -OnHeartbeat {
                    param($Elapsed)
                    $beats.Add($Elapsed)
                }
            [pscustomobject]@{ ExitCode = $result.ExitCode; Beats = $beats.Count }
        }

        $outcome.ExitCode | Should -Be 0
        $outcome.Beats | Should -BeGreaterThan 1 -Because 'a command that runs for seconds must say so while it runs'
    }

    It 'still enforces the timeout while a heartbeat is watching' {
        { Invoke-WaInternal {
            Invoke-WaNativeProcess -FilePath (Join-Path $env:SystemRoot 'System32\ping.exe') `
                -Arguments @('-n', '30', '127.0.0.1') -TimeoutSeconds 2 -HeartbeatSeconds 1 -OnHeartbeat { param($Elapsed) }
        } } | Should -Throw -ExpectedMessage '*timeout*'
    }

    It 'does not let a failing heartbeat affect the command' {
        Invoke-WaInternal {
            $result = Invoke-WaNativeProcess -FilePath (Join-Path $env:SystemRoot 'System32\ping.exe') `
                -Arguments @('-n', '3', '127.0.0.1') -TimeoutSeconds 60 -HeartbeatSeconds 1 `
                -OnHeartbeat { param($Elapsed) throw 'the display is broken' }
            $result.ExitCode
        } | Should -Be 0
    }
}
