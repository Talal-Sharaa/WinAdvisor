<#
    Core/Entry.ps1 - Start-WinAdvisor and the top-level flows.

    Each mode is a composition of the same building blocks. Dry Run in particular is not a
    separate implementation: it runs discovery, analysis, questioning, planning, approval
    simulation and reporting through exactly the same functions as a real run, in a session
    whose ReadOnly flag makes the execution engine refuse to change anything.
#>

function Start-WinAdvisor {
    <#
    .SYNOPSIS
        Entry point. Runs the requested mode and returns the session when asked.

    .DESCRIPTION
        Every mode except Cleanup and Rollback creates a read-only session, which the
        execution engine enforces independently of anything the interface does.

    .EXAMPLE
        Start-WinAdvisor -Mode ViewSpecs

    .EXAMPLE
        $session = Start-WinAdvisor -Mode DryRun -PassThru
        $session.Recommendations | Format-Table Title, Risk, EstimatedBytes
    #>
    [CmdletBinding()]
    param(
        [ValidateSet('Menu', 'ViewSpecs', 'Analyze', 'Storage', 'Startup', 'Plan', 'DryRun', 'Cleanup', 'Report', 'Rollback')]
        [string]$Mode = 'Menu',

        [string]$ConfigPath,
        [string]$ReportPath,
        [string[]]$DeepScanPath,
        [string[]]$IncludeProvider,
        [string[]]$ExcludeProvider,
        [switch]$NonInteractive,
        [switch]$PassThru
    )

    if (-not (Test-WaWindowsPlatform)) {
        throw 'WinAdvisor inspects and services Windows, so it only runs on Windows.'
    }

    $sessionArguments = @{
        Mode           = $Mode
        NonInteractive = [bool]$NonInteractive
    }
    if ($ConfigPath)      { $sessionArguments.ConfigPath      = $ConfigPath }
    if ($ReportPath)      { $sessionArguments.ReportPath      = $ReportPath }
    if ($DeepScanPath)    { $sessionArguments.DeepScanPath    = $DeepScanPath }
    if ($IncludeProvider) { $sessionArguments.IncludeProvider = $IncludeProvider }
    if ($ExcludeProvider) { $sessionArguments.ExcludeProvider = $ExcludeProvider }

    $session = New-WaSession @sessionArguments
    Show-WaBanner -Session $session

    try {
        switch ($Mode) {
            'Menu' {
                Show-WaMenu -Session $session
            }
            'ViewSpecs' {
                [void](Get-WaMachineProfile -Session $session)
                Show-WaSpecs -Session $session
            }
            'Analyze' {
                $analysis = Get-WaAnalysis -Session $session -IncludeComponentStore
                Show-WaFindings -Analysis $analysis
                Show-WaProviderStatus -Analysis $analysis
                [void](Export-WaReport -Session $session -Analysis $analysis)
            }
            'Storage' {
                $analysis = Get-WaAnalysis -Session $session
                Show-WaStorageAnalysis -Session $session -Analysis $analysis -Deep:(@($session.Config.DeepScanPaths).Count -gt 0)
                [void](Export-WaReport -Session $session -Analysis $analysis)
            }
            'Startup' {
                [void](Get-WaMachineProfile -Session $session)
                Show-WaStartupAndMemory -Session $session
            }
            'Plan' {
                $analysis = Get-WaAnalysis -Session $session -IncludeComponentStore
                Show-WaQuestionSet -Session $session
                $plan = New-WaPlan -Session $session -Analysis $analysis
                Show-WaPlan -Plan $plan
                [void](Export-WaReport -Session $session -Analysis $analysis)
                Write-Host '  This is a plan only. Nothing was changed.' -ForegroundColor DarkGray
            }
            'DryRun' {
                [void](Invoke-WaDryRun -Session $session)
            }
            'Cleanup' {
                [void](Invoke-WaCleanupFlow -ParentSession $session)
            }
            'Report' {
                Show-WaReportList
                $analysis = Get-WaAnalysis -Session $session
                $paths = Export-WaReport -Session $session -Analysis $analysis
                foreach ($path in $paths) { Write-Host ('  written: {0}' -f $path) -ForegroundColor Green }
            }
            'Rollback' {
                Show-WaRollbackMenu -Session $session
            }
        }
    } catch {
        Write-WaLog -Session $session -Level 'Error' -Category 'Session' -Message ('Run failed: {0}' -f $_.Exception.Message)
        Write-Host ''
        Write-Host ('  {0}' -f $_.Exception.Message) -ForegroundColor Red
        Write-Host ('  The full log is at {0}' -f $session.LogPath) -ForegroundColor DarkGray
        throw
    } finally {
        [void](Complete-WaSession -Session $session)
    }

    if ($PassThru) { return $session }
}

