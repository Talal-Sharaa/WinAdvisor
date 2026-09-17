<#
    Providers/Windows.Servicing.ps1 - component store and upgrade leftovers.

    The component store (WinSxS) is serviced only through DISM. Microsoft documents that
    deleting files from WinSxS can leave a machine unbootable and unable to update, so this
    provider never touches it directly: it measures with /AnalyzeComponentStore and acts
    with /StartComponentCleanup.

    Windows.old is reported and explained but never deleted by this toolkit. It carries
    ACLs that make hand-deletion unreliable, Windows removes it automatically once the
    rollback window closes, and the supported way to remove it early is Storage Sense or
    Disk Cleanup. Explaining that is more useful than a delete that half-succeeds and
    leaves an undeletable directory behind.
#>

function Get-WaWindowsOldInfo {
    <#
    .SYNOPSIS
        Measures a previous Windows installation, if one is present.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session)

    $path = Join-Path (Get-WaBasePaths).SystemDrive 'Windows.old'
    if (-not (Test-Path -LiteralPath $path -PathType Container)) { return $null }

    $created = $null
    try { $created = (Get-Item -LiteralPath $path -Force -ErrorAction Stop).CreationTimeUtc } catch { $created = $null }
    $size = Get-WaDirectorySize -Path $path -Config $Session.Config

    [pscustomobject]@{
        Path      = $path
        Bytes     = $size.Bytes
        Complete  = $size.Complete
        CreatedUtc = $created
        AgeDays   = $(if ($null -ne $created) { [int][Math]::Floor(([datetime]::UtcNow - $created).TotalDays) } else { $null })
    }
}

