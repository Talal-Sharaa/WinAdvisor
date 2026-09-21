<#
    Core/Execution.ps1 - the only code in the project that changes the machine.

    Every mutating primitive begins with Assert-WaMutationAllowed. Providers never reach
    these functions directly; they describe typed operations and the dispatcher below is
    the single place those operations are interpreted.

    Order of gates before anything happens to an action:

      1  the machine is one we are willing to modify (Windows 11 client, 64-bit)
      2  the recommendation still satisfies policy
      3  it is executable at all (not MANUAL-ONLY, has operations)
      4  a valid approval exists whose fingerprint still matches
      5  HIGH risk carries an individual approval, not a batch one
      6  the session holds the privileges the operation declares
      7  for a FileDelete, each individual file is re-validated at the moment of deletion

    In a read-only session the pipeline still runs, producing exactly the commands and
    decisions it would otherwise, and stops at the point of change. That is Dry Run: not a
    separate code path, the same one with the final step withheld.
#>

# ---------------------------------------------------------------------------------------
# Progress reporting
#
# Execution is the slow phase. A manifest can hold tens of thousands of files, a servicing
# command can run for minutes, and measuring the before and after state walks directories.
# On a console, silence is indistinguishable from a hang, so every step announces itself.
#
# The reporter is module-scoped state that exists only for the duration of one Invoke-WaPlan
# call. It is held here rather than passed down so that an operation handler deep in the
# dispatch chain can say what it is doing without adding a parameter to every signature in
# between. It is presentation only, and deliberately powerless:
#
#   * nothing in this file reads it to decide anything
#   * a sink that throws is dropped and the run continues on the progress bar, because a
#     broken display must never abandon a change half-finished
#   * a run without a sink behaves exactly as before, save for a Write-Progress bar
# ---------------------------------------------------------------------------------------

$script:WaExecutionProgress = $null

# Updates from inside a loop can arrive faster than any console can render them. Throttled
# events closer together than this are dropped rather than queued.
$script:WaProgressThrottleMs = 400

function Start-WaExecutionProgress {
    <#
    .SYNOPSIS
        Opens the progress channel for one plan.

    .PARAMETER OnProgress
        Presentation callback, invoked once per step with a progress event. When it is
        absent the steps are drawn as a Write-Progress bar instead; when it is present the
        caller owns the display entirely, because two renderers on one console overwrite
        each other.
    #>
    [CmdletBinding()]
    param([int]$Total = 0, [scriptblock]$OnProgress)

    $script:WaExecutionProgress = [pscustomobject]@{
        Total      = [Math]::Max(0, $Total)
        Index      = 0
        Sink       = $OnProgress
        SinkError  = ''
        Title      = ''
        Provider   = ''
        Activity   = 'WinAdvisor execution'
        LastUpdate = [Diagnostics.Stopwatch]::StartNew()
    }
}

function Stop-WaExecutionProgress {
    <#
    .SYNOPSIS
        Closes the progress channel and clears any bar left on screen.
    #>
    [CmdletBinding()]
    param()

    $reporter = $script:WaExecutionProgress
    if ($null -eq $reporter) { return }
    if ($null -eq $reporter.Sink) { Write-Progress -Activity $reporter.Activity -Completed }
    $script:WaExecutionProgress = $null
}

function Write-WaExecutionProgress {
    <#
    .SYNOPSIS
        Reports one step of execution to whoever is listening.

    .DESCRIPTION
        Safe to call from anywhere on the execution path, including when no run is in
        progress, in which case it does nothing at all.

    .PARAMETER Throttle
        For updates emitted from inside a loop. The event is dropped if the previous one is
        recent enough that nobody could have read it yet.

    .EXAMPLE
        Write-WaExecutionProgress -Phase 'Operation' -Message 'deleting 1,200 of 4,312 file(s)' -Throttle
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Start', 'Baseline', 'RestorePoint', 'Action', 'Operation', 'ActionComplete', 'Verify', 'Complete')]
        [string]$Phase,
        [string]$Message = '',
        [int]$Index = -1,
        [string]$ActionId = '',
        [string]$Title = '',
        [string]$Provider = '',
        [string]$Status = '',
        $BytesReclaimed = $null,
        [int]$ElapsedMs = 0,
        [switch]$Throttle
    )

    $reporter = $script:WaExecutionProgress
    if ($null -eq $reporter) { return }

    if ($Throttle -and $reporter.LastUpdate.ElapsedMilliseconds -lt $script:WaProgressThrottleMs) { return }
    $reporter.LastUpdate.Restart()

    if ($Index -ge 0) { $reporter.Index = $Index }

    # An operation reports what it is doing, not which action it belongs to, so the action
    # last announced stays attached to everything reported under it.
    if ($Title)    { $reporter.Title = $Title }       else { $Title = $reporter.Title }
    if ($Provider) { $reporter.Provider = $Provider } else { $Provider = $reporter.Provider }

    $percent = 0
    if ($reporter.Total -gt 0) {
        $percent = [int][Math]::Min(99, ($reporter.Index / $reporter.Total) * 100)
    }

    $progressEvent = [pscustomobject][ordered]@{
        PSTypeName      = 'WinAdvisor.ExecutionProgress'
        Phase           = $Phase
        Index           = $reporter.Index
        Total           = $reporter.Total
        PercentComplete = $percent
        ActionId        = $ActionId
        Title           = $Title
        Provider        = $Provider
        Status          = $Status
        Message         = $Message
        BytesReclaimed  = $BytesReclaimed
        ElapsedMs       = $ElapsedMs
    }

    if ($null -ne $reporter.Sink) {
        # A display fault must not interrupt a machine change that is already under way, but
        # it must not silently turn into no progress at all either: the sink is dropped and
        # the rest of the run falls back to the progress bar below.
        try {
            [void](& $reporter.Sink $progressEvent)
            return
        } catch {
            $reporter.Sink = $null
            $reporter.SinkError = $_.Exception.Message
        }
    }

    $text = if ($Message) { $Message } elseif ($Title) { $Title } else { $Phase }
    Write-Progress -Activity $reporter.Activity -Status $text -PercentComplete $percent
}

function Get-WaOperationLabel {
    <#
    .SYNOPSIS
        A short human phrase for what an operation is about to do. Progress only.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Operation)

    $description = [string](Get-WaProperty -Object $Operation -Name 'Description')
    if ($description) { return $description }
    return ('performing {0}' -f $Operation.Kind)
}

