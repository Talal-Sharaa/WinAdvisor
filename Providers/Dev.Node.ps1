<#
    Providers/Dev.Node.ps1 - npm, pnpm, Yarn and Bun caches.

    Each tool is asked where its own cache lives rather than assuming a default path, and
    each is cleaned with its own documented command.

    pnpm deserves specific mention. Its store is content-addressable and installed projects
    hard-link into it, so deleting the store directory corrupts every project on the machine
    that depends on it. The only correct operation is pnpm store prune, which removes
    entries nothing references. This provider never file-deletes a pnpm store.

    node_modules directories are never touched. They are project state, they are what a
    lock file exists to reproduce, and a developer who wants them gone knows where they are.
#>

function Get-WaNodeCacheTool {
    <#
    .SYNOPSIS
        The Node-ecosystem package managers present on this machine, with their cache paths.

    .DESCRIPTION
        The cache path is read from each tool. npm honours .npmrc and the npm_config_cache
        environment variable, Yarn Classic and Berry use different locations, and pnpm's
        store can be moved entirely, so guessing produces wrong measurements.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session)

    $config = $Session.Config
    $tools = New-Object 'System.Collections.Generic.List[object]'

    $readPath = {
        param([string]$CommandId)
        $probe = Invoke-WaCatalogProbe -CommandId $CommandId -Session $Session
        if (-not $probe.Available -or $probe.ExitCode -ne 0) { return $null }
        $text = ([string]$probe.Output).Trim()
        $line = @($text -split "`r?`n" | Where-Object { $_.Trim() -match '^[A-Za-z]:\\' }) | Select-Object -First 1
        if (-not $line) { return $null }
        return $line.Trim()
    }

    if ((Get-WaProviderSetting -Config $config -Provider 'Dev.Node' -Name 'IncludeNpm' -Default $true) -and (Resolve-WaCommandPath -Name 'npm')) {
        $path = & $readPath 'npm.cache.path'
        if ($path) {
            # npm reports the cache root; the package data lives in _cacache beneath it.
            $cacache = Join-Path $path '_cacache'
            $measured = if (Test-Path -LiteralPath $cacache -PathType Container) { $cacache } else { $path }
            $tools.Add([pscustomobject]@{
                Key = 'npm'; Name = 'npm'; Path = $measured; CommandId = 'npm.cache.clean'
                Description = 'The npm content-addressable cache. npm treats it as fully disposable and self-heals: clearing it only means package tarballs are downloaded again.'
                Consequence = 'The next install in each project re-downloads package tarballs from the registry.'
            })
        }
    }

    if ((Get-WaProviderSetting -Config $config -Provider 'Dev.Node' -Name 'IncludePnpm' -Default $true) -and (Resolve-WaCommandPath -Name 'pnpm')) {
        $path = & $readPath 'pnpm.store.path'
        if ($path) {
            $tools.Add([pscustomobject]@{
                Key = 'pnpm'; Name = 'pnpm'; Path = $path; CommandId = 'pnpm.store.prune'
                Description = 'The pnpm content-addressable store. Pruning removes only packages that no project references; packages still in use are kept.'
                Consequence = 'Unreferenced packages are removed. Installed projects keep working, because their hard links point at entries that are retained.'
            })
        }
    }

    if ((Get-WaProviderSetting -Config $config -Provider 'Dev.Node' -Name 'IncludeYarn' -Default $true) -and (Resolve-WaCommandPath -Name 'yarn')) {
        $path = & $readPath 'yarn.cache.dir'
        if ($path) {
            $tools.Add([pscustomobject]@{
                Key = 'yarn'; Name = 'Yarn'; Path = $path; CommandId = 'yarn.cache.clean'
                Description = 'The Yarn package cache.'
                Consequence = 'Packages are downloaded again on the next install.'
            })
        }
    }

    return $tools.ToArray()
}

function Get-WaBunCachePath {
    <#
    .SYNOPSIS
        Bun's install cache, which is a plain directory of downloaded package tarballs.
    #>
    [CmdletBinding()]
    param()
    if (-not (Resolve-WaCommandPath -Name 'bun')) { return $null }
    $path = Join-Path (Get-WaBasePaths).UserProfile '.bun\install\cache'
    if (-not (Test-Path -LiteralPath $path -PathType Container)) { return $null }
    return $path
}

