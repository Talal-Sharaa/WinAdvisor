<#
    Providers/Windows.DeliveryOptimization.ps1 - Delivery Optimization cache, reported only.

    Delivery Optimization caches update and Store content so it can be shared between
    machines and resumed. Windows manages the cache itself: it has a size cap, an age
    policy, and it trims automatically.

    Windows also ships a supported cmdlet for clearing it on demand
    (Delete-DeliveryOptimizationCache). WinAdvisor reports the state and names that cmdlet
    rather than running it, because the execution engine deliberately runs only executables
    from the command catalog and not arbitrary PowerShell cmdlets. See docs/ARCHITECTURE.md
    (ADR-005) for why that boundary exists and what it would take to move it.
#>

Register-WaProvider -Name 'Windows.DeliveryOptimization' -Order 70 `
    -Title 'Delivery Optimization' `
    -Category 'Windows' `
    -Description 'Reports Delivery Optimization cache state and the supported way to clear it. Does not clear it.' `
    -AdvisoryOnly $true `
    -Reference 'https://learn.microsoft.com/en-us/windows/deployment/do/waas-delivery-optimization' `
    -TestAvailable {
        param($Session)
        $info = $Session.MachineProfile.DeliveryOptimization
        if ($null -eq $info) {
            return (New-WaProviderAvailability -Available $false -Reason 'Delivery Optimization state could not be read.')
        }
        New-WaProviderAvailability -Available $true
    } `
    -GetInventory {
        param($Session)
        $info = $Session.MachineProfile.DeliveryOptimization
        @(New-WaInstalledComponent -Name 'Delivery Optimization' -Category 'Windows feature' `
            -InstallPath (Get-WaProperty -Object $info -Name 'CachePath') -DetectionMethod 'Get-DeliveryOptimizationStatus' `
            -Note ('{0} active download(s)' -f (Get-WaProperty -Object $info -Name 'ActiveDownloads' -Default 0)))
    } `
    -GetAnalysis {
        param($Session, $Inventory)
        $info = $Session.MachineProfile.DeliveryOptimization
        $cachePath = [string](Get-WaProperty -Object $info -Name 'CachePath')

        $output = New-Object 'System.Collections.Generic.List[object]'
        $consumer = Get-WaDirectoryConsumer -Session $Session -Name 'Delivery Optimization cache' `
            -Category 'Update leftovers' -Path $cachePath -Provider 'Windows.DeliveryOptimization' `
            -Disposition 'Informational' `
            -Note 'Windows caps and trims this cache automatically. Reported only.'
        if ($null -ne $consumer) { $output.Add($consumer) }

        $bytes = if ($null -ne $consumer) { $consumer.Bytes } else { $null }

        $output.Add((New-WaFinding -Id 'windows.deliveryoptimization.state' `
            -Title 'Delivery Optimization cache' -Category 'Windows' -Provider 'Windows.DeliveryOptimization' `
            -Description ('The Delivery Optimization cache measures {0}. Windows manages its size and age policy, so it is not usually worth intervening.' -f (Format-WaBytes $bytes)) `
            -Evidence @(
                New-WaEvidence -Source $cachePath -Method 'Bounded filesystem enumeration' `
                    -Statement ('Cache directory measures {0}.' -f (Format-WaBytes $bytes)) -Value $bytes -Unit 'bytes'
                New-WaEvidence -Source 'Get-DeliveryOptimizationStatus' -Method 'Cmdlet' `
                    -Statement ('{0} download(s) currently tracked.' -f (Get-WaProperty -Object $info -Name 'ActiveDownloads' -Default 0)) -Measured $true
            ) `
            -CurrentImpact ('{0} of cached update and Store content.' -f (Format-WaBytes $bytes)) `
            -Confidence 'MEDIUM' -Disposition 'Informational' -Bytes $bytes `
            -Warnings @(
                'To clear it yourself, run Delete-DeliveryOptimizationCache in an elevated PowerShell session. That is the supported mechanism.'
                'Do not delete the cache directory by hand while an update is downloading.'
            )))

        return $output.ToArray()
    } | Out-Null
