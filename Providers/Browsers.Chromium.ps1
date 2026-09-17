<#
    Providers/Browsers.Chromium.ps1 - Chromium-family browser caches.

    Covers Chrome, Edge, Brave, Vivaldi and Opera, which share a profile layout.

    Scope is cache and only cache. The directories targeted hold content that is re-fetched
    or recompiled on demand. Everything that represents a decision the user made is out of
    scope and never enumerated for deletion:

        Login Data          saved passwords
        Web Data            autofill and payment methods
        Cookies             sign-in sessions
        History             browsing history
        Bookmarks           bookmarks
        Preferences         settings
        Extensions          installed extensions
        Sessions/Tabs       open tabs and session restore
        Local Storage       site data, including offline app data

    The browser does not need to be closed. Files it holds open are skipped rather than
    forced, which simply means a running browser reclaims less.
#>

function Get-WaChromiumBrowserDefinition {
    <#
    .SYNOPSIS
        The Chromium-family browsers this provider understands, and where their data lives.
    #>
    [CmdletBinding()]
    param()

    $base = Get-WaBasePaths
    @(
        [pscustomobject]@{ Key = 'chrome';   Name = 'Google Chrome';  UserData = (Join-Path $base.LocalAppData 'Google\Chrome\User Data') }
        [pscustomobject]@{ Key = 'edge';     Name = 'Microsoft Edge'; UserData = (Join-Path $base.LocalAppData 'Microsoft\Edge\User Data') }
        [pscustomobject]@{ Key = 'brave';    Name = 'Brave';          UserData = (Join-Path $base.LocalAppData 'BraveSoftware\Brave-Browser\User Data') }
        [pscustomobject]@{ Key = 'vivaldi';  Name = 'Vivaldi';        UserData = (Join-Path $base.LocalAppData 'Vivaldi\User Data') }
        [pscustomobject]@{ Key = 'opera';    Name = 'Opera';          UserData = (Join-Path $base.RoamingAppData 'Opera Software\Opera Stable') }
        [pscustomobject]@{ Key = 'chromium'; Name = 'Chromium';       UserData = (Join-Path $base.LocalAppData 'Chromium\User Data') }
    )
}

