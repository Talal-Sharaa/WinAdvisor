<#
    Providers/Windows.RestorePoints.ps1 - System Protection, reported only.

    Restore points are never removed by this toolkit, silently or otherwise. They are the
    only thing standing between a bad configuration change and a reinstall, and the space
    they occupy is capped by Windows already.

    This provider reports the state and, importantly, sets expectations: System Restore is
    routinely mistaken for a general undo. It is not. It does not restore personal files,
    protection can be switched off per volume, Windows discards older checkpoints as the
    shadow-storage allocation fills, and a restore point that exists today may not exist
    next week.
#>

Register-WaProvider -Name 'Windows.RestorePoints' -Order 60 `
    -Title 'System Protection and restore points' `
    -Category 'Windows configuration' `
    -Description 'Reports System Protection state, restore point availability and shadow-copy storage. Never removes a restore point.' `
    -AdvisoryOnly $true `
    -Reference 'https://learn.microsoft.com/en-us/windows/win32/sr/system-restore-portal' `
    -TestAvailable {
        param($Session)
        New-WaProviderAvailability -Available $true
    } `
    -GetInventory {
        param($Session)
        $protection = $Session.MachineProfile.SystemProtection
        @(New-WaInstalledComponent -Name 'System Protection' -Category 'Windows feature' `
            -DetectionMethod 'CIM SystemRestore' `
            -DetectionConfidence $(if ((Get-WaProperty -Object $protection -Name 'RestorePointError')) { 'LOW' } else { 'HIGH' }) `
            -Note ('{0} restore point(s) visible' -f (Get-WaProperty -Object $protection -Name 'RestorePointCount' -Default 0)))
    } `
    -GetAnalysis {
        param($Session, $Inventory)
        $protection = $Session.MachineProfile.SystemProtection
        $count = [int](Get-WaProperty -Object $protection -Name 'RestorePointCount' -Default 0)
        $shadowStorage = @(Get-WaProperty -Object $protection -Name 'ShadowStorage' -Default @())
        $usedBytes = [long](($shadowStorage | Where-Object { $null -ne $_.UsedBytes } | ForEach-Object { [long]$_.UsedBytes }) | Measure-Object -Sum).Sum

        $output = New-Object 'System.Collections.Generic.List[object]'

        if ($usedBytes -gt 0) {
            $output.Add((New-WaStorageConsumer -Name 'Shadow copy storage (System Protection)' -Category 'Windows' `
                -Bytes $usedBytes -Provider 'Windows.RestorePoints' -Measurement 'Win32_ShadowStorage' `
                -Disposition 'Informational' `
                -Note 'Shared with other VSS consumers such as backup software, so this is not purely a restore-point total. Capped by Windows and never reclaimed by WinAdvisor.'))
        }

        $evidence = New-Object 'System.Collections.Generic.List[object]'
        $evidence.Add((New-WaEvidence -Source 'CIM SystemRestore (root/default)' -Method 'CIM enumeration' `
            -Statement ('{0} restore point(s) are visible to this session.' -f $count) -Value $count -Unit 'restore points'))
        foreach ($storage in $shadowStorage) {
            $evidence.Add((New-WaEvidence -Source 'Win32_ShadowStorage' -Method 'CIM enumeration' `
                -Statement ('Shadow storage: {0} used, {1} allocated, {2} maximum.' -f
                    (Format-WaBytes $storage.UsedBytes), (Format-WaBytes $storage.AllocatedBytes), (Format-WaBytes $storage.MaxBytes)) `
                -Value $storage.UsedBytes -Unit 'bytes'))
        }
        $restoreError = [string](Get-WaProperty -Object $protection -Name 'RestorePointError' -Default '')
        if ($restoreError) {
            $evidence.Add((New-WaEvidence -Source 'CIM SystemRestore' -Method 'CIM enumeration' -Statement $restoreError -Measured $false))
        }

        $description = if ($count -gt 0) {
            '{0} restore point(s) are available. They are reported here and never removed.' -f $count
        } elseif ($restoreError) {
            'Restore points could not be enumerated without elevation, so their presence is unknown. Unknown is reported as unknown rather than assumed to be zero.'
        } else {
            'No restore points are visible. System Protection may be switched off for this volume, which means a bad configuration change cannot be rolled back through Windows.'
        }

        $output.Add((New-WaFinding -Id 'windows.restorepoints.state' `
            -Title 'System Protection state' -Category 'Windows configuration' -Provider 'Windows.RestorePoints' `
            -Description $description `
            -Evidence $evidence.ToArray() `
            -CurrentImpact $(if ($usedBytes -gt 0) { ('{0} of shadow storage in use.' -f (Format-WaBytes $usedBytes)) } else { 'No measurable shadow storage.' }) `
            -Confidence $(if ($restoreError) { 'LOW' } else { 'HIGH' }) `
            -Disposition 'Informational' -Bytes $usedBytes `
            -Warnings @(
                'System Restore is not a general undo. It does not restore personal files.'
                'Windows discards older checkpoints as the shadow-storage allocation fills, so a restore point that exists today may not exist next week.'
                'WinAdvisor never deletes a restore point. Before a HIGH-risk change it attempts to create one, and reports honestly when Windows declines.'
            )))

        return $output.ToArray()
    } | Out-Null
