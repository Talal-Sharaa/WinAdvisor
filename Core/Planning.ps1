<#
    Core/Planning.ps1 - plan construction.

    A plan is the complete, ordered statement of what would happen, with everything needed
    to decide: risk, confidence, evidence, the exact command, what changes, what it costs,
    whether it can be undone, and who must approve it.

    Building a plan changes nothing. A plan can be built, printed, exported and discarded
    in a read-only session; that is exactly what Dry Run does.
#>

function New-WaPlan {
    <#
    .SYNOPSIS
        Builds a maintenance plan from an analysis.

    .DESCRIPTION
        Ordering is deliberate: safest first, and within equal risk the best-evidenced
        first. Manual-review items are kept in the plan but marked as never executable, so
        the report is complete without implying they will be acted on.

    .PARAMETER Question
        Answered questions. Recommendations tied to a skipped question are excluded.

    .EXAMPLE
        $plan = New-WaPlan -Session $session -Analysis $analysis
        $plan.Summary.TotalEstimatedBytes
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)]$Analysis,
        [object[]]$Question = @()
    )

    if (@($Question).Count -eq 0) { $Question = @($Session.Questions) }

    $selected = Select-WaRecommendationByAnswer -Recommendation @($Analysis.Recommendations) -Question $Question
    $ordered = Sort-WaRecommendation -Recommendation $selected

    $actions = New-Object 'System.Collections.Generic.List[object]'
    $order = 0
    foreach ($recommendation in $ordered) {
        $order++
        # Validated again at plan time: a recommendation that was acceptable during
        # analysis must still satisfy policy now.
        try {
            [void](Assert-WaRecommendationPolicy -Recommendation $recommendation -Policy $Session.Config.Policy)
        } catch {
            Write-WaLog -Session $Session -Level 'Error' -Category 'Policy' -Message (
                "Recommendation '{0}' was dropped from the plan: {1}" -f $recommendation.Id, $_.Exception.Message
            )
            continue
        }
        $actions.Add((New-WaPlannedAction -Recommendation $recommendation -Order $order))
    }

    $plan = [pscustomobject][ordered]@{
        PSTypeName  = 'WinAdvisor.Plan'
        Id          = (New-WaIdentifier -Prefix 'PLAN')
        SessionId   = $Session.Id
        CreatedUtc  = (Get-WaUtcTimestamp)
        Mode        = $Session.Mode
        Actions     = $actions.ToArray()
        Questions   = @($Question)
        Summary     = $null
    }
    $plan.Summary = Get-WaPlanSummary -Plan $plan
    $Session.Plan = $plan

    Write-WaLog -Session $Session -Level 'Info' -Category 'Planning' -Message (
        'Plan {0} built with {1} action(s): {2} executable, {3} manual-review.' -f
            $plan.Id, @($plan.Actions).Count, $plan.Summary.ExecutableCount, $plan.Summary.ManualOnlyCount
    )
    return $plan
}

