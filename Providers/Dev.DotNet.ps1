<#
    Providers/Dev.DotNet.ps1 - .NET and NuGet caches.

    The NuGet global-packages folder is frequently the largest developer cache on a machine
    and one of the most clearly regenerable: every package in it came from a feed and can
    come from that feed again.

    Cleanup goes through NuGet's own documented mechanism (dotnet nuget locals --clear)
    rather than by deleting the directory. NuGet maintains metadata alongside the extracted
    packages, and the official command is the only path guaranteed to leave the cache in a
    consistent state.

    Cache locations are discovered by asking NuGet where they are, not by assuming
    %USERPROFILE%\.nuget\packages. NUGET_PACKAGES and NuGet.Config both relocate it, and a
    wrong guess here means measuring the wrong directory.
#>

function Get-WaNuGetCacheLocation {
    <#
    .SYNOPSIS
        Asks NuGet where its caches live and measures each one.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session)

    $probe = Invoke-WaCatalogProbe -CommandId 'dotnet.nuget.locals.list' -Session $Session
    if (-not $probe.Available -or $probe.ExitCode -ne 0) { return @() }

    $settingByCache = @{
        'global-packages' = 'IncludeGlobalPackages'
        'http-cache'      = 'IncludeHttpCache'
        'temp'            = 'IncludeTempCache'
        'plugins-cache'   = 'IncludePluginsCache'
    }

    $locations = New-Object 'System.Collections.Generic.List[object]'
    foreach ($line in ([string]$probe.Output -split "`r?`n")) {
        $match = [regex]::Match($line.Trim(), '^(?<name>[a-z-]+):\s*(?<path>[A-Za-z]:\\.*)$')
        if (-not $match.Success) { continue }

        $name = $match.Groups['name'].Value
        $path = $match.Groups['path'].Value.TrimEnd('\')
        if (-not $settingByCache.ContainsKey($name)) { continue }
        if (-not (Get-WaProviderSetting -Config $Session.Config -Provider 'Dev.DotNet' -Name $settingByCache[$name] -Default $true)) { continue }
        if (-not (Test-Path -LiteralPath $path -PathType Container)) { continue }

        $locations.Add([pscustomobject]@{
            Name      = $name
            Path      = $path
            CommandId = ('dotnet.nuget.locals.clear.' + $name)
        })
    }
    return $locations.ToArray()
}

