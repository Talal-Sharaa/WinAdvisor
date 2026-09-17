<#
.SYNOPSIS
    Parses every PowerShell file in the project and reports syntax errors.

.DESCRIPTION
    Static verification gate. Run this before the Pester suite: it exits non-zero when
    any file fails to parse, which makes it cheap to wire into CI ahead of the tests.

.EXAMPLE
    pwsh -NoProfile -File Tests/Test-Syntax.ps1
#>
[CmdletBinding()]
param([string]$Root)

$ErrorActionPreference = 'Stop'

# Resolved here rather than as a param default: on Windows PowerShell 5.1, $PSScriptRoot is
# not populated when a param block default is evaluated, so the default silently became an
# empty string and Split-Path failed.
if (-not $Root) { $Root = Split-Path -Parent $PSScriptRoot }

$excludedDirectories = @('TestResults', 'Data', '.git')
$sourceExtensions = @('.ps1', '.psm1', '.psd1')

# Extension filtered explicitly rather than with -Include: on Windows PowerShell 5.1,
# -Include combined with -LiteralPath is unreliable and matches far more than intended.
$files = Get-ChildItem -LiteralPath $Root -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object {
        if ($sourceExtensions -notcontains $_.Extension) { return $false }
        $relative = $_.FullName.Substring($Root.Length).Trim([char]92)
        $segments = $relative.Split([char]92)
        -not ($segments | Where-Object { $excludedDirectories -contains $_ })
    } |
    Sort-Object FullName

$failed = 0
foreach ($file in $files) {
    $errors = $null
    $tokens = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)

    $relative = $file.FullName.Substring($Root.Length).Trim([char]92)
    if ($errors -and $errors.Count -gt 0) {
        $failed++
        Write-Host ("FAIL  {0}" -f $relative) -ForegroundColor Red
        foreach ($parseError in $errors) {
            Write-Host ("        line {0}: {1}" -f $parseError.Extent.StartLineNumber, $parseError.Message) -ForegroundColor Red
        }
    } else {
        Write-Host ("ok    {0}" -f $relative) -ForegroundColor DarkGray
    }
}

Write-Host ''
Write-Host ("{0} file(s) parsed, {1} failed." -f $files.Count, $failed)
if ($failed -gt 0) { exit 1 }
