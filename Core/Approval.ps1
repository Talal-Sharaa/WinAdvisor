<#
    Core/Approval.ps1 - approval records and enforcement.

    An approval is a record bound to one action by fingerprint. The fingerprint covers the
    action's identity, risk, privilege requirement and the operations themselves, so:

      * an approval cannot be replayed against a different action;
      * if anything about what would run changes after approval, the fingerprint no longer
        matches and execution refuses;
      * a saved plan cannot be edited between approval and execution.

    Two scopes exist. Batch approval covers several low-risk actions at once and is capped
    by configuration. Individual approval covers exactly one action and is the only way a
    HIGH-risk action can ever run. MANUAL-ONLY actions cannot be approved at all.
#>

function Grant-WaApproval {
    <#
    .SYNOPSIS
        Records an approval or refusal for one planned action.

    .PARAMETER Scope
        Individual  an explicit decision about this one action.
        Batch       part of a bulk approval, permitted only up to the configured risk ceiling.

    .EXAMPLE
        Grant-WaApproval -Session $s -Plan $plan -ActionId 'browser.chrome.cache' -Decision Approved -Scope Individual
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)]$Plan,
        [Parameter(Mandatory)][string]$ActionId,
        [Parameter(Mandatory)][ValidateSet('Approved', 'Declined')][string]$Decision,
        [ValidateSet('Individual', 'Batch')][string]$Scope = 'Individual',
        [string]$Note = ''
    )

    $action = Get-WaPlanAction -Plan $Plan -ActionId $ActionId
    if ($null -eq $action) { throw "No action '$ActionId' exists in plan $($Plan.Id)." }

    $recommendation = $action.Recommendation

    if ($Decision -eq 'Approved') {
        if ($recommendation.Risk -eq 'MANUAL-ONLY') {
            throw "Action '$ActionId' is MANUAL-ONLY and cannot be approved for execution. It is reported for you to act on yourself."
        }
        if (-not (Test-WaExecutableRecommendation -Recommendation $recommendation)) {
            throw "Action '$ActionId' has no executable operations and cannot be approved."
        }
        if ($Scope -eq 'Batch') {
            if ($recommendation.IndividualApprovalRequired) {
                throw "Action '$ActionId' is $($recommendation.Risk) risk and requires its own individual approval; it cannot be included in a batch."
            }
            $ceiling = Get-WaRiskRank -Risk $Session.Config.MaximumAutoApprovableRisk
            if ((Get-WaRiskRank -Risk $recommendation.Risk) -gt $ceiling) {
                throw "Action '$ActionId' is $($recommendation.Risk) risk, above the configured batch-approval ceiling of $($Session.Config.MaximumAutoApprovableRisk)."
            }
        }
    }

    $action.Approval = [pscustomobject][ordered]@{
        PSTypeName  = 'WinAdvisor.Approval'
        ActionId    = $ActionId
        Decision    = $Decision
        Scope       = $Scope
        Fingerprint = $action.Fingerprint
        GrantedUtc  = (Get-WaUtcTimestamp)
        GrantedBy   = [Environment]::UserName
        Note        = $Note
    }
    $action.Status = $(if ($Decision -eq 'Approved') { 'Approved' } else { 'Declined' })

    Write-WaLog -Session $Session -Level 'Info' -Category 'Approval' -Message (
        '{0} [{1}] {2} ({3} approval).' -f $Decision, $recommendation.Risk, $recommendation.Title, $Scope.ToLowerInvariant()
    )
    return $action
}

