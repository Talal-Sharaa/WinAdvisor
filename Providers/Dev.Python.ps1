<#
    Providers/Dev.Python.ps1 - pip and uv caches.

    Both tools are asked where their cache lives and cleaned with their own documented
    command.

    Virtual environments are never touched. A .venv is not a cache: it is the environment a
    project runs in, it may contain packages no longer available at the versions pinned,
    and recreating one is not always possible offline. The policy path-segment list blocks
    .venv and site-packages from any file manifest regardless of what a provider asks for.
#>

function Get-WaPythonCacheTool {
    <#
    .SYNOPSIS
        The Python package managers present here, with their cache paths.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session)

    $config = $Session.Config
    $tools = New-Object 'System.Collections.Generic.List[object]'

    $readPath = {
        param([string]$CommandId)
        $probe = Invoke-WaCatalogProbe -CommandId $CommandId -Session $Session
        if (-not $probe.Available -or $probe.ExitCode -ne 0) { return $null }
        $line = @(([string]$probe.Output) -split "`r?`n" | Where-Object { $_.Trim() -match '^[A-Za-z]:\\' }) | Select-Object -First 1
        if (-not $line) { return $null }
        return $line.Trim()
    }

    if ((Get-WaProviderSetting -Config $config -Provider 'Dev.Python' -Name 'IncludePip' -Default $true) -and (Resolve-WaCommandPath -Name 'pip')) {
        $path = & $readPath 'pip.cache.dir'
        if ($path) {
            $tools.Add([pscustomobject]@{
                Key = 'pip'; Name = 'pip'; Path = $path; CommandId = 'pip.cache.purge'
                Description = 'The pip cache of built wheels and HTTP responses. Installed environments do not depend on it.'
                Consequence = 'Wheels are rebuilt or re-downloaded on the next install. Existing virtual environments keep working exactly as they are.'
            })
        }
    }

    if ((Get-WaProviderSetting -Config $config -Provider 'Dev.Python' -Name 'IncludeUv' -Default $true) -and (Resolve-WaCommandPath -Name 'uv')) {
        $path = & $readPath 'uv.cache.dir'
        if ($path) {
            $tools.Add([pscustomobject]@{
                Key = 'uv'; Name = 'uv'; Path = $path; CommandId = 'uv.cache.prune'
                Description = 'The uv cache. Pruning removes entries uv considers unused and keeps what current environments rely on.'
                Consequence = 'Unused cached distributions are removed. Current environments keep working.'
            })
        }
    }

    return $tools.ToArray()
}