Register-WaProvider -Name 'Windows.Servicing' -Order 20 `
    -Title 'Windows servicing and component store' `
    -Category 'Windows' `
    -Description 'Measures the component store with DISM and proposes cleanup through the supported servicing path. Reports previous Windows installations without deleting them.' `
    -Reference 'https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/clean-up-the-winsxs-folder' `
    -TestAvailable {
        param($Session)
        New-WaProviderAvailability -Available $true
    } `
    -GetInventory {
        param($Session)
        $components = New-Object 'System.Collections.Generic.List[object]'
        $componentStore = $Session.MachineProfile.ComponentStore
        if ((Get-WaProperty -Object $componentStore -Name 'Analyzed' -Default $false)) {
            $components.Add((New-WaInstalledComponent -Name 'Component store' -Category 'Windows location' `
                -InstallPath (Join-Path (Get-WaBasePaths).Windows 'WinSxS') -DetectionMethod 'DISM analysis' `
                -Note ('Actual size {0}' -f (Format-WaBytes (Get-WaProperty -Object $componentStore -Name 'ActualSizeBytes')))))
        }
        $windowsOld = Get-WaWindowsOldInfo -Session $Session
        if ($null -ne $windowsOld) {
            $components.Add((New-WaInstalledComponent -Name 'Previous Windows installation' -Category 'Windows location' `
                -InstallPath $windowsOld.Path -DetectionMethod 'Directory' `
                -Note ('{0}, created {1} day(s) ago' -f (Format-WaBytes $windowsOld.Bytes), $windowsOld.AgeDays)))
        }
        return $components.ToArray()
    } `
    -GetAnalysis {
        param($Session, $Inventory)
        $output = New-Object 'System.Collections.Generic.List[object]'
        $componentStore = $Session.MachineProfile.ComponentStore

        if ((Get-WaProperty -Object $componentStore -Name 'Analyzed' -Default $false)) {
            $actual      = Get-WaProperty -Object $componentStore -Name 'ActualSizeBytes'
            $shared      = Get-WaProperty -Object $componentStore -Name 'SharedWithWindows'
            $reclaimable = Get-WaProperty -Object $componentStore -Name 'ReclaimableBytes'
            $recommended = [bool](Get-WaProperty -Object $componentStore -Name 'CleanupRecommended' -Default $false)

            $output.Add((New-WaStorageConsumer -Name 'Component store (WinSxS)' -Category 'Component store' `
                -Path (Join-Path (Get-WaBasePaths).Windows 'WinSxS') -Bytes $actual -Provider 'Windows.Servicing' `
                -Measurement 'DISM /Online /Cleanup-Image /AnalyzeComponentStore' -Disposition 'Actionable' `
                -Note 'Measured with DISM, the supported mechanism. Directory size cannot be used here: most of WinSxS is hard links to files that also live in System32, so adding up file sizes counts the same bytes repeatedly.'))

            $output.Add((New-WaFinding -Id 'windows.servicing.componentstore' `
                -Title 'Component store measurement' -Category 'Windows servicing' -Provider 'Windows.Servicing' `
                -Description ('Windows reports the component store at {0}, of which {1} is shared with Windows itself and cannot be recovered.' -f (Format-WaBytes $actual), (Format-WaBytes $shared)) `
                -Evidence @(
                    New-WaEvidence -Source 'DISM' -Method '/Online /Cleanup-Image /AnalyzeComponentStore' `
                        -Statement ('Actual size {0}; shared with Windows {1}; reclaimable {2}.' -f (Format-WaBytes $actual), (Format-WaBytes $shared), (Format-WaBytes $reclaimable)) `
                        -Value $actual -Unit 'bytes' -Reference 'https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/clean-up-the-winsxs-folder'
                    New-WaEvidence -Source 'DISM' -Method 'Cleanup recommendation' `
                        -Statement ("Windows' own recommendation: cleanup {0}." -f $(if ($recommended) { 'is recommended' } else { 'is not recommended' })) -Measured $true
                ) `
                -CurrentImpact ('{0} reclaimable according to DISM.' -f (Format-WaBytes $reclaimable)) `
                -Confidence 'HIGH' -Disposition $(if ($recommended) { 'Actionable' } else { 'Informational' }) -Bytes $reclaimable `
                -Warnings @('Windows also runs a StartComponentCleanup scheduled task automatically, which does this work when the machine is idle, after a 30-day grace period per component.')))
        } else {
            $output.Add((New-WaFinding -Id 'windows.servicing.notmeasured' `
                -Title 'Component store was not measured' -Category 'Windows servicing' -Provider 'Windows.Servicing' `
                -Description ([string](Get-WaProperty -Object $componentStore -Name 'Reason' -Default 'Not analysed.')) `
                -Evidence @(New-WaEvidence -Source 'WinAdvisor' -Method 'Configuration and privilege check' `
                    -Statement ([string](Get-WaProperty -Object $componentStore -Name 'Note' -Default '')) -Measured $false) `
                -Confidence 'HIGH' -Disposition 'Informational'))
        }

        $windowsOld = Get-WaWindowsOldInfo -Session $Session
        if ($null -ne $windowsOld) {
            $output.Add((New-WaStorageConsumer -Name 'Previous Windows installation (Windows.old)' -Category 'Update leftovers' `
                -Path $windowsOld.Path -Bytes $windowsOld.Bytes -Complete $windowsOld.Complete -Provider 'Windows.Servicing' `
                -Disposition 'ManualReview' `
                -Note 'Reported only. WinAdvisor does not delete Windows.old; see the manual-review recommendation for the supported way to remove it.'))
        }

        return $output.ToArray()
    } `
    -GetCleanupCandidates {
        param($Session, $Inventory)
        # This provider works through DISM and advisory items rather than file manifests,
        # so candidates are represented directly as recommendations in GetCleanupPlan.
        # A single placeholder candidate keeps the contract satisfied.
        @(New-WaCleanupCandidate -Key 'windows.servicing' -Provider 'Windows.Servicing' `
            -Title 'Windows servicing' -Category 'Windows servicing' -Risk 'MANUAL-ONLY' `
            -Explanation 'Servicing actions are expressed as commands, not file manifests.')
    } `
    -GetCleanupPlan {
        param($Session, $Candidates)
        $recommendations = New-Object 'System.Collections.Generic.List[object]'
        $componentStore = $Session.MachineProfile.ComponentStore
        $config = $Session.Config

        if ((Get-WaProperty -Object $componentStore -Name 'Analyzed' -Default $false)) {
            $reclaimable = Get-WaProperty -Object $componentStore -Name 'ReclaimableBytes'
            $recommended = [bool](Get-WaProperty -Object $componentStore -Name 'CleanupRecommended' -Default $false)

            if ($recommended -or ($null -ne $reclaimable -and [long]$reclaimable -gt 1GB)) {
                $cleanup = New-WaCommandRecommendation -Session $Session `
                    -Id 'windows.servicing.startcomponentcleanup' `
                    -CommandId 'dism.startcomponentcleanup' `
                    -Title 'Clean up the component store' `
                    -Category 'Windows servicing' `
                    -Provider 'Windows.Servicing' `
                    -Description 'Removes superseded component versions through DISM, the supported servicing mechanism. This is the same work the built-in StartComponentCleanup scheduled task does, without waiting for the 30-day grace period per component.' `
                    -Evidence @(
                        New-WaEvidence -Source 'DISM' -Method '/AnalyzeComponentStore' `
                            -Statement ('DISM reports {0} as reclaimable.' -f (Format-WaBytes $reclaimable)) -Value $reclaimable -Unit 'bytes'
                        New-WaEvidence -Source 'DISM' -Method 'Cleanup recommendation' `
                            -Statement ("Windows' own recommendation: {0}." -f $(if ($recommended) { 'cleanup recommended' } else { 'cleanup not explicitly recommended, but over 1 GB is reclaimable' })) -Measured $true
                    ) `
                    -CurrentImpact ('{0} of superseded components.' -f (Format-WaBytes $reclaimable)) `
                    -EstimatedBytes $reclaimable `
                    -Risk 'MODERATE' -Confidence 'HIGH' -Reversibility 'Irreversible' `
                    -RollbackNote 'Not reversible. Superseded component versions are removed permanently. Updates installed so far can still be uninstalled; only their older superseded payloads go.' `
                    -Warnings @(
                        'This can take a long time and must not be interrupted. WinAdvisor never terminates DISM mid-operation.'
                        'Do not start Windows Update or another servicing operation while it runs.'
                    ) `
                    -Prerequisites @('An elevated session.', 'No servicing operation currently in progress.')
                if ($null -ne $cleanup) { $recommendations.Add($cleanup) }
            }

            if (Get-WaProviderSetting -Config $config -Provider 'Windows.Servicing' -Name 'AllowResetBase' -Default $false) {
                $resetBase = New-WaCommandRecommendation -Session $Session `
                    -Id 'windows.servicing.resetbase' `
                    -CommandId 'dism.startcomponentcleanup.resetbase' `
                    -Title 'Clean up the component store and reset the base' `
                    -Category 'Windows servicing' `
                    -Provider 'Windows.Servicing' `
                    -Description 'Removes every superseded component version. Recovers more than the standard cleanup, at a permanent cost.' `
                    -Evidence @(New-WaEvidence -Source 'Microsoft Learn' -Method 'Documented behaviour' `
                        -Statement 'Microsoft documents that no currently installed update can be uninstalled after this command completes.' `
                        -Measured $false -Reference 'https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/clean-up-the-winsxs-folder') `
                    -CurrentImpact 'Recovers more than the standard cleanup, amount not predictable in advance.' `
                    -EstimatedBytes $null `
                    -Risk 'HIGH' -Confidence 'HIGH' -Reversibility 'Irreversible' `
                    -RollbackNote 'Not reversible under any circumstances.' `
                    -Warnings @(
                        'After this, no update currently installed can be uninstalled. If an update later turns out to be the cause of a problem, removing it will not be an option.'
                        'Future updates remain uninstallable in the normal way.'
                        'Enabled only because Providers.Windows.Servicing.AllowResetBase is set to true in configuration.'
                    ) `
                    -Prerequisites @('An elevated session.', 'A machine you are confident is stable on its current updates.')
                if ($null -ne $resetBase) { $recommendations.Add($resetBase) }
            }
        }

        $windowsOld = Get-WaWindowsOldInfo -Session $Session
        if ($null -ne $windowsOld) {
            $rollbackWindowText = if ($null -ne $windowsOld.AgeDays -and $windowsOld.AgeDays -ge 10) {
                'The directory is {0} days old, so the rollback window has probably already closed and Windows should remove it on its own shortly.' -f $windowsOld.AgeDays
            } else {
                'The directory is {0} days old, so rolling back to the previous Windows version is probably still possible.' -f $windowsOld.AgeDays
            }

            $recommendations.Add((New-WaAdvisoryRecommendation `
                -Id 'windows.servicing.windowsold' `
                -Title 'Previous Windows installation is present' `
                -Category 'Windows servicing' `
                -Provider 'Windows.Servicing' `
                -Description ('Windows.old holds your previous Windows installation and is what the "Go back" recovery option uses. {0}' -f $rollbackWindowText) `
                -Evidence @(
                    New-WaEvidence -Source $windowsOld.Path -Method 'Bounded filesystem enumeration' `
                        -Statement ('{0} occupied.' -f (Format-WaBytes $windowsOld.Bytes)) -Value $windowsOld.Bytes -Unit 'bytes' -Complete $windowsOld.Complete
                    New-WaEvidence -Source $windowsOld.Path -Method 'Directory creation time' `
                        -Statement ('Created {0} day(s) ago. Creation time is a hint, not a guaranteed upgrade date or rollback deadline.' -f $windowsOld.AgeDays) -Value $windowsOld.AgeDays -Unit 'days'
                ) `
                -CurrentImpact ('{0} on {1}.' -f (Format-WaBytes $windowsOld.Bytes), (Get-WaBasePaths).SystemDrive) `
                -EstimatedBytes $windowsOld.Bytes -EstimateComplete $windowsOld.Complete `
                -Confidence 'HIGH' `
                -ManualSteps 'Settings > System > Storage > Temporary files, then tick "Previous Windows installation(s)" and remove. Disk Cleanup run as administrator offers the same option. Both use the supported removal path, which hand-deleting the directory does not: its ACLs make a manual delete fail part-way and leave an undeletable remnant.' `
                -Warnings @(
                    'Removing it permanently ends the ability to go back to your previous Windows version.'
                    'Windows deletes it automatically once the rollback window closes, so waiting costs nothing but time.'
                    'WinAdvisor will not delete this directory.'
                ) `
                -Reference 'https://learn.microsoft.com/en-us/windows/client-management/client-tools/windows-version-search'))
        }

        return $recommendations.ToArray()
    } `
    -TestResult {
        param($Session, $Results)
        # Re-measure with DISM so the claim is checked against the tool that owns the data.
        if (-not (Test-WaAdministrator)) {
            return @([pscustomobject]@{ Provider = 'Windows.Servicing'; Verified = $false; Message = 'Cannot re-measure the component store without elevation.' })
        }
        $after = Get-WaComponentStoreInfo -Config $Session.Config -Allow
        if (-not $after.Analyzed) {
            return @([pscustomobject]@{ Provider = 'Windows.Servicing'; Verified = $false; Message = $after.Reason })
        }
        @([pscustomobject]@{
            Provider = 'Windows.Servicing'
            Verified = $true
            Message  = ('Component store now measures {0} actual with {1} reclaimable (re-measured with DISM).' -f (Format-WaBytes $after.ActualSizeBytes), (Format-WaBytes $after.ReclaimableBytes))
        })
    } | Out-Null
