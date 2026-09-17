<#
    Core/Elevation.ps1 - privilege handling.

    The toolkit does not require elevation. Inspection, analysis, dry run and every
    user-scope cleanup work in an ordinary session, which is the normal way to use it.

    Design decision (ADR-004 in docs/ARCHITECTURE.md): an approved plan is never marshalled
    across the privilege boundary. Handing a serialised list of file paths and commands to
    an elevated child process creates exactly the channel an attacker would want, since
    anything able to influence that payload gains administrator execution.

    Instead, when an approved action needs administrator rights and the session does not
    have them, the action is blocked with an explanation, and the user is offered a
    relaunch of the whole toolkit elevated. The elevated run repeats discovery and asks for
    approval again, in that session. Re-approving a handful of items is a small cost for
    removing a privilege-escalation channel entirely.
#>

function Get-WaElevationRequirement {
    <#
    .SYNOPSIS
        Reports which actions in a plan need administrator rights and whether they can run.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)]$Plan)

    $needsAdmin = @($Plan.Actions | Where-Object { $_.Recommendation.AdminRequired })

    [pscustomobject][ordered]@{
        IsElevated        = $Session.IsAdministrator
        RequiresElevation = ($needsAdmin.Count -gt 0)
        Satisfied         = ($needsAdmin.Count -eq 0 -or $Session.IsAdministrator)
        Actions           = @($needsAdmin | ForEach-Object {
            [pscustomobject]@{
                Id     = $_.Id
                Title  = $_.Recommendation.Title
                Risk   = $_.Recommendation.Risk
                Reason = (Get-WaElevationReason -Recommendation $_.Recommendation)
            }
        })
    }
}

function Get-WaElevationReason {
    <#
    .SYNOPSIS
        Explains, in plain terms, why one action needs administrator rights.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Recommendation)

    $reasons = New-Object 'System.Collections.Generic.List[string]'
    foreach ($operation in $Recommendation.Operations) {
        if (-not $operation.RequiresAdmin) { continue }
        switch ($operation.Kind) {
            'FileDelete'         { $reasons.Add('The files are outside your user profile, so deleting them needs administrator rights.') }
            'NativeCommand'      { $reasons.Add(('The command "{0}" services Windows itself and refuses to run unelevated.' -f $Recommendation.CommandPreview)) }
            'RegistryValueSet'   { $reasons.Add('Writing to a machine-wide registry key needs administrator rights.') }
            'ServiceStartupSet'  { $reasons.Add('Changing a service start mode needs administrator rights.') }
            'ScheduledTaskState' { $reasons.Add('Changing a machine-scope scheduled task needs administrator rights.') }
            'StartupItemState'   { $reasons.Add('This startup entry is machine-wide rather than per-user.') }
            'RestorePointCreate' { $reasons.Add('Creating a System Restore checkpoint needs administrator rights.') }
            default              { $reasons.Add('This operation needs administrator rights.') }
        }
    }
    if ($reasons.Count -eq 0) { return 'Administrator rights are declared for this action.' }
    return (($reasons | Select-Object -Unique) -join ' ')
}

function Request-WaElevatedRelaunch {
    <#
    .SYNOPSIS
        Offers to relaunch WinAdvisor elevated. Returns $true only if a process started.

    .DESCRIPTION
        Starts a fresh elevated instance of the launcher. Nothing about the current
        session's approvals is passed to it: the elevated instance rediscovers, re-analyses
        and asks for approval again. A cancelled UAC prompt is an ordinary outcome and is
        reported as such, not as an error.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]$Session,
        # Constrained: this value becomes an argument to an elevated process, so it is
        # restricted to the known modes rather than accepted as free text.
        [ValidateSet('Menu', 'ViewSpecs', 'Analyze', 'Storage', 'Startup', 'Plan', 'DryRun', 'Cleanup', 'Report', 'Rollback')]
        [string]$Mode = 'Menu'
    )

    if ($Session.IsAdministrator) {
        Write-WaLog -Session $Session -Level 'Info' -Category 'Elevation' -Message 'Already elevated; relaunch not needed.'
        return $false
    }

    $launcher = Join-Path (Get-WaModuleRoot) 'WinAdvisor.ps1'
    if (-not (Test-Path -LiteralPath $launcher -PathType Leaf)) {
        Add-WaSessionWarning -Session $Session -Message "Could not find the launcher at $launcher to relaunch elevated."
        return $false
    }

    # Not $host: that is a PowerShell automatic variable.
    $shellExecutable = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh.exe' } else { 'powershell.exe' }

    if (-not $PSCmdlet.ShouldProcess($launcher, 'Relaunch WinAdvisor with administrator rights')) { return $false }

    try {
        # -Verb RunAs triggers the UAC prompt. Arguments are fixed here, not user-supplied.
        $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $launcher), '-Mode', $Mode)
        [void](Start-Process -FilePath $shellExecutable -ArgumentList $arguments -Verb 'RunAs' -ErrorAction Stop)
        Write-WaLog -Session $Session -Level 'Info' -Category 'Elevation' -Message 'An elevated WinAdvisor instance was started. It performs its own discovery and asks for approval again.'
        return $true
    } catch {
        # The common case here is the user declining the UAC prompt.
        Write-WaLog -Session $Session -Level 'Info' -Category 'Elevation' -Message (
            'Elevation was not granted. Continuing without administrator rights; actions that need them stay blocked. ({0})' -f $_.Exception.Message
        )
        return $false
    }
}

function Test-WaOperationPrivilege {
    <#
    .SYNOPSIS
        True when the current session can perform this operation's privilege requirement.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)]$Operation)

    if (-not $Operation.RequiresAdmin) { return $true }
    return [bool]$Session.IsAdministrator
}
