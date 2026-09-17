<#
    Core/Analysis.ps1 - analysis orchestration.

    Runs every relevant provider through the contract, collects findings, cleanup
    candidates and recommendations, and adds the core analyses that are derived from the
    machine profile rather than from any one provider (storage attribution, memory
    consumers, startup posture).

    Analysis never changes the machine. It runs in ViewSpecs-adjacent modes, in DryRun and
    as the first phase of Cleanup, and it produces exactly the same result in all of them.
#>

function Get-WaAnalysis {
    <#
    .SYNOPSIS
        Runs the full read-only analysis and attaches the result to the session.

    .PARAMETER IncludeComponentStore
        Permit DISM component-store measurement during discovery.

    .EXAMPLE
        $session = New-WaSession -Mode Analyze
        $analysis = Get-WaAnalysis -Session $session
        $analysis.Recommendations | Format-Table Title, Risk, Confidence, EstimatedBytes
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Session,
        [switch]$IncludeComponentStore
    )

    if ($null -eq $Session.MachineProfile) {
        [void](Get-WaMachineProfile -Session $Session -IncludeComponentStore:$IncludeComponentStore)
    }

    $machineProfile = $Session.MachineProfile
    $config = $Session.Config

    Write-WaLog -Session $Session -Level 'Info' -Category 'Analysis' -Message 'Starting analysis.'

    # Memoise directory scans for the analysis phase only. Providers legitimately ask about
    # the same root more than once (a size in GetAnalysis, a manifest in
    # GetCleanupCandidates), and rescanning a multi-gigabyte cache for the second answer is
    # wasted work. The cache is switched off again before the before/after measurement,
    # which must always read the real filesystem.
    Enable-WaInventoryCache

    try {

    $providerSet = Get-WaActiveProvider -Session $Session
    $findings        = New-Object 'System.Collections.Generic.List[object]'
    $recommendations = New-Object 'System.Collections.Generic.List[object]'
    $candidates      = New-Object 'System.Collections.Generic.List[object]'
    $consumers       = New-Object 'System.Collections.Generic.List[object]'
    $providerStatus  = New-Object 'System.Collections.Generic.List[object]'

    $index = 0
    foreach ($provider in $providerSet.Active) {
        $index++
        Write-Progress -Activity 'WinAdvisor analysis' -Status $provider.Title `
            -PercentComplete ([Math]::Min(99, ($index / [Math]::Max(1, @($providerSet.Active).Count)) * 100))

        $status = [ordered]@{
            Name            = $provider.Name
            Title           = $provider.Title
            Category        = $provider.Category
            Available       = $true
            Degraded        = $false
            Messages        = @()
            Findings        = 0
            Candidates      = 0
            Recommendations = 0
        }
        $messages = New-Object 'System.Collections.Generic.List[string]'

        $inventoryResult = Invoke-WaProviderStage -Session $Session -Provider $provider -Stage 'GetInventory' -Arguments @($Session)
        if (-not $inventoryResult.Succeeded) {
            $status.Degraded = $true
            $messages.Add("Inventory failed: $($inventoryResult.Error)")
        }
        $inventory = @($inventoryResult.Output)

        $analysisResult = Invoke-WaProviderStage -Session $Session -Provider $provider -Stage 'GetAnalysis' -Arguments @($Session, $inventory)
        if (-not $analysisResult.Succeeded) {
            $status.Degraded = $true
            $messages.Add("Analysis failed: $($analysisResult.Error)")
        }
        foreach ($item in @($analysisResult.Output)) {
            if ($null -eq $item) { continue }
            # Providers may emit either findings or storage consumers from GetAnalysis.
            if ((Get-WaProperty -Object $item -Name 'PSTypeName') -eq 'WinAdvisor.StorageConsumer' -or
                ($item.PSObject.TypeNames -contains 'WinAdvisor.StorageConsumer')) {
                $consumers.Add($item)
            } else {
                $findings.Add($item)
                $status.Findings++
            }
        }

        if ($null -ne $provider.GetCleanupCandidates) {
            $candidateResult = Invoke-WaProviderStage -Session $Session -Provider $provider -Stage 'GetCleanupCandidates' -Arguments @($Session, $inventory)
            if (-not $candidateResult.Succeeded) {
                $status.Degraded = $true
                $messages.Add("Candidate discovery failed: $($candidateResult.Error)")
            }
            $providerCandidates = @($candidateResult.Output | Where-Object { $null -ne $_ })
            foreach ($candidate in $providerCandidates) { $candidates.Add($candidate) }
            $status.Candidates = $providerCandidates.Count

            if ($providerCandidates.Count -gt 0 -and $null -ne $provider.GetCleanupPlan) {
                $planResult = Invoke-WaProviderStage -Session $Session -Provider $provider -Stage 'GetCleanupPlan' -Arguments @($Session, $providerCandidates)
                if (-not $planResult.Succeeded) {
                    $status.Degraded = $true
                    $messages.Add("Plan generation failed: $($planResult.Error)")
                }

                foreach ($recommendation in @($planResult.Output | Where-Object { $null -ne $_ })) {
                    # A provider that produces a policy-violating recommendation loses that
                    # recommendation, not the whole run. The violation is logged loudly.
                    try {
                        [void](Assert-WaRecommendationPolicy -Recommendation $recommendation -Policy $config.Policy)
                    } catch {
                        $status.Degraded = $true
                        $messages.Add("Recommendation '$($recommendation.Id)' rejected by policy: $($_.Exception.Message)")
                        Write-WaLog -Session $Session -Level 'Error' -Category 'Policy' -Message (
                            "Provider '{0}' produced a recommendation that violates policy and it was discarded. {1}" -f $provider.Name, $_.Exception.Message
                        )
                        continue
                    }
                    $recommendations.Add($recommendation)
                    $status.Recommendations++
                }
            }
        }

        $status.Messages = $messages.ToArray()
        $providerStatus.Add([pscustomobject]$status)
    }
    Write-Progress -Activity 'WinAdvisor analysis' -Completed

    foreach ($inactive in $providerSet.Inactive) {
        $providerStatus.Add([pscustomobject][ordered]@{
            Name = $inactive.Name; Title = ''; Category = ''
            Available = $false; Degraded = $false
            Messages = @($inactive.Reason)
            Findings = 0; Candidates = 0; Recommendations = 0
        })
    }

    # Core analyses derived from the profile rather than from a single provider.
    foreach ($finding in (Get-WaMemoryAnalysis -Session $Session)) { $findings.Add($finding) }
    foreach ($finding in (Get-WaStartupPostureAnalysis -Session $Session)) { $findings.Add($finding) }
    foreach ($consumer in (Get-WaVolumeStorageConsumer -Session $Session)) { $consumers.Add($consumer) }

    $orderedRecommendations = @(Sort-WaRecommendation -Recommendation $recommendations.ToArray())

    $Session.Findings = $findings.ToArray()
    $Session.Recommendations = $orderedRecommendations

    $analysis = [pscustomobject][ordered]@{
        PSTypeName       = 'WinAdvisor.Analysis'
        SessionId        = $Session.Id
        CapturedUtc      = (Get-WaUtcTimestamp)
        MachineProfile   = $machineProfile
        Findings         = $findings.ToArray()
        Recommendations  = $orderedRecommendations
        Candidates       = $candidates.ToArray()
        StorageConsumers = @($consumers | Sort-Object { if ($null -eq $_.Bytes) { -1 } else { [long]$_.Bytes } } -Descending)
        ProviderStatus   = $providerStatus.ToArray()
        Summary          = (Get-WaAnalysisSummary -Recommendation $orderedRecommendations -Finding $findings.ToArray())
    }

    Write-WaLog -Session $Session -Level 'Info' -Category 'Analysis' -Message (
        'Analysis complete: {0} finding(s), {1} recommendation(s) from {2} active provider(s).' -f
            $findings.ToArray().Count, $orderedRecommendations.Count, @($providerSet.Active).Count
    )

    $Session.Questions = @(Get-WaQuestion -Session $Session -Analysis $analysis)
    return $analysis

    } finally {
        Disable-WaInventoryCache
    }
}

function Sort-WaRecommendation {
    <#
    .SYNOPSIS
        Orders recommendations for presentation: safest and best-evidenced first.

    .DESCRIPTION
        Ascending risk, then descending confidence, then descending estimated benefit.
        The result is that a reviewer reads the obviously-safe items first and reaches the
        items that need real thought last, when they have context.
    #>
    [CmdletBinding()]
    param([object[]]$Recommendation = @())

    @($Recommendation | Sort-Object `
        @{ Expression = { Get-WaRiskRank -Risk $_.Risk }; Ascending = $true },
        @{ Expression = { Get-WaConfidenceRank -Confidence $_.Confidence }; Ascending = $false },
        @{ Expression = { if ($null -eq $_.EstimatedBytes) { 0 } else { [long]$_.EstimatedBytes } }; Ascending = $false },
        @{ Expression = { $_.Title }; Ascending = $true })
}