function Invoke-WaDryRun {
    <#
    .SYNOPSIS
        Runs the complete pipeline and changes nothing.

    .DESCRIPTION
        Discovery, analysis, questioning, planning, approval simulation, command generation
        and reporting, all through the same code a real run uses. The only difference is
        that the session is read-only, so Invoke-WaPlan simulates instead of executing.

        Approval is simulated too: batch approval is applied to the plan so the output shows
        what would and would not have run, which is what makes a dry run worth reading.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session)

    if (-not $Session.ReadOnly) {
        throw 'Dry run requires a read-only session. This is a programming error, not a configuration one.'
    }

    Write-Host ''
    Write-Host '  DRY RUN - the full pipeline runs and nothing is changed.' -ForegroundColor Cyan

    $analysis = Get-WaAnalysis -Session $Session -IncludeComponentStore
    Show-WaQuestionSet -Session $Session
    $plan = New-WaPlan -Session $Session -Analysis $analysis
    Show-WaPlan -Plan $plan

    # Simulate the approval the user would most plausibly give, so the output shows the
    # split between what would run and what would still need a decision.
    $approvalOutcome = Grant-WaBatchApproval -Session $Session -Plan $plan
    Write-WaHeading 'Approval simulation'
    Write-Host ('    Would be approved in a batch at or below {0}: {1} item(s)' -f $approvalOutcome.MaximumRisk, @($approvalOutcome.Approved).Count) -ForegroundColor Gray
    foreach ($item in @($approvalOutcome.Approved)) { Write-Host ('      + {0}' -f $item.Title) -ForegroundColor DarkGray }
    Write-Host ('    Would still need a decision: {0} item(s)' -f @($approvalOutcome.Skipped).Count) -ForegroundColor Gray
    foreach ($item in @($approvalOutcome.Skipped)) { Write-Host ('      - {0} [{1}] {2}' -f $item.Title, $item.Risk, $item.Reason) -ForegroundColor DarkGray }

    $results = Invoke-WaPlan -Session $Session -Plan $plan
    Show-WaResults -Session $Session -Results $results

    $paths = Export-WaReport -Session $Session -Analysis $analysis
    Write-Host ''
    foreach ($path in $paths) { Write-Host ('  report: {0}' -f $path) -ForegroundColor Green }
    Write-Host '  Dry run complete. This machine was not modified.' -ForegroundColor Green

    return $results
}

