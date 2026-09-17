<#
    Providers/Windows.Temp.ps1 - Windows temporary files, error reports and shader caches.

    These are the locations where Windows and applications leave regenerable working files.
    Only files older than the configured age threshold are ever proposed for deletion: a
    temp file written minutes ago is very likely still in use by whatever created it.

    Deliberately NOT included:
      Prefetch          Windows uses it to start applications faster and rebuilds it
                        anyway. Deleting it is folklore, not maintenance.
      SoftwareDistribution\Download
                        Reported for size, never deleted. The supported way to clear it is
                        Storage Sense or Disk Cleanup; removing it by hand while servicing
                        is active can break an in-flight update.
      WinSxS            Serviced only through DISM; see Windows.Servicing.
#>

function Get-WaTempRootDefinition {
    <#
    .SYNOPSIS
        The locations this provider knows how to clean, with their risk classification.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session)

    $base = Get-WaBasePaths
    $config = $Session.Config
    $tempAge = $config.MinimumTempAgeDays
    $cacheAge = $config.MinimumCacheAgeDays

    $definitions = New-Object 'System.Collections.Generic.List[object]'

    $definitions.Add([pscustomobject]@{
        Key = 'windows.temp.user'; Title = 'User temporary files'
        Path = (Join-Path $base.LocalAppData 'Temp'); AgeDays = $tempAge
        Risk = 'LOW'; Confidence = 'HIGH'; RequiresAdmin = $false; Setting = ''
        Explanation = 'Your per-user TEMP directory. Applications write working files here and are expected to clean up after themselves, but many do not. Only files older than the age threshold are proposed, and anything currently locked is skipped.'
        Consequence = 'Nothing that is still needed. An application that left state here without expecting it to persist may recreate it.'
    })

    $definitions.Add([pscustomobject]@{
        Key = 'windows.temp.machine'; Title = 'Windows temporary files'
        Path = (Join-Path $base.Windows 'Temp'); AgeDays = $tempAge
        Risk = 'LOW'; Confidence = 'HIGH'; RequiresAdmin = $true; Setting = 'IncludeWindowsTemp'
        Explanation = 'The machine-wide TEMP directory, used by installers and services. Files still held open by an installer or service are skipped rather than forced.'
        Consequence = 'Installer working files are removed. An installation in progress is unaffected, because its files are locked and therefore skipped.'
    })

    $definitions.Add([pscustomobject]@{
        Key = 'windows.wer.user'; Title = 'User error reports'
        Path = (Join-Path $base.LocalAppData 'Microsoft\Windows\WER\ReportArchive'); AgeDays = $tempAge
        Risk = 'LOW'; Confidence = 'HIGH'; RequiresAdmin = $false; Setting = 'IncludeErrorReports'
        Explanation = 'Archived Windows Error Reporting data for your account. These are records of past application crashes.'
        Consequence = 'Historical crash information is lost. Keep these if you are currently investigating a crash or working with a support case.'
    })

    $definitions.Add([pscustomobject]@{
        Key = 'windows.wer.queue'; Title = 'Queued error reports'
        Path = (Join-Path $base.LocalAppData 'Microsoft\Windows\WER\ReportQueue'); AgeDays = $tempAge
        Risk = 'LOW'; Confidence = 'HIGH'; RequiresAdmin = $false; Setting = 'IncludeErrorReports'
        Explanation = 'Error reports queued for submission. Old entries here are reports that were never sent.'
        Consequence = 'Unsent crash reports are discarded.'
    })

    $definitions.Add([pscustomobject]@{
        Key = 'windows.wer.machine'; Title = 'System error reports'
        Path = (Join-Path $base.ProgramData 'Microsoft\Windows\WER\ReportArchive'); AgeDays = $tempAge
        Risk = 'LOW'; Confidence = 'HIGH'; RequiresAdmin = $true; Setting = 'IncludeErrorReports'
        Explanation = 'Machine-wide archived error reports, covering services and other accounts.'
        Consequence = 'System-wide crash history is lost.'
    })

    $definitions.Add([pscustomobject]@{
        Key = 'windows.crashdumps.user'; Title = 'Application crash dumps'
        Path = (Join-Path $base.LocalAppData 'CrashDumps'); AgeDays = $tempAge
        Risk = 'MODERATE'; Confidence = 'HIGH'; RequiresAdmin = $false; Setting = 'IncludeCrashDumps'
        Explanation = 'Full memory dumps written when an application crashed. They are large and only useful while a crash is being diagnosed.'
        Consequence = 'A developer or support engineer can no longer analyse those crashes. Classified MODERATE because a dump can be the only record of a fault that is hard to reproduce.'
    })

    $definitions.Add([pscustomobject]@{
        Key = 'windows.d3dcache'; Title = 'DirectX shader cache'
        Path = (Join-Path $base.LocalAppData 'D3DSCache'); AgeDays = $cacheAge
        Risk = 'LOW'; Confidence = 'HIGH'; RequiresAdmin = $false; Setting = 'IncludeShaderCaches'
        Explanation = 'Compiled DirectX shaders, cached so games and graphical applications do not recompile them every run. Entirely regenerable.'
        Consequence = 'The first run of a game or graphical application recompiles its shaders, which can cause brief stutter until the cache rebuilds.'
    })

    $definitions.Add([pscustomobject]@{
        Key = 'windows.nvidia.dxcache'; Title = 'NVIDIA shader cache'
        Path = (Join-Path $base.LocalAppData 'NVIDIA\DXCache'); AgeDays = $cacheAge
        Risk = 'LOW'; Confidence = 'HIGH'; RequiresAdmin = $false; Setting = 'IncludeShaderCaches'
        Explanation = 'NVIDIA driver shader cache. Regenerated automatically as applications run.'
        Consequence = 'Shaders are recompiled on next use, which can cause brief stutter.'
    })

    $definitions.Add([pscustomobject]@{
        Key = 'windows.inetcache'; Title = 'Windows internet cache'
        Path = (Join-Path $base.LocalAppData 'Microsoft\Windows\INetCache'); AgeDays = $cacheAge
        Risk = 'LOW'; Confidence = 'MEDIUM'; RequiresAdmin = $false; Setting = ''
        Explanation = 'The legacy WinINet cache, used by Windows components and applications that host the classic web control. Separate from any modern browser cache.'
        Consequence = 'Cached web content is fetched again on next use. Sign-in state is not held here.'
    })

    return @($definitions | Where-Object {
        $_.Setting -eq '' -or (Get-WaProviderSetting -Config $config -Provider 'Windows.Temp' -Name $_.Setting -Default $true)
    })
}