function Invoke-WaPlan {
    <#
    .SYNOPSIS
        Executes the approved actions in a plan, or simulates them in a read-only session.

    .DESCRIPTION
        Returns one execution result per action. A failing action is recorded and the run
        continues; the run only stops early if continuing could leave the machine in an
        inconsistent state.

    .PARAMETER OnProgress
        Optional presentation callback, invoked with a progress event as each step starts
        and finishes. It cannot influence what runs; see the progress notes at the top of
        this file.

    .EXAMPLE
        $results = Invoke-WaPlan -Session $session -Plan $plan
        $results | Format-Table ActionId, Status, BytesReclaimed
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)]$Plan,
        [scriptblock]$OnProgress
    )

    $results = New-Object 'System.Collections.Generic.List[object]'
    $orderedActions = @($Plan.Actions | Sort-Object Order)

    Start-WaExecutionProgress -Total $orderedActions.Count -OnProgress $OnProgress
    try {

    if ($Session.ReadOnly) {
        Write-WaLog -Session $Session -Level 'Info' -Category 'Execution' -Message (
            'Simulating plan {0} in read-only {1} mode. Nothing will be changed.' -f $Plan.Id, $Session.Mode
        )
        Write-WaExecutionProgress -Phase 'Start' -Message (
            'Simulating {0} action(s). Nothing will be changed.' -f $orderedActions.Count)

        # A simulation re-validates every file manifest, which on a large cache is slow
        # enough to need reporting even though nothing is being changed.
        $index = 0
        foreach ($action in $orderedActions) {
            $index++
            $recommendation = $action.Recommendation
            Write-WaExecutionProgress -Phase 'Action' -Index $index -ActionId $action.Id `
                -Title $recommendation.Title -Provider $recommendation.Provider -Message 'checking what would happen'

            $simulated = Get-WaSimulatedResult -Session $Session -Action $action
            $results.Add($simulated)

            Write-WaExecutionProgress -Phase 'ActionComplete' -Index $index -ActionId $action.Id `
                -Title $recommendation.Title -Provider $recommendation.Provider -Status $simulated.Status
        }
        $Session.Results = $results.ToArray()
        Write-WaExecutionProgress -Phase 'Complete' -Index $orderedActions.Count -Message 'Dry run complete.'
        return $results.ToArray()
    }

    # From here on the session is mutable, so every guard matters.
    if ($Session.Config.RequireSupportedWindows -and -not (Test-WaSupportedForExecution -MachineProfile $Session.MachineProfile)) {
        $reasons = (@($Session.MachineProfile.Support.Reasons) -join ' ')
        throw "This machine is not supported for changes: $reasons Analysis and reporting remain available."
    }

    [void](Initialize-WaRollbackSession -Session $Session)

    # Measuring the starting point walks every cleanup root the plan targets, so it can take
    # noticeably longer than the first action itself. Say so before it starts.
    Write-WaExecutionProgress -Phase 'Baseline' -Message 'measuring free space and target sizes before the first change'
    $baseline = Get-WaBaseline -Session $Session -Plan $Plan
    $Session.Baseline = $baseline

    $approvedActions = @(Get-WaApprovedAction -Plan $Plan)
    Write-WaLog -Session $Session -Level 'Info' -Category 'Execution' -Message (
        'Executing {0} approved action(s) of {1} in plan {2}.' -f $approvedActions.Count, @($Plan.Actions).Count, $Plan.Id
    )
    Write-WaExecutionProgress -Phase 'Start' -Message $(
        if ($approvedActions.Count -eq $orderedActions.Count) {
            'Executing {0} approved action(s).' -f $approvedActions.Count
        } else {
            'Executing {0} approved action(s) of {1}.' -f $approvedActions.Count, $orderedActions.Count
        })

    # A restore point is attempted once, before the first HIGH-risk change, if configured.
    $hasHighRisk = @($approvedActions | Where-Object { $_.Recommendation.Risk -eq 'HIGH' }).Count -gt 0
    if ($hasHighRisk -and $Session.Config.CreateRestorePointBeforeHighRisk) {
        Write-WaExecutionProgress -Phase 'RestorePoint' -Message 'creating a system restore point before the first HIGH risk change'
        $results.Add((Invoke-WaRestorePointCreation -Session $Session))
    }

    $index = 0
    foreach ($action in $orderedActions) {
        $index++
        $recommendation = $action.Recommendation
        Write-WaExecutionProgress -Phase 'Action' -Index $index -ActionId $action.Id `
            -Title $recommendation.Title -Provider $recommendation.Provider

        if (-not (Test-WaExecutableRecommendation -Recommendation $recommendation)) {
            $results.Add((New-WaExecutionResult -ActionId $action.Id -Provider $recommendation.Provider -Status 'Skipped' `
                -Summary 'Manual review only. WinAdvisor performs no action on this item.'))
            Write-WaExecutionProgress -Phase 'ActionComplete' -Index $index -ActionId $action.Id `
                -Title $recommendation.Title -Provider $recommendation.Provider -Status 'Skipped' -Message 'manual review only'
            continue
        }
        if (-not (Test-WaApproval -Action $action)) {
            $results.Add((New-WaExecutionResult -ActionId $action.Id -Provider $recommendation.Provider -Status 'Skipped' `
                -Summary 'Not approved, or the approval no longer matches this action.'))
            Write-WaExecutionProgress -Phase 'ActionComplete' -Index $index -ActionId $action.Id `
                -Title $recommendation.Title -Provider $recommendation.Provider -Status 'Skipped' -Message 'not approved'
            continue
        }

        # Logged as well as reported, so a run that is interrupted still says where it was.
        Write-WaLog -Session $Session -Level 'Info' -Category 'Execution' -Message (
            'Starting action {0} of {1}: {2} ({3}).' -f $index, $orderedActions.Count, $recommendation.Title, $action.Id
        )

        $result = Invoke-WaPlannedAction -Session $Session -Action $action
        $results.Add($result)
        $action.Status = $result.Status

        Write-WaExecutionProgress -Phase 'ActionComplete' -Index $index -ActionId $action.Id `
            -Title $recommendation.Title -Provider $recommendation.Provider -Status $result.Status `
            -BytesReclaimed $result.BytesReclaimed -ElapsedMs ([int](Get-WaProperty -Object $result -Name 'DurationMs'))
    }

    $Session.Results = $results.ToArray()
    [void](Save-WaRollbackActions -Session $Session)

    Write-WaExecutionProgress -Phase 'Verify' -Index $orderedActions.Count -Message 'measuring what actually changed'
    $Session.Verification = Compare-WaBaseline -Session $Session -Baseline $baseline -Results $results.ToArray()

    Write-WaExecutionProgress -Phase 'Complete' -Index $orderedActions.Count -Message 'execution complete'
    return $results.ToArray()

    } finally {
        Stop-WaExecutionProgress
    }
}

function Get-WaSimulatedResult {
    <#
    .SYNOPSIS
        Produces the result a read-only run reports for one action.

    .DESCRIPTION
        Everything up to the change: approval state is evaluated, commands are resolved,
        file manifests are re-validated so the count reported is the count that would
        actually be deleted. No mutating primitive is called.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)]$Action)

    $recommendation = $Action.Recommendation
    $messages = New-Object 'System.Collections.Generic.List[string]'

    if (-not (Test-WaExecutableRecommendation -Recommendation $recommendation)) {
        return (New-WaExecutionResult -ActionId $Action.Id -Provider $recommendation.Provider -Status 'Skipped' `
            -Summary 'Manual review only. It would not be executed even with approval.')
    }

    $wouldRun = Test-WaApproval -Action $Action
    if (-not $wouldRun) {
        $messages.Add('No valid approval is recorded, so this would not run.')
    }

    $eligibleBytes = [long]0
    $unselectedCandidates = 0
    foreach ($operation in $recommendation.Operations) {
        switch ($operation.Kind) {
            'CzkawkaDelete' {
                # Unapproved Czkawka results are candidates, not intentions: until someone
                # picks items on the review screen there is nothing to check per file.
                if (-not $wouldRun) {
                    $unselectedCandidates++
                } else {
                    try {
                        [void](Assert-WaCzkawkaCandidate -Session $Session -Operation $operation)
                        $messages.Add(('Would permanently delete: {0}' -f $operation.Parameters.Target.Path))
                        $eligibleBytes += [long]$operation.Parameters.Target.Length
                    } catch {
                        $messages.Add(('Would skip: {0}' -f $_.Exception.Message))
                    }
                }
            }
            'FileDelete' {
                $preview = Get-WaFileDeletePreview -Session $Session -Action $Action -Operation $operation
                $eligibleBytes += $preview.Bytes
                $messages.Add(('Would delete {0} of {1} reviewed file(s), totalling {2}. {3} would be skipped as no longer eligible.' -f
                    $preview.EligibleCount, $preview.TotalCount, (Format-WaBytes $preview.Bytes), $preview.SkippedCount))
            }
            'NativeCommand' {
                $resolved = Resolve-WaCommand -CommandId ([string]$operation.Parameters['CommandId']) -Values (Get-WaOperationValues -Operation $operation)
                if ($resolved.Available) {
                    $messages.Add(('Would run: {0}' -f $resolved.Preview))
                } else {
                    $messages.Add(('Would not run: {0} is not installed on this machine.' -f $resolved.Tool))
                }
            }
            default {
                $messages.Add(('Would perform {0}: {1}' -f $operation.Kind, $operation.Description))
            }
        }
        if ($operation.RequiresAdmin -and -not $Session.IsAdministrator) {
            $messages.Add('Administrator rights are required and this session does not have them, so it would be blocked.')
        }
    }
    if ($unselectedCandidates -gt 0) {
        $messages.Add(('{0} candidate(s) found. In a cleanup run you choose which to delete on a review screen; nothing is selected by default.' -f $unselectedCandidates))
    }

    New-WaExecutionResult -ActionId $Action.Id -Provider $recommendation.Provider -Status 'Simulated' `
        -Summary ('Dry run: no change was made. {0}' -f $(if ($wouldRun) { 'This action is approved and would have run.' } else { 'This action is not approved.' })) `
        -BytesReclaimed $null `
        -Messages $messages.ToArray() `
        -BeforeState ([ordered]@{ EligibleBytes = $eligibleBytes; Approved = $wouldRun })
}

