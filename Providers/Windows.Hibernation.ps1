<#
    Providers/Windows.Hibernation.ps1 - hibernation as a storage/functionality trade-off.

    hiberfil.sys is often one of the largest single files on a system drive, and disabling
    hibernation is the documented way to remove it. It is presented as a trade-off, not a
    saving, because it is genuinely both:

      * you recover the file's size, permanently;
      * you lose Hibernate;
      * you also lose Fast Startup, because Fast Startup writes the kernel session to that
        same file, which is the part people are usually surprised by;
      * on a laptop you lose the behaviour that preserves your work when the battery
        reaches a critical level.

    Classified HIGH and always requires its own individual approval. Reversible with the
    documented counterpart command, which the rollback record names.
#>

Register-WaProvider -Name 'Windows.Hibernation' -Order 50 `
    -Title 'Hibernation and Fast Startup' `
    -Category 'Windows configuration' `
    -Description 'Reports hibernation state and hiberfil.sys size, and offers to disable hibernation as an explicit, reversible trade-off.' `
    -Reference 'https://learn.microsoft.com/en-us/windows-hardware/design/device-experiences/powercfg-command-line-options' `
    -TestAvailable {
        param($Session)
        $hibernation = $Session.MachineProfile.Hibernation
        if ($null -eq $hibernation) {
            return (New-WaProviderAvailability -Available $false -Reason 'Hibernation state could not be read.')
        }
        if (-not $hibernation.Enabled) {
            return (New-WaProviderAvailability -Available $false -Reason 'Hibernation is already disabled; there is nothing to report or recover.')
        }
        New-WaProviderAvailability -Available $true
    } `
    -GetInventory {
        param($Session)
        $hibernation = $Session.MachineProfile.Hibernation
        @(New-WaInstalledComponent -Name 'Hibernation file' -Category 'Windows location' `
            -InstallPath $hibernation.HiberfilPath -DetectionMethod 'Registry and filesystem' `
            -Note ('{0}, type: {1}' -f (Format-WaBytes $hibernation.HiberfilBytes), $hibernation.HiberFileType))
    } `
    -GetAnalysis {
        param($Session, $Inventory)
        $hibernation = $Session.MachineProfile.Hibernation
        $hardware = $Session.MachineProfile.Hardware
        $isPortable = [bool](Get-WaProperty -Object $hardware -Name 'IsPortable' -Default $false)

        @(
            New-WaStorageConsumer -Name 'hiberfil.sys' -Category 'Windows' `
                -Path $hibernation.HiberfilPath -Bytes $hibernation.HiberfilBytes `
                -Provider 'Windows.Hibernation' -Measurement 'File length' -Disposition 'Actionable' `
                -Note 'Reserved by Windows for hibernation and Fast Startup. Removed only by disabling hibernation.'

            New-WaFinding -Id 'windows.hibernation.state' `
                -Title 'Hibernation is enabled' -Category 'Windows configuration' -Provider 'Windows.Hibernation' `
                -Description ('hiberfil.sys occupies {0} on {1}. {2}' -f
                    (Format-WaBytes $hibernation.HiberfilBytes),
                    (Get-WaBasePaths).SystemDrive,
                    $(if ($isPortable) { 'This is a laptop or tablet, where hibernation is what preserves your work when the battery runs critically low.' } else { 'This is a desktop, where hibernation is less commonly relied on.' })) `
                -Evidence @(
                    New-WaEvidence -Source $hibernation.HiberfilPath -Method 'File length' `
                        -Statement ('hiberfil.sys is {0}.' -f (Format-WaBytes $hibernation.HiberfilBytes)) -Value $hibernation.HiberfilBytes -Unit 'bytes'
                    New-WaEvidence -Source 'Registry Control\Power' -Method 'Registry read' `
                        -Statement ('Hibernation file type: {0}.' -f $hibernation.HiberFileType) -Measured $true
                    New-WaEvidence -Source 'Registry Session Manager\Power' -Method 'Registry read' `
                        -Statement ('Fast Startup is currently {0}.' -f $(if ($hibernation.FastStartupEffective) { 'in effect' } else { 'not in effect' })) -Measured $true
                    New-WaEvidence -Source 'Win32_ComputerSystem' -Method 'Chassis type' `
                        -Statement ('Chassis: {0}.' -f (Get-WaProperty -Object $hardware -Name 'ChassisType')) -Measured $true
                ) `
                -CurrentImpact ('{0} of disk reserved.' -f (Format-WaBytes $hibernation.HiberfilBytes)) `
                -Confidence 'HIGH' -Disposition 'Actionable' -Bytes $hibernation.HiberfilBytes `
                -Warnings @('Disabling hibernation also disables Fast Startup. The two share the same file.')
        )
    } `
    -GetCleanupCandidates {
        param($Session, $Inventory)
        @(New-WaCleanupCandidate -Key 'windows.hibernation' -Provider 'Windows.Hibernation' `
            -Title 'Hibernation' -Category 'Windows configuration' -Risk 'MANUAL-ONLY' `
            -Explanation 'Hibernation is changed with powercfg, not by deleting files.')
    } `
    -GetCleanupPlan {
        param($Session, $Candidates)
        $hibernation = $Session.MachineProfile.Hibernation
        $hardware = $Session.MachineProfile.Hardware
        $isPortable = [bool](Get-WaProperty -Object $hardware -Name 'IsPortable' -Default $false)

        $warnings = New-Object 'System.Collections.Generic.List[string]'
        $warnings.Add('Fast Startup stops working too. Fast Startup writes the kernel session to hiberfil.sys, so removing the file removes both features.')
        $warnings.Add('Windows shut down and started up will take slightly longer, because a full boot replaces the Fast Startup path.')
        if ($isPortable) {
            $warnings.Add('This is a portable machine. Without hibernation, reaching a critical battery level means losing unsaved work rather than suspending to disk.')
        }
        $warnings.Add('Re-enabling recreates hiberfil.sys, taking the space back again.')

        $recommendation = New-WaCommandRecommendation -Session $Session `
            -Id 'windows.hibernation.disable' `
            -CommandId 'powercfg.hibernate.off' `
            -Title 'Disable hibernation and remove hiberfil.sys' `
            -Category 'Windows configuration' `
            -Provider 'Windows.Hibernation' `
            -Description ('Recovers {0} permanently by turning off hibernation. This is a functionality trade-off, not a cleanup: you are exchanging two features for disk space.' -f (Format-WaBytes $hibernation.HiberfilBytes)) `
            -Evidence @(
                New-WaEvidence -Source $hibernation.HiberfilPath -Method 'File length' `
                    -Statement ('hiberfil.sys currently occupies {0}.' -f (Format-WaBytes $hibernation.HiberfilBytes)) `
                    -Value $hibernation.HiberfilBytes -Unit 'bytes'
                New-WaEvidence -Source 'Win32_ComputerSystem' -Method 'Chassis type' `
                    -Statement ('This machine reports its chassis as {0}.' -f (Get-WaProperty -Object $hardware -Name 'ChassisType')) -Measured $true
            ) `
            -CurrentImpact ('{0} reserved on {1}.' -f (Format-WaBytes $hibernation.HiberfilBytes), (Get-WaBasePaths).SystemDrive) `
            -EstimatedBytes $hibernation.HiberfilBytes `
            -Risk 'HIGH' -Confidence 'HIGH' -Reversibility 'Reversible' `
            -RollbackNote 'Reversible by running powercfg /hibernate on, which WinAdvisor records as the counterpart command. Doing so recreates hiberfil.sys and takes the space back.' `
            -Warnings $warnings.ToArray() `
            -Prerequisites @('An elevated session.') `
            -RestartRequired 'Restart' `
            -QuestionId 'hibernation'

        if ($null -eq $recommendation) { return @() }
        return @($recommendation)
    } `
    -TestResult {
        param($Session, $Results)
        $after = Get-WaHibernationInfo
        @([pscustomobject]@{
            Provider = 'Windows.Hibernation'
            Verified = $true
            Message  = ('Hibernation is now {0}; hiberfil.sys measures {1}.' -f
                $(if ($after.Enabled) { 'enabled' } else { 'disabled' }),
                (Format-WaBytes $after.HiberfilBytes))
        })
    } | Out-Null
