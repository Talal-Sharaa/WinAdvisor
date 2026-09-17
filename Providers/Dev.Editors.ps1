<#
    Providers/Dev.Editors.ps1 - editor and IDE caches.

    Visual Studio Code, JetBrains IDEs and Visual Studio all keep large regenerable caches
    and indexes. Those are in scope.

    Out of scope, deliberately:

      Extensions and plugins   removing them uninstalls working tools, and re-installing
                               may not restore the same version.
      Settings and keymaps     configuration the user chose.
      Workspace storage        holds per-project state such as unsaved editor buffers and
                               local history, which JetBrains in particular uses as a
                               genuine recovery mechanism.
      Package Cache (VS)       Visual Studio's installer cache. Removing it breaks repair,
                               modify and uninstall. Reported for size, never deleted.
#>

function Get-WaEditorCacheLocation {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session)

    $base = Get-WaBasePaths
    $config = $Session.Config
    $locations = New-Object 'System.Collections.Generic.List[object]'

    if (Get-WaProviderSetting -Config $config -Provider 'Dev.Editors' -Name 'IncludeVSCode' -Default $true) {
        foreach ($variant in @(
            @{ Name = 'Visual Studio Code'; Root = (Join-Path $base.RoamingAppData 'Code') }
            @{ Name = 'VS Code Insiders';   Root = (Join-Path $base.RoamingAppData 'Code - Insiders') }
            @{ Name = 'VSCodium';           Root = (Join-Path $base.RoamingAppData 'VSCodium') }
        )) {
            if (-not (Test-Path -LiteralPath $variant.Root -PathType Container)) { continue }
            foreach ($subdirectory in @('Cache', 'CachedData', 'CachedExtensionVSIXs', 'Code Cache', 'GPUCache', 'DawnGraphiteCache', 'DawnWebGPUCache', 'logs')) {
                $path = Join-Path $variant.Root $subdirectory
                if (-not (Test-Path -LiteralPath $path -PathType Container)) { continue }
                $locations.Add([pscustomobject]@{
                    Key = ('dev.editors.vscode.{0}.{1}' -f ($variant.Name -replace '[^A-Za-z0-9]', ''), ($subdirectory -replace '[^A-Za-z0-9]', ''))
                    Title = ('{0} {1}' -f $variant.Name, $subdirectory)
                    Path = $path; Risk = 'LOW'
                    Explanation = ('Regenerable cache written by {0}. Extensions, settings and workspace storage are in different directories and are not touched.' -f $variant.Name)
                    Consequence = 'The editor rebuilds these caches on next launch; the first start afterwards is slightly slower.'
                })
            }
        }
    }

    if (Get-WaProviderSetting -Config $config -Provider 'Dev.Editors' -Name 'IncludeJetBrains' -Default $true) {
        $jetBrainsRoot = Join-Path $base.LocalAppData 'JetBrains'
        if (Test-Path -LiteralPath $jetBrainsRoot -PathType Container) {
            $products = @()
            try { $products = @(Get-ChildItem -LiteralPath $jetBrainsRoot -Directory -ErrorAction Stop) } catch { $products = @() }

            foreach ($product in $products) {
                foreach ($subdirectory in @('caches', 'index', 'log', 'tmp')) {
                    $path = Join-Path $product.FullName $subdirectory
                    if (-not (Test-Path -LiteralPath $path -PathType Container)) { continue }
                    $locations.Add([pscustomobject]@{
                        Key = ('dev.editors.jetbrains.{0}.{1}' -f ($product.Name -replace '[^A-Za-z0-9]', ''), $subdirectory)
                        Title = ('JetBrains {0} {1}' -f $product.Name, $subdirectory)
                        Path = $path; Risk = 'LOW'
                        Explanation = ('Index and cache data for {0}. The IDE rebuilds it by reindexing.' -f $product.Name)
                        Consequence = 'The IDE reindexes your projects on next open, which on a large project can take several minutes and use significant CPU.'
                    })
                }
            }
        }
    }

    if (Get-WaProviderSetting -Config $config -Provider 'Dev.Editors' -Name 'IncludeVisualStudio' -Default $true) {
        $visualStudioRoot = Join-Path $base.LocalAppData 'Microsoft\VisualStudio'
        if (Test-Path -LiteralPath $visualStudioRoot -PathType Container) {
            $instances = @()
            try { $instances = @(Get-ChildItem -LiteralPath $visualStudioRoot -Directory -ErrorAction Stop) } catch { $instances = @() }

            foreach ($instance in $instances) {
                foreach ($subdirectory in @('ComponentModelCache', 'Designer\ShadowCache')) {
                    $path = Join-Path $instance.FullName $subdirectory
                    if (-not (Test-Path -LiteralPath $path -PathType Container)) { continue }
                    $locations.Add([pscustomobject]@{
                        Key = ('dev.editors.vs.{0}.{1}' -f ($instance.Name -replace '[^A-Za-z0-9]', ''), ($subdirectory -replace '[^A-Za-z0-9]', ''))
                        Title = ('Visual Studio {0} {1}' -f $instance.Name, (Split-Path -Leaf $subdirectory))
                        Path = $path; Risk = 'LOW'
                        Explanation = 'Visual Studio MEF component and designer shadow caches. Rebuilt automatically at next start.'
                        Consequence = 'The next Visual Studio start is slower while the cache rebuilds.'
                    })
                }
            }
        }
    }

    return $locations.ToArray()
}