function Invoke-WaPlannedAction {
    <#
    .SYNOPSIS
        Executes one approved action's operations in order.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)]$Action)

    [void](Assert-WaMutationAllowed -Session $Session -Operation ('action ' + $Action.Id))
    $script:WaCzkawkaVerifiedAction = $null
    $script:WaCzkawkaOperationIndex = $null

    $recommendation = $Action.Recommendation
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    $messages = New-Object 'System.Collections.Generic.List[string]'
    $operationResults = New-Object 'System.Collections.Generic.List[object]'
    $bytesReclaimed = [long]0
    $rollbackId = ''
    $failures = 0
    $skips = 0

    # Policy is re-asserted immediately before execution, not only at plan time.
    try {
        [void](Assert-WaRecommendationPolicy -Recommendation $recommendation -Policy $Session.Config.Policy)
    } catch {
        return (New-WaExecutionResult -ActionId $Action.Id -Provider $recommendation.Provider -Status 'Blocked' `
            -Summary 'Blocked by policy immediately before execution.' -Error $_.Exception.Message)
    }

    foreach ($operation in $recommendation.Operations) {
        Write-WaExecutionProgress -Phase 'Operation' -ActionId $Action.Id -Title $recommendation.Title `
            -Provider $recommendation.Provider -Message (Get-WaOperationLabel -Operation $operation)

        if (-not (Test-WaOperationPrivilege -Session $Session -Operation $operation)) {
            $reason = Get-WaElevationReason -Recommendation $recommendation
            $messages.Add("Blocked: $reason Restart WinAdvisor as administrator to perform it.")
            $operationResults.Add([pscustomobject]@{ Kind = $operation.Kind; Status = 'Blocked'; Message = $reason })
            $failures++
            continue
        }

        try {
            $outcome = Invoke-WaOperation -Session $Session -Action $Action -Operation $operation
            $operationResults.Add($outcome)
            foreach ($message in @($outcome.Messages)) { $messages.Add($message) }
            if ($null -ne $outcome.BytesReclaimed) { $bytesReclaimed += [long]$outcome.BytesReclaimed }
            if ($outcome.RollbackId) { $rollbackId = $outcome.RollbackId }
            if ($outcome.Status -eq 'Failed') { $failures++ }
            elseif ($outcome.Status -eq 'Skipped') { $skips++ }
        } catch {
            $failures++
            $messages.Add(("Operation {0} failed: {1}" -f $operation.Kind, $_.Exception.Message))
            $operationResults.Add([pscustomobject]@{ Kind = $operation.Kind; Status = 'Failed'; Message = $_.Exception.Message })
        }
    }

    $stopwatch.Stop()
    # An operation that changed nothing for a stated, benign reason (every candidate file
    # in use, a tool's data held by another process) is a skip, not a success: the action
    # is reported as skipped so nobody reads a green line as work done.
    $completed = @($recommendation.Operations).Count - $failures - $skips
    $status = if ($failures -eq 0 -and $skips -eq 0) { 'Succeeded' }
              elseif ($failures -eq 0 -and $completed -eq 0) { 'Skipped' }
              elseif ($completed -gt 0) { 'PartiallySucceeded' }
              else { 'Failed' }

    $result = New-WaExecutionResult `
        -ActionId $Action.Id `
        -Provider $recommendation.Provider `
        -Status $status `
        -Summary $recommendation.Title `
        -BytesReclaimed $(if ($bytesReclaimed -gt 0) { $bytesReclaimed } else { $null }) `
        -Messages $messages.ToArray() `
        -DurationMs ([int]$stopwatch.Elapsed.TotalMilliseconds) `
        -RollbackId $rollbackId `
        -OperationResults $operationResults.ToArray()

    Write-WaActionLog -Session $Session -Action $Action -Result $result
    return $result
}

function Get-WaOperationValues {
    <#
    .SYNOPSIS
        Extracts the placeholder values from a NativeCommand operation as a dictionary.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Operation)

    $values = Get-WaProperty -Object $Operation.Parameters -Name 'Values'
    if ($null -eq $values) { return @{} }
    if ($values -is [System.Collections.IDictionary]) { return $values }
    return (ConvertTo-WaHashtable -InputObject $values)
}

function Invoke-WaOperation {
    <#
    .SYNOPSIS
        Dispatches one typed operation to its handler.

    .DESCRIPTION
        The sole interpreter of operations. An unknown kind fails closed, which is why the
        registry of operation kinds in Core/Models.ps1 is the effective limit on what the
        toolkit can do to a machine.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)]$Action, [Parameter(Mandatory)]$Operation)

    [void](Assert-WaMutationAllowed -Session $Session -Operation $Operation.Kind)

    switch ($Operation.Kind) {
        'CzkawkaDelete'      { return (Invoke-WaCzkawkaDeleteOperation -Session $Session -Action $Action -Operation $Operation) }
        'FileDelete'         { return (Invoke-WaFileDeleteOperation -Session $Session -Action $Action -Operation $Operation) }
        'NativeCommand'      { return (Invoke-WaNativeCommandOperation -Session $Session -Action $Action -Operation $Operation) }
        'RegistryValueSet'   { return (Invoke-WaRegistryValueSetOperation -Session $Session -Action $Action -Operation $Operation) }
        'ServiceStartupSet'  { return (Invoke-WaServiceStartupSetOperation -Session $Session -Action $Action -Operation $Operation) }
        'ScheduledTaskState' { return (Invoke-WaScheduledTaskStateOperation -Session $Session -Action $Action -Operation $Operation) }
        'StartupItemState'   { return (Invoke-WaStartupItemStateOperation -Session $Session -Action $Action -Operation $Operation) }
        'RestorePointCreate' { return (Invoke-WaRestorePointCreation -Session $Session) }
        default              { throw "Operation kind '$($Operation.Kind)' has no handler and cannot be executed." }
    }
}

function Get-WaFileDeletePreview {
    <#
    .SYNOPSIS
        Re-validates a file manifest without deleting anything.

    .DESCRIPTION
        Shared by the dry run and by the real delete, so what a dry run reports is produced
        by the same validation that governs the real thing.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)]$Action, [Parameter(Mandatory)]$Operation)

    $config = $Session.Config
    $policy = $config.Policy
    $parameters = $Operation.Parameters

    $root = (Get-WaApprovedRoot -Session $Session -RootKey ([string]$parameters['RootKey'])).Path
    $cutoff = [datetime]::MaxValue
    $rawCutoff = $parameters['CutoffUtc']
    if ($rawCutoff -is [datetime]) {
        $cutoff = $rawCutoff
    } elseif ($rawCutoff) {
        $parsed = [datetime]::MinValue
        if ([datetime]::TryParse([string]$rawCutoff, [ref]$parsed)) { $cutoff = $parsed.ToUniversalTime() }
    }

    $files = @($parameters['Files'])
    $eligible = New-Object 'System.Collections.Generic.List[object]'
    $skipped = New-Object 'System.Collections.Generic.List[object]'
    $bytes = [long]0

    foreach ($file in $files) {
        $decision = Test-WaFileDeleteAllowed -Path ([string]$file.Path) -Root $root -Config $config -Policy $policy -CutoffUtc $cutoff -Manifest $file
        if ($decision.Allowed) {
            # Carry the normalised path the validator actually approved, so the delete acts
            # on exactly the string that passed every check rather than re-deriving it.
            $eligible.Add([pscustomobject]@{
                Path          = $decision.Path
                ManifestPath  = $file.Path
                Length        = $file.Length
                LastWriteUtc  = $file.LastWriteUtc
            })
            $bytes += [long]$file.Length
        } else {
            $skipped.Add([pscustomobject]@{ Path = $file.Path; Reason = $decision.Reason })
        }
    }

    [pscustomobject]@{
        Root         = $root
        TotalCount   = $files.Count
        EligibleCount = $eligible.Count
        SkippedCount = $skipped.Count
        Eligible     = $eligible.ToArray()
        Skipped      = $skipped.ToArray()
        Bytes        = $bytes
    }
}

function Invoke-WaFileDeleteOperation {
    <#
    .SYNOPSIS
        Deletes the files in a reviewed manifest, re-validating each immediately first.

    .DESCRIPTION
        The manifest was produced during analysis and reviewed by a person. Between then
        and now a file may have been written to, locked, replaced by a link, or moved
        behind a protected path, so each one is checked again at the moment of deletion.
        A file that fails any check is skipped with a recorded reason rather than forced.

        A file that Windows refuses to delete because an application has it open, or
        because access is denied (a running executable, a loaded DLL), is left in place.
        That is the normal state of a folder in active use, not a fault: the operation
        succeeded if it deleted anything, and is skipped, not failed, if there was nothing
        it could delete. Only an error of an unexpected kind counts as a failure.

        No directory is ever removed, and no recursive delete is performed. Only the exact
        files in the manifest are touched.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)]$Action, [Parameter(Mandatory)]$Operation)

    [void](Assert-WaMutationAllowed -Session $Session -Operation 'file deletion')

    # Re-validating a large manifest is itself slow, so it is announced before it starts.
    Write-WaExecutionProgress -Phase 'Operation' -ActionId $Action.Id `
        -Message ('re-checking {0:N0} reviewed file(s)' -f @($Operation.Parameters['Files']).Count)

    $preview = Get-WaFileDeletePreview -Session $Session -Action $Action -Operation $Operation
    $messages = New-Object 'System.Collections.Generic.List[string]'
    $deletedBytes = [long]0
    $deletedCount = 0
    $inUseCount = 0
    $errorCount = 0
    $firstError = ''
    $processedCount = 0

    foreach ($file in $preview.Eligible) {
        $path = [string]$file.Path
        try {
            # Delete by exact path only. No wildcard, no recursion, no directory removal.
            [IO.File]::Delete($path)
            $deletedCount++
            $deletedBytes += [long]$file.Length
        } catch [IO.IOException], [UnauthorizedAccessException] {
            # Open by an application, a running executable, or removed by something else
            # in the meantime. Normal for a live folder; the file is simply left alone.
            $inUseCount++
        } catch {
            $errorCount++
            if (-not $firstError) { $firstError = $_.Exception.Message }
        }

        # Throttled: a manifest of tens of thousands of files would otherwise spend more
        # time reporting than deleting.
        $processedCount++
        Write-WaExecutionProgress -Phase 'Operation' -ActionId $Action.Id -Throttle `
            -Message ('deleting file {0:N0} of {1:N0}, {2} so far' -f
                $processedCount, $preview.EligibleCount, (Format-WaBytes $deletedBytes))
    }

    if ($deletedCount -gt 0) {
        $messages.Add(('Deleted {0} file(s) totalling {1} under {2}.' -f $deletedCount, (Format-WaBytes $deletedBytes), $preview.Root))
    } else {
        $messages.Add(('Nothing was deleted under {0}.' -f $preview.Root))
    }
    if ($preview.SkippedCount -gt 0) {
        $reasons = @($preview.Skipped | Group-Object Reason | Sort-Object Count -Descending | Select-Object -First 4 |
            ForEach-Object { '{0} ({1})' -f $_.Name, $_.Count })
        $messages.Add(('Skipped {0} file(s) that were no longer eligible: {1}' -f $preview.SkippedCount, ($reasons -join '; ')))
    }
    if ($inUseCount -gt 0) {
        $messages.Add(('{0} file(s) were left in place because an application has them open or access was denied. That is normal for a folder in use; they are considered again on the next run.' -f $inUseCount))
    }
    if ($errorCount -gt 0) {
        $messages.Add(('{0} file(s) could not be deleted for an unexpected reason: {1}' -f $errorCount, $firstError))
    }

    # Deleting something is success. Deleting nothing is a failure only when something
    # actually went wrong; a folder whose every candidate is in use is simply skipped.
    $status = if ($deletedCount -gt 0) { 'Succeeded' }
              elseif ($errorCount -gt 0) { 'Failed' }
              else { 'Skipped' }

    [pscustomobject]@{
        Kind           = 'FileDelete'
        Status         = $status
        Messages       = $messages.ToArray()
        BytesReclaimed = $deletedBytes
        RollbackId     = ''
        Detail         = [ordered]@{
            Root      = $preview.Root
            Deleted   = $deletedCount
            Skipped   = $preview.SkippedCount
            InUse     = $inUseCount
            Errors    = $errorCount
            Reviewed  = $preview.TotalCount
        }
    }
}

# The action whose approval and policy were last verified for Czkawka deletion, and an
# identity index of its operations. One reviewed action can hold thousands of deletions;
# re-fingerprinting the whole action for each file would make the run quadratic. Both are
# cleared at the start of every action (Invoke-WaPlannedAction), so a check never outlives
# the single action it was made for.
$script:WaCzkawkaVerifiedAction = $null
$script:WaCzkawkaOperationIndex = $null

function Test-WaActionContainsOperation {
    <# True when this exact operation object appears exactly once in the action. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Action, [Parameter(Mandatory)]$Operation)

    if ($null -eq $script:WaCzkawkaOperationIndex -or -not [object]::ReferenceEquals($script:WaCzkawkaOperationIndex.Action, $Action)) {
        $index = New-Object 'System.Collections.Generic.Dictionary[int,System.Collections.Generic.List[object]]'
        foreach ($candidate in @($Action.Recommendation.Operations)) {
            $key = [Runtime.CompilerServices.RuntimeHelpers]::GetHashCode($candidate)
            if (-not $index.ContainsKey($key)) { $index[$key] = New-Object 'System.Collections.Generic.List[object]' }
            $index[$key].Add($candidate)
        }
        $script:WaCzkawkaOperationIndex = @{ Action = $Action; Index = $index }
    }
    $key = [Runtime.CompilerServices.RuntimeHelpers]::GetHashCode($Operation)
    if (-not $script:WaCzkawkaOperationIndex.Index.ContainsKey($key)) { return $false }
    $found = 0
    foreach ($candidate in $script:WaCzkawkaOperationIndex.Index[$key]) {
        if ([object]::ReferenceEquals($candidate, $Operation)) { $found++ }
    }
    return ($found -eq 1)
}

function Invoke-WaCzkawkaDeleteOperation {
    <# Deletes only a session-registered, individually approved Czkawka candidate. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)]$Action, [Parameter(Mandatory)]$Operation)

    [void](Assert-WaMutationAllowed -Session $Session -Operation 'Czkawka deletion')
    if (-not [object]::ReferenceEquals($script:WaCzkawkaVerifiedAction, $Action)) {
        [void](Assert-WaRecommendationPolicy -Recommendation $Action.Recommendation -Policy $Session.Config.Policy)
        if ($Action.Recommendation.Provider -ne 'External.Czkawka' -or -not (Test-WaApproval $Action) -or $Action.Approval.Scope -ne 'Individual') {
            throw 'Czkawka deletion requires individual approval of this exact operation.'
        }
        $script:WaCzkawkaVerifiedAction = $Action
    }
    if (-not (Test-WaActionContainsOperation -Action $Action -Operation $Operation)) {
        throw 'Czkawka deletion requires individual approval of this exact operation.'
    }
    $targetStream = $null
    $keeperStream = $null
    $deleted = 0
    $bytes = [long]0
    $status = 'Skipped'
    $messages = New-Object 'System.Collections.Generic.List[string]'
    try {
        $keeper = Assert-WaCzkawkaCandidate $Session $Operation
        $parameters = $Operation.Parameters
        if ($parameters.Mode -eq 'empty-folders') {
            foreach ($directory in $parameters.Directories) {
                # Revalidate the absolute target; never recursively remove a directory.
                # Directory.Delete(false) fails if anything was added after the scan.
                Assert-WaCzkawkaPath $Session $directory
                [IO.Directory]::Delete($directory, $false)
                $deleted++
            }
        } else {
            # Hold the kept file against writes/removal while deleting the other copy, then
            # re-check with that same kept file.
            if ($null -ne $keeper) {
                $keeperStream = [IO.File]::Open($keeper.Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
            }
            $targetStream = [IO.File]::Open($parameters.Target.Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::Read -bor [IO.FileShare]::Delete))
            [void](Assert-WaCzkawkaCandidate $Session $Operation -Keeper $keeper)
            [IO.File]::Delete($parameters.Target.Path)
            $deleted = 1
            $bytes = [long]$parameters.Target.Length
        }
        $status = 'Succeeded'
        $messages.Add(('Permanently deleted {0} item(s): {1}' -f $deleted, $parameters.Target.Path))
    } catch {
        $messages.Add(('Left in place where possible: {0}. Removed {1} item(s).' -f $_.Exception.Message, $deleted))
        if ($deleted -gt 0) { $status = 'Failed' }
    } finally {
        if ($null -ne $targetStream) { $targetStream.Dispose() }
        if ($null -ne $keeperStream) { $keeperStream.Dispose() }
    }
    [pscustomobject]@{
        Kind = 'CzkawkaDelete'; Status = $status; Messages = $messages.ToArray()
        BytesReclaimed = $bytes; RollbackId = ''; Detail = @{ Deleted = $deleted }
    }
}

function Invoke-WaNativeCommandOperation {
    <#
    .SYNOPSIS
        Runs one catalog command.

    .DESCRIPTION
        The catalog owns the executable and the arguments. The only thing the operation
        supplies is the catalog id and any declared placeholder values, which are validated
        against their patterns during resolution.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)]$Action, [Parameter(Mandatory)]$Operation)

    [void](Assert-WaMutationAllowed -Session $Session -Operation 'native command')

    $commandId = [string]$Operation.Parameters['CommandId']
    $resolved = Resolve-WaCommand -CommandId $commandId -Values (Get-WaOperationValues -Operation $Operation)

    if (-not $resolved.Available) {
        return [pscustomobject]@{
            Kind = 'NativeCommand'; Status = 'Failed'
            Messages = @(("{0} is not installed on this machine, so '{1}' could not run." -f $resolved.Tool, $commandId))
            BytesReclaimed = $null; RollbackId = ''
        }
    }
    if ($resolved.RequiresAdmin -and -not $Session.IsAdministrator) {
        return [pscustomobject]@{
            Kind = 'NativeCommand'; Status = 'Blocked'
            Messages = @(("'{0}' needs administrator rights and this session is not elevated." -f $resolved.Preview))
            BytesReclaimed = $null; RollbackId = ''
        }
    }

    Write-WaLog -Session $Session -Level 'Info' -Category 'Execution' -Message ('Running: {0}' -f $resolved.Preview)

    # A command with a documented counterpart gets a rollback record naming it.
    $rollbackId = ''
    $definition = Get-WaCommandDefinition -CommandId $commandId
    if ($definition.Reverses) {
        $record = Add-WaRollbackRecord -Session $Session -ActionId $Action.Id -Kind 'NativeCommand' `
            -Target $resolved.Preview -BeforeValue 'before' -AfterValue 'after' `
            -RestoreDescription ("Reverse by running the documented counterpart command '{0}'." -f $definition.Reverses) `
            -RestoreParameters ([ordered]@{ ReverseCommandId = $definition.Reverses })
        $rollbackId = $record.Id
    }

    # Servicing commands routinely run for minutes with nothing on stdout. The heartbeat is
    # the only sign the machine is still working rather than stuck.
    # Not GetNewClosure: that would rebind the scriptblock to a new dynamic module where
    # Write-WaExecutionProgress does not exist. A plain scriptblock keeps this module, and
    # reads $actionId and $resolved from this scope, which is still on the stack while the
    # process it is reporting on runs.
    $actionId = [string]$Action.Id
    $heartbeat = {
        param($Elapsed)
        Write-WaExecutionProgress -Phase 'Operation' -ActionId $actionId `
            -Message ('{0} has been running for {1}s. It is still working; do not interrupt it.' -f
                [IO.Path]::GetFileName($resolved.FilePath), [int]$Elapsed.TotalSeconds)
    }

    Write-WaExecutionProgress -Phase 'Operation' -ActionId $Action.Id -Message ('running: {0}' -f $resolved.Preview)
    $result = Invoke-WaNativeProcess -FilePath $resolved.FilePath -Arguments $resolved.Arguments `
                -TimeoutSeconds $resolved.TimeoutSeconds -NeverKill:$resolved.NeverKill `
                -OnHeartbeat $heartbeat -HeartbeatSeconds 5 -Environment $resolved.Environment

    return (Get-WaNativeCommandOutcome -Resolved $resolved -Result $result -RollbackId $rollbackId)
}

function Get-WaNativeCommandOutcome {
    <#
    .SYNOPSIS
        Turns a finished process into an operation outcome.

    .DESCRIPTION
        A non-zero exit is a failure unless the catalog entry declares a BusyPattern and the
        output matches it. That is the tool saying another process holds its data and it
        changed nothing, which is a reason to try later, not a fault, and it is reported as
        skipped with the entry's advice on what usually holds the resource.

        Kept separate from the process launch so the classification can be exercised with
        recorded output, without the tool being installed or its data being busy.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Resolved,
        [Parameter(Mandatory)]$Result,
        [string]$RollbackId = ''
    )

    $messages = New-Object 'System.Collections.Generic.List[string]'
    $messages.Add(('Ran: {0}' -f $Resolved.Preview))
    $messages.Add(('Exit code: {0}' -f $Result.ExitCode))

    $output = Get-WaRedactedText -Text ([string]$Result.Output)
    $outputLine = Get-WaOutputTail -Text $output
    if ($outputLine) { $messages.Add(('Output: {0}' -f $outputLine)) }

    # Several tools report what they freed on stdout; parse it as a measured figure.
    $reclaimed = Get-WaReclaimedBytesFromOutput -Text ([string]$Result.Output)

    if ($Result.ExitCode -ne 0) {
        $errorText = Get-WaRedactedText -Text ([string]$Result.Error)
        $errorLine = Get-WaOutputTail -Text $errorText
        if ($errorLine) { $messages.Add(('Error output: {0}' -f $errorLine)) }

        $busyPattern = [string](Get-WaProperty -Object $Resolved -Name 'BusyPattern' -Default '')
        if ($busyPattern -and (($errorText + "`n" + $output) -match $busyPattern)) {
            $explanation = ("Another {0} process is using the data this command works on, so '{1}' stopped without changing anything." -f
                $Resolved.Tool, $Resolved.Preview)
            $advice = [string](Get-WaProperty -Object $Resolved -Name 'BusyAdvice' -Default '')
            if ($advice) { $explanation = $explanation + ' ' + $advice }
            return [pscustomobject]@{
                Kind = 'NativeCommand'; Status = 'Skipped'
                Messages = @(@($explanation) + $messages.ToArray())
                BytesReclaimed = $null; RollbackId = $RollbackId
            }
        }

        return [pscustomobject]@{
            Kind = 'NativeCommand'; Status = 'Failed'
            Messages = $messages.ToArray()
            BytesReclaimed = $null; RollbackId = $RollbackId
        }
    }

    [pscustomobject]@{
        Kind = 'NativeCommand'; Status = 'Succeeded'
        Messages = $messages.ToArray()
        BytesReclaimed = $reclaimed
        RollbackId = $RollbackId
    }
}