function Invoke-WaCleanupFlow {
    <#
    .SYNOPSIS
        The interactive cleanup flow: analyse, ask, plan, approve, execute, verify, report.

    .DESCRIPTION
        Creates its own mutable session rather than reusing the caller's read-only one, so
        a read-only session is never promoted. The caller's configuration is carried over.

    .PARAMETER Custom
        Ask which providers to include before analysing, rather than running them all.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$ParentSession,
        [switch]$Custom
    )

    $config = $ParentSession.Config

    if ($Custom -and -not $ParentSession.NonInteractive) {
        Write-WaHeading 'Choose providers'
        $providers = @(Get-WaProvider)
        $index = 0
        foreach ($provider in $providers) {
            $index++
            Write-Host ('    [{0,2}] {1} {2}' -f $index, ([string]$provider.Name).PadRight(26), $provider.Title) -ForegroundColor Gray
        }
        Write-Host ''
        $selection = (Read-Host '  Numbers to include, comma separated (Enter for all)').Trim()
        if ($selection) {
            $chosen = New-Object 'System.Collections.Generic.List[string]'
            foreach ($part in ($selection -split ',')) {
                $number = 0
                if ([int]::TryParse($part.Trim(), [ref]$number) -and $number -ge 1 -and $number -le $providers.Count) {
                    $chosen.Add($providers[$number - 1].Name)
                }
            }
            if ($chosen.Count -gt 0) { $config.EnabledProviders = $chosen.ToArray() }
        }
    }

    $session = New-WaSession -Mode 'Cleanup' -Config $config -NonInteractive:$ParentSession.NonInteractive
    Show-WaBanner -Session $session

    try {
        $analysis = Get-WaAnalysis -Session $session -IncludeComponentStore
        Show-WaFindings -Analysis $analysis
        Show-WaQuestionSet -Session $session

        $plan = New-WaPlan -Session $session -Analysis $analysis
        Show-WaPlan -Plan $plan

        $elevation = Get-WaElevationRequirement -Session $session -Plan $plan
        if ($elevation.RequiresElevation -and -not $elevation.IsElevated) {
            Write-Host ''
            Write-Host '  Some proposed actions need administrator rights:' -ForegroundColor Yellow
            foreach ($item in @($elevation.Actions)) {
                Write-Host ('    - {0} [{1}]' -f $item.Title, $item.Risk) -ForegroundColor DarkGray
                Write-Host ('      {0}' -f $item.Reason) -ForegroundColor DarkGray
            }
            Write-Host '  They cannot be approved in this session. Everything else still can.' -ForegroundColor DarkGray

            if (-not $session.NonInteractive) {
                Write-Host ''
                $relaunch = (Read-Host '  Start an elevated WinAdvisor instead? It re-runs discovery and asks again. [y/N]').Trim().ToUpperInvariant()
                if ($relaunch -eq 'Y') {
                    if (Request-WaElevatedRelaunch -Session $session -Mode 'Cleanup' -Confirm:$false) {
                        Write-Host '  An elevated instance was started. Continue there.' -ForegroundColor Green
                        return @()
                    }
                    Write-Host '  Elevation was not granted. Continuing without it.' -ForegroundColor DarkGray
                }
            }
        }

        if (@($plan.Actions).Count -eq 0) {
            Write-Host '  Nothing to do.' -ForegroundColor Green
            return @()
        }

        Write-Host ''
        if (-not (Invoke-WaInteractiveApproval -Session $session -Plan $plan)) {
            Write-Host '  No action was approved, so nothing was changed.' -ForegroundColor Green
            [void](Export-WaReport -Session $session -Analysis $analysis)
            return @()
        }

        $approved = @(Get-WaApprovedAction -Plan $plan)
        if ($approved.Count -eq 0) {
            Write-Host '  Nothing ended up approved. Nothing was changed.' -ForegroundColor Green
            [void](Export-WaReport -Session $session -Analysis $analysis)
            return @()
        }

        Write-Host ''
        Write-Host ('  Executing {0} approved action(s).' -f $approved.Count) -ForegroundColor Cyan
        $results = Invoke-WaPlan -Session $session -Plan $plan
        Show-WaResults -Session $session -Results $results

        $providerVerification = Invoke-WaProviderVerification -Session $session -Results $results
        if (@($providerVerification).Count -gt 0) {
            Write-WaHeading 'Provider verification'
            foreach ($verification in @($providerVerification)) {
                Write-Host ('    {0}: {1}' -f
                    (Get-WaProperty -Object $verification -Name 'Provider'),
                    (Get-WaProperty -Object $verification -Name 'Message')) -ForegroundColor Gray
            }
        }

        $paths = Export-WaReport -Session $session -Analysis $analysis
        Write-Host ''
        foreach ($path in $paths) { Write-Host ('  report: {0}' -f $path) -ForegroundColor Green }

        $restartNeeded = @($results | Where-Object { $_.Status -eq 'Succeeded' } | ForEach-Object {
            $action = Get-WaPlanAction -Plan $plan -ActionId $_.ActionId
            if ($null -ne $action -and $action.Recommendation.RestartRequired -ne 'None') { $action.Recommendation }
        })
        if (@($restartNeeded).Count -gt 0) {
            Write-Host ''
            Write-Host '  Restart or sign-out required to complete:' -ForegroundColor Yellow
            foreach ($recommendation in @($restartNeeded)) {
                Write-Host ('    - {0} ({1})' -f $recommendation.Title, $recommendation.RestartRequired) -ForegroundColor DarkGray
            }
        }

        return $results
    } finally {
        [void](Complete-WaSession -Session $session)
    }
}