Register-WaProvider -Name 'Dev.Node' -Order 310 `
    -Title 'Node.js package manager caches' `
    -Category 'Developer tooling' `
    -Description 'npm, pnpm, Yarn and Bun caches, each cleaned with its own documented command. node_modules directories and lock files are never touched.' `
    -Reference 'https://docs.npmjs.com/cli/v10/commands/npm-cache' `
    -TestAvailable {
        param($Session)
        $tools = @(Get-WaNodeCacheTool -Session $Session)
        $bunPath = Get-WaBunCachePath
        $Session.ProviderState['Dev.Node'] = [pscustomobject]@{ Tools = $tools; BunPath = $bunPath }

        if ($tools.Count -eq 0 -and -not $bunPath) {
            return (New-WaProviderAvailability -Available $false -Reason 'No Node.js package manager was found on PATH.')
        }
        New-WaProviderAvailability -Available $true -Reason (('Found: ' + ((@($tools | ForEach-Object { $_.Name }) + @(if ($bunPath) { 'Bun' })) -join ', ')))
    } `
    -GetInventory {
        param($Session)
        $state = $Session.ProviderState['Dev.Node']
        $components = New-Object 'System.Collections.Generic.List[object]'

        foreach ($tool in @($state.Tools)) {
            $size = Get-WaDirectorySize -Path $tool.Path -Config $Session.Config
            $components.Add((New-WaInstalledComponent -Name ($tool.Name + ' cache') -Category 'Package cache' `
                -InstallPath $tool.Path -DetectionMethod 'Tool-reported cache path' -DetectionConfidence 'HIGH' `
                -Note ('{0} measured' -f (Format-WaBytes $size.Bytes))))
        }
        if ($state.BunPath) {
            $size = Get-WaDirectorySize -Path $state.BunPath -Config $Session.Config
            $components.Add((New-WaInstalledComponent -Name 'Bun cache' -Category 'Package cache' `
                -InstallPath $state.BunPath -DetectionMethod 'Directory' -DetectionConfidence 'HIGH' `
                -Note ('{0} measured' -f (Format-WaBytes $size.Bytes))))
        }
        return $components.ToArray()
    } `
    -GetAnalysis {
        param($Session, $Inventory)
        $state = $Session.ProviderState['Dev.Node']
        $output = New-Object 'System.Collections.Generic.List[object]'
        $evidence = New-Object 'System.Collections.Generic.List[object]'
        $totalBytes = [long]0

        foreach ($tool in @($state.Tools)) {
            $size = Get-WaDirectorySize -Path $tool.Path -Config $Session.Config
            if ($null -eq $size.Bytes) { continue }
            $totalBytes += [long]$size.Bytes
            $evidence.Add((New-WaEvidence -Source $tool.Path -Method 'Bounded filesystem enumeration' `
                -Statement ('{0}: {1}.' -f $tool.Name, (Format-WaBytes $size.Bytes)) -Value $size.Bytes -Unit 'bytes' -Complete $size.Complete))
            $output.Add((New-WaStorageConsumer -Name ($tool.Name + ' cache') -Category 'Package-manager caches' `
                -Path $tool.Path -Bytes $size.Bytes -Complete $size.Complete -Provider 'Dev.Node' -Disposition 'Actionable' `
                -Note $tool.Description))
        }

        if ($state.BunPath) {
            $size = Get-WaDirectorySize -Path $state.BunPath -Config $Session.Config
            if ($null -ne $size.Bytes) {
                $totalBytes += [long]$size.Bytes
                $evidence.Add((New-WaEvidence -Source $state.BunPath -Method 'Bounded filesystem enumeration' `
                    -Statement ('Bun: {0}.' -f (Format-WaBytes $size.Bytes)) -Value $size.Bytes -Unit 'bytes' -Complete $size.Complete))
                $output.Add((New-WaStorageConsumer -Name 'Bun cache' -Category 'Package-manager caches' `
                    -Path $state.BunPath -Bytes $size.Bytes -Complete $size.Complete -Provider 'Dev.Node' -Disposition 'Actionable' `
                    -Note 'Downloaded package tarballs. Re-downloaded on demand.'))
            }
        }

        if ($totalBytes -eq 0) { return $output.ToArray() }

        $output.Add((New-WaFinding -Id 'dev.node.caches' `
            -Title 'Node.js package caches' -Category 'Developer tooling' -Provider 'Dev.Node' `
            -Description ('Node.js package manager caches hold {0}.' -f (Format-WaBytes $totalBytes)) `
            -Evidence $evidence.ToArray() `
            -CurrentImpact ('{0} of downloaded package data.' -f (Format-WaBytes $totalBytes)) `
            -Confidence 'HIGH' -Disposition 'Actionable' -Bytes $totalBytes `
            -Warnings @(
                'node_modules directories are not included here and are never touched by WinAdvisor.'
                'A pnpm store is never deleted as files: installed projects hard-link into it, so only pnpm store prune is used.'
            )))

        return $output.ToArray()
    } `
    -GetCleanupCandidates {
        param($Session, $Inventory)
        $state = $Session.ProviderState['Dev.Node']
        $candidates = New-Object 'System.Collections.Generic.List[object]'

        # Bun has no catalog command, so its cache is handled as a file manifest. This is
        # safe because it is a flat directory of downloaded tarballs with no hard links
        # into installed projects.
        if ($state.BunPath) {
            $candidate = Get-WaCacheRootCandidate -Session $Session -Provider 'Dev.Node' `
                -Key 'dev.node.bun' -Title 'Bun package cache' -Category 'Package-manager caches' `
                -Path $state.BunPath -AgeDays $Session.Config.MinimumCacheAgeDays -Risk 'LOW' -Confidence 'HIGH' `
                -Explanation 'Downloaded package archives cached by Bun. Re-downloaded from the registry on the next install.'
            if ($null -ne $candidate) { $candidates.Add($candidate) }
        }

        $candidates.Add((New-WaCleanupCandidate -Key 'dev.node' -Provider 'Dev.Node' `
            -Title 'Node package manager caches' -Category 'Developer tooling' -Risk 'MANUAL-ONLY' `
            -Explanation 'npm, pnpm and Yarn caches are cleared with their own commands.'))

        return $candidates.ToArray()
    } `
    -GetCleanupPlan {
        param($Session, $Candidates)
        $state = $Session.ProviderState['Dev.Node']
        $recommendations = New-Object 'System.Collections.Generic.List[object]'

        foreach ($candidate in ($Candidates | Where-Object { $_.Key -eq 'dev.node.bun' })) {
            $recommendation = New-WaFileCleanupRecommendation -Session $Session -Candidate $candidate `
                -Consequence 'Packages are downloaded again on the next bun install.' -QuestionId 'devtools'
            if ($null -ne $recommendation) { $recommendations.Add($recommendation) }
        }

        foreach ($tool in @($state.Tools)) {
            $size = Get-WaDirectorySize -Path $tool.Path -Config $Session.Config
            if ($null -eq $size.Bytes -or [long]$size.Bytes -lt 10MB) { continue }

            $risk = if ($tool.Key -eq 'pnpm') { 'LOW' } else { 'LOW' }
            $warnings = New-Object 'System.Collections.Generic.List[string]'
            $warnings.Add('The next install in each project spends time downloading again.')
            if ($tool.Key -eq 'pnpm') {
                $warnings.Add('Only unreferenced packages are removed, so the recovered amount is usually well below the store size. The store directory itself is never deleted, because installed projects hard-link into it.')
            }

            $recommendation = New-WaCommandRecommendation -Session $Session `
                -Id ('dev.node.clear.' + $tool.Key) `
                -CommandId $tool.CommandId `
                -Title ('Clear the {0} cache' -f $tool.Name) `
                -Category 'Developer tooling' -Provider 'Dev.Node' `
                -Description $tool.Description `
                -Evidence @(
                    New-WaEvidence -Source $tool.Path -Method 'Bounded filesystem enumeration' `
                        -Statement ('{0} currently occupied.' -f (Format-WaBytes $size.Bytes)) -Value $size.Bytes -Unit 'bytes' -Complete $size.Complete
                    New-WaEvidence -Source $tool.Name -Method 'Tool-reported cache path' `
                        -Statement ('{0} reports its cache at {1}, so the location is confirmed rather than assumed.' -f $tool.Name, $tool.Path) -Measured $true
                ) `
                -CurrentImpact ('{0} in the {1} cache.' -f (Format-WaBytes $size.Bytes), $tool.Name) `
                -EstimatedBytes $(if ($tool.Key -eq 'pnpm') { $null } else { $size.Bytes }) `
                -EstimateComplete $size.Complete `
                -Risk $risk -Confidence 'HIGH' -Reversibility 'RegenerableOnly' `
                -RollbackNote 'Not reversible, and not needed: packages are downloaded again on demand.' `
                -Warnings $warnings.ToArray() `
                -QuestionId 'devtools'

            if ($null -ne $recommendation) { $recommendations.Add($recommendation) }
        }

        return $recommendations.ToArray()
    } `
    -TestResult {
        param($Session, $Results)
        $state = $Session.ProviderState['Dev.Node']
        @(foreach ($tool in @($state.Tools)) {
            $size = Get-WaDirectorySize -Path $tool.Path -Config $Session.Config
            [pscustomobject]@{
                Provider = 'Dev.Node'
                Verified = $true
                Message  = ('{0} cache now measures {1}.' -f $tool.Name, (Format-WaBytes $size.Bytes))
            }
        })
    } | Out-Null