function Get-WaOutputTail {
    <#
    .SYNOPSIS
        The last few non-empty lines of tool output on one line, for the results view.

    .DESCRIPTION
        Results are printed indented under their action. A raw multi-line message breaks
        that indentation, so lines are joined with a separator instead.
    #>
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Text, [int]$Lines = 6)

    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    $tail = @($Text -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Last $Lines)
    return ($tail -join ' | ')
}

function Get-WaReclaimedBytesFromOutput {
    <#
    .SYNOPSIS
        Extracts a reclaimed-space figure from tool output, when the tool reports one.

    .DESCRIPTION
        Docker prints "Total reclaimed space: 21.4GB". When a tool states what it freed,
        that is a measured figure and is preferred over the estimate. Returns $null when
        nothing can be parsed, so an estimate is never presented as a measurement.
    #>
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $match = [regex]::Match($Text, '(?i)(?:total\s+reclaimed\s+space|reclaimed)\s*:?\s*(?<value>[\d.]+)\s*(?<unit>B|KB|MB|GB|TB|KiB|MiB|GiB|TiB)')
    if (-not $match.Success) { return $null }

    $value = [double]$match.Groups['value'].Value
    switch -Regex ($match.Groups['unit'].Value) {
        '^(KB|KiB)$' { return [long]($value * 1KB) }
        '^(MB|MiB)$' { return [long]($value * 1MB) }
        '^(GB|GiB)$' { return [long]($value * 1GB) }
        '^(TB|TiB)$' { return [long]($value * 1TB) }
        default      { return [long]$value }
    }
}

