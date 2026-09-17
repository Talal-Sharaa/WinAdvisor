<#
.SYNOPSIS
    WinAdvisor - adaptive Windows 11 maintenance advisor, diagnostics toolkit and
    approval-gated cleanup orchestrator.

.DESCRIPTION
    Diagnose first. Recommend second. Execute last.

    Launched with no arguments the toolkit opens an interactive menu and changes
    nothing until an operation is individually reviewed and approved.

    The ViewSpecs, Analyze, Storage, Startup, Plan and DryRun modes are read-only by
    construction: the execution engine refuses every mutating primitive while the
    session is marked read-only.

.PARAMETER Mode
    Menu       Interactive menu (default).
    ViewSpecs  Read-only hardware/Windows/software/startup inventory.
    Analyze    Read-only system analysis and findings.
    Storage    Read-only storage attribution.
    Startup    Read-only startup and memory-consumer analysis.
    Plan       Build and print a maintenance plan without executing it.
    DryRun     Full pipeline including provider command generation, executing nothing.
    Cleanup    Interactive, per-action approval and execution.
    Report     Regenerate reports from the most recent session.
    Rollback   List and restore recorded rollback state.

.PARAMETER ConfigPath
    Path to a JSON configuration file overriding Config/defaults.json.

.PARAMETER ReportPath
    Directory to write HTML/JSON reports to. Defaults to Data/Reports.

.PARAMETER DeepScanPath
    Explicit directories to scan recursively. Deep recursion is never implied by
    configuration alone; supplying this parameter is the authorisation.

.PARAMETER IncludeProvider
    Limit analysis to the named providers.

.PARAMETER ExcludeProvider
    Skip the named providers.

.PARAMETER NonInteractive
    Never prompt. Combined with -Mode Cleanup this executes nothing, because every
    mutating action requires an interactive approval unless an approval file is supplied.

.PARAMETER PassThru
    Emit the session object on the pipeline.

.EXAMPLE
    .\WinAdvisor.ps1
    Opens the interactive menu.

.EXAMPLE
    .\WinAdvisor.ps1 -Mode ViewSpecs
    Prints a full read-only machine specification.

.EXAMPLE
    .\WinAdvisor.ps1 -Mode DryRun -PassThru
    Runs the complete pipeline, generates every provider command, executes none of
    them, and returns the session for inspection.
#>
#Requires -Version 5.1
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

$ErrorActionPreference = 'Stop'

$manifest = Join-Path $PSScriptRoot 'WinAdvisor.psd1'
Import-Module $manifest -Force -ErrorAction Stop

$startArguments = @{
    Mode           = $Mode
    NonInteractive = [bool]$NonInteractive
    PassThru       = [bool]$PassThru
}
if ($PSBoundParameters.ContainsKey('ConfigPath'))      { $startArguments.ConfigPath      = $ConfigPath }
if ($PSBoundParameters.ContainsKey('ReportPath'))      { $startArguments.ReportPath      = $ReportPath }
if ($PSBoundParameters.ContainsKey('DeepScanPath'))    { $startArguments.DeepScanPath    = $DeepScanPath }
if ($PSBoundParameters.ContainsKey('IncludeProvider')) { $startArguments.IncludeProvider = $IncludeProvider }
if ($PSBoundParameters.ContainsKey('ExcludeProvider')) { $startArguments.ExcludeProvider = $ExcludeProvider }

Start-WinAdvisor @startArguments