function Get-WaAnalysisSummary {
    <#
    .SYNOPSIS
        Headline numbers, separated by how defensible they are.

    .DESCRIPTION
        Three separate totals, never combined into one "you can free N GB" claim:
          SafeBytes        SAFE and LOW risk with HIGH confidence and a complete measurement
          ReviewBytes      everything else that is executable and needs a decision
          AdvisoryBytes    MANUAL-ONLY, reported for context and never executed
    #>
    [CmdletBinding()]
    param([object[]]$Recommendation = @(), [object[]]$Finding = @())

    $safe = [long]0; $review = [long]0; $advisory = [long]0
    $incomplete = $false

    foreach ($item in $Recommendation) {
        $bytes = $item.EstimatedBytes
        if ($null -eq $bytes) { continue }
        $bytes = [long]$bytes
        if (-not $item.EstimateComplete) { $incomplete = $true }

        if ($item.Risk -eq 'MANUAL-ONLY') {
            $advisory += $bytes
        } elseif ((Get-WaRiskRank -Risk $item.Risk) -le (Get-WaRiskRank -Risk 'LOW') -and
                  $item.Confidence -eq 'HIGH' -and $item.EstimateComplete) {
            $safe += $bytes
        } else {
            $review += $bytes
        }
    }

    [pscustomobject][ordered]@{
        FindingCount           = @($Finding).Count
        RecommendationCount    = @($Recommendation).Count
        ExecutableCount        = @($Recommendation | Where-Object { Test-WaExecutableRecommendation -Recommendation $_ }).Count
        ManualOnlyCount        = @($Recommendation | Where-Object { $_.Risk -eq 'MANUAL-ONLY' }).Count
        AdminRequiredCount     = @($Recommendation | Where-Object { $_.AdminRequired }).Count
        RestartRequiredCount   = @($Recommendation | Where-Object { $_.RestartRequired -ne 'None' }).Count
        SafeBytes              = $safe
        ReviewBytes            = $review
        AdvisoryBytes          = $advisory
        EstimatesIncomplete    = $incomplete
        ByRisk                 = @(
            foreach ($level in (Get-WaRiskLevels)) {
                $matching = @($Recommendation | Where-Object { $_.Risk -eq $level })
                if ($matching.Count -eq 0) { continue }
                [pscustomobject]@{
                    Risk  = $level
                    Count = $matching.Count
                    Bytes = ([long](($matching | ForEach-Object { if ($null -eq $_.EstimatedBytes) { 0 } else { [long]$_.EstimatedBytes } }) | Measure-Object -Sum).Sum)
                }
            }
        )
        Note = 'Safe, review and advisory totals are kept apart on purpose. Only the safe total is both well-evidenced and completely measured; adding them together would overstate what can actually be recovered.'
    }
}