function Invoke-WaRegistryValueSetOperation {
    <#
    .SYNOPSIS
        Writes one registry value, capturing the prior state first.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)]$Action, [Parameter(Mandatory)]$Operation)

    [void](Assert-WaMutationAllowed -Session $Session -Operation 'registry write')

    $parameters = $Operation.Parameters
    $path  = [string]$parameters['Path']
    $name  = [string]$parameters['Name']
    $value = $parameters['Value']
    $type  = [string](Get-WaProperty -Object $parameters -Name 'Type' -Default 'DWord')

    if ($path -notmatch '^(HKLM|HKCU):\\') {
        throw "Registry writes are limited to HKLM: and HKCU:. Refused: $path"
    }
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Registry key does not exist: $path"
    }

    $existed = $true
    $before = $null
    try {
        $current = Get-ItemProperty -LiteralPath $path -Name $name -ErrorAction Stop
        $before = $current.$name
    } catch {
        $existed = $false
    }

    $record = Add-WaRollbackRecord -Session $Session -ActionId $Action.Id -Kind 'RegistryValueSet' `
        -Target ('{0}\{1}' -f $path, $name) -BeforeValue $before -AfterValue $value -Existed $existed `
        -RestoreDescription $(if ($existed) { 'Write the previous value back.' } else { 'Remove the value, which did not exist before.' }) `
        -RestoreParameters ([ordered]@{ Path = $path; Name = $name; Type = $type })

    if ($existed -and $before -eq $value) {
        return [pscustomobject]@{
            Kind = 'RegistryValueSet'; Status = 'Succeeded'
            Messages = @(('{0}\{1} already has the intended value; nothing was written.' -f $path, $name))
            BytesReclaimed = $null; RollbackId = $record.Id
        }
    }

    if ($existed) {
        Set-ItemProperty -LiteralPath $path -Name $name -Value $value -Force -ErrorAction Stop
    } else {
        [void](New-ItemProperty -LiteralPath $path -Name $name -Value $value -PropertyType $type -Force -ErrorAction Stop)
    }

    [pscustomobject]@{
        Kind = 'RegistryValueSet'; Status = 'Succeeded'
        Messages = @(('Set {0}\{1} to {2} (was {3}).' -f $path, $name, $value, $(if ($existed) { $before } else { 'absent' })))
        BytesReclaimed = $null; RollbackId = $record.Id
    }
}

function Invoke-WaServiceStartupSetOperation {
    <#
    .SYNOPSIS
        Changes one service start mode, with the prior mode captured first.

    .DESCRIPTION
        No service recommendation ships in the default policy, so this handler is normally
        unreachable. It exists, is tested and refuses protected services, so that a curated
        service entry added to Config/policies.json is executed safely rather than through
        code written in a hurry later.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)]$Action, [Parameter(Mandatory)]$Operation)

    [void](Assert-WaMutationAllowed -Session $Session -Operation 'service configuration')

    $parameters = $Operation.Parameters
    $serviceName = [string]$parameters['ServiceName']
    $startupType = [string]$parameters['StartupType']

    if (Test-WaProtectedService -Name $serviceName -Policy $Session.Config.Policy) {
        throw "Service '$serviceName' is on the protected list and will not be modified."
    }
    if (@('Automatic', 'Manual', 'Disabled', 'AutomaticDelayedStart') -notcontains $startupType) {
        throw "Unsupported service start mode '$startupType'."
    }

    $service = Get-Service -Name $serviceName -ErrorAction Stop
    $currentStartType = [string]$service.StartType

    if ($currentStartType -eq $startupType) {
        return [pscustomobject]@{
            Kind = 'ServiceStartupSet'; Status = 'Succeeded'
            Messages = @(("Service '{0}' is already set to {1}; nothing was changed." -f $serviceName, $startupType))
            BytesReclaimed = $null; RollbackId = ''
        }
    }

    $record = Add-WaRollbackRecord -Session $Session -ActionId $Action.Id -Kind 'ServiceStartupSet' `
        -Target $serviceName -BeforeValue $currentStartType -AfterValue $startupType `
        -RestoreDescription ("Set the '{0}' service start mode back to {1}." -f $serviceName, $currentStartType) `
        -RestoreParameters ([ordered]@{ ServiceName = $serviceName })

    Set-Service -Name $serviceName -StartupType $startupType -ErrorAction Stop

    [pscustomobject]@{
        Kind = 'ServiceStartupSet'; Status = 'Succeeded'
        Messages = @(("Service '{0}' start mode changed from {1} to {2}." -f $serviceName, $currentStartType, $startupType))
        BytesReclaimed = $null; RollbackId = $record.Id
    }
}

