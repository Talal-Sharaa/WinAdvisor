<#
    Tests/ReadOnly.Tests.ps1 - the read-only guarantee.

    The project's central promise is that View Specs, Analyze, Storage, Startup, Plan and
    Dry Run cannot change the machine. These tests assert that with real files in a
    sandbox: an approved delete is run through the engine in a read-only session, and the
    files must still be there afterwards.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    [void](Import-WaForTest)
}

Describe 'Read-only modes' -Tag 'ReadOnly', 'Safety' {

    It 'creates every inspection mode as read-only' {
        foreach ($mode in @('Menu', 'ViewSpecs', 'Analyze', 'Storage', 'Startup', 'Plan', 'DryRun', 'Report')) {
            $session = New-WaTestSession -Mode $mode
            $session.ReadOnly | Should -BeTrue -Because "$mode must never change the machine"
        }
    }

    It 'creates only Cleanup and Rollback as mutable' {
        foreach ($mode in @('Cleanup', 'Rollback')) {
            $session = New-WaTestSession -Mode $mode
            $session.ReadOnly | Should -BeFalse -Because "$mode is the mode that acts"
        }
    }

    It 'blocks every mutating primitive in a read-only session' {
        $session = New-WaTestSession -Mode 'DryRun'
        { Invoke-WaInternal { param($s) Assert-WaMutationAllowed -Session $s -Operation 'test' } $session } |
            Should -Throw -ExpectedMessage '*read-only*'
    }

    It 'allows mutating primitives in a cleanup session' {
        $session = New-WaTestSession -Mode 'Cleanup'
        Invoke-WaInternal { param($s) Assert-WaMutationAllowed -Session $s -Operation 'test' } $session | Should -BeTrue
    }

    It 'refuses a mutation with no session at all' {
        { Invoke-WaInternal { Assert-WaMutationAllowed -Session $null -Operation 'test' } } | Should -Throw
    }
}

Describe 'Dry run leaves the filesystem untouched' -Tag 'ReadOnly', 'Safety' {

    BeforeEach {
        $script:sandbox = New-WaTestSandbox
        $script:cachePath = Join-Path $script:sandbox 'cache'
    }
    AfterEach {
        Remove-WaTestSandbox -Path $script:sandbox
    }

    It 'does not delete files even when the action is approved' {
        $before = @(Get-ChildItem -LiteralPath $script:cachePath -File).Count
        $before | Should -BeGreaterThan 0

        $results = Invoke-WaInternal {
            param($CachePath)

            $session = New-WaSession -Mode 'DryRun'
            $session.MachineProfile = [pscustomobject]@{
                Support = [pscustomobject]@{ SupportedForExecution = $true; Reasons = @() }
                Hibernation = $null
                Startup = @()
                Storage = [pscustomobject]@{ Volumes = @() }
            }

            $candidate = Get-WaCacheRootCandidate -Session $session -Provider 'Test' -Key 'test.readonly' `
                -Title 'Sandbox cache' -Category 'Test' -Path $CachePath -AgeDays 7 `
                -Risk 'LOW' -Confidence 'HIGH' -Explanation 'Sandbox files.' -MinimumBytes 0

            $recommendation = New-WaFileCleanupRecommendation -Session $session -Candidate $candidate
            $plan = [pscustomobject]@{
                Id = 'PLAN-TEST'; SessionId = $session.Id; CreatedUtc = (Get-WaUtcTimestamp); Mode = 'DryRun'
                Actions = @(New-WaPlannedAction -Recommendation $recommendation -Order 1)
                Questions = @(); Summary = $null
            }
            $session.Plan = $plan

            # Approve it. A read-only session must still refuse to act.
            [void](Grant-WaApproval -Session $session -Plan $plan -ActionId $recommendation.Id -Decision 'Approved' -Scope 'Individual')

            Invoke-WaPlan -Session $session -Plan $plan
        } $script:cachePath

        $after = @(Get-ChildItem -LiteralPath $script:cachePath -File).Count
        $after | Should -Be $before -Because 'a dry run must not delete anything, approved or not'

        @($results).Count | Should -BeGreaterThan 0
        @($results)[0].Status | Should -Be 'Simulated'
    }

    It 'still reports what it would have deleted' {
        $preview = Invoke-WaInternal {
            param($CachePath)
            $session = New-WaSession -Mode 'DryRun'
            $candidate = Get-WaCacheRootCandidate -Session $session -Provider 'Test' -Key 'test.preview' `
                -Title 'Sandbox cache' -Category 'Test' -Path $CachePath -AgeDays 7 `
                -Risk 'LOW' -Confidence 'HIGH' -Explanation 'Sandbox files.' -MinimumBytes 0
            $recommendation = New-WaFileCleanupRecommendation -Session $session -Candidate $candidate
            $action = New-WaPlannedAction -Recommendation $recommendation -Order 1
            Get-WaFileDeletePreview -Session $session -Action $action -Operation $recommendation.Operations[0]
        } $script:cachePath

        # Three old files were created; the two new ones must not qualify.
        $preview.EligibleCount | Should -Be 3
    }
}

Describe 'Read-only probes' -Tag 'ReadOnly', 'Safety' {

    It 'refuses to run a mutating catalog command through the probe path' {
        foreach ($commandId in @('dism.startcomponentcleanup', 'powercfg.hibernate.off', 'docker.image.prune')) {
            { Invoke-WaInternal { param($c) Invoke-WaCatalogProbe -CommandId $c } $commandId } |
                Should -Throw -Because "$commandId changes the machine and is not a probe"
        }
    }

    It 'allows a genuine read-only probe' {
        # Resolution only; the command is not executed here.
        $resolved = Invoke-WaInternal { Resolve-WaCommand -CommandId 'powercfg.sleepstates' }
        $resolved.ReadOnly | Should -BeTrue
    }
}
