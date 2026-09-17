<#
    Providers/Windows.RecycleBin.ps1 - Recycle Bin, measured but never emptied.

    The Recycle Bin holds files the user deleted and Windows deliberately kept recoverable.
    Emptying it destroys personal data, and "the user already deleted it" is not consent to
    destroy the copy that exists precisely so the deletion can be undone.

    So this provider measures and reports, and the action stays where it belongs: one click
    in Explorer, or Storage Sense with a retention policy the user chose. What the toolkit
    adds is the number, which Explorer does not show without asking.
#>

Register-WaProvider -Name 'Windows.RecycleBin' -Order 65 `
    -Title 'Recycle Bin' `
    -Category 'User data' `
    -Description 'Measures Recycle Bin contents per volume for the current user. Never empties it: the contents are personal files kept deliberately recoverable.' `
    -AdvisoryOnly $true `
    -Reference 'https://learn.microsoft.com/en-us/windows/win32/shell/recycle-bin' `
    -TestAvailable {
        param($Session)
        New-WaProviderAvailability -Available $true
    } `
    -GetInventory {
        param($Session)
        @(New-WaInstalledComponent -Name 'Recycle Bin' -Category 'Windows feature' `
            -DetectionMethod 'Shell' -Note 'Per-volume, per-user deleted item store')
    } `
    -GetAnalysis {
        param($Session, $Inventory)
        $sid = (Get-WaProperty -Object $Session.MachineProfile.Identity -Name 'UserSid')
        if (-not $sid) { return @() }

        $volumes = @($Session.MachineProfile.Storage.Volumes)
        $output = New-Object 'System.Collections.Generic.List[object]'
        $totalBytes = [long]0
        $evidence = New-Object 'System.Collections.Generic.List[object]'

        foreach ($volume in $volumes) {
            $path = Join-Path ($volume.Drive + '\') (Join-Path '$Recycle.Bin' $sid)
            $size = Get-WaDirectorySize -Path $path -Config $Session.Config
            if (-not $size.Exists -or $null -eq $size.Bytes -or [long]$size.Bytes -eq 0) { continue }

            $totalBytes += [long]$size.Bytes
            $evidence.Add((New-WaEvidence -Source $path -Method 'Bounded filesystem enumeration' `
                -Statement ('{0} on volume {1}.' -f (Format-WaBytes $size.Bytes), $volume.Drive) `
                -Value $size.Bytes -Unit 'bytes' -Complete $size.Complete))

            $output.Add((New-WaStorageConsumer -Name ('Recycle Bin on ' + $volume.Drive) -Category 'Recycle Bin' `
                -Path $path -Bytes $size.Bytes -Complete $size.Complete -Provider 'Windows.RecycleBin' `
                -Disposition 'ManualReview' `
                -Note 'Current user only. Other accounts have their own Recycle Bin storage that this session cannot measure.'))
        }

        # Stashed for GetCleanupPlan. Session.Findings is not populated until every
        # provider has finished, so a provider cannot read its own finding back from there.
        $Session.ProviderState['Windows.RecycleBin'] = [pscustomobject]@{
            TotalBytes = $totalBytes
            Evidence   = $evidence.ToArray()
        }

        if ($totalBytes -eq 0) { return $output.ToArray() }

        $output.Add((New-WaFinding -Id 'windows.recyclebin.size' `
            -Title 'Recycle Bin contents' -Category 'User data' -Provider 'Windows.RecycleBin' `
            -Description ('Your Recycle Bin holds {0} across all volumes.' -f (Format-WaBytes $totalBytes)) `
            -Evidence $evidence.ToArray() `
            -CurrentImpact ('{0} recoverable but occupying disk.' -f (Format-WaBytes $totalBytes)) `
            -Confidence 'HIGH' -Disposition 'Advisory' -Bytes $totalBytes `
            -Warnings @('Measured for the current user only. Each account has its own Recycle Bin storage.')))

        return $output.ToArray()
    } `
    -GetCleanupCandidates {
        param($Session, $Inventory)
        @(New-WaCleanupCandidate -Key 'windows.recyclebin' -Provider 'Windows.RecycleBin' `
            -Title 'Recycle Bin' -Category 'User data' -Risk 'MANUAL-ONLY' `
            -Explanation 'Recycle Bin contents are personal files and are never deleted by WinAdvisor.')
    } `
    -GetCleanupPlan {
        param($Session, $Candidates)
        $state = $Session.ProviderState['Windows.RecycleBin']
        if ($null -eq $state) { return @() }
        $bytes = $state.TotalBytes
        if ($null -eq $bytes -or [long]$bytes -eq 0) { return @() }

        @(New-WaAdvisoryRecommendation `
            -Id 'windows.recyclebin.empty' `
            -Title 'Recycle Bin is holding recoverable files' `
            -Category 'User data' `
            -Provider 'Windows.RecycleBin' `
            -Description ('{0} of deleted files are still recoverable. WinAdvisor will not empty the Recycle Bin: those are your files, and they are sitting there specifically so the deletion can be undone.' -f (Format-WaBytes $bytes)) `
            -Evidence $state.Evidence `
            -CurrentImpact ('{0} occupied by recoverable deleted files.' -f (Format-WaBytes $bytes)) `
            -EstimatedBytes $bytes `
            -Confidence 'HIGH' `
            -AffectsPersonalData $true `
            -ManualSteps 'Look through it in Explorer first, then right-click the Recycle Bin and choose Empty. To have Windows do it on a schedule, use Settings > System > Storage > Storage Sense and set a retention period you are comfortable with.' `
            -Warnings @(
                'Emptying it is immediate and permanent; the files do not go anywhere else first.'
                'Check for anything you deleted by accident before emptying.'
            ) `
            -Reference 'https://learn.microsoft.com/en-us/windows/win32/shell/recycle-bin')
    } | Out-Null