function Invoke-WaScheduledTaskStateOperation {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)]$Action, [Parameter(Mandatory)]$Operation)

    [void](Assert-WaMutationAllowed -Session $Session -Operation 'scheduled task state change')

    $parameters = $Operation.Parameters
    $taskPath = [string]$parameters['TaskPath']
    $taskName = [string]$parameters['TaskName']
    $enabled  = [bool]$parameters['Enabled']

    if ($taskPath -like '\Microsoft\Windows\*') {
        throw "Task '$taskPath$taskName' belongs to Windows servicing and will not be modified."
    }

    $task = Get-ScheduledTask -TaskPath $taskPath -TaskName $taskName -ErrorAction Stop
    $currentlyEnabled = ($task.State -ne 'Disabled')

    if ($currentlyEnabled -eq $enabled) {
        return [pscustomobject]@{
            Kind = 'ScheduledTaskState'; Status = 'Succeeded'
            Messages = @(("Task '{0}' is already {1}; nothing was changed." -f $taskName, $(if ($enabled) { 'enabled' } else { 'disabled' })))
            BytesReclaimed = $null; RollbackId = ''
        }
    }

    $record = Add-WaRollbackRecord -Session $Session -ActionId $Action.Id -Kind 'ScheduledTaskState' `
        -Target ('{0}{1}' -f $taskPath, $taskName) -BeforeValue $currentlyEnabled -AfterValue $enabled `
        -RestoreDescription ("Set task '{0}' back to {1}." -f $taskName, $(if ($currentlyEnabled) { 'enabled' } else { 'disabled' })) `
        -RestoreParameters ([ordered]@{ TaskPath = $taskPath; TaskName = $taskName })

    if ($enabled) {
        [void](Enable-ScheduledTask -TaskPath $taskPath -TaskName $taskName -ErrorAction Stop)
    } else {
        [void](Disable-ScheduledTask -TaskPath $taskPath -TaskName $taskName -ErrorAction Stop)
    }

    [pscustomobject]@{
        Kind = 'ScheduledTaskState'; Status = 'Succeeded'
        Messages = @(("Task '{0}' set to {1}." -f $taskName, $(if ($enabled) { 'enabled' } else { 'disabled' })))
        BytesReclaimed = $null; RollbackId = $record.Id
    }
}

function Set-WaStartupApprovedState {
    <#
    .SYNOPSIS
        Writes the Explorer StartupApproved state for one startup item.

    .DESCRIPTION
        The value is a binary blob whose first byte carries the state: even means enabled,
        odd means disabled. Any existing bytes are preserved and only the first is changed,
        so Explorer's own bookkeeping (including the timestamp it records) survives.

        The original Run value or startup shortcut is never touched, which is what makes
        this reversible with a single write.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('Run', 'Run32', 'StartupFolder')][string]$Scope,
        [Parameter(Mandatory)][ValidateSet('User', 'Machine')][string]$Hive,
        [Parameter(Mandatory)][bool]$Enabled
    )

    [void](Assert-WaMutationAllowed -Session $Session -Operation 'startup item state change')

    $root = if ($Hive -eq 'User') { 'HKCU:' } else { 'HKLM:' }
    $path = "$root\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\$Scope"

    if (-not (Test-Path -LiteralPath $path)) {
        [void](New-Item -Path $path -Force -ErrorAction Stop)
    }

    $bytes = $null
    try {
        $existing = Get-ItemProperty -LiteralPath $path -Name $Name -ErrorAction Stop
        $bytes = [byte[]]@($existing.$Name)
    } catch {
        $bytes = New-Object 'byte[]' 12
    }
    if ($null -eq $bytes -or $bytes.Length -lt 1) { $bytes = New-Object 'byte[]' 12 }

    $bytes[0] = if ($Enabled) { [byte]2 } else { [byte]3 }

    [void](New-ItemProperty -LiteralPath $path -Name $Name -Value $bytes -PropertyType 'Binary' -Force -ErrorAction Stop)
    return $path
}

function Invoke-WaStartupItemStateOperation {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)]$Action, [Parameter(Mandatory)]$Operation)

    [void](Assert-WaMutationAllowed -Session $Session -Operation 'startup item state change')

    $parameters = $Operation.Parameters
    $name    = [string]$parameters['Name']
    $scope   = [string]$parameters['Scope']
    $hive    = [string]$parameters['Hive']
    $enabled = [bool]$parameters['Enabled']

    # Re-checked here: policy protection must hold at execution time, not only at analysis.
    if (Test-WaProtectedStartupItem -Name $name -Policy $Session.Config.Policy) {
        throw "Startup item '$name' is protected by policy and will not be changed."
    }

    $current = Get-WaStartupApprovedState -Name $name -Scope $scope -Hive $hive
    if ($current.Enabled -eq $enabled) {
        return [pscustomobject]@{
            Kind = 'StartupItemState'; Status = 'Succeeded'
            Messages = @(("Startup item '{0}' is already {1}; nothing was changed." -f $name, $(if ($enabled) { 'enabled' } else { 'disabled' })))
            BytesReclaimed = $null; RollbackId = ''
        }
    }

    $record = Add-WaRollbackRecord -Session $Session -ActionId $Action.Id -Kind 'StartupItemState' `
        -Target $name -BeforeValue $current.Enabled -AfterValue $enabled `
        -RestoreDescription ("Set startup item '{0}' back to {1}." -f $name, $(if ($current.Enabled) { 'enabled' } else { 'disabled' })) `
        -RestoreParameters ([ordered]@{ Name = $name; Scope = $scope; Hive = $hive })

    [void](Set-WaStartupApprovedState -Session $Session -Name $name -Scope $scope -Hive $hive -Enabled $enabled)

    [pscustomobject]@{
        Kind = 'StartupItemState'; Status = 'Succeeded'
        Messages = @(
            ("Startup item '{0}' set to {1}. The original entry was left in place." -f $name, $(if ($enabled) { 'enabled' } else { 'disabled' }))
            'Sign out and back in for this to take effect.'
        )
        BytesReclaimed = $null; RollbackId = $record.Id
    }
}

