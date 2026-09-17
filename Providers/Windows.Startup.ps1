<#
    Providers/Windows.Startup.ps1 - startup item analysis.

    Reports every discovered startup item and proposes disabling only optional ones, using
    the Explorer StartupApproved mechanism so the original entry survives and the change is
    a single write to reverse.

    Never proposed, regardless of memory cost: security software, endpoint protection,
    device management, accessibility tooling, hardware and driver components, Windows
    itself, cloud synchronisation clients, and anything the classifier could not recognise.
    An unrecognised startup entry is more likely to be load-bearing than junk.
#>

Register-WaProvider -Name 'Windows.Startup' -Order 30 `
    -Title 'Startup programs' `
    -Category 'Startup' `
    -Description 'Enumerates Run keys, startup folders and logon scheduled tasks, classifies each item, and proposes disabling optional entries reversibly.' `
    -Reference 'https://learn.microsoft.com/en-us/windows/win32/setupapi/run-and-runonce-registry-keys' `
    -TestAvailable {
        param($Session)
        New-WaProviderAvailability -Available $true
    } `
    -GetInventory {
        param($Session)
        @(foreach ($item in @($Session.MachineProfile.Startup)) {
            New-WaInstalledComponent -Name $item.Name -Category ('Startup: ' + $item.Category) `
                -Executable $item.Executable -DetectionMethod $item.SourceKind `
                -DetectionConfidence $(if ($item.StateKnown) { 'HIGH' } else { 'MEDIUM' }) `
                -Note $item.Source
        })
    } `
    -GetAnalysis {
        param($Session, $Inventory)
        $startup = @($Session.MachineProfile.Startup)
        if ($startup.Count -eq 0) { return @() }

        $processes = $Session.MachineProfile.Processes
        $memoryByExecutable = @{}
        if ($null -ne $processes) {
            foreach ($group in @($processes.ProcessGroups)) {
                $memoryByExecutable[($group.Name + '.exe')] = $group.PrivateBytes
            }
        }

        $threshold = [long](Get-WaProviderSetting -Config $Session.Config -Provider 'Windows.Startup' -Name 'MinimumMemoryMBToFlag' -Default 150) * 1MB

        $resident = New-Object 'System.Collections.Generic.List[object]'
        foreach ($item in ($startup | Where-Object { $_.Enabled })) {
            $executableName = [IO.Path]::GetFileName([string]$item.Executable)
            if (-not $executableName) { continue }
            if (-not $memoryByExecutable.ContainsKey($executableName)) { continue }
            $bytes = [long]$memoryByExecutable[$executableName]
            if ($bytes -lt $threshold) { continue }
            $resident.Add([pscustomobject]@{ Item = $item; Bytes = $bytes })
        }

        $findings = New-Object 'System.Collections.Generic.List[object]'
        if ($resident.Count -gt 0) {
            $findings.Add((New-WaFinding -Id 'windows.startup.resident' `
                -Title 'Startup programs that stay resident' -Category 'Startup' -Provider 'Windows.Startup' `
                -Description ('{0} startup program(s) are currently running and each holds at least {1} of private memory.' -f $resident.Count, (Format-WaBytes $threshold)) `
                -Evidence @($resident | Sort-Object { $_.Bytes } -Descending | Select-Object -First 10 | ForEach-Object {
                    New-WaEvidence -Source $_.Item.Source -Method 'Startup enumeration correlated with running processes' `
                        -Statement ('{0} ({1}) is using {2}.' -f $_.Item.Name, $_.Item.Category.ToLowerInvariant(), (Format-WaBytes $_.Bytes)) `
                        -Value $_.Bytes -Unit 'bytes'
                }) `
                -CurrentImpact ('{0} of private memory held by startup programs.' -f (Format-WaBytes (($resident | ForEach-Object { $_.Bytes }) | Measure-Object -Sum).Sum)) `
                -Confidence 'HIGH' -Disposition 'Actionable' `
                -Warnings @('Memory held now is not memory that would be freed permanently: if you open the application anyway, it uses the same memory either way.')))
        }

        $protectedCount = @($startup | Where-Object { $_.Protected }).Count
        if ($protectedCount -gt 0) {
            $findings.Add((New-WaFinding -Id 'windows.startup.protected' `
                -Title 'Protected startup items' -Category 'Startup' -Provider 'Windows.Startup' `
                -Description ('{0} startup item(s) are on the never-touch list and will not be proposed for disabling under any circumstances.' -f $protectedCount) `
                -Evidence @($startup | Where-Object { $_.Protected } | Select-Object -First 10 | ForEach-Object {
                    New-WaEvidence -Source $_.Source -Method 'Policy pattern match' -Statement ('{0} ({1})' -f $_.Name, $_.Category) -Measured $true
                }) `
                -Confidence 'HIGH' -Disposition 'Informational'))
        }

        return $findings.ToArray()
    } `
    -GetCleanupCandidates {
        param($Session, $Inventory)
        # Startup changes are registry state rather than file manifests, so candidates are
        # a placeholder and the real work happens in GetCleanupPlan.
        @(New-WaCleanupCandidate -Key 'windows.startup' -Provider 'Windows.Startup' `
            -Title 'Startup items' -Category 'Startup' -Risk 'MANUAL-ONLY' `
            -Explanation 'Startup changes are expressed as reversible state changes, not file deletions.')
    } `
    -GetCleanupPlan {
        param($Session, $Candidates)
        $startup = @($Session.MachineProfile.Startup)
        $processes = $Session.MachineProfile.Processes

        $memoryByExecutable = @{}
        if ($null -ne $processes) {
            foreach ($group in @($processes.ProcessGroups)) {
                $memoryByExecutable[($group.Name + '.exe')] = $group.PrivateBytes
            }
        }

        $recommendations = New-Object 'System.Collections.Generic.List[object]'
        foreach ($item in ($startup | Where-Object { $_.Enabled })) {
            $executableName = [IO.Path]::GetFileName([string]$item.Executable)
            $bytes = $null
            if ($executableName -and $memoryByExecutable.ContainsKey($executableName)) {
                $bytes = [long]$memoryByExecutable[$executableName]
            }

            $recommendation = New-WaStartupDisableRecommendation -Session $Session -Item $item -MemoryBytes $bytes
            if ($null -ne $recommendation) { $recommendations.Add($recommendation) }
        }

        # Unclassified items are surfaced for a human to look at, never acted on.
        $unknown = @($startup | Where-Object { $_.Enabled -and $_.Category -eq 'Unknown' -and -not $_.Protected })
        if ($unknown.Count -gt 0) {
            $recommendations.Add((New-WaAdvisoryRecommendation `
                -Id 'windows.startup.unknown' `
                -Title 'Unrecognised startup items need a human decision' `
                -Category 'Startup' `
                -Provider 'Windows.Startup' `
                -Description ('{0} enabled startup item(s) could not be classified. WinAdvisor does not propose disabling software it cannot identify: an unrecognised entry is as likely to be a VPN client, a fingerprint reader or a licence service as it is to be clutter.' -f $unknown.Count) `
                -Evidence @($unknown | Select-Object -First 15 | ForEach-Object {
                    New-WaEvidence -Source $_.Source -Method 'Registry and startup folder enumeration' `
                        -Statement ('{0} -> {1}' -f $_.Name, $_.Executable) -Measured $true
                }) `
                -CurrentImpact ('{0} item(s) start automatically and were not recognised.' -f $unknown.Count) `
                -Confidence 'LOW' `
                -ManualSteps 'Look each one up by its executable path. Task Manager''s Startup tab disables an item the same way WinAdvisor would, and the change is equally reversible.' `
                -Warnings @('Disabling software you cannot identify is how working machines break.')))
        }

        return $recommendations.ToArray()
    } `
    -TestResult {
        param($Session, $Results)
        $startup = Get-WaStartupInventory -Config $Session.Config
        @([pscustomobject]@{
            Provider = 'Windows.Startup'
            Verified = $true
            Message  = ('{0} of {1} startup item(s) are now enabled (re-read from the registry).' -f @($startup | Where-Object { $_.Enabled }).Count, @($startup).Count)
        })
    } | Out-Null