function Get-WaPlanSummary {
    <#
    .SYNOPSIS
        Aggregates a plan into the figures shown before approval.

    .DESCRIPTION
        Three storage totals, kept separate:
          SafeBytes       fully measured, low-risk, high-confidence: the defensible figure
          ReviewBytes     executable but needing a judgement call
          AdvisoryBytes   manual-review only, never executed by the toolkit
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Plan)

    $actions = @($Plan.Actions)
    $recommendations = @($actions | ForEach-Object { $_.Recommendation })

    $safe = [long]0; $review = [long]0; $advisory = [long]0
    foreach ($recommendation in $recommendations) {
        if ($null -eq $recommendation.EstimatedBytes) { continue }
        $bytes = [long]$recommendation.EstimatedBytes
        if ($recommendation.Risk -eq 'MANUAL-ONLY') {
            $advisory += $bytes
        } elseif ((Get-WaRiskRank -Risk $recommendation.Risk) -le (Get-WaRiskRank -Risk 'LOW') -and
                  $recommendation.Confidence -eq 'HIGH' -and $recommendation.EstimateComplete) {
            $safe += $bytes
        } else {
            $review += $bytes
        }
    }

    [pscustomobject][ordered]@{
        ActionCount          = $actions.Count
        ExecutableCount      = @($recommendations | Where-Object { Test-WaExecutableRecommendation -Recommendation $_ }).Count
        ManualOnlyCount      = @($recommendations | Where-Object { $_.Risk -eq 'MANUAL-ONLY' }).Count
        SafeBytes            = $safe
        ReviewBytes          = $review
        AdvisoryBytes        = $advisory
        TotalEstimatedBytes  = ($safe + $review)
        IncompleteEstimates  = @($recommendations | Where-Object { -not $_.EstimateComplete }).Count
        AdminRequired        = @($recommendations | Where-Object { $_.AdminRequired } | ForEach-Object { $_.Title })
        RestartRequired      = @($recommendations | Where-Object { $_.RestartRequired -eq 'Restart' } | ForEach-Object { $_.Title })
        SignOutRequired      = @($recommendations | Where-Object { $_.RestartRequired -eq 'SignOut' } | ForEach-Object { $_.Title })
        Reversible           = @($recommendations | Where-Object { $_.Reversibility -eq 'Reversible' } | ForEach-Object { $_.Title })
        RegenerableOnly      = @($recommendations | Where-Object { $_.Reversibility -eq 'RegenerableOnly' } | ForEach-Object { $_.Title })
        Irreversible         = @($recommendations | Where-Object { $_.Reversibility -eq 'Irreversible' -and $_.Risk -ne 'MANUAL-ONLY' } | ForEach-Object { $_.Title })
        IndividualApproval   = @($recommendations | Where-Object { $_.IndividualApprovalRequired -and $_.Risk -ne 'MANUAL-ONLY' } | ForEach-Object { $_.Title })
        ByCategory           = @(
            $recommendations | Group-Object Category | Sort-Object Name | ForEach-Object {
                [pscustomobject]@{
                    Category = $_.Name
                    Count    = $_.Count
                    Bytes    = [long](($_.Group | ForEach-Object { if ($null -eq $_.EstimatedBytes) { 0 } else { [long]$_.EstimatedBytes } }) | Measure-Object -Sum).Sum
                }
            }
        )
        ByRisk = @(
            foreach ($level in (Get-WaRiskLevels)) {
                $matching = @($recommendations | Where-Object { $_.Risk -eq $level })
                if ($matching.Count -eq 0) { continue }
                [pscustomobject]@{
                    Risk  = $level
                    Count = $matching.Count
                    Bytes = [long](($matching | ForEach-Object { if ($null -eq $_.EstimatedBytes) { 0 } else { [long]$_.EstimatedBytes } }) | Measure-Object -Sum).Sum
                }
            }
        )
    }
}

function Get-WaPlanAction {
    <#
    .SYNOPSIS
        Retrieves one planned action by id.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Plan, [Parameter(Mandatory)][string]$ActionId)
    return (@($Plan.Actions | Where-Object { $_.Id -eq $ActionId }) | Select-Object -First 1)
}

function Set-WaPlanActionRecommendation {
    <#
    .SYNOPSIS
        Replaces what one planned action will do, before it is approved.

    .DESCRIPTION
        Used when the user narrows an action on a review screen (Czkawka results). The
        action keeps its place and id, loses any approval it had, and gets a new
        fingerprint, so only an approval given afterwards can run it.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)]$Plan,
        [Parameter(Mandatory)][string]$ActionId,
        [Parameter(Mandatory)]$Recommendation
    )

    if ($Recommendation.Id -ne $ActionId) { throw "Replacement recommendation '$($Recommendation.Id)' does not match action '$ActionId'." }
    [void](Assert-WaRecommendationPolicy -Recommendation $Recommendation -Policy $Session.Config.Policy)

    $actions = @($Plan.Actions)
    for ($i = 0; $i -lt $actions.Count; $i++) {
        if ($actions[$i].Id -ne $ActionId) { continue }
        $replacement = New-WaPlannedAction -Recommendation $Recommendation -Order $actions[$i].Order
        $actions[$i] = $replacement
        $Plan.Actions = $actions
        $Plan.Summary = Get-WaPlanSummary -Plan $Plan
        Write-WaLog -Session $Session -Level 'Info' -Category 'Planning' -Message (
            "Action '{0}' narrowed before approval: {1}" -f $ActionId, $Recommendation.Title
        )
        return $replacement
    }
    throw "No action '$ActionId' exists in plan $($Plan.Id)."
}

function Get-WaApprovedAction {
    <#
    .SYNOPSIS
        The actions in a plan that are currently approved and executable.

    .DESCRIPTION
        Checked independently of how the approvals were granted. An action reaches this
        list only if it is executable at all, its approval record is valid, and its
        fingerprint still matches the recommendation as it stands now.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Plan)

    @($Plan.Actions | Where-Object {
        (Test-WaExecutableRecommendation -Recommendation $_.Recommendation) -and
        (Test-WaApproval -Action $_)
    } | Sort-Object Order)
}