Register-WaProvider -Name 'Dev.Python' -Order 320 `
    -Title 'Python package caches' `
    -Category 'Developer tooling' `
    -Description 'pip and uv caches, cleaned with their own documented commands. Virtual environments and site-packages are never touched.' `
    -Reference 'https://pip.pypa.io/en/stable/cli/pip_cache/' `
    -TestAvailable {
        param($Session)
        $tools = @(Get-WaPythonCacheTool -Session $Session)
        $Session.ProviderState['Dev.Python'] = $tools
        if ($tools.Count -eq 0) {
            return (New-WaProviderAvailability -Available $false -Reason 'Neither pip nor uv was found on PATH.')
        }
        New-WaProviderAvailability -Available $true -Reason (('Found: ' + (($tools | ForEach-Object { $_.Name }) -join ', ')))
    } `
    -GetInventory {
        param($Session)
        @(foreach ($tool in @($Session.ProviderState['Dev.Python'])) {
            $size = Get-WaDirectorySize -Path $tool.Path -Config $Session.Config
            New-WaInstalledComponent -Name ($tool.Name + ' cache') -Category 'Package cache' `
                -InstallPath $tool.Path -DetectionMethod 'Tool-reported cache path' -DetectionConfidence 'HIGH' `
                -Note ('{0} measured' -f (Format-WaBytes $size.Bytes))
        })
    } `
    -GetAnalysis {
        param($Session, $Inventory)
        $tools = @($Session.ProviderState['Dev.Python'])
        if ($tools.Count -eq 0) { return @() }

        $output = New-Object 'System.Collections.Generic.List[object]'
        $evidence = New-Object 'System.Collections.Generic.List[object]'
        $totalBytes = [long]0

        foreach ($tool in $tools) {
            $size = Get-WaDirectorySize -Path $tool.Path -Config $Session.Config
            if ($null -eq $size.Bytes) { continue }
            $totalBytes += [long]$size.Bytes
            $evidence.Add((New-WaEvidence -Source $tool.Path -Method 'Bounded filesystem enumeration' `
                -Statement ('{0}: {1}.' -f $tool.Name, (Format-WaBytes $size.Bytes)) -Value $size.Bytes -Unit 'bytes' -Complete $size.Complete))
            $output.Add((New-WaStorageConsumer -Name ($tool.Name + ' cache') -Category 'Package-manager caches' `
                -Path $tool.Path -Bytes $size.Bytes -Complete $size.Complete -Provider 'Dev.Python' -Disposition 'Actionable' `
                -Note $tool.Description))
        }

        if ($totalBytes -eq 0) { return $output.ToArray() }

        $output.Add((New-WaFinding -Id 'dev.python.caches' `
            -Title 'Python package caches' -Category 'Developer tooling' -Provider 'Dev.Python' `
            -Description ('Python package caches hold {0}. These are downloaded or locally built artefacts that can be produced again.' -f (Format-WaBytes $totalBytes)) `
            -Evidence $evidence.ToArray() `
            -CurrentImpact ('{0} of cached wheels and package data.' -f (Format-WaBytes $totalBytes)) `
            -Confidence 'HIGH' -Disposition 'Actionable' -Bytes $totalBytes `
            -Warnings @(
                'Virtual environments are not included and are never touched: a .venv is the environment a project runs in, not a cache.'
                'Rebuilding a wheel that needs a compiler is slower than downloading one. Clearing the pip cache on a machine that builds native extensions has a real cost.'
            )))

        return $output.ToArray()
    } `
    -GetCleanupCandidates {
        param($Session, $Inventory)
        @(New-WaCleanupCandidate -Key 'dev.python' -Provider 'Dev.Python' `
            -Title 'Python package caches' -Category 'Developer tooling' -Risk 'MANUAL-ONLY' `
            -Explanation 'Python caches are cleared with their own commands.')
    } `
    -GetCleanupPlan {
        param($Session, $Candidates)
        $recommendations = New-Object 'System.Collections.Generic.List[object]'

        foreach ($tool in @($Session.ProviderState['Dev.Python'])) {
            $size = Get-WaDirectorySize -Path $tool.Path -Config $Session.Config
            if ($null -eq $size.Bytes -or [long]$size.Bytes -lt 10MB) { continue }

            $recommendation = New-WaCommandRecommendation -Session $Session `
                -Id ('dev.python.clear.' + $tool.Key) `
                -CommandId $tool.CommandId `
                -Title ('Clear the {0} cache' -f $tool.Name) `
                -Category 'Developer tooling' -Provider 'Dev.Python' `
                -Description $tool.Description `
                -Evidence @(
                    New-WaEvidence -Source $tool.Path -Method 'Bounded filesystem enumeration' `
                        -Statement ('{0} currently occupied.' -f (Format-WaBytes $size.Bytes)) -Value $size.Bytes -Unit 'bytes' -Complete $size.Complete
                    New-WaEvidence -Source $tool.Name -Method 'Tool-reported cache path' `
                        -Statement ('{0} reports its cache at {1}.' -f $tool.Name, $tool.Path) -Measured $true
                ) `
                -CurrentImpact ('{0} in the {1} cache.' -f (Format-WaBytes $size.Bytes), $tool.Name) `
                -EstimatedBytes $(if ($tool.Key -eq 'uv') { $null } else { $size.Bytes }) `
                -EstimateComplete $size.Complete `
                -Risk 'LOW' -Confidence 'HIGH' -Reversibility 'RegenerableOnly' `
                -RollbackNote 'Not reversible, and not needed: cached artefacts are rebuilt or re-downloaded on demand.' `
                -Warnings @(
                    'Installed virtual environments are unaffected.'
                    $(if ($tool.Key -eq 'uv') { 'uv prune removes only what it considers unused, so the recovered amount is not predictable in advance and no figure is claimed.' } else { 'Packages needing a native build will be recompiled rather than installed from a cached wheel.' })
                ) `
                -QuestionId 'devtools'

            if ($null -ne $recommendation) { $recommendations.Add($recommendation) }
        }

        return $recommendations.ToArray()
    } `
    -TestResult {
        param($Session, $Results)
        @(foreach ($tool in @($Session.ProviderState['Dev.Python'])) {
            $size = Get-WaDirectorySize -Path $tool.Path -Config $Session.Config
            [pscustomobject]@{
                Provider = 'Dev.Python'
                Verified = $true
                Message  = ('{0} cache now measures {1}.' -f $tool.Name, (Format-WaBytes $size.Bytes))
            }
        })
    } | Out-Null