Register-WaProvider -Name 'Windows.Temp' -Order 10 `
    -Title 'Windows temporary files and caches' `
    -Category 'Windows' `
    -Description 'Temporary directories, Windows Error Reporting archives, crash dumps and shader caches. Age-filtered, never recursive beyond the named directories, and Prefetch is deliberately excluded.' `
    -Reference 'https://learn.microsoft.com/en-us/windows/win32/wer/windows-error-reporting' `
    -TestAvailable {
        param($Session)
        # Always relevant: every Windows installation has these locations.
        New-WaProviderAvailability -Available $true
    } `
    -GetInventory {
        param($Session)
        @(foreach ($definition in (Get-WaTempRootDefinition -Session $Session)) {
            $size = Get-WaDirectorySize -Path $definition.Path -Config $Session.Config
            if (-not $size.Exists) { continue }
            New-WaInstalledComponent -Name $definition.Title -Category 'Windows location' `
                -InstallPath $definition.Path -DetectionMethod 'Directory' `
                -Note ('{0} measured' -f (Format-WaBytes $size.Bytes))
        })
    } `
    -GetAnalysis {
        param($Session, $Inventory)
        $consumers = New-Object 'System.Collections.Generic.List[object]'

        foreach ($definition in (Get-WaTempRootDefinition -Session $Session)) {
            $consumer = Get-WaDirectoryConsumer -Session $Session -Name $definition.Title `
                -Category 'Temporary data' -Path $definition.Path -Provider 'Windows.Temp' `
                -Disposition 'Actionable' -Note $definition.Explanation
            if ($null -ne $consumer) { $consumers.Add($consumer) }
        }

        # Reported for completeness; never proposed for deletion by this provider.
        $base = Get-WaBasePaths
        foreach ($informational in @(
            @{ Name = 'Windows Update download cache'; Path = (Join-Path $base.Windows 'SoftwareDistribution\Download'); Category = 'Update leftovers'
               Note = 'Managed by Windows Update. Reported only: the supported way to clear it is Storage Sense or Disk Cleanup, and removing it by hand can disrupt an in-flight update.' }
            @{ Name = 'Prefetch'; Path = (Join-Path $base.Windows 'Prefetch'); Category = 'Windows'
               Note = 'Deliberately never touched. Windows uses Prefetch to start applications faster and rebuilds it if deleted, so clearing it costs performance and saves almost nothing.' }
            @{ Name = 'System minidumps'; Path = (Join-Path $base.Windows 'Minidump'); Category = 'Crash dumps'
               Note = 'Kernel crash dumps. Reported only: these are often the only evidence of a bug check and are small.' }
        )) {
            $consumer = Get-WaDirectoryConsumer -Session $Session -Name $informational.Name `
                -Category $informational.Category -Path $informational.Path -Provider 'Windows.Temp' `
                -Disposition 'Informational' -Note $informational.Note
            if ($null -ne $consumer) { $consumers.Add($consumer) }
        }

        $total = [long](($consumers | Where-Object { $_.Disposition -eq 'Actionable' -and $null -ne $_.Bytes } |
            ForEach-Object { [long]$_.Bytes }) | Measure-Object -Sum).Sum

        $findings = @()
        if ($total -gt 0) {
            $findings = @(New-WaFinding -Id 'windows.temp.total' -Title 'Temporary files and caches' `
                -Category 'Storage' -Provider 'Windows.Temp' `
                -Description ('Windows temporary locations hold {0} in total.' -f (Format-WaBytes $total)) `
                -Evidence @($consumers | Where-Object { $_.Disposition -eq 'Actionable' } | ForEach-Object {
                    New-WaEvidence -Source $_.Path -Method 'Bounded filesystem enumeration' `
                        -Statement ('{0}: {1}' -f $_.Name, (Format-WaBytes $_.Bytes)) -Value $_.Bytes -Unit 'bytes' -Complete $_.Complete
                }) `
                -CurrentImpact ('{0} across {1} location(s).' -f (Format-WaBytes $total), @($consumers | Where-Object { $_.Disposition -eq 'Actionable' }).Count) `
                -Confidence 'HIGH' -Disposition 'Actionable' -Bytes $total)
        }

        return @($findings + $consumers.ToArray())
    } `
    -GetCleanupCandidates {
        param($Session, $Inventory)
        @(foreach ($definition in (Get-WaTempRootDefinition -Session $Session)) {
            Get-WaCacheRootCandidate -Session $Session -Provider 'Windows.Temp' `
                -Key $definition.Key -Title $definition.Title -Category 'Temporary data' `
                -Path $definition.Path -AgeDays $definition.AgeDays `
                -Risk $definition.Risk -Confidence $definition.Confidence `
                -Explanation $definition.Explanation -RequiresAdmin $definition.RequiresAdmin
        })
    } `
    -GetCleanupPlan {
        param($Session, $Candidates)
        $definitions = @{}
        foreach ($definition in (Get-WaTempRootDefinition -Session $Session)) { $definitions[$definition.Key] = $definition }

        @(foreach ($candidate in $Candidates) {
            $definition = $definitions[$candidate.Key]
            New-WaFileCleanupRecommendation -Session $Session -Candidate $candidate `
                -Consequence $(if ($null -ne $definition) { $definition.Consequence } else { 'Regenerable working files are removed.' }) `
                -Warnings @('Files currently open by an application are skipped rather than forced.')
        })
    } `
    -TestResult {
        param($Session, $Results)
        @(foreach ($definition in (Get-WaTempRootDefinition -Session $Session)) {
            $size = Get-WaDirectorySize -Path $definition.Path -Config $Session.Config
            if (-not $size.Exists) { continue }
            [pscustomobject]@{
                Provider = 'Windows.Temp'
                Verified = $true
                Message  = ('{0} now measures {1}.' -f $definition.Title, (Format-WaBytes $size.Bytes))
            }
        })
    } | Out-Null