function Get-WaChromiumCacheLocation {
    <#
    .SYNOPSIS
        Cache directories for one browser installation, across all of its profiles.

    .DESCRIPTION
        Profile directories are 'Default' and 'Profile N'. 'System Profile' and
        'Guest Profile' are included because their caches are equally disposable.

        The list is an explicit allow-list of cache subdirectories. It is never derived by
        scanning the profile for things that look like caches, because a heuristic that
        guesses wrong here deletes someone's passwords.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Browser, [Parameter(Mandatory)]$Session)

    if (-not (Test-Path -LiteralPath $Browser.UserData -PathType Container)) { return @() }

    $includeCodeCache = [bool](Get-WaProviderSetting -Config $Session.Config -Provider 'Browsers.Chromium' -Name 'IncludeCodeCaches' -Default $true)
    $includeGpuCache  = [bool](Get-WaProviderSetting -Config $Session.Config -Provider 'Browsers.Chromium' -Name 'IncludeGpuCache' -Default $true)

    $profileNames = New-Object 'System.Collections.Generic.List[string]'
    try {
        foreach ($directory in (Get-ChildItem -LiteralPath $Browser.UserData -Directory -ErrorAction Stop)) {
            if ($directory.Name -eq 'Default' -or $directory.Name -like 'Profile *' -or
                $directory.Name -eq 'Guest Profile' -or $directory.Name -eq 'System Profile') {
                $profileNames.Add($directory.Name)
            }
        }
    } catch { return @() }

    $locations = New-Object 'System.Collections.Generic.List[object]'

    foreach ($profileName in $profileNames) {
        $profilePath = Join-Path $Browser.UserData $profileName

        $subdirectories = New-Object 'System.Collections.Generic.List[string]'
        $subdirectories.Add('Cache\Cache_Data')
        $subdirectories.Add('Service Worker\CacheStorage')
        $subdirectories.Add('Service Worker\ScriptCache')
        if ($includeCodeCache) {
            $subdirectories.Add('Code Cache\js')
            $subdirectories.Add('Code Cache\wasm')
        }
        if ($includeGpuCache) {
            $subdirectories.Add('GPUCache')
            $subdirectories.Add('DawnCache')
            $subdirectories.Add('DawnGraphiteCache')
            $subdirectories.Add('DawnWebGPUCache')
        }

        foreach ($subdirectory in $subdirectories) {
            $path = Join-Path $profilePath $subdirectory
            if (-not (Test-Path -LiteralPath $path -PathType Container)) { continue }
            $locations.Add([pscustomobject]@{
                Key   = ('browsers.{0}.{1}.{2}' -f $Browser.Key, ($profileName -replace '[^A-Za-z0-9]', ''), ($subdirectory -replace '[^A-Za-z0-9]', ''))
                Title = ('{0} {1} cache ({2})' -f $Browser.Name, $profileName, $subdirectory)
                Path  = $path
            })
        }
    }

    # Shader caches live at the user-data root rather than inside a profile.
    if ($includeGpuCache) {
        foreach ($shaderDirectory in @('ShaderCache', 'GrShaderCache', 'GraphiteDawnCache')) {
            $path = Join-Path $Browser.UserData $shaderDirectory
            if (-not (Test-Path -LiteralPath $path -PathType Container)) { continue }
            $locations.Add([pscustomobject]@{
                Key   = ('browsers.{0}.{1}' -f $Browser.Key, $shaderDirectory.ToLowerInvariant())
                Title = ('{0} {1}' -f $Browser.Name, $shaderDirectory)
                Path  = $path
            })
        }
    }

    return $locations.ToArray()
}

function Get-WaInstalledChromiumBrowser {
    [CmdletBinding()]
    param()
    @(Get-WaChromiumBrowserDefinition | Where-Object { Test-Path -LiteralPath $_.UserData -PathType Container })
}

