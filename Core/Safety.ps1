<#
    Core/Safety.ps1 - path safety and policy enforcement.

    Everything that could damage the machine passes through this file. The rules here are
    deliberately independent of what a provider claims:

      * A provider declares cache roots. Safety decides whether a path is inside one.
      * A provider proposes a risk level. Safety enforces the policy floor for the
        operation kind, so a service change cannot be presented as SAFE.
      * A provider builds a file manifest during analysis. Safety re-validates every
        single file immediately before it is deleted, including that it has not changed
        since it was reviewed.

    The guiding rule: when safety cannot be positively established, refuse.
#>

# Reparse point (0x400), offline (0x1000), recall-on-open (0x40000) and
# recall-on-data-access (0x400000). Any of these means the path is a junction, a symlink,
# or a cloud placeholder whose content does not live where it appears to.
$script:WaLinkedOrOfflineAttributeMask = 0x00441400

function Get-WaNormalizedPath {
    <#
    .SYNOPSIS
        Normalises a path, rejecting anything that is not an absolute local filesystem path.

    .DESCRIPTION
        Rejects relative paths, UNC paths, wildcards, alternate data streams and device
        paths. Normalising first means a later prefix comparison cannot be defeated by
        '..' segments or mixed separators.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'Empty path rejected.' }
    if ($Path -notmatch '^[A-Za-z]:\\')      { throw "Only absolute local paths are accepted. Rejected: $Path" }
    if ($Path -match '[*?]')                 { throw "Wildcards are not accepted in a target path. Rejected: $Path" }
    # A second colon means an alternate data stream (C:\file.txt:stream).
    if ($Path.Substring(2).Contains(':'))    { throw "Alternate data streams are not accepted. Rejected: $Path" }

    $full = [IO.Path]::GetFullPath($Path)
    # Preserve a bare drive root as 'C:\'; trim the separator everywhere else so that
    # prefix comparisons are unambiguous.
    if ($full.Length -le 3) { return $full.ToUpperInvariant().Substring(0, 1) + ':\' }
    return $full.TrimEnd('\')
}

function Test-WaPathWithin {
    <#
    .SYNOPSIS
        True when Path is inside Root (or equal to it, with -AllowEqual).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Root,
        [switch]$AllowEqual
    )
    try {
        $candidate = Get-WaNormalizedPath -Path $Path
        $boundary  = Get-WaNormalizedPath -Path $Root
    } catch {
        return $false
    }

    if ($AllowEqual -and $candidate.Equals($boundary, [StringComparison]::OrdinalIgnoreCase)) { return $true }

    $prefix = if ($boundary.EndsWith('\')) { $boundary } else { $boundary + '\' }
    return $candidate.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
}

function Test-WaPathUnlinked {
    <#
    .SYNOPSIS
        True when a path and every one of its parents is a real local directory entry.

    .DESCRIPTION
        Deleting through a junction, a symlink or a OneDrive placeholder destroys data
        somewhere other than where the path suggests, and touching a placeholder can force
        a multi-gigabyte download. The whole ancestor chain is checked, because a junction
        three levels up redirects everything beneath it.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    try {
        $normalized = Get-WaNormalizedPath -Path $Path
        $item = Get-Item -LiteralPath $normalized -Force -ErrorAction Stop
        while ($null -ne $item) {
            if (([long]$item.Attributes -band $script:WaLinkedOrOfflineAttributeMask) -ne 0) { return $false }
            if ($item -is [IO.FileInfo]) { $item = $item.Directory } else { $item = $item.Parent }
        }
        return $true
    } catch {
        return $false
    }
}

function Test-WaProtectedPath {
    <#
    .SYNOPSIS
        True when a path is, or is inside, a policy-protected location.

    .DESCRIPTION
        Three lists, checked in order:

          AllowExactRootMatch  approved cleanup roots that sit under a protected parent
                               (Windows\Temp under Windows). Checked first, so the
                               exemption wins; every sibling stays protected.
          Paths                protected recursively: the path and everything beneath it.
          RootsOnly            protected as an exact path only. The user profile is here
                               rather than in Paths, because protecting it recursively
                               would also protect every application cache inside it.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Policy)

    try { $candidate = Get-WaNormalizedPath -Path $Path } catch { return $true }

    foreach ($exempt in $Policy.AllowExactRootMatch) {
        if (Test-WaPathWithin -Path $candidate -Root $exempt -AllowEqual) { return $false }
    }
    foreach ($protected in $Policy.ProtectedPaths) {
        if (Test-WaPathWithin -Path $candidate -Root $protected -AllowEqual) { return $true }
    }
    foreach ($rootOnly in $Policy.ProtectedRootsOnly) {
        try { $normalizedRoot = Get-WaNormalizedPath -Path $rootOnly } catch { continue }
        if ($candidate.Equals($normalizedRoot, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Test-WaProtectedSegment {
    <#
    .SYNOPSIS
        True when any directory name in the path is policy-protected (.git, node_modules, ...).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Policy)

    if ($Policy.ProtectedPathSegments.Count -eq 0) { return $false }
    foreach ($segment in $Path.Split([char]92)) {
        if ([string]::IsNullOrEmpty($segment)) { continue }
        foreach ($protected in $Policy.ProtectedPathSegments) {
            if ($segment.Equals($protected, [StringComparison]::OrdinalIgnoreCase)) { return $true }
        }
    }
    return $false
}

function Test-WaProtectedExtension {
    <#
    .SYNOPSIS
        True for file types that are never deleted, wherever they are found.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Policy)

    $extension = [IO.Path]::GetExtension($Path)
    if ([string]::IsNullOrEmpty($extension)) { return $false }
    return ($Policy.NeverDeleteExtensions -contains $extension.ToLowerInvariant())
}

function Test-WaExcludedPath {
    <#
    .SYNOPSIS
        True when the user has excluded this path in configuration.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Config)

    foreach ($excluded in $Config.ExcludedPaths) {
        if (Test-WaPathWithin -Path $Path -Root $excluded -AllowEqual) { return $true }
    }
    return $false
}

function Test-WaProtectedService {
    <#
    .SYNOPSIS
        True when a service is on the never-modify list. Wildcards are supported.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Name, [Parameter(Mandatory)]$Policy)

    if ([string]::IsNullOrWhiteSpace($Name)) { return $true }
    foreach ($pattern in $Policy.ProtectedServices) {
        if ($Name -like $pattern) { return $true }
    }
    return $false
}

function Test-WaProtectedStartupItem {
    <#
    .SYNOPSIS
        True when a startup item matches a never-disable pattern, by name or executable.
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyString()][string]$Name = '',
        [AllowEmptyString()][string]$Command = '',
        [AllowEmptyString()][string]$Publisher = '',
        [Parameter(Mandatory)]$Policy
    )
    foreach ($pattern in $Policy.ProtectedStartupPatterns) {
        if ($Name -and $Name -like $pattern)           { return $true }
        if ($Command -and $Command -like $pattern)     { return $true }
        if ($Publisher -and $Publisher -like $pattern) { return $true }
    }
    return $false
}

