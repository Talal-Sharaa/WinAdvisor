<#
    Tests/Approval.Tests.ps1 - approval enforcement.

    The approval gate is what separates a recommendation from a change. These tests cover
    the ways an approval could be bypassed: replaying one approval against another action,
    editing the plan after approval, batching a HIGH-risk item, or approving something that
    is manual-review only.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    [void](Import-WaForTest)
}

Describe 'Approval records' -Tag 'Approval', 'Safety' {

    It 'refuses an action with no approval' {
        $recommendation = New-WaTestRecommendation -Risk 'LOW' -Operations @(New-WaTestFileOperation)
        $plan = New-WaTestPlan -Recommendation @($recommendation)
        Invoke-WaInternal { param($a) Test-WaApproval -Action $a } $plan.Actions[0] | Should -BeFalse
    }

    It 'accepts a valid individual approval' {
        $session = New-WaTestSession -Mode 'Cleanup'
        $recommendation = New-WaTestRecommendation -Risk 'LOW' -Operations @(New-WaTestFileOperation)
        $plan = New-WaTestPlan -Recommendation @($recommendation)

        Invoke-WaInternal { param($s, $p, $id) Grant-WaApproval -Session $s -Plan $p -ActionId $id -Decision 'Approved' -Scope 'Individual' } $session $plan $recommendation.Id | Out-Null
        Invoke-WaInternal { param($a) Test-WaApproval -Action $a } $plan.Actions[0] | Should -BeTrue
    }

    It 'refuses a declined approval' {
        $session = New-WaTestSession -Mode 'Cleanup'
        $recommendation = New-WaTestRecommendation -Risk 'LOW' -Operations @(New-WaTestFileOperation)
        $plan = New-WaTestPlan -Recommendation @($recommendation)

        Invoke-WaInternal { param($s, $p, $id) Grant-WaApproval -Session $s -Plan $p -ActionId $id -Decision 'Declined' -Scope 'Individual' } $session $plan $recommendation.Id | Out-Null
        Invoke-WaInternal { param($a) Test-WaApproval -Action $a } $plan.Actions[0] | Should -BeFalse
    }
}

Describe 'Approval cannot be replayed or tampered with' -Tag 'Approval', 'Safety' {

    It 'invalidates the approval when the operations change afterwards' {
        $session = New-WaTestSession -Mode 'Cleanup'
        $recommendation = New-WaTestRecommendation -Risk 'LOW' -Operations @(New-WaTestFileOperation)
        $plan = New-WaTestPlan -Recommendation @($recommendation)

        Invoke-WaInternal { param($s, $p, $id) Grant-WaApproval -Session $s -Plan $p -ActionId $id -Decision 'Approved' -Scope 'Individual' } $session $plan $recommendation.Id | Out-Null
        Invoke-WaInternal { param($a) Test-WaApproval -Action $a } $plan.Actions[0] | Should -BeTrue

        # Repoint the delete at a different directory after approval was granted.
        $plan.Actions[0].Recommendation.Operations[0].Parameters['Root'] = 'C:\Windows\System32'

        Invoke-WaInternal { param($a) Test-WaApproval -Action $a } $plan.Actions[0] |
            Should -BeFalse -Because 'the fingerprint no longer matches what was approved'
    }

    It 'invalidates the approval when the risk level is raised afterwards' {
        $session = New-WaTestSession -Mode 'Cleanup'
        $recommendation = New-WaTestRecommendation -Risk 'LOW' -Operations @(New-WaTestFileOperation)
        $plan = New-WaTestPlan -Recommendation @($recommendation)

        Invoke-WaInternal { param($s, $p, $id) Grant-WaApproval -Session $s -Plan $p -ActionId $id -Decision 'Approved' -Scope 'Individual' } $session $plan $recommendation.Id | Out-Null
        $plan.Actions[0].Recommendation.Risk = 'HIGH'

        Invoke-WaInternal { param($a) Test-WaApproval -Action $a } $plan.Actions[0] | Should -BeFalse
    }

    It 'refuses an approval issued for a different action' {
        $session = New-WaTestSession -Mode 'Cleanup'
        $first = New-WaTestRecommendation -Id 'first' -Risk 'LOW' -Operations @(New-WaTestFileOperation)
        $second = New-WaTestRecommendation -Id 'second' -Risk 'LOW' -Operations @(New-WaTestFileOperation)
        $plan = New-WaTestPlan -Recommendation @($first, $second)

        Invoke-WaInternal { param($s, $p) Grant-WaApproval -Session $s -Plan $p -ActionId 'first' -Decision 'Approved' -Scope 'Individual' } $session $plan | Out-Null

        # Move the approval record onto the other action.
        $plan.Actions[1].Approval = $plan.Actions[0].Approval
        Invoke-WaInternal { param($a) Test-WaApproval -Action $a } $plan.Actions[1] |
            Should -BeFalse -Because 'an approval is bound to one action id'
    }
}

