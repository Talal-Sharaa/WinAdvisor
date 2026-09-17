<#
.SYNOPSIS
    Runs the WinAdvisor Pester suite.

.DESCRIPTION
    Requires Pester 5. Nothing is installed automatically: if Pester 5 is not available the
    script says so and stops, because silently downloading and executing a module would be
    exactly the behaviour this project tells users to distrust.

    A locally cached copy under TestResults/Dependencies is used when present, so a machine
    without PSGallery access can still run the suite from a reviewed copy.

.EXAMPLE
    pwsh -NoProfile -File Tests/Run-Tests.ps1

.EXAMPLE
    powershell -NoProfile -File Tests/Run-Tests.ps1 -Tag Safety
#>
[CmdletBinding()]
param(
    [string[]]$Tag,
    [string[]]$ExcludeTag,
    [ValidateSet('None', 'Normal', 'Detailed', 'Diagnostic')][string]$Verbosity = 'Normal'
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot

$pesterModule = $null
$localPester = Join-Path $projectRoot 'TestResults\Dependencies\Pester\5.7.1\Pester.psd1'
if (Test-Path -LiteralPath $localPester) {
    $pesterModule = $localPester
} else {
    $installed = Get-Module -ListAvailable -Name Pester |
                 Where-Object { $_.Version.Major -ge 5 } |
                 Sort-Object Version -Descending |
                 Select-Object -First 1
    if ($installed) { $pesterModule = $installed.Path }
}

if (-not $pesterModule) {
    throw @'
Pester 5 or later is required and was not found.

Install it yourself with:
    Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser

or place a reviewed copy at TestResults/Dependencies/Pester/<version>/Pester.psd1.
Nothing is downloaded automatically by this script.
'@
}

Import-Module $pesterModule -Force -ErrorAction Stop
Write-Host ("Using Pester {0} on PowerShell {1}" -f (Get-Module Pester).Version, $PSVersionTable.PSVersion) -ForegroundColor DarkGray

$resultDirectory = Join-Path $projectRoot 'TestResults'
if (-not (Test-Path -LiteralPath $resultDirectory -PathType Container)) {
    [void](New-Item -ItemType Directory -Path $resultDirectory -Force)
}

$configuration = New-PesterConfiguration
$configuration.Run.Path = $PSScriptRoot
$configuration.Run.PassThru = $true
$configuration.Output.Verbosity = $Verbosity
$configuration.TestResult.Enabled = $true
$configuration.TestResult.OutputPath = Join-Path $resultDirectory ('pester-{0}.xml' -f $PSVersionTable.PSVersion.Major)
if ($Tag)        { $configuration.Filter.Tag = $Tag }
if ($ExcludeTag) { $configuration.Filter.ExcludeTag = $ExcludeTag }

$result = Invoke-Pester -Configuration $configuration

Write-Host ''
Write-Host ("Passed {0}  Failed {1}  Skipped {2}" -f $result.PassedCount, $result.FailedCount, $result.SkippedCount) -ForegroundColor $(if ($result.FailedCount -gt 0) { 'Red' } else { 'Green' })

if ($result.FailedCount -gt 0) { exit 1 }
