<#
    Core/ProviderContract.ps1 - provider registration and the provider interface.

    A provider is a descriptor plus script blocks. Providers are responsible for knowing
    their own domain: where a tool keeps its caches, what its output means, what is safe
    to propose. They never change cleanup targets. Czkawka can request verified
    dependency setup through Core/CzkawkaInstaller.ps1 before scanning.

    The contract, matching the seven-member interface in the design:

      TestAvailable         is this provider relevant on this machine?
      GetInventory          what components does it find?
      GetAnalysis           what findings follow from that?
      GetCleanupCandidates  what measured cleanup opportunities exist?
      GetCleanupPlan        what recommendations, with typed operations, follow?
      InvokeCleanup         fixed. Always the core execution engine; see below.
      TestResult            re-measure after execution to verify what actually happened.

    InvokeCleanup is deliberately not overridable. If each provider could supply its own
    execution body, the read-only guarantee, the approval gate and the rollback capture
    would each have as many implementations as there are providers. Instead every provider
    expresses intent as typed operations and Core/Execution.ps1 performs them, so there is
    exactly one place where cleanup changes are applied.

    Every provider entry point is called through Invoke-WaProviderStage, which isolates
    failures: a provider that throws is recorded as degraded and the run continues.
#>

$script:WaProviderRegistry = New-Object 'System.Collections.Specialized.OrderedDictionary' ([StringComparer]::OrdinalIgnoreCase)

function Register-WaProvider {
    <#
    .SYNOPSIS
        Registers a provider and validates that it satisfies the contract.

    .PARAMETER ExternalDependency
        Name of a third-party tool the provider needs. Providers with an external
        dependency additionally require Safety.AllowExternalTools in configuration.
        Czkawka can download its verified CLI on first use when AutoDownload is enabled.

    .PARAMETER UsesDeepScanPaths
        The provider scans the directories named with -DeepScanPath. The cleanup flow
        says so when such a provider does not run, because the user asked for it by name.

    .EXAMPLE
        Register-WaProvider -Name 'Dev.Node' -Title 'Node.js package managers' `
            -Category 'Developer tooling' -Description '...' `
            -TestAvailable { param($Session) ... } -GetInventory { param($Session) ... } ...
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Category,
        [Parameter(Mandatory)][string]$Description,

        [Parameter(Mandatory)][scriptblock]$TestAvailable,
        [Parameter(Mandatory)][scriptblock]$GetInventory,
        [Parameter(Mandatory)][scriptblock]$GetAnalysis,
        [scriptblock]$GetCleanupCandidates = $null,
        [scriptblock]$GetCleanupPlan = $null,
        [scriptblock]$TestResult = $null,

        [string]$ExternalDependency = '',
        [string]$Reference = '',
        [bool]$AdvisoryOnly = $false,
        [bool]$UsesDeepScanPaths = $false,
        [int]$Order = 100
    )

    if ($script:WaProviderRegistry.Contains($Name)) {
        throw "Provider '$Name' is already registered. Provider names must be unique."
    }

    # A provider that can produce candidates must also be able to turn them into a plan,
    # otherwise analysis would surface an opportunity with no way to act on or explain it.
    if ($null -ne $GetCleanupCandidates -and $null -eq $GetCleanupPlan) {
        throw "Provider '$Name' supplies GetCleanupCandidates but no GetCleanupPlan."
    }

    $script:WaProviderRegistry[$Name] = [pscustomobject][ordered]@{
        PSTypeName           = 'WinAdvisor.Provider'
        Name                 = $Name
        Title                = $Title
        Category             = $Category
        Description          = $Description
        ExternalDependency   = $ExternalDependency
        Reference            = $Reference
        AdvisoryOnly         = $AdvisoryOnly
        UsesDeepScanPaths    = $UsesDeepScanPaths
        Order                = $Order

        TestAvailable        = $TestAvailable
        GetInventory         = $GetInventory
        GetAnalysis          = $GetAnalysis
        GetCleanupCandidates = $GetCleanupCandidates
        GetCleanupPlan       = $GetCleanupPlan
        TestResult           = $TestResult
        # Fixed for every provider: intent is executed by the core engine, never by the
        # provider itself. Present so the contract is complete and introspectable.
        InvokeCleanup        = 'Core/Execution.ps1::Invoke-WaPlannedAction'
    }
    return $script:WaProviderRegistry[$Name]
}

function Get-WaProvider {
    <#
    .SYNOPSIS
        Returns registered providers, optionally one by name.

    .EXAMPLE
        Get-WaProvider | Select-Object Name, Category, ExternalDependency
    #>
    [CmdletBinding()]
    param([string]$Name)

    if ($Name) {
        if (-not $script:WaProviderRegistry.Contains($Name)) { return $null }
        return $script:WaProviderRegistry[$Name]
    }
    return @($script:WaProviderRegistry.Values | Sort-Object Order, Name)
}