function Get-WaMemoryAnalysis {
    <#
    .SYNOPSIS
        Diagnoses persistent memory consumers. Never proposes freeing memory.

    .DESCRIPTION
        There is no RAM cleaning here, and there never will be. Trimming working sets or
        purging the standby list makes Task Manager show a larger free number and makes the
        machine slower, because the data Windows cached has to be read from disk again.

        What this does instead is identify software that is resident all the time, what it
        costs, and whether it starts automatically, so the user can decide whether they
        want it running.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session)

    $machineProfile = $Session.MachineProfile
    $memory = $machineProfile.Memory
    $processes = $machineProfile.Processes
    if ($null -eq $processes) { return @() }

    $findings = New-Object 'System.Collections.Generic.List[object]'
    $threshold = [long](Get-WaProviderSetting -Config $Session.Config -Provider 'Windows.Startup' -Name 'MinimumMemoryMBToFlag' -Default 150) * 1MB

    $heavy = @($processes.ProcessGroups | Where-Object { $_.PrivateBytes -ge $threshold })

    if ($heavy.Count -gt 0) {
        $evidence = @(
            foreach ($group in ($heavy | Select-Object -First 12)) {
                New-WaEvidence -Source 'Get-Process' -Method 'Private bytes summed per executable' `
                    -Statement ('{0}: {1} across {2} process(es){3}{4}' -f
                        $group.Name,
                        (Format-WaBytes $group.PrivateBytes),
                        $group.ProcessCount,
                        $(if ($group.StartsAtLogon) { ', starts at logon' } else { '' }),
                        $(if ($group.Category -ne 'Unknown') { ", $($group.Category.ToLowerInvariant())" } else { '' })) `
                    -Value $group.PrivateBytes -Unit 'bytes'
            }
        )

        $findings.Add((New-WaFinding `
            -Id 'core.memory.consumers' `
            -Title 'Persistent memory consumers' `
            -Category 'Memory' `
            -Provider 'Core' `
            -Description ('{0} application(s) each hold at least {1} of private memory. Reducing memory use means running less software, not clearing caches.' -f $heavy.Count, (Format-WaBytes $threshold)) `
            -Evidence $evidence `
            -CurrentImpact ('Top consumers account for {0} of private memory in total.' -f (Format-WaBytes (($heavy | ForEach-Object { $_.PrivateBytes } | Measure-Object -Sum).Sum))) `
            -Confidence 'HIGH' `
            -Disposition 'Advisory' `
            -Warnings @('Memory figures are a point-in-time sample and vary with workload. No process is terminated by this toolkit.')))
    }

    $commitPercent = Get-WaProperty -Object $memory -Name 'CommitPercent'
    if ($null -ne $commitPercent -and [double]$commitPercent -ge 85) {
        $findings.Add((New-WaFinding `
            -Id 'core.memory.commit' `
            -Title 'Commit charge is high' `
            -Category 'Memory' `
            -Provider 'Core' `
            -Description 'Committed memory is close to the commit limit. This is the measurement that indicates genuine memory pressure, unlike a low "free memory" figure.' `
            -Evidence @(
                New-WaEvidence -Source 'Win32_PerfRawData_PerfOS_Memory' -Method 'CommittedBytes against CommitLimit' `
                    -Statement ('{0} committed of a {1} limit ({2}%).' -f (Format-WaBytes $memory.CommittedBytes), (Format-WaBytes $memory.CommitLimitBytes), $commitPercent) `
                    -Value $commitPercent -Unit 'percent'
            ) `
            -CurrentImpact 'Allocations may start failing, and the system will page more aggressively.' `
            -Confidence 'HIGH' `
            -Disposition 'Advisory' `
            -Warnings @('The supported responses are to run less software concurrently, add physical memory, or leave the pagefile system-managed so the commit limit can grow. Disabling the pagefile lowers the commit limit and makes this worse.')))
    }

    return $findings.ToArray()
}