Describe 'HIGH risk requires individual approval' -Tag 'Approval', 'Safety' {

    It 'refuses to include a HIGH-risk action in a batch approval' {
        $session = New-WaTestSession -Mode 'Cleanup'
        $operation = New-WaTestHighRiskOperation
        $recommendation = New-WaTestRecommendation -Risk 'HIGH' -Operations @($operation) -AdminRequired $true
        $plan = New-WaTestPlan -Recommendation @($recommendation)

        { Invoke-WaInternal { param($s, $p, $id) Grant-WaApproval -Session $s -Plan $p -ActionId $id -Decision 'Approved' -Scope 'Batch' } $session $plan $recommendation.Id } |
            Should -Throw
    }

    It 'rejects a batch-scoped approval record on a HIGH-risk action' {
        $session = New-WaTestSession -Mode 'Cleanup'
        $operation = New-WaTestHighRiskOperation
        $recommendation = New-WaTestRecommendation -Risk 'HIGH' -Operations @($operation) -AdminRequired $true
        $plan = New-WaTestPlan -Recommendation @($recommendation)

        # Forge a batch approval directly, bypassing Grant-WaApproval.
        $plan.Actions[0].Approval = [pscustomobject]@{
            ActionId = $recommendation.Id; Decision = 'Approved'; Scope = 'Batch'
            Fingerprint = $plan.Actions[0].Fingerprint; GrantedUtc = 'now'; GrantedBy = 'test'; Note = ''
        }

        Invoke-WaInternal { param($a) Test-WaApproval -Action $a } $plan.Actions[0] |
            Should -BeFalse -Because 'HIGH risk demands an individual decision'
    }

    It 'excludes HIGH-risk actions from batch approval and says why' {
        $session = New-WaTestSession -Mode 'Cleanup'
        $safeOperation = New-WaTestFileOperation
        $highOperation = New-WaTestHighRiskOperation
        $low = New-WaTestRecommendation -Id 'low' -Risk 'LOW' -Operations @($safeOperation)
        $high = New-WaTestRecommendation -Id 'high' -Risk 'HIGH' -Operations @($highOperation) -AdminRequired $true
        $plan = New-WaTestPlan -Recommendation @($low, $high)

        $outcome = Invoke-WaInternal { param($s, $p) Grant-WaBatchApproval -Session $s -Plan $p } $session $plan

        @($outcome.Approved).Count | Should -Be 1
        @($outcome.Approved)[0].Risk | Should -Be 'LOW'
        @($outcome.Skipped | Where-Object { $_.Risk -eq 'HIGH' }).Count | Should -Be 1
    }
}

Describe 'MANUAL-ONLY can never be executed' -Tag 'Approval', 'Safety' {

    BeforeAll {
        $script:advisory = Invoke-WaInternal {
            New-WaAdvisoryRecommendation -Id 'manual.only' -Title 'Manual' -Category 'Test' `
                -Provider 'Test' -Description 'Requires a human decision.'
        }
    }

    It 'refuses to approve it' {
        $session = New-WaTestSession -Mode 'Cleanup'
        $plan = New-WaTestPlan -Recommendation @($script:advisory)
        { Invoke-WaInternal { param($s, $p) Grant-WaApproval -Session $s -Plan $p -ActionId 'manual.only' -Decision 'Approved' -Scope 'Individual' } $session $plan } |
            Should -Throw
    }

    It 'rejects a forged approval record on it' {
        $plan = New-WaTestPlan -Recommendation @($script:advisory)
        $plan.Actions[0].Approval = [pscustomobject]@{
            ActionId = 'manual.only'; Decision = 'Approved'; Scope = 'Individual'
            Fingerprint = $plan.Actions[0].Fingerprint; GrantedUtc = 'now'; GrantedBy = 'test'; Note = ''
        }
        Invoke-WaInternal { param($a) Test-WaApproval -Action $a } $plan.Actions[0] |
            Should -BeFalse -Because 'MANUAL-ONLY is refused unconditionally, not merely unapproved'
    }

    It 'carries no operations, so there is nothing to run even if the gate were bypassed' {
        @($script:advisory.Operations).Count | Should -Be 0
    }

    It 'is skipped rather than executed when a plan runs' {
        $session = New-WaTestSession -Mode 'Cleanup'
        $plan = New-WaTestPlan -Recommendation @($script:advisory)
        $plan.Actions[0].Approval = [pscustomobject]@{
            ActionId = 'manual.only'; Decision = 'Approved'; Scope = 'Individual'
            Fingerprint = $plan.Actions[0].Fingerprint; GrantedUtc = 'now'; GrantedBy = 'test'; Note = ''
        }

        [void](Set-WaTestMachineProfile -Session $session)
        $session.Plan = $plan

        $results = Invoke-WaInternal { param($s, $p) Invoke-WaPlan -Session $s -Plan $p } $session $plan

        @($results | Where-Object { $_.Status -eq 'Skipped' }).Count | Should -BeGreaterThan 0
        @($results | Where-Object { $_.Status -eq 'Succeeded' }).Count | Should -Be 0
    }
}

Describe 'Batch approval ceiling' -Tag 'Approval', 'Safety' {

    It 'does not batch-approve above the configured ceiling' {
        $session = New-WaTestSession -Mode 'Cleanup'
        $session.Config.MaximumAutoApprovableRisk | Should -Be 'LOW'

        $operation = Invoke-WaInternal {
            New-WaOperation -Kind 'StartupItemState' -Description 'test' `
                -Parameters ([ordered]@{ Name = 'Test'; Scope = 'Run'; Hive = 'User'; Enabled = $false })
        }
        $moderate = New-WaTestRecommendation -Risk 'MODERATE' -Operations @($operation)
        $plan = New-WaTestPlan -Recommendation @($moderate)

        $outcome = Invoke-WaInternal { param($s, $p) Grant-WaBatchApproval -Session $s -Plan $p } $session $plan
        @($outcome.Approved).Count | Should -Be 0
        @($outcome.Skipped).Count | Should -Be 1
    }
}
