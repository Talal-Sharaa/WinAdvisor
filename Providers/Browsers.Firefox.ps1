<#
    Providers/Browsers.Firefox.ps1 - Firefox cache.

    Firefox splits its data: the profile (bookmarks, passwords, cookies, history) lives
    under Roaming AppData, while the disk cache lives under Local AppData. That split is
    convenient here, because it means the cache can be cleared without going anywhere near
    the profile directory that holds anything worth keeping.

    Only cache2 and startupCache are targeted. logins.json, key4.db, places.sqlite,
    cookies.sqlite, formhistory.sqlite and extensions are never enumerated.
#>

function Get-WaFirefoxCacheProfile {
    <#
    .SYNOPSIS
        Firefox cache directories, one per profile.
    #>
    [CmdletBinding()]
    param()

    $base = Get-WaBasePaths
    $cacheRoot = Join-Path $base.LocalAppData 'Mozilla\Firefox\Profiles'
    if (-not (Test-Path -LiteralPath $cacheRoot -PathType Container)) { return @() }

    $profiles = @()
    try { $profiles = @(Get-ChildItem -LiteralPath $cacheRoot -Directory -ErrorAction Stop) } catch { return @() }

    $locations = New-Object 'System.Collections.Generic.List[object]'
    foreach ($profileDirectory in $profiles) {
        foreach ($subdirectory in @('cache2', 'startupCache', 'OfflineCache')) {
            $path = Join-Path $profileDirectory.FullName $subdirectory
            if (-not (Test-Path -LiteralPath $path -PathType Container)) { continue }
            $locations.Add([pscustomobject]@{
                Key     = ('browsers.firefox.{0}.{1}' -f ($profileDirectory.Name -replace '[^A-Za-z0-9]', ''), $subdirectory.ToLowerInvariant())
                Title   = ('Firefox {0} cache ({1})' -f $profileDirectory.Name, $subdirectory)
                Path    = $path
                Profile = $profileDirectory.Name
            })
        }
    }
    return $locations.ToArray()
}

Register-WaProvider -Name 'Browsers.Firefox' -Order 110 `
    -Title 'Firefox cache' `
    -Category 'Browsers' `
    -Description 'Firefox disk and startup cache. The profile directory holding passwords, bookmarks, cookies and history is in a different location entirely and is never touched.' `
    -Reference 'https://support.mozilla.org/en-US/kb/profiles-where-firefox-stores-user-data' `
    -TestAvailable {
        param($Session)
        $locations = @(Get-WaFirefoxCacheProfile)
        if ($locations.Count -eq 0) {
            return (New-WaProviderAvailability -Available $false -Reason 'No Firefox cache profile was found.')
        }
        New-WaProviderAvailability -Available $true -Reason ('{0} cache location(s) found.' -f $locations.Count)
    } `
    -GetInventory {
        param($Session)
        $profiles = @(Get-WaFirefoxCacheProfile | Select-Object -ExpandProperty Profile -Unique)
        @(New-WaInstalledComponent -Name 'Mozilla Firefox' -Category 'Browser' `
            -Vendor 'Mozilla' -InstallPath (Join-Path (Get-WaBasePaths).LocalAppData 'Mozilla\Firefox\Profiles') `
            -DetectionMethod 'Directory' -Note ('{0} profile(s) with a cache' -f $profiles.Count))
    } `
    -GetAnalysis {
        param($Session, $Inventory)
        $locations = @(Get-WaFirefoxCacheProfile)
        if ($locations.Count -eq 0) { return @() }

        $totalBytes = [long]0
        $complete = $true
        $evidence = New-Object 'System.Collections.Generic.List[object]'

        foreach ($location in $locations) {
            $size = Get-WaDirectorySize -Path $location.Path -Config $Session.Config
            if ($null -eq $size.Bytes) { $complete = $false; continue }
            $totalBytes += [long]$size.Bytes
            if (-not $size.Complete) { $complete = $false }
            $evidence.Add((New-WaEvidence -Source $location.Path -Method 'Bounded filesystem enumeration' `
                -Statement ('{0}: {1}.' -f $location.Title, (Format-WaBytes $size.Bytes)) `
                -Value $size.Bytes -Unit 'bytes' -Complete $size.Complete))
        }

        if ($totalBytes -eq 0) { return @() }

        @(
            New-WaStorageConsumer -Name 'Firefox cache' -Category 'Browser caches' `
                -Path (Join-Path (Get-WaBasePaths).LocalAppData 'Mozilla\Firefox\Profiles') `
                -Bytes $totalBytes -Complete $complete -Provider 'Browsers.Firefox' -Disposition 'Actionable' `
                -Note 'Cache only. The Firefox profile directory under Roaming AppData, which holds passwords, bookmarks and history, is a separate location and is not measured or touched here.'

            New-WaFinding -Id 'browsers.firefox.cache' `
                -Title 'Firefox cache' -Category 'Browser caches' -Provider 'Browsers.Firefox' `
                -Description ('Firefox holds {0} of cache across {1} location(s).' -f (Format-WaBytes $totalBytes), $locations.Count) `
                -Evidence $evidence.ToArray() `
                -CurrentImpact ('{0} of regenerable cache.' -f (Format-WaBytes $totalBytes)) `
                -Confidence 'HIGH' -Disposition 'Actionable' -Bytes $totalBytes `
                -Warnings @('Sign-in state lives in cookies in the profile directory, which is not touched. You stay signed in.')
        )
    } `
    -GetCleanupCandidates {
        param($Session, $Inventory)
        $age = $Session.Config.MinimumCacheAgeDays
        @(foreach ($location in (Get-WaFirefoxCacheProfile)) {
            Get-WaCacheRootCandidate -Session $Session -Provider 'Browsers.Firefox' `
                -Key $location.Key -Title $location.Title -Category 'Browser caches' `
                -Path $location.Path -AgeDays $age -Risk 'LOW' -Confidence 'HIGH' `
                -Explanation 'Firefox disk cache. Re-fetched from the network on demand. Holds no bookmarks, passwords, cookies or history: those live in the profile directory under Roaming AppData.'
        })
    } `
    -GetCleanupPlan {
        param($Session, $Candidates)
        @(foreach ($candidate in $Candidates) {
            New-WaFileCleanupRecommendation -Session $Session -Candidate $candidate `
                -Consequence 'Pages load from the network once instead of from disk. Bookmarks, saved logins, history and open tabs are unaffected.' `
                -Warnings @('A running Firefox holds cache files open; those are skipped, so closing it first reclaims more.') `
                -QuestionId 'browsers'
        })
    } `
    -TestResult {
        param($Session, $Results)
        $bytes = [long]0
        foreach ($location in (Get-WaFirefoxCacheProfile)) {
            $size = Get-WaDirectorySize -Path $location.Path -Config $Session.Config
            if ($null -ne $size.Bytes) { $bytes += [long]$size.Bytes }
        }
        @([pscustomobject]@{
            Provider = 'Browsers.Firefox'
            Verified = $true
            Message  = ('Firefox cache now measures {0}.' -f (Format-WaBytes $bytes))
        })
    } | Out-Null