Register-WaProvider -Name 'Browsers.Chromium' -Order 100 `
    -Title 'Chromium browser caches' `
    -Category 'Browsers' `
    -Description 'Cache, code cache, service worker cache and shader cache for Chrome, Edge, Brave, Vivaldi, Opera and Chromium. Passwords, bookmarks, cookies, history, autofill, extensions and sessions are never touched.' `
    -Reference 'https://chromium.googlesource.com/chromium/src/+/HEAD/docs/user_data_dir.md' `
    -TestAvailable {
        param($Session)
        $browsers = @(Get-WaInstalledChromiumBrowser)
        if ($browsers.Count -eq 0) {
            return (New-WaProviderAvailability -Available $false -Reason 'No Chromium-family browser profile was found.')
        }
        New-WaProviderAvailability -Available $true -Reason (('Found: ' + (($browsers | ForEach-Object { $_.Name }) -join ', ')))
    } `
    -GetInventory {
        param($Session)
        @(foreach ($browser in (Get-WaInstalledChromiumBrowser)) {
            New-WaInstalledComponent -Name $browser.Name -Category 'Browser' `
                -InstallPath $browser.UserData -DetectionMethod 'Directory' -DetectionConfidence 'HIGH' `
                -Note ('{0} cache location(s)' -f @(Get-WaChromiumCacheLocation -Browser $browser -Session $Session).Count)
        })
    } `
    -GetAnalysis {
        param($Session, $Inventory)
        $output = New-Object 'System.Collections.Generic.List[object]'
        $totalBytes = [long]0
        $evidence = New-Object 'System.Collections.Generic.List[object]'

        foreach ($browser in (Get-WaInstalledChromiumBrowser)) {
            $browserBytes = [long]0
            $complete = $true
            foreach ($location in (Get-WaChromiumCacheLocation -Browser $browser -Session $Session)) {
                $size = Get-WaDirectorySize -Path $location.Path -Config $Session.Config
                if ($null -eq $size.Bytes) { $complete = $false; continue }
                $browserBytes += [long]$size.Bytes
                if (-not $size.Complete) { $complete = $false }
            }
            if ($browserBytes -eq 0) { continue }

            $totalBytes += $browserBytes
            $evidence.Add((New-WaEvidence -Source $browser.UserData -Method 'Bounded filesystem enumeration' `
                -Statement ('{0}: {1} of cache.' -f $browser.Name, (Format-WaBytes $browserBytes)) `
                -Value $browserBytes -Unit 'bytes' -Complete $complete))

            $output.Add((New-WaStorageConsumer -Name ($browser.Name + ' cache') -Category 'Browser caches' `
                -Path $browser.UserData -Bytes $browserBytes -Complete $complete -Provider 'Browsers.Chromium' `
                -Disposition 'Actionable' `
                -Note 'Cache directories only. Profile data such as passwords, bookmarks and cookies is not included in this figure and is never targeted.'))
        }

        if ($totalBytes -gt 0) {
            $output.Add((New-WaFinding -Id 'browsers.chromium.cache' `
                -Title 'Browser caches' -Category 'Browser caches' -Provider 'Browsers.Chromium' `
                -Description ('Chromium-family browsers hold {0} of cache. Cache is re-fetched on demand, so clearing it costs one slower page load per site.' -f (Format-WaBytes $totalBytes)) `
                -Evidence $evidence.ToArray() `
                -CurrentImpact ('{0} of regenerable cache.' -f (Format-WaBytes $totalBytes)) `
                -Confidence 'HIGH' -Disposition 'Actionable' -Bytes $totalBytes `
                -Warnings @('You stay signed in to websites: sign-in state lives in cookies, which are not touched.')))
        }

        return $output.ToArray()
    } `
    -GetCleanupCandidates {
        param($Session, $Inventory)
        $age = $Session.Config.MinimumCacheAgeDays
        @(foreach ($browser in (Get-WaInstalledChromiumBrowser)) {
            foreach ($location in (Get-WaChromiumCacheLocation -Browser $browser -Session $Session)) {
                Get-WaCacheRootCandidate -Session $Session -Provider 'Browsers.Chromium' `
                    -Key $location.Key -Title $location.Title -Category 'Browser caches' `
                    -Path $location.Path -AgeDays $age -Risk 'LOW' -Confidence 'HIGH' `
                    -Explanation ('Cached web content for {0}. Re-downloaded automatically the next time you visit a site. This directory holds no sign-in state, bookmarks or saved passwords.' -f $browser.Name)
            }
        })
    } `
    -GetCleanupPlan {
        param($Session, $Candidates)
        @(foreach ($candidate in $Candidates) {
            New-WaFileCleanupRecommendation -Session $Session -Candidate $candidate `
                -Consequence 'Pages load from the network once instead of from disk, then re-cache. You stay signed in, and bookmarks, passwords, history and extensions are unaffected.' `
                -Warnings @(
                    'A running browser holds many cache files open. Those are skipped, so closing the browser first reclaims more.'
                ) `
                -QuestionId 'browsers'
        })
    } `
    -TestResult {
        param($Session, $Results)
        @(foreach ($browser in (Get-WaInstalledChromiumBrowser)) {
            $bytes = [long]0
            foreach ($location in (Get-WaChromiumCacheLocation -Browser $browser -Session $Session)) {
                $size = Get-WaDirectorySize -Path $location.Path -Config $Session.Config
                if ($null -ne $size.Bytes) { $bytes += [long]$size.Bytes }
            }
            [pscustomobject]@{
                Provider = 'Browsers.Chromium'
                Verified = $true
                Message  = ('{0} cache now measures {1}.' -f $browser.Name, (Format-WaBytes $bytes))
            }
        })
    } | Out-Null