function Test-WaFileDeleteAllowed {
    <#
    .SYNOPSIS
        The full gate for deleting one specific file. Returns a decision with a reason.

    .DESCRIPTION
        Applied twice: once while a candidate manifest is built, and again immediately
        before each delete. The second pass is what makes the manifest trustworthy, because
        it also verifies that the file has not changed since the person reviewed it.

    .PARAMETER Manifest
        The entry recorded during analysis. When supplied, the file's current length and
        last-write time must still match it, otherwise the file is skipped: something
        wrote to it between review and execution, so it is in use.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$Policy,
        [datetime]$CutoffUtc = [datetime]::MaxValue,
        $Manifest = $null
    )

    $deny = {
        param([string]$Reason)
        [pscustomobject]@{ Allowed = $false; Reason = $Reason; Path = $Path }
    }

    try { $normalized = Get-WaNormalizedPath -Path $Path } catch { return (& $deny "Path rejected: $($_.Exception.Message)") }

    if (-not (Test-WaPathWithin -Path $normalized -Root $Root)) {
        return (& $deny 'Outside the approved cleanup root for this action.')
    }
    if (Test-WaProtectedPath -Path $normalized -Policy $Policy) {
        return (& $deny 'Inside a policy-protected location.')
    }
    if (Test-WaProtectedSegment -Path $normalized -Policy $Policy) {
        return (& $deny 'Path contains a protected directory name (source control, dependency tree or virtual environment).')
    }
    if (Test-WaProtectedExtension -Path $normalized -Policy $Policy) {
        return (& $deny 'File type is never deleted (virtual disk, database, mail store or key material).')
    }
    if (Test-WaExcludedPath -Path $normalized -Config $Config) {
        return (& $deny 'Excluded by configuration.')
    }

    $item = $null
    try { $item = Get-Item -LiteralPath $normalized -Force -ErrorAction Stop } catch { return (& $deny 'No longer present or not readable.') }
    if ($item.PSIsContainer) { return (& $deny 'Target is a directory; only files are deleted.') }
    if (([long]$item.Attributes -band $script:WaLinkedOrOfflineAttributeMask) -ne 0) {
        return (& $deny 'Link, offline file or cloud placeholder.')
    }
    if (-not (Test-WaPathUnlinked -Path $normalized)) {
        return (& $deny 'Reached through a junction, symlink or cloud placeholder.')
    }
    if ($item.LastWriteTimeUtc -ge $CutoffUtc -or $item.CreationTimeUtc -ge $CutoffUtc) {
        return (& $deny 'Newer than the age threshold for this category.')
    }

    if ($null -ne $Manifest) {
        $manifestLength = Get-WaProperty -Object $Manifest -Name 'Length'
        $manifestWrite  = Get-WaProperty -Object $Manifest -Name 'LastWriteUtc'
        if ($null -ne $manifestLength -and [long]$manifestLength -ne [long]$item.Length) {
            return (& $deny 'Changed size since it was reviewed; it is in use.')
        }
        if ($null -ne $manifestWrite) {
            $recorded = [datetime]::MinValue
            if ([datetime]::TryParse([string]$manifestWrite, [ref]$recorded)) {
                if ([Math]::Abs(($recorded.ToUniversalTime() - $item.LastWriteTimeUtc).TotalSeconds) -gt 1) {
                    return (& $deny 'Modified since it was reviewed; it is in use.')
                }
            }
        }
    }

    return [pscustomobject]@{ Allowed = $true; Reason = 'Validated'; Path = $normalized }
}