function Get-WaActiveProvider {
    <#
    .SYNOPSIS
        Providers that are enabled by configuration and available on this machine.

    .DESCRIPTION
        Each provider is asked whether it is relevant. A provider that reports itself
        unavailable is not an error: no Docker means the Docker provider stands down, and
        the reason is recorded so the report can explain the gap rather than omit it.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session)

    $config = $Session.Config
    $active = New-Object 'System.Collections.Generic.List[object]'
    $inactive = New-Object 'System.Collections.Generic.List[object]'

    foreach ($provider in (Get-WaProvider)) {
        if (-not (Test-WaProviderEnabled -Config $config -Provider $provider.Name)) {
            $inactive.Add([pscustomobject]@{ Name = $provider.Name; Reason = 'Disabled by configuration.' })
            continue
        }

        if ($provider.ExternalDependency -and -not $config.AllowExternalTools) {
            $inactive.Add([pscustomobject]@{
                Name   = $provider.Name
                Reason = ("Requires the external tool '{0}'. Set Safety.AllowExternalTools to true to enable this provider. Czkawka downloads its verified dependency on first use when needed." -f $provider.ExternalDependency)
            })
            continue
        }

        $availability = Invoke-WaProviderStage -Session $Session -Provider $provider -Stage 'TestAvailable' -Arguments @($Session)
        if (-not $availability.Succeeded) {
            $inactive.Add([pscustomobject]@{ Name = $provider.Name; Reason = ("Availability check failed: {0}" -f $availability.Error) })
            continue
        }

        $result = @($availability.Output) | Select-Object -First 1
        $isAvailable = $false
        $reason = 'Not present on this machine.'
        if ($result -is [bool]) {
            $isAvailable = $result
        } elseif ($null -ne $result) {
            $isAvailable = [bool](Get-WaProperty -Object $result -Name 'Available' -Default $false)
            $reason = [string](Get-WaProperty -Object $result -Name 'Reason' -Default $reason)
        }

        if ($isAvailable) {
            $active.Add($provider)
        } else {
            $inactive.Add([pscustomobject]@{ Name = $provider.Name; Reason = $reason })
        }
    }

    [pscustomobject]@{
        Active   = $active.ToArray()
        Inactive = $inactive.ToArray()
    }
}

function Invoke-WaProviderStage {
    <#
    .SYNOPSIS
        Calls one provider entry point with failure isolation.

    .DESCRIPTION
        A provider parses third-party output and touches the filesystem, so it can fail in
        ways the core cannot anticipate: a tool changed its output format, a daemon is
        not running, a registry key is denied. One provider failing must not end the run,
        so failures become a recorded degradation rather than a terminating error.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)]$Provider,
        [Parameter(Mandatory)][ValidateSet('TestAvailable', 'GetInventory', 'GetAnalysis', 'GetCleanupCandidates', 'GetCleanupPlan', 'TestResult')][string]$Stage,
        [object[]]$Arguments = @()
    )

    $block = $Provider.$Stage
    if ($null -eq $block) {
        return [pscustomobject]@{ Succeeded = $true; Output = @(); Error = ''; Skipped = $true }
    }

    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    try {
        $output = @(& $block @Arguments)
        $stopwatch.Stop()
        Write-WaLog -Session $Session -Level 'Verbose' -Category 'Provider' -Message (
            '{0}.{1} returned {2} item(s) in {3}ms.' -f $Provider.Name, $Stage, @($output).Count, [int]$stopwatch.Elapsed.TotalMilliseconds
        )
        return [pscustomobject]@{ Succeeded = $true; Output = $output; Error = ''; Skipped = $false }
    } catch {
        $stopwatch.Stop()
        $message = '{0}: {1}' -f $_.Exception.GetType().Name, $_.Exception.Message
        Write-WaLog -Session $Session -Level 'Warning' -Category 'Provider' -Message (
            "Provider '{0}' failed during {1} and was skipped. {2}" -f $Provider.Name, $Stage, $message
        )
        return [pscustomobject]@{ Succeeded = $false; Output = @(); Error = $message; Skipped = $false }
    }
}

function New-WaProviderAvailability {
    <#
    .SYNOPSIS
        Helper for a provider's TestAvailable block to report availability with a reason.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][bool]$Available, [string]$Reason = '', [string]$Version = '')
    [pscustomobject]@{
        Available = $Available
        Reason    = $Reason
        Version   = $Version
    }
}

function Test-WaProviderContract {
    <#
    .SYNOPSIS
        Verifies that every registered provider satisfies the contract. Used by tests.

    .DESCRIPTION
        Returns one row per provider describing which contract members are implemented,
        so a provider that silently forgot its plan stage is visible rather than merely
        producing no recommendations.
    #>
    [CmdletBinding()]
    param()

    @(foreach ($provider in (Get-WaProvider)) {
        [pscustomobject][ordered]@{
            Name                 = $provider.Name
            Category             = $provider.Category
            TestAvailable        = ($null -ne $provider.TestAvailable)
            GetInventory         = ($null -ne $provider.GetInventory)
            GetAnalysis          = ($null -ne $provider.GetAnalysis)
            GetCleanupCandidates = ($null -ne $provider.GetCleanupCandidates)
            GetCleanupPlan       = ($null -ne $provider.GetCleanupPlan)
            TestResult           = ($null -ne $provider.TestResult)
            InvokeCleanup        = $provider.InvokeCleanup
            AdvisoryOnly         = $provider.AdvisoryOnly
            ExternalDependency   = $provider.ExternalDependency
            Complete             = (($null -ne $provider.TestAvailable) -and ($null -ne $provider.GetInventory) -and ($null -ne $provider.GetAnalysis))
        }
    })
}

function Clear-WaProviderRegistry {
    <#
    .SYNOPSIS
        Empties the registry. Test support only.
    #>
    [CmdletBinding()]
    param()
    $script:WaProviderRegistry = New-Object 'System.Collections.Specialized.OrderedDictionary' ([StringComparer]::OrdinalIgnoreCase)
}