function Get-WaStartupPostureAnalysis {
    <#
    .SYNOPSIS
        Summarises the startup picture as a finding.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session)

    $startup = @($Session.MachineProfile.Startup)
    if ($startup.Count -eq 0) { return @() }

    $enabled = @($startup | Where-Object { $_.Enabled })
    $byCategory = $enabled | Group-Object Category | Sort-Object Count -Descending

    $evidence = @(
        foreach ($group in $byCategory) {
            New-WaEvidence -Source 'Run keys, startup folders and logon scheduled tasks' -Method 'Registry and Task Scheduler enumeration' `
                -Statement ('{0}: {1} enabled item(s)' -f $group.Name, $group.Count) -Value $group.Count -Unit 'items'
        }
    )

    @(New-WaFinding `
        -Id 'core.startup.posture' `
        -Title 'Startup inventory' `
        -Category 'Startup' `
        -Provider 'Core' `
        -Description ('{0} of {1} discovered startup item(s) are enabled.' -f $enabled.Count, $startup.Count) `
        -Evidence $evidence `
        -CurrentImpact 'Each enabled item extends sign-in and may stay resident afterwards.' `
        -Confidence 'HIGH' `
        -Disposition 'Advisory' `
        -Warnings @('Security, device-management, accessibility and hardware items are never proposed for disabling, and unclassified items are left alone.'))
}

function Get-WaVolumeStorageConsumer {
    <#
    .SYNOPSIS
        Per-volume used and free space as storage consumers, for the storage view.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session)

    $storage = $Session.MachineProfile.Storage
    if ($null -eq $storage) { return @() }

    @(foreach ($volume in $storage.Volumes) {
        New-WaStorageConsumer `
            -Name ('Volume {0} ({1})' -f $volume.Drive, $(if ($volume.VolumeName) { $volume.VolumeName } else { 'unnamed' })) `
            -Category 'Volume' `
            -Path ($volume.Drive + '\') `
            -Bytes $volume.UsedBytes `
            -Complete $true `
            -Provider 'Core' `
            -Measurement 'Win32_LogicalDisk size minus free space' `
            -Disposition 'Informational' `
            -Note ('{0} free of {1} ({2}% used).' -f (Format-WaBytes $volume.FreeBytes), (Format-WaBytes $volume.SizeBytes), $volume.UsedPercent)
    })
}

function Get-WaStorageAnalysis {
    <#
    .SYNOPSIS
        Storage attribution: where the space went, by category.

    .DESCRIPTION
        Aggregates every measured storage consumer into categories and reports what is left
        unattributed. The unattributed figure is shown deliberately: a storage report that
        silently accounts for 40% of a disk and stays quiet about the rest is misleading.

    .PARAMETER Deep
        Include a recursive scan of the directories named in configuration or on the
        command line. Without it, only targeted known locations are measured.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)]$Analysis,
        [switch]$Deep
    )

    $config = $Session.Config
    $consumers = @($Analysis.StorageConsumers | Where-Object { $_.Category -ne 'Volume' })

    $byCategory = @(
        $consumers | Where-Object { $null -ne $_.Bytes } | Group-Object Category | ForEach-Object {
            $bytes = [long](($_.Group | ForEach-Object { [long]$_.Bytes }) | Measure-Object -Sum).Sum
            [pscustomobject][ordered]@{
                Category   = $_.Name
                Bytes      = $bytes
                Items      = $_.Count
                Complete   = (@($_.Group | Where-Object { -not $_.Complete }).Count -eq 0)
                Actionable = (@($_.Group | Where-Object { $_.Disposition -eq 'Actionable' }).Count -gt 0)
            }
        } | Sort-Object Bytes -Descending
    )

    $volumes = @($Analysis.MachineProfile.Storage.Volumes)
    $totalUsed = [long](($volumes | Where-Object { $null -ne $_.UsedBytes } | ForEach-Object { [long]$_.UsedBytes }) | Measure-Object -Sum).Sum
    $attributed = [long](($byCategory | ForEach-Object { $_.Bytes }) | Measure-Object -Sum).Sum

    $largeFiles = $null
    if ($Deep -and @($config.DeepScanPaths).Count -gt 0) {
        Write-WaLog -Session $Session -Level 'Info' -Category 'Storage' -Message (
            'Deep scan requested for {0} explicitly named path(s).' -f @($config.DeepScanPaths).Count
        )
        $largeFiles = Get-WaLargeFile -Path $config.DeepScanPaths -Config $config -Recurse
    }

    [pscustomobject][ordered]@{
        PSTypeName       = 'WinAdvisor.StorageAnalysis'
        Volumes          = $volumes
        Categories       = $byCategory
        Consumers        = @($consumers | Sort-Object { if ($null -eq $_.Bytes) { -1 } else { [long]$_.Bytes } } -Descending | Select-Object -First $config.TopStorageConsumerCount)
        TotalUsedBytes   = $totalUsed
        AttributedBytes  = $attributed
        # [long] on both arguments: an untyped 0 selects the Int32 overload of Math::Max,
        # which then cannot hold a byte count from a modern disk.
        UnattributedBytes = [Math]::Max([long]0, [long]($totalUsed - $attributed))
        AttributedPercent = (Get-WaPercentage -Part $attributed -Whole $totalUsed)
        DeepScan         = $largeFiles
        DeepScanRequested = [bool]$Deep
        Note = 'Attribution covers the locations the enabled providers know how to measure. The unattributed remainder is applications, user data and Windows itself, and is reported rather than hidden. Use the deep scan on a specific directory to look into it further.'
    }
}