function Get-WaOperationPolicy {
    <#
    .SYNOPSIS
        Returns the policy entry for an operation kind, failing closed when absent.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Kind, [Parameter(Mandatory)]$Policy)

    if (-not $Policy.OperationPolicy.Contains($Kind)) {
        throw "Operation kind '$Kind' has no policy entry and cannot be executed."
    }
    return $Policy.OperationPolicy[$Kind]
}

function Assert-WaRecommendationPolicy {
    <#
    .SYNOPSIS
        Validates a recommendation against policy. Throws on any violation.

    .DESCRIPTION
        Run when a recommendation enters a plan, and again before execution. Checks:
          * every operation kind is one the engine knows;
          * the recommendation's risk is at least the policy floor for each of its
            operations, so risk cannot be understated to reach batch approval;
          * a recommendation whose operations require administrator rights says so;
          * an operation kind that policy marks as needing individual approval is
            reflected in the recommendation.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Recommendation, [Parameter(Mandatory)]$Policy)

    $knownKinds = Get-WaOperationKinds
    $recommendationRank = Get-WaRiskRank -Risk $Recommendation.Risk

    foreach ($operation in $Recommendation.Operations) {
        if ($knownKinds -notcontains $operation.Kind) {
            throw "Recommendation '$($Recommendation.Id)' uses unknown operation kind '$($operation.Kind)'."
        }

        $operationPolicy = Get-WaOperationPolicy -Kind $operation.Kind -Policy $Policy
        $floor = Get-WaRiskRank -Risk $operationPolicy.MinimumRisk
        if ($recommendationRank -lt $floor) {
            throw ("Recommendation '{0}' is classified {1} but operation kind '{2}' has a policy floor of {3}. Risk downgrade refused." -f
                $Recommendation.Id, $Recommendation.Risk, $operation.Kind, $operationPolicy.MinimumRisk)
        }
        if ($operation.RequiresAdmin -and -not $Recommendation.AdminRequired) {
            throw "Recommendation '$($Recommendation.Id)' contains an operation that needs administrator rights but does not declare AdminRequired."
        }
        if ($operationPolicy.RequiresIndividualApproval -and -not $Recommendation.IndividualApprovalRequired) {
            throw "Recommendation '$($Recommendation.Id)' contains operation kind '$($operation.Kind)', which policy requires be approved individually."
        }
    }

    if ($Recommendation.Risk -eq 'HIGH' -and -not $Recommendation.IndividualApprovalRequired) {
        throw "Recommendation '$($Recommendation.Id)' is HIGH risk and must require individual approval."
    }
    return $true
}