function Test-WaApproval {
    <#
    .SYNOPSIS
        True when an action carries a valid approval for exactly this content.

    .DESCRIPTION
        The last line of defence before execution. Every check fails closed:

          * no approval record                    -> refuse
          * MANUAL-ONLY                            -> refuse, unconditionally
          * decision is not Approved               -> refuse
          * approval is for a different action     -> refuse
          * fingerprint no longer matches          -> refuse
          * HIGH risk with only batch approval     -> refuse
          * individual approval required, batch    -> refuse
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Action)

    $approval = Get-WaProperty -Object $Action -Name 'Approval'
    if ($null -eq $approval) { return $false }

    $recommendation = $Action.Recommendation

    # MANUAL-ONLY is refused here as well as at approval time, deliberately. This check
    # must hold even if an approval record were fabricated or a plan deserialised.
    if ($recommendation.Risk -eq 'MANUAL-ONLY') { return $false }
    if (-not (Test-WaExecutableRecommendation -Recommendation $recommendation)) { return $false }

    if ((Get-WaProperty -Object $approval -Name 'Decision') -ne 'Approved') { return $false }
    if ((Get-WaProperty -Object $approval -Name 'ActionId') -ne $Action.Id) { return $false }

    $currentFingerprint = Get-WaActionFingerprint -Recommendation $recommendation
    if ((Get-WaProperty -Object $approval -Name 'Fingerprint') -ne $currentFingerprint) { return $false }
    if ($Action.Fingerprint -ne $currentFingerprint) { return $false }

    if ($recommendation.IndividualApprovalRequired -and (Get-WaProperty -Object $approval -Name 'Scope') -ne 'Individual') { return $false }

    return $true
}

function Grant-WaBatchApproval {
    <#
    .SYNOPSIS
        Approves every action eligible for batch approval, up to the configured ceiling.

    .DESCRIPTION
        Eligible means: executable, not MANUAL-ONLY, not requiring individual approval, and
        at or below Risk.MaximumAutoApprovableRisk. Everything else is left untouched and
        reported, so a user who chooses "approve the safe items" knows precisely what they
        did and did not approve.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)]$Plan,
        [string]$MaximumRisk
    )

    if (-not $MaximumRisk) { $MaximumRisk = $Session.Config.MaximumAutoApprovableRisk }
    $ceiling = Get-WaRiskRank -Risk $MaximumRisk

    $approved = New-Object 'System.Collections.Generic.List[object]'
    $skipped  = New-Object 'System.Collections.Generic.List[object]'

    foreach ($action in @($Plan.Actions)) {
        $recommendation = $action.Recommendation

        if (-not (Test-WaExecutableRecommendation -Recommendation $recommendation)) {
            $skipped.Add([pscustomobject]@{ Title = $recommendation.Title; Risk = $recommendation.Risk; Reason = 'Manual review only; never executed.' })
            continue
        }
        if ($recommendation.IndividualApprovalRequired) {
            $skipped.Add([pscustomobject]@{ Title = $recommendation.Title; Risk = $recommendation.Risk; Reason = 'Requires individual approval.' })
            continue
        }
        if ((Get-WaRiskRank -Risk $recommendation.Risk) -gt $ceiling) {
            $skipped.Add([pscustomobject]@{ Title = $recommendation.Title; Risk = $recommendation.Risk; Reason = "Above the $MaximumRisk batch ceiling." })
            continue
        }
        if ($recommendation.AdminRequired -and -not $Session.IsAdministrator) {
            $skipped.Add([pscustomobject]@{ Title = $recommendation.Title; Risk = $recommendation.Risk; Reason = 'Needs administrator rights; this session is not elevated.' })
            continue
        }

        [void](Grant-WaApproval -Session $Session -Plan $Plan -ActionId $action.Id -Decision 'Approved' -Scope 'Batch' -Note ("Batch approval up to $MaximumRisk."))
        $approved.Add([pscustomobject]@{ Title = $recommendation.Title; Risk = $recommendation.Risk })
    }

    [pscustomobject]@{
        Approved    = $approved.ToArray()
        Skipped     = $skipped.ToArray()
        MaximumRisk = $MaximumRisk
    }
}

function Reset-WaApproval {
    <#
    .SYNOPSIS
        Clears every approval on a plan.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Plan)
    foreach ($action in @($Plan.Actions)) {
        $action.Approval = $null
        $action.Status = 'Pending'
    }
    return $Plan
}
