#Requires -Version 5.1
<#
.SYNOPSIS
    Install or repair the official Czkawka CLI 12.0.2 Windows release locally.
.DESCRIPTION
    Uses the same pinned download and SHA-256 verification as automatic first-use setup.
    No PATH changes, elevation, or cleanup is performed.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $projectRoot 'Core\CzkawkaInstaller.ps1')
$binary = Install-WaCzkawka -DestinationDirectory (Join-Path $projectRoot 'Tools\Czkawka')
Write-Host "Czkawka CLI 12.0.2 is installed: $binary"
