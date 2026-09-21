<#
    WinAdvisor root module.

    Architecture note
    -----------------
    Core and provider components are plain .ps1 files that are dot-sourced into this
    single module session state, rather than being separate binary/script modules.

    Rationale (see docs/ARCHITECTURE.md, ADR-001):
      * One session state means providers can call Core safety primitives directly
        without every primitive having to be a public, exported surface.
      * Nested modules in PowerShell each receive their own session state, which makes
        cross-module helper visibility order-dependent and fragile on 5.1.
      * The public contract stays small and explicit: only the functions listed in
        WinAdvisor.psd1 / Export-ModuleMember below leave the module.
#>

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$script:WaModuleRoot = $PSScriptRoot

# Load order matters: each file may use functions from the files above it.
$script:WaCoreFiles = @(
    'Common'          # primitive helpers: property access, formatting, native process execution
    'Models'          # typed data-model constructors
    'Logging'         # human-readable + JSON structured logs
    'Configuration'   # config/policy loading and validation
    'Safety'          # path safety, risk/confidence ranks, policy gates
    'CommandCatalog'  # the allow-list of every external command the toolkit may run
    'CzkawkaInstaller'# pinned dependency setup; also used by the standalone installer
    'Czkawka'         # versioned scan reports and validation of reviewed cleanup targets
    'Inventory'       # bounded filesystem measurement
    'Session'         # session lifecycle and read-only mode
    'ProviderContract'# provider registration and contract validation
    'Discovery'       # machine profile (hardware, Windows, software, startup, processes)
    'Workloads'       # workload/component detection and classification
    'Analysis'        # findings from profile + providers
    'RecommendationEngine'
    'Questions'       # adaptive, device-specific questioning
    'Planning'        # plan construction
    'Approval'        # approval records and enforcement
    'Elevation'       # per-action elevation
    'Execution'       # the only code allowed to apply cleanup changes
    'Rollback'        # rollback records and restoration
    'Verification'    # before/after baselines
    'Reporting'       # HTML + JSON reports
    'Interface'       # interactive menu
    'CzkawkaReview'   # choosing which Czkawka results to delete, with Czkawka's selection rules
    'Entry'           # Start-WinAdvisor
)

foreach ($coreFile in $script:WaCoreFiles) {
    $corePath = Join-Path $PSScriptRoot (Join-Path 'Core' ($coreFile + '.ps1'))
    if (-not (Test-Path -LiteralPath $corePath)) {
        throw "WinAdvisor core component missing: $corePath"
    }
    . $corePath
}

# Providers are discovered from disk so that adding a file is the only registration step.
$script:WaProviderDirectory = Join-Path $PSScriptRoot 'Providers'
if (Test-Path -LiteralPath $script:WaProviderDirectory) {
    foreach ($providerFile in (Get-ChildItem -LiteralPath $script:WaProviderDirectory -Filter '*.ps1' -File | Sort-Object Name)) {
        . $providerFile.FullName
    }
}

Export-ModuleMember -Function @(
    'Start-WinAdvisor'
    'Get-WaConfiguration'
    'Get-WaMachineProfile'
    'Get-WaAnalysis'
    'Get-WaQuestion'
    'New-WaPlan'
    'Grant-WaApproval'
    'Invoke-WaPlan'
    'Get-WaBaseline'
    'Compare-WaBaseline'
    'Export-WaReport'
    'Get-WaProvider'
    'Get-WaRollbackSession'
    'Invoke-WaRollback'
    'New-WaSession'
)