function Test-WaExecutableRecommendation {
    <#
    .SYNOPSIS
        True when a recommendation is of a kind that may ever be executed.

    .DESCRIPTION
        MANUAL-ONLY recommendations and recommendations with no operations are advisory:
        they are reported and explained, and the execution engine refuses them. This is
        checked in several places on purpose; it is the single most important invariant
        in the toolkit.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Recommendation)

    if ($Recommendation.Risk -eq 'MANUAL-ONLY') { return $false }
    if (@($Recommendation.Operations).Count -eq 0) { return $false }
    return $true
}

function Assert-WaMutationAllowed {
    <#
    .SYNOPSIS
        The read-only gate. Throws when the session must not change the machine.

    .DESCRIPTION
        Called at the top of every primitive that writes, deletes or runs a mutating
        command. ViewSpecs, Analyze, Storage, Startup, Plan and DryRun sessions are all
        created read-only, so this is what makes those modes read-only by construction
        rather than by convention.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session, [string]$Operation = 'operation')

    if ($null -eq $Session) { throw 'A session is required before any change can be made.' }
    if ($Session.ReadOnly) {
        throw ("Refused: this is a read-only {0} session and '{1}' would change the machine." -f $Session.Mode, $Operation)
    }
    return $true
}

function Test-WaSupportedForExecution {
    <#
    .SYNOPSIS
        True when the machine is one the toolkit is willing to modify.

    .DESCRIPTION
        Analysis runs anywhere; changes are limited to 64-bit Windows 11 client builds
        (10.0.22000 and later), because that is what the providers were written and
        verified against.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$MachineProfile)

    $support = Get-WaProperty -Object $MachineProfile -Name 'Support'
    if ($null -eq $support) { return $false }
    return [bool](Get-WaProperty -Object $support -Name 'SupportedForExecution' -Default $false)
}

function Get-WaApprovedRoot {
    <#
    .SYNOPSIS
        Looks up a cleanup root that a provider declared during this session.

    .DESCRIPTION
        FileDelete operations reference a root by key rather than carrying a raw path that
        the executor would have to trust. Editing a saved plan to point somewhere else
        therefore fails here, because the key would no longer resolve to a declared root.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)][string]$RootKey)

    $roots = Get-WaProperty -Object $Session -Name 'ApprovedRoots'
    if ($null -eq $roots -or -not $roots.Contains($RootKey)) {
        throw "No cleanup root is registered under key '$RootKey' in this session. The plan does not match the analysis it came from."
    }
    return $roots[$RootKey]
}

function Register-WaApprovedRoot {
    <#
    .SYNOPSIS
        Records a cleanup root a provider has declared, after validating it against policy.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)][string]$RootKey,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Provider
    )

    $policy = $Session.Config.Policy
    $normalized = Get-WaNormalizedPath -Path $Path

    if (Test-WaProtectedPath -Path $normalized -Policy $policy) {
        throw "Provider '$Provider' tried to register a protected location as a cleanup root: $normalized"
    }
    if (Test-WaProtectedSegment -Path $normalized -Policy $policy) {
        throw "Provider '$Provider' tried to register a root containing a protected directory name: $normalized"
    }

    $Session.ApprovedRoots[$RootKey] = [pscustomobject][ordered]@{
        Key      = $RootKey
        Path     = $normalized
        Provider = $Provider
    }
    return $Session.ApprovedRoots[$RootKey]
}