function Get-WaVisualStudioPackageCache {
    <#
    .SYNOPSIS
        The Visual Studio installer package cache, reported but never deleted.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session)

    $path = Join-Path (Get-WaBasePaths).ProgramData 'Package Cache'
    if (-not (Test-Path -LiteralPath $path -PathType Container)) { return $null }
    $size = Get-WaDirectorySize -Path $path -Config $Session.Config
    if (-not $size.Exists) { return $null }
    return [pscustomobject]@{ Path = $path; Bytes = $size.Bytes; Complete = $size.Complete }
}

Register-WaProvider -Name 'Dev.Editors' -Order 350 `
    -Title 'Editor and IDE caches' `
    -Category 'Developer tooling' `
    -Description 'VS Code, JetBrains and Visual Studio caches and indexes. Extensions, settings and workspace storage are never touched, and the Visual Studio installer cache is reported rather than removed.' `
    -Reference 'https://code.visualstudio.com/docs/getstarted/settings' `
    -TestAvailable {
        param($Session)
        $locations = @(Get-WaEditorCacheLocation -Session $Session)
        $packageCache = Get-WaVisualStudioPackageCache -Session $Session
        $Session.ProviderState['Dev.Editors'] = [pscustomobject]@{ Locations = $locations; PackageCache = $packageCache }

        if ($locations.Count -eq 0 -and $null -eq $packageCache) {
            return (New-WaProviderAvailability -Available $false -Reason 'No editor or IDE cache directory was found.')
        }
        New-WaProviderAvailability -Available $true -Reason ('{0} cache location(s).' -f $locations.Count)
    } `
    -GetInventory {
        param($Session)
        $state = $Session.ProviderState['Dev.Editors']
        @(foreach ($location in @($state.Locations)) {
            $size = Get-WaDirectorySize -Path $location.Path -Config $Session.Config
            New-WaInstalledComponent -Name $location.Title -Category 'Editor cache' `
                -InstallPath $location.Path -DetectionMethod 'Directory' `
                -Note ('{0} measured' -f (Format-WaBytes $size.Bytes))
        })
    } `
    -GetAnalysis {
        param($Session, $Inventory)
        $state = $Session.ProviderState['Dev.Editors']
        $output = New-Object 'System.Collections.Generic.List[object]'
        $evidence = New-Object 'System.Collections.Generic.List[object]'
        $totalBytes = [long]0

        foreach ($location in @($state.Locations)) {
            $size = Get-WaDirectorySize -Path $location.Path -Config $Session.Config
            if ($null -eq $size.Bytes -or [long]$size.Bytes -eq 0) { continue }
            $totalBytes += [long]$size.Bytes
            $evidence.Add((New-WaEvidence -Source $location.Path -Method 'Bounded filesystem enumeration' `
                -Statement ('{0}: {1}.' -f $location.Title, (Format-WaBytes $size.Bytes)) -Value $size.Bytes -Unit 'bytes' -Complete $size.Complete))
            $output.Add((New-WaStorageConsumer -Name $location.Title -Category 'Developer tooling' `
                -Path $location.Path -Bytes $size.Bytes -Complete $size.Complete -Provider 'Dev.Editors' -Disposition 'Actionable' `
                -Note $location.Explanation))
        }

        if ($null -ne $state.PackageCache) {
            $output.Add((New-WaStorageConsumer -Name 'Visual Studio installer package cache' -Category 'Installers' `
                -Path $state.PackageCache.Path -Bytes $state.PackageCache.Bytes -Complete $state.PackageCache.Complete `
                -Provider 'Dev.Editors' -Disposition 'ManualReview' `
                -Note 'Reported only. Visual Studio needs this to repair, modify or uninstall itself; removing it makes those operations demand the original installer media or a full re-download.'))

            $output.Add((New-WaFinding -Id 'dev.editors.packagecache' `
                -Title 'Visual Studio installer package cache' -Category 'Developer tooling' -Provider 'Dev.Editors' `
                -Description ('The Visual Studio installer package cache holds {0}. It is left alone: Visual Studio uses it to repair, modify and uninstall itself.' -f (Format-WaBytes $state.PackageCache.Bytes)) `
                -Evidence @(New-WaEvidence -Source $state.PackageCache.Path -Method 'Bounded filesystem enumeration' `
                    -Statement ('{0} occupied.' -f (Format-WaBytes $state.PackageCache.Bytes)) -Value $state.PackageCache.Bytes -Unit 'bytes' -Complete $state.PackageCache.Complete) `
                -CurrentImpact ('{0} of installer payloads.' -f (Format-WaBytes $state.PackageCache.Bytes)) `
                -Confidence 'HIGH' -Disposition 'Informational' -Bytes $state.PackageCache.Bytes `
                -Warnings @('If you want this space back, the supported route is the Visual Studio Installer, which can be configured to keep less. Deleting the directory by hand breaks repair and uninstall.')))
        }

        if ($totalBytes -gt 0) {
            $output.Add((New-WaFinding -Id 'dev.editors.caches' `
                -Title 'Editor and IDE caches' -Category 'Developer tooling' -Provider 'Dev.Editors' `
                -Description ('Editor and IDE caches hold {0}.' -f (Format-WaBytes $totalBytes)) `
                -Evidence $evidence.ToArray() `
                -CurrentImpact ('{0} of index and cache data.' -f (Format-WaBytes $totalBytes)) `
                -Confidence 'HIGH' -Disposition 'Actionable' -Bytes $totalBytes `
                -Warnings @('Clearing a JetBrains index means the IDE reindexes on next open, which on a large project takes minutes and a lot of CPU.')))
        }

        return $output.ToArray()
    } `
    -GetCleanupCandidates {
        param($Session, $Inventory)
        $state = $Session.ProviderState['Dev.Editors']
        $age = $Session.Config.MinimumCacheAgeDays
        @(foreach ($location in @($state.Locations)) {
            Get-WaCacheRootCandidate -Session $Session -Provider 'Dev.Editors' `
                -Key $location.Key -Title $location.Title -Category 'Developer tooling' `
                -Path $location.Path -AgeDays $age -Risk $location.Risk -Confidence 'HIGH' `
                -Explanation $location.Explanation
        })
    } `
    -GetCleanupPlan {
        param($Session, $Candidates)
        $state = $Session.ProviderState['Dev.Editors']
        $byKey = @{}
        foreach ($location in @($state.Locations)) { $byKey[$location.Key] = $location }

        @(foreach ($candidate in $Candidates) {
            $location = $byKey[$candidate.Key]
            if ($null -eq $location) { continue }
            New-WaFileCleanupRecommendation -Session $Session -Candidate $candidate `
                -Consequence $location.Consequence `
                -Warnings @(
                    'Close the editor first. Files it holds open are skipped, so cleaning with it running reclaims less.'
                    'Extensions, settings and workspace storage are not included in this manifest.'
                ) `
                -QuestionId 'devtools'
        })
    } `
    -TestResult {
        param($Session, $Results)
        $state = $Session.ProviderState['Dev.Editors']
        $bytes = [long]0
        foreach ($location in @($state.Locations)) {
            $size = Get-WaDirectorySize -Path $location.Path -Config $Session.Config
            if ($null -ne $size.Bytes) { $bytes += [long]$size.Bytes }
        }
        @([pscustomobject]@{
            Provider = 'Dev.Editors'
            Verified = $true
            Message  = ('Editor and IDE caches now measure {0} in total.' -f (Format-WaBytes $bytes))
        })
    } | Out-Null
