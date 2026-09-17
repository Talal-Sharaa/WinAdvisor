<#
    Providers/Containers.Docker.ps1 - Docker storage.

    Docker is often the largest single consumer on a developer machine, and it is also the
    one where careless cleanup destroys real work. The split used here:

        Build cache          safe to remove; rebuilds, costs build time
        Dangling images      safe to remove; untagged and unreferenced
        All unused images    a judgement call; tagged images go too
        Stopped containers   a judgement call; writable layers are destroyed
        Volumes              never removed, and never offered for removal

    Volumes are where containers keep the data they exist to keep: databases, uploads,
    state. There is no reliable way to tell a throwaway volume from the one holding six
    months of local development data, so they are measured, listed and left alone.

    Docker reports sizes with base-1000 units (GB = 10^9), unlike the binary units used
    elsewhere in this toolkit. The parser accounts for the difference.
#>

function ConvertFrom-WaDockerSize {
    <#
    .SYNOPSIS
        Parses a Docker size string such as '21.4GB' or '1.2 GiB' into bytes.

    .DESCRIPTION
        Docker's human-readable sizes are base 1000 (kB, MB, GB, TB) while its binary
        sizes are base 1024 (KiB, MiB, GiB). The suffix decides which, so a figure is never
        inflated by 7% through assuming the wrong base.
    #>
    [CmdletBinding()]
    param([AllowEmptyString()][AllowNull()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $match = [regex]::Match($Text, '(?<value>[\d.]+)\s*(?<unit>[KMGTP]?i?B)')
    if (-not $match.Success) { return $null }

    $value = 0.0
    if (-not [double]::TryParse($match.Groups['value'].Value, [ref]$value)) { return $null }
    $unit = $match.Groups['unit'].Value

    $multiplier = switch -Regex ($unit) {
        '^B$'    { 1 }
        '^KiB$'  { 1024 }
        '^MiB$'  { 1024 * 1024 }
        '^GiB$'  { 1024 * 1024 * 1024 }
        '^TiB$'  { 1024L * 1024 * 1024 * 1024 }
        '^[kK]B$' { 1000 }
        '^MB$'   { 1000 * 1000 }
        '^GB$'   { 1000 * 1000 * 1000 }
        '^TB$'   { 1000L * 1000 * 1000 * 1000 }
        default  { 1 }
    }
    return [long]($value * $multiplier)
}

function Get-WaDockerDiskUsage {
    <#
    .SYNOPSIS
        Runs docker system df and normalises the result.

    .DESCRIPTION
        Returns an object with Available plus a Categories map. Available is $false when
        the CLI is missing or the engine is not reachable, which is a normal state on a
        machine where Docker Desktop simply is not running, not an error.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session)

    $probe = Invoke-WaCatalogProbe -CommandId 'docker.systemdf' -Session $Session
    if (-not $probe.Available) {
        return [pscustomobject]@{ Available = $false; Reason = $probe.Error; Categories = @{} }
    }
    if ($probe.ExitCode -ne 0) {
        # The overwhelmingly common cause is the engine not running.
        return [pscustomobject]@{
            Available = $false
            Reason    = 'The Docker CLI is installed but the engine did not respond. Docker Desktop is probably not running, so its storage cannot be measured.'
            Categories = @{}
        }
    }

    $categories = @{}
    foreach ($line in ([string]$probe.Output -split "`r?`n")) {
        $trimmed = $line.Trim()
        if (-not $trimmed.StartsWith('{')) { continue }

        $row = $null
        try { $row = $trimmed | ConvertFrom-Json -ErrorAction Stop } catch { continue }

        $type = [string](Get-WaProperty -Object $row -Name 'Type')
        if (-not $type) { continue }

        $reclaimableText = [string](Get-WaProperty -Object $row -Name 'Reclaimable')
        $categories[$type] = [pscustomobject]@{
            Type             = $type
            TotalCount       = [string](Get-WaProperty -Object $row -Name 'TotalCount')
            Active           = [string](Get-WaProperty -Object $row -Name 'Active')
            SizeText         = [string](Get-WaProperty -Object $row -Name 'Size')
            SizeBytes        = (ConvertFrom-WaDockerSize -Text ([string](Get-WaProperty -Object $row -Name 'Size')))
            ReclaimableText  = $reclaimableText
            ReclaimableBytes = (ConvertFrom-WaDockerSize -Text $reclaimableText)
        }
    }

    if ($categories.Count -eq 0) {
        return [pscustomobject]@{
            Available = $false
            Reason    = 'docker system df produced output this version of WinAdvisor could not parse. Nothing is proposed when the measurement is not understood.'
            Categories = @{}
        }
    }

    [pscustomobject]@{ Available = $true; Reason = ''; Categories = $categories }
}

function Get-WaDockerCategory {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Usage, [Parameter(Mandatory)][string]$Name)
    if (-not $Usage.Available) { return $null }
    if (-not $Usage.Categories.ContainsKey($Name)) { return $null }
    return $Usage.Categories[$Name]
}