Register-WaProvider -Name 'Dev.DotNet' -Order 300 `
    -Title '.NET and NuGet caches' `
    -Category 'Developer tooling' `
    -Description 'Measures NuGet local caches and clears them through the official dotnet nuget locals command. No project, package reference or build output is touched.' `
    -Reference 'https://learn.microsoft.com/en-us/nuget/reference/cli-reference/cli-ref-locals' `
    -TestAvailable {
        param($Session)
        if (-not (Resolve-WaCommandPath -Name 'dotnet')) {
            return (New-WaProviderAvailability -Available $false -Reason 'The dotnet CLI was not found on PATH.')
        }
        $locations = @(Get-WaNuGetCacheLocation -Session $Session)
        $Session.ProviderState['Dev.DotNet'] = $locations
        if ($locations.Count -eq 0) {
            return (New-WaProviderAvailability -Available $false -Reason 'dotnet is installed but reported no usable NuGet cache locations.')
        }
        New-WaProviderAvailability -Available $true -Reason ('{0} NuGet cache location(s).' -f $locations.Count)
    } `
    -GetInventory {
        param($Session)
        $components = New-Object 'System.Collections.Generic.List[object]'

        $sdkProbe = Invoke-WaCatalogProbe -CommandId 'dotnet.sdks' -Session $Session
        if ($sdkProbe.Available -and $sdkProbe.ExitCode -eq 0) {
            foreach ($line in ([string]$sdkProbe.Output -split "`r?`n")) {
                $trimmed = $line.Trim()
                if (-not $trimmed) { continue }
                $version = ($trimmed -split '\s+')[0]
                $components.Add((New-WaInstalledComponent -Name ('.NET SDK ' + $version) -Category 'Developer runtime' `
                    -Vendor 'Microsoft' -Version $version -DetectionMethod 'dotnet --list-sdks' -DetectionConfidence 'HIGH'))
            }
        }

        foreach ($location in @($Session.ProviderState['Dev.DotNet'])) {
            $size = Get-WaDirectorySize -Path $location.Path -Config $Session.Config
            $components.Add((New-WaInstalledComponent -Name ('NuGet ' + $location.Name) -Category 'Package cache' `
                -Vendor 'Microsoft' -InstallPath $location.Path -DetectionMethod 'dotnet nuget locals --list' `
                -DetectionConfidence 'HIGH' -Note ('{0} measured' -f (Format-WaBytes $size.Bytes))))
        }

        return $components.ToArray()
    } `
    -GetAnalysis {
        param($Session, $Inventory)
        $locations = @($Session.ProviderState['Dev.DotNet'])
        if ($locations.Count -eq 0) { return @() }

        $output = New-Object 'System.Collections.Generic.List[object]'
        $evidence = New-Object 'System.Collections.Generic.List[object]'
        $totalBytes = [long]0
        $complete = $true

        foreach ($location in $locations) {
            $size = Get-WaDirectorySize -Path $location.Path -Config $Session.Config
            if ($null -eq $size.Bytes) { $complete = $false; continue }
            $totalBytes += [long]$size.Bytes
            if (-not $size.Complete) { $complete = $false }

            $evidence.Add((New-WaEvidence -Source $location.Path -Method 'Bounded filesystem enumeration' `
                -Statement ('NuGet {0}: {1}.' -f $location.Name, (Format-WaBytes $size.Bytes)) `
                -Value $size.Bytes -Unit 'bytes' -Complete $size.Complete))

            $output.Add((New-WaStorageConsumer -Name ('NuGet ' + $location.Name) -Category 'Package-manager caches' `
                -Path $location.Path -Bytes $size.Bytes -Complete $size.Complete -Provider 'Dev.DotNet' `
                -Disposition 'Actionable' `
                -Note 'Regenerable: every package here can be restored from its feed again.'))
        }

        if ($totalBytes -eq 0) { return $output.ToArray() }

        $output.Add((New-WaFinding -Id 'dev.dotnet.nugetcache' `
            -Title 'NuGet caches' -Category 'Developer tooling' -Provider 'Dev.DotNet' `
            -Description ('NuGet local caches hold {0}. Everything in them was downloaded from a package feed and can be downloaded again.' -f (Format-WaBytes $totalBytes)) `
            -Evidence $evidence.ToArray() `
            -CurrentImpact ('{0} across {1} cache location(s).' -f (Format-WaBytes $totalBytes), $locations.Count) `
            -Confidence 'HIGH' -Disposition 'Actionable' -Bytes $totalBytes `
            -Warnings @(
                'Clearing global-packages means the next restore of every project downloads again. On a slow or metered connection that is a real cost.'
                'Offline or air-gapped builds will fail until packages are restored.'
            )))

        return $output.ToArray()
    } `
    -GetCleanupCandidates {
        param($Session, $Inventory)
        @(New-WaCleanupCandidate -Key 'dev.dotnet' -Provider 'Dev.DotNet' `
            -Title 'NuGet caches' -Category 'Developer tooling' -Risk 'MANUAL-ONLY' `
            -Explanation 'NuGet caches are cleared with the official CLI, not by deleting files.')
    } `
    -GetCleanupPlan {
        param($Session, $Candidates)
        $locations = @($Session.ProviderState['Dev.DotNet'])
        $recommendations = New-Object 'System.Collections.Generic.List[object]'

        foreach ($location in $locations) {
            $size = Get-WaDirectorySize -Path $location.Path -Config $Session.Config
            if ($null -eq $size.Bytes -or [long]$size.Bytes -lt 10MB) { continue }

            $description = switch ($location.Name) {
                'global-packages' { 'The extracted package store shared by every project on this machine. Restoring any project re-downloads what it needs.' }
                'http-cache'      { 'Cached HTTP responses from package feeds. Purely a network optimisation.' }
                'temp'            { 'NuGet scratch files. Transient by design.' }
                'plugins-cache'   { 'Cached authentication plugin metadata. Rebuilt on next use.' }
                default           { 'A NuGet local cache.' }
            }

            $recommendation = New-WaCommandRecommendation -Session $Session `
                -Id ('dev.dotnet.clear.' + $location.Name) `
                -CommandId $location.CommandId `
                -Title ('Clear the NuGet {0} cache' -f $location.Name) `
                -Category 'Developer tooling' -Provider 'Dev.DotNet' `
                -Description $description `
                -Evidence @(
                    New-WaEvidence -Source $location.Path -Method 'Bounded filesystem enumeration' `
                        -Statement ('{0} currently occupied.' -f (Format-WaBytes $size.Bytes)) -Value $size.Bytes -Unit 'bytes' -Complete $size.Complete
                    New-WaEvidence -Source 'dotnet nuget locals all --list' -Method 'NuGet CLI' `
                        -Statement ('NuGet reports this cache at {0}, so the location is confirmed rather than assumed.' -f $location.Path) -Measured $true
                ) `
                -CurrentImpact ('{0} in the {1} cache.' -f (Format-WaBytes $size.Bytes), $location.Name) `
                -EstimatedBytes $size.Bytes -EstimateComplete $size.Complete `
                -Risk 'LOW' -Confidence 'HIGH' -Reversibility 'RegenerableOnly' `
                -RollbackNote 'Not reversible, and not needed: packages are re-downloaded on the next restore.' `
                -Warnings @('Your next build of each project will spend time restoring packages.') `
                -QuestionId 'devtools'

            if ($null -ne $recommendation) { $recommendations.Add($recommendation) }
        }

        return $recommendations.ToArray()
    } `
    -TestResult {
        param($Session, $Results)
        @(foreach ($location in @($Session.ProviderState['Dev.DotNet'])) {
            $size = Get-WaDirectorySize -Path $location.Path -Config $Session.Config
            [pscustomobject]@{
                Provider = 'Dev.DotNet'
                Verified = $true
                Message  = ('NuGet {0} now measures {1}.' -f $location.Name, (Format-WaBytes $size.Bytes))
            }
        })
    } | Out-Null
