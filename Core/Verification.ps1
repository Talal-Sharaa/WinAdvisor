<#
    Core/Verification.ps1 - before/after measurement.

    A baseline is captured immediately before execution and the same quantities are
    measured again afterwards. What is reported is the difference that was actually
    observed, alongside what was predicted, so the two can be compared honestly.

    Deliberately not inferred: speed, responsiveness, boot time or any other performance
    characteristic. Freeing disk space and disabling a startup entry are real, measurable
    outcomes. "The machine is now faster" is not something this toolkit measures, so it is
    not something this toolkit claims.

    Free space on a live system also moves for reasons unrelated to the run: Windows
    Update, the search indexer and the page file all write during it. The comparison says
    so rather than attributing every recovered byte to the cleanup.
#>

function Get-WaBaseline {
    <#
    .SYNOPSIS
        Captures the measurable state before a plan runs.

    .EXAMPLE
        $baseline = Get-WaBaseline -Session $session -Plan $plan
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Session,
        $Plan = $null
    )

    $metrics = New-Object 'System.Collections.Generic.List[object]'

    foreach ($volume in (Get-WaVolumeFreeSpace)) {
        $metrics.Add((New-WaBaselineMetric -Key ('volume.free.' + $volume.Drive) `
            -Name ('Free space on ' + $volume.Drive) -Unit 'bytes' -Value $volume.FreeBytes `
            -Source 'Win32_LogicalDisk'))
    }

    # Per-action targets: the size of each cleanup root the plan intends to touch.
    if ($null -ne $Plan) {
        foreach ($action in @($Plan.Actions)) {
            foreach ($operation in $action.Recommendation.Operations) {
                if ($operation.Kind -ne 'FileDelete') { continue }
                $root = [string]$operation.Parameters['Root']
                if (-not $root) { continue }
                $size = Get-WaDirectorySize -Path $root -Config $Session.Config
                $metrics.Add((New-WaBaselineMetric -Key ('path.size.' + $root) `
                    -Name ('Size of ' + $root) -Unit 'bytes' -Value $size.Bytes `
                    -Measured $size.Complete -Source 'Bounded filesystem enumeration'))
            }
        }
    }

    $hibernation = Get-WaProperty -Object $Session.MachineProfile -Name 'Hibernation'
    if ($null -ne $hibernation) {
        $metrics.Add((New-WaBaselineMetric -Key 'hibernation.enabled' -Name 'Hibernation enabled' -Unit 'boolean' `
            -Value $hibernation.Enabled -Source 'Registry Control\Power'))
        $metrics.Add((New-WaBaselineMetric -Key 'hibernation.size' -Name 'hiberfil.sys size' -Unit 'bytes' `
            -Value $hibernation.HiberfilBytes -Source 'Filesystem'))
    }

    $startup = @($Session.MachineProfile.Startup)
    $metrics.Add((New-WaBaselineMetric -Key 'startup.enabled.count' -Name 'Enabled startup items' -Unit 'count' `
        -Value @($startup | Where-Object { $_.Enabled }).Count -Source 'Registry and Task Scheduler'))

    [pscustomobject][ordered]@{
        PSTypeName  = 'WinAdvisor.Baseline'
        SessionId   = $Session.Id
        CapturedUtc = (Get-WaUtcTimestamp)
        Metrics     = $metrics.ToArray()
    }
}

function Compare-WaBaseline {
    <#
    .SYNOPSIS
        Re-measures after execution and reports what actually changed.

    .DESCRIPTION
        Two separate figures for storage:

          ReportedByActions  the sum of what each action measured itself as having freed.
                             This is the defensible figure: each number came from files
                             that were counted as they were deleted, or from a tool that
                             reported what it removed.

          VolumeDelta        the change in free space across all fixed volumes. Useful as
                             a sanity check, but it includes everything else that wrote to
                             disk during the run, so it is presented as context.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)]$Baseline,
        [object[]]$Results = @()
    )

    $after = Get-WaBaseline -Session $Session
    $beforeByKey = @{}
    foreach ($metric in $Baseline.Metrics) { $beforeByKey[$metric.Key] = $metric }

    $comparisons = New-Object 'System.Collections.Generic.List[object]'
    foreach ($metric in $after.Metrics) {
        if (-not $beforeByKey.ContainsKey($metric.Key)) { continue }
        $before = $beforeByKey[$metric.Key]

        $delta = $null
        if ($null -ne $before.Value -and $null -ne $metric.Value -and $metric.Unit -ne 'boolean') {
            try { $delta = [double]$metric.Value - [double]$before.Value } catch { $delta = $null }
        }

        $comparisons.Add([pscustomobject][ordered]@{
            Key         = $metric.Key
            Name        = $metric.Name
            Unit        = $metric.Unit
            Before      = $before.Value
            After       = $metric.Value
            Delta       = $delta
            Changed     = ($before.Value -ne $metric.Value)
            BeforeText  = (Format-WaMetricValue -Value $before.Value -Unit $metric.Unit)
            AfterText   = (Format-WaMetricValue -Value $metric.Value -Unit $metric.Unit)
        })
    }

    $volumeDelta = [double]0
    foreach ($comparison in @($comparisons | Where-Object { $_.Key -like 'volume.free.*' -and $null -ne $_.Delta })) {
        $volumeDelta += [double]$comparison.Delta
    }

    $reported = [long]0
    foreach ($result in $Results) {
        if ($null -ne $result.BytesReclaimed) { $reported += [long]$result.BytesReclaimed }
    }

    $estimated = [long]0
    # A session may reach verification without a plan attached (a provider-driven or
    # programmatic run). Treat that as "nothing was predicted" rather than failing the
    # whole verification pass, which would discard the measured results too.
    $planActions = @()
    if ($null -ne $Session.Plan) { $planActions = @($Session.Plan.Actions) }

    foreach ($action in $planActions) {
        $recommendation = $action.Recommendation
        if ($null -eq $recommendation.EstimatedBytes) { continue }
        $matchingResult = @($Results | Where-Object { $_.ActionId -eq $action.Id -and $_.Status -in @('Succeeded', 'PartiallySucceeded') })
        if ($matchingResult.Count -gt 0) { $estimated += [long]$recommendation.EstimatedBytes }
    }

    # Write the measured figure back onto the recommendations so reports can show
    # prediction against outcome per item.
    foreach ($result in $Results) {
        $action = @($planActions | Where-Object { $_.Id -eq $result.ActionId }) | Select-Object -First 1
        if ($null -eq $action) { continue }
        if ($null -eq $result.BytesReclaimed) { continue }
        $action.Recommendation.MeasuredBytes = [long]$result.BytesReclaimed
        $action.Recommendation.MeasuredBenefit = ('{0} reclaimed, measured during execution.' -f (Format-WaBytes $result.BytesReclaimed))
    }

    [pscustomobject][ordered]@{
        PSTypeName            = 'WinAdvisor.Verification'
        SessionId             = $Session.Id
        CompletedUtc          = (Get-WaUtcTimestamp)
        Metrics               = $comparisons.ToArray()
        ReportedBytesReclaimed = $reported
        VolumeFreeSpaceDelta  = [long]$volumeDelta
        EstimatedBytes        = $estimated
        EstimateAccuracy      = $(if ($estimated -gt 0) { Get-WaPercentage -Part $reported -Whole $estimated } else { $null })
        Succeeded             = @($Results | Where-Object { $_.Status -eq 'Succeeded' }).Count
        PartiallySucceeded    = @($Results | Where-Object { $_.Status -eq 'PartiallySucceeded' }).Count
        Failed                = @($Results | Where-Object { $_.Status -eq 'Failed' }).Count
        Skipped               = @($Results | Where-Object { $_.Status -eq 'Skipped' }).Count
        Blocked               = @($Results | Where-Object { $_.Status -eq 'Blocked' }).Count
        Notes                 = @(
            'Reported reclaimed space is the sum of what each action measured as it worked, and is the defensible figure.'
            'Free-space change across volumes is shown as context only. Windows writes to disk continuously during a run, so it will not match exactly and can even be negative.'
            'No performance improvement is claimed. Storage recovered and configuration changed are measured; speed is not measured and therefore is not reported.'
        )
    }
}

function Format-WaMetricValue {
    [CmdletBinding()]
    param($Value, [string]$Unit)
    if ($null -eq $Value) { return 'unknown' }
    switch ($Unit) {
        'bytes'   { return (Format-WaBytes $Value) }
        'boolean' { return $(if ([bool]$Value) { 'enabled' } else { 'disabled' }) }
        'count'   { return ([string]$Value) }
        default   { return ([string]$Value) }
    }
}

function Invoke-WaProviderVerification {
    <#
    .SYNOPSIS
        Asks each provider that implements TestResult to re-measure its own domain.

    .DESCRIPTION
        Volume free space is a blunt instrument. A provider can verify precisely: the
        Docker provider re-runs docker system df, so its claim is checked against the tool
        that owns the data rather than inferred from the disk.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session, [object[]]$Results = @())

    $verifications = New-Object 'System.Collections.Generic.List[object]'
    foreach ($provider in (Get-WaProvider)) {
        if ($null -eq $provider.TestResult) { continue }
        $relevant = @($Results | Where-Object { $_.Provider -eq $provider.Name -and $_.Status -in @('Succeeded', 'PartiallySucceeded') })
        if ($relevant.Count -eq 0) { continue }

        $outcome = Invoke-WaProviderStage -Session $Session -Provider $provider -Stage 'TestResult' -Arguments @($Session, $relevant)
        foreach ($item in @($outcome.Output)) {
            if ($null -ne $item) { $verifications.Add($item) }
        }
        if (-not $outcome.Succeeded) {
            $verifications.Add([pscustomobject]@{
                Provider = $provider.Name
                Verified = $false
                Message  = ("Verification failed: {0}" -f $outcome.Error)
            })
        }
    }
    return $verifications.ToArray()
}