Register-WaProvider -Name 'Containers.Docker' -Order 200 `
    -Title 'Docker storage' `
    -Category 'Containers' `
    -Description 'Measures Docker disk usage with docker system df and proposes build cache and image cleanup through the Docker CLI. Volumes are listed for review and never removed.' `
    -Reference 'https://docs.docker.com/reference/cli/docker/system/df/' `
    -TestAvailable {
        param($Session)
        $path = Resolve-WaCommandPath -Name 'docker'
        if (-not $path) {
            return (New-WaProviderAvailability -Available $false -Reason 'The Docker CLI was not found on PATH.')
        }
        $usage = Get-WaDockerDiskUsage -Session $Session
        $Session.ProviderState['Containers.Docker'] = $usage
        if (-not $usage.Available) {
            return (New-WaProviderAvailability -Available $false -Reason $usage.Reason)
        }
        New-WaProviderAvailability -Available $true
    } `
    -GetInventory {
        param($Session)
        $usage = $Session.ProviderState['Containers.Docker']
        if ($null -eq $usage -or -not $usage.Available) { return @() }

        @(foreach ($key in ($usage.Categories.Keys | Sort-Object)) {
            $category = $usage.Categories[$key]
            New-WaInstalledComponent -Name ('Docker ' + $category.Type) -Category 'Container storage' `
                -DetectionMethod 'docker system df' -DetectionConfidence 'HIGH' `
                -Note ('{0} total, {1} active, {2}, {3} reclaimable' -f $category.TotalCount, $category.Active, $category.SizeText, $category.ReclaimableText)
        })
    } `
    -GetAnalysis {
        param($Session, $Inventory)
        $usage = $Session.ProviderState['Containers.Docker']
        if ($null -eq $usage -or -not $usage.Available) { return @() }

        $output = New-Object 'System.Collections.Generic.List[object]'
        $evidence = New-Object 'System.Collections.Generic.List[object]'
        $totalBytes = [long]0
        $reclaimableBytes = [long]0

        foreach ($key in ($usage.Categories.Keys | Sort-Object)) {
            $category = $usage.Categories[$key]
            if ($null -ne $category.SizeBytes) { $totalBytes += [long]$category.SizeBytes }
            if ($null -ne $category.ReclaimableBytes) { $reclaimableBytes += [long]$category.ReclaimableBytes }

            $evidence.Add((New-WaEvidence -Source 'docker system df' -Method 'Docker CLI' `
                -Statement ('{0}: {1} total across {2} item(s), {3} reclaimable.' -f $category.Type, $category.SizeText, $category.TotalCount, $category.ReclaimableText) `
                -Value $category.SizeBytes -Unit 'bytes' -Reference 'https://docs.docker.com/reference/cli/docker/system/df/'))

            $disposition = if ($category.Type -match '(?i)volume') { 'ManualReview' } else { 'Actionable' }
            $output.Add((New-WaStorageConsumer -Name ('Docker ' + $category.Type) -Category 'Containers' `
                -Bytes $category.SizeBytes -Provider 'Containers.Docker' `
                -Measurement 'docker system df' -Disposition $disposition `
                -Note $(if ($disposition -eq 'ManualReview') { 'Volumes hold container data and are never removed by WinAdvisor.' } else { ('{0} reclaimable according to Docker.' -f $category.ReclaimableText) })))
        }

        $output.Add((New-WaFinding -Id 'containers.docker.usage' `
            -Title 'Docker storage usage' -Category 'Containers' -Provider 'Containers.Docker' `
            -Description ('Docker is using {0} in total, of which Docker itself reports {1} as reclaimable.' -f (Format-WaBytes $totalBytes), (Format-WaBytes $reclaimableBytes)) `
            -Evidence $evidence.ToArray() `
            -CurrentImpact ('{0} total, {1} reclaimable.' -f (Format-WaBytes $totalBytes), (Format-WaBytes $reclaimableBytes)) `
            -Confidence 'HIGH' -Disposition 'Actionable' -Bytes $reclaimableBytes `
            -Warnings @(
                "Docker's reclaimable figure assumes every unused image is disposable. Whether it is depends on whether you can pull or rebuild it again."
                'Volumes are excluded from every cleanup this provider proposes.'
            )))

        return $output.ToArray()
    } `
    -GetCleanupCandidates {
        param($Session, $Inventory)
        $usage = $Session.ProviderState['Containers.Docker']
        if ($null -eq $usage -or -not $usage.Available) { return @() }
        @(New-WaCleanupCandidate -Key 'containers.docker' -Provider 'Containers.Docker' `
            -Title 'Docker storage' -Category 'Containers' -Risk 'MANUAL-ONLY' `
            -Explanation 'Docker cleanup runs through the Docker CLI rather than by deleting files.')
    } `
    -GetCleanupPlan {
        param($Session, $Candidates)
        $usage = $Session.ProviderState['Containers.Docker']
        if ($null -eq $usage -or -not $usage.Available) { return @() }

        $config = $Session.Config
        $recommendations = New-Object 'System.Collections.Generic.List[object]'

        $buildCache = Get-WaDockerCategory -Usage $usage -Name 'Build Cache'
        if ($null -ne $buildCache -and $null -ne $buildCache.ReclaimableBytes -and [long]$buildCache.ReclaimableBytes -gt 0 -and
            (Get-WaProviderSetting -Config $config -Provider 'Containers.Docker' -Name 'AllowBuildCachePrune' -Default $true)) {
            $recommendation = New-WaCommandRecommendation -Session $Session `
                -Id 'containers.docker.builderprune' `
                -CommandId 'docker.builder.prune' `
                -Title 'Remove the Docker build cache' `
                -Category 'Containers' -Provider 'Containers.Docker' `
                -Description 'Clears BuildKit build cache. This is the safest large Docker reclaim: no image, container or volume is affected, and the only cost is that the next build cannot reuse cached layers.' `
                -Evidence @(New-WaEvidence -Source 'docker system df' -Method 'Docker CLI' `
                    -Statement ('Build cache: {0} total, {1} reclaimable.' -f $buildCache.SizeText, $buildCache.ReclaimableText) `
                    -Value $buildCache.ReclaimableBytes -Unit 'bytes') `
                -CurrentImpact ('{0} of build cache.' -f $buildCache.SizeText) `
                -EstimatedBytes $buildCache.ReclaimableBytes `
                -Risk 'MODERATE' -Confidence 'HIGH' -Reversibility 'RegenerableOnly' `
                -RollbackNote 'Not reversible, but fully regenerable: the cache rebuilds as you build.' `
                -Warnings @('Your next build of each image will be slower until the cache refills.') `
                -QuestionId 'docker'
            if ($null -ne $recommendation) { $recommendations.Add($recommendation) }
        }

        $images = Get-WaDockerCategory -Usage $usage -Name 'Images'
        if ($null -ne $images -and (Get-WaProviderSetting -Config $config -Provider 'Containers.Docker' -Name 'AllowImagePrune' -Default $true)) {
            $danglingRecommendation = New-WaCommandRecommendation -Session $Session `
                -Id 'containers.docker.imageprune' `
                -CommandId 'docker.image.prune' `
                -Title 'Remove dangling Docker images' `
                -Category 'Containers' -Provider 'Containers.Docker' `
                -Description 'Removes untagged images that no container references. These are almost always intermediate layers left behind by rebuilds, which is why this is the conservative image cleanup.' `
                -Evidence @(New-WaEvidence -Source 'docker system df' -Method 'Docker CLI' `
                    -Statement ('Images: {0} total across {1}, {2} reclaimable overall.' -f $images.SizeText, $images.TotalCount, $images.ReclaimableText) `
                    -Value $images.ReclaimableBytes -Unit 'bytes') `
                -CurrentImpact ('{0} of images, {1} of which Docker considers reclaimable.' -f $images.SizeText, $images.ReclaimableText) `
                -EstimatedBytes $null `
                -Risk 'LOW' -Confidence 'MEDIUM' -Reversibility 'RegenerableOnly' `
                -RollbackNote 'Not reversible. Dangling layers are rebuilt on the next build.' `
                -Warnings @('Only untagged images are removed. The amount is not predictable in advance, so no figure is claimed; the measured result is reported afterwards.') `
                -QuestionId 'docker'
            if ($null -ne $danglingRecommendation) { $recommendations.Add($danglingRecommendation) }

            if ($null -ne $images.ReclaimableBytes -and [long]$images.ReclaimableBytes -gt 1GB) {
                $allRecommendation = New-WaCommandRecommendation -Session $Session `
                    -Id 'containers.docker.imageprune.all' `
                    -CommandId 'docker.image.prune.all' `
                    -Title 'Remove every Docker image not used by a container' `
                    -Category 'Containers' -Provider 'Containers.Docker' `
                    -Description 'Removes tagged images too, keeping only those an existing container uses. Recovers considerably more than the dangling-only cleanup, and takes images you may want back.' `
                    -Evidence @(New-WaEvidence -Source 'docker system df' -Method 'Docker CLI' `
                        -Statement ('Docker reports {0} reclaimable across images.' -f $images.ReclaimableText) `
                        -Value $images.ReclaimableBytes -Unit 'bytes') `
                    -CurrentImpact ('{0} of images, {1} reclaimable.' -f $images.SizeText, $images.ReclaimableText) `
                    -EstimatedBytes $images.ReclaimableBytes `
                    -Risk 'MODERATE' -Confidence 'HIGH' -Reversibility 'RegenerableOnly' `
                    -RollbackNote 'Not reversible. Images must be pulled or rebuilt again.' `
                    -Warnings @(
                        'Anything you cannot pull from a registry you still have access to must be rebuilt from source.'
                        'Locally built images with no registry copy are the ones to think about here.'
                    ) `
                    -QuestionId 'docker'
                if ($null -ne $allRecommendation) { $recommendations.Add($allRecommendation) }
            }
        }

        $containers = Get-WaDockerCategory -Usage $usage -Name 'Containers'
        if ($null -ne $containers -and $null -ne $containers.ReclaimableBytes -and [long]$containers.ReclaimableBytes -gt 0) {
            $containerRecommendation = New-WaCommandRecommendation -Session $Session `
                -Id 'containers.docker.containerprune' `
                -CommandId 'docker.container.prune' `
                -Title 'Remove stopped Docker containers' `
                -Category 'Containers' -Provider 'Containers.Docker' `
                -Description 'Removes containers that are not running, along with their writable layers.' `
                -Evidence @(New-WaEvidence -Source 'docker system df' -Method 'Docker CLI' `
                    -Statement ('Containers: {0} total, {1} active, {2} reclaimable.' -f $containers.TotalCount, $containers.Active, $containers.ReclaimableText) `
                    -Value $containers.ReclaimableBytes -Unit 'bytes') `
                -CurrentImpact ('{0} held by stopped containers.' -f $containers.ReclaimableText) `
                -EstimatedBytes $containers.ReclaimableBytes `
                -Risk 'MODERATE' -Confidence 'HIGH' -Reversibility 'Irreversible' `
                -RollbackNote 'Not reversible. A removed container cannot be restarted; it must be recreated from its image.' `
                -Warnings @(
                    'Anything a container wrote outside a mounted volume is in its writable layer and is destroyed with it.'
                    'Named volumes those containers used are not touched.'
                    'Check docker ps -a for a stopped container you meant to go back to.'
                ) `
                -QuestionId 'docker'
            if ($null -ne $containerRecommendation) { $recommendations.Add($containerRecommendation) }
        }

        $volumes = Get-WaDockerCategory -Usage $usage -Name 'Local Volumes'
        if ($null -ne $volumes -and $null -ne $volumes.SizeBytes -and [long]$volumes.SizeBytes -gt 0) {
            $recommendations.Add((New-WaAdvisoryRecommendation `
                -Id 'containers.docker.volumes' `
                -Title 'Docker volumes need a human decision' `
                -Category 'Containers' -Provider 'Containers.Docker' `
                -Description ('Docker volumes hold {0}, of which Docker reports {1} as unused. WinAdvisor never removes a volume: volumes are where containers keep the data they were created to keep, and there is no reliable way to tell a throwaway volume from the one holding your local database.' -f $volumes.SizeText, $volumes.ReclaimableText) `
                -Evidence @(New-WaEvidence -Source 'docker system df' -Method 'Docker CLI' `
                    -Statement ('Local volumes: {0} across {1}, {2} unused.' -f $volumes.SizeText, $volumes.TotalCount, $volumes.ReclaimableText) `
                    -Value $volumes.SizeBytes -Unit 'bytes') `
                -CurrentImpact ('{0} in Docker volumes.' -f $volumes.SizeText) `
                -EstimatedBytes $volumes.ReclaimableBytes `
                -Confidence 'HIGH' `
                -ManualSteps 'List them with docker volume ls and inspect anything unfamiliar with docker volume inspect <name>. Remove individually with docker volume rm <name> once you are sure. docker volume prune removes every unused volume at once and is the command people regret.' `
                -Warnings @(
                    '"Unused" here means no container currently references it, not that the data is unwanted. A stopped-and-removed container leaves its database volume looking unused.'
                    'Volume removal is immediate and permanent.'
                ) `
                -Reference 'https://docs.docker.com/reference/cli/docker/volume/prune/'))
        }

        return $recommendations.ToArray()
    } `
    -TestResult {
        param($Session, $Results)
        # Re-measure with Docker itself rather than inferring from disk free space.
        $after = Get-WaDockerDiskUsage -Session $Session
        if (-not $after.Available) {
            return @([pscustomobject]@{ Provider = 'Containers.Docker'; Verified = $false; Message = $after.Reason })
        }
        @(foreach ($key in ($after.Categories.Keys | Sort-Object)) {
            $category = $after.Categories[$key]
            [pscustomobject]@{
                Provider = 'Containers.Docker'
                Verified = $true
                Message  = ('{0} now {1} total with {2} reclaimable (re-measured with docker system df).' -f $category.Type, $category.SizeText, $category.ReclaimableText)
            }
        })
    } | Out-Null