function Invoke-WaRestorePointCreation {
    <#
    .SYNOPSIS
        Attempts a System Restore checkpoint before high-risk changes.

    .DESCRIPTION
        Best effort, and never treated as a safety net. System Restore does not restore
        personal files, can be disabled per volume, and Windows rate-limits checkpoint
        creation. A failure here is reported and the run continues, because presenting a
        restore point that was not created as protection would be worse than having none.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session)

    [void](Assert-WaMutationAllowed -Session $Session -Operation 'restore point creation')

    $result = {
        param([string]$Status, [string]$Message)
        New-WaExecutionResult -ActionId 'core.restorepoint' -Provider 'Windows.RestorePoints' -Status $Status `
            -Summary 'System Restore checkpoint' -Messages @($Message)
    }

    if (-not $Session.IsAdministrator) {
        return (& $result 'Skipped' 'A restore point needs administrator rights and this session is not elevated. Continuing without one.')
    }

    try {
        Checkpoint-Computer -Description ('WinAdvisor {0}' -f $Session.Id) -RestorePointType 'MODIFY_SETTINGS' -ErrorAction Stop
        Write-WaLog -Session $Session -Level 'Info' -Category 'Execution' -Message 'System Restore checkpoint created.'
        return (& $result 'Succeeded' 'Created a System Restore checkpoint. Note that System Restore does not restore personal files and is not a general undo.')
    } catch {
        # Windows rate-limits checkpoints and refuses when protection is off; both are normal.
        return (& $result 'Skipped' ('A restore point could not be created, so the run continued without one. Windows limits how often checkpoints are made and refuses when System Protection is off. ({0})' -f $_.Exception.Message))
    }
}
