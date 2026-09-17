<#
    Providers/Storage.LargeFiles.ps1 - large file reporting, advisory only.

    Size is not evidence. A 40 GB file may be a forgotten ISO or it may be the virtual
    machine someone's job depends on, and nothing about its size distinguishes the two. So
    this provider reports and categorises, and never proposes deleting anything.

    It also only looks where it has been told to look. Walking an entire user profile is
    millions of filesystem operations, so recursion happens only for directories named
    explicitly with -DeepScanPath or in configuration. Without that, the provider reports
    the top level of the user profile and says so.
#>

Register-WaProvider -Name 'Storage.LargeFiles' -Order 400 `
    -Title 'Large files' `
    -Category 'Storage' `
    -Description 'Reports files above the configured size threshold in explicitly named directories, categorised by type. Advisory only: nothing is ever proposed for deletion based on size.' `
    -AdvisoryOnly $true `
    -TestAvailable {
        param($Session)
        New-WaProviderAvailability -Available $true
    } `
    -GetInventory {
        param($Session)
        @()
    } `
    -GetAnalysis {
        param($Session, $Inventory)
        $config = $Session.Config
        $deepPaths = @($config.DeepScanPaths)

        # Without an explicit deep-scan path, look only at the top level of the profile.
        # That is cheap, and it still finds the large files people leave on the desktop or
        # in the profile root.
        $paths = if ($deepPaths.Count -gt 0) { $deepPaths } else { @((Get-WaBasePaths).UserProfile) }
        $recurse = ($deepPaths.Count -gt 0)

        $result = Get-WaLargeFile -Path $paths -Config $config -Recurse:$recurse
        $files = @($result.Files)
        if ($files.Count -eq 0) {
            return @(New-WaFinding -Id 'storage.largefiles.none' `
                -Title 'Large files' -Category 'Storage' -Provider 'Storage.LargeFiles' `
                -Description ('No file above {0} was found in the {1} that were examined.' -f
                    (Format-WaBytes $config.LargeFileThresholdBytes),
                    $(if ($recurse) { 'directories' } else { 'top level of your user profile' })) `
                -Evidence @(foreach ($status in @($result.ScanStatus)) {
                    New-WaEvidence -Source $status.Path -Method $(if ($status.Recursive) { 'Recursive enumeration' } else { 'Top-level enumeration' }) `
                        -Statement ('Scan status: {0}.' -f $status.Status) -Measured $true -Complete $status.Complete
                }) `
                -Confidence 'MEDIUM' -Disposition 'Informational' `
                -Warnings @($(if (-not $recurse) { 'Only the top level was examined. Use -DeepScanPath to look inside a specific directory.' } else { '' }) | Where-Object { $_ }))
        }

        $totalBytes = [long](($files | ForEach-Object { [long]$_.Bytes }) | Measure-Object -Sum).Sum
        $byCategory = $files | Group-Object Category | Sort-Object { ($_.Group | Measure-Object -Property Bytes -Sum).Sum } -Descending

        $consumers = @(foreach ($group in $byCategory) {
            $categoryBytes = [long](($group.Group | ForEach-Object { [long]$_.Bytes }) | Measure-Object -Sum).Sum
            New-WaStorageConsumer -Name ('Large files: ' + $group.Name) -Category $group.Name `
                -Bytes $categoryBytes -Provider 'Storage.LargeFiles' -Disposition 'ManualReview' `
                -Measurement 'Filesystem enumeration of explicitly named directories' `
                -Note ('{0} file(s) above the size threshold. Reported for review; never proposed for deletion.' -f $group.Count)
        })

        $finding = New-WaFinding -Id 'storage.largefiles' `
            -Title 'Large files' -Category 'Storage' -Provider 'Storage.LargeFiles' `
            -Description ('{0} file(s) above {1} account for {2}.' -f $files.Count, (Format-WaBytes $config.LargeFileThresholdBytes), (Format-WaBytes $totalBytes)) `
            -Evidence @($files | Select-Object -First 20 | ForEach-Object {
                New-WaEvidence -Source $_.Path -Method 'Filesystem enumeration' `
                    -Statement ('{0} - {1} ({2})' -f (Format-WaBytes $_.Bytes), $_.Path, $_.Category) `
                    -Value $_.Bytes -Unit 'bytes'
            }) `
            -CurrentImpact ('{0} across {1} large file(s).' -f (Format-WaBytes $totalBytes), $files.Count) `
            -Confidence 'HIGH' -Disposition 'Advisory' -Bytes $totalBytes `
            -Warnings @(
                'Size alone says nothing about whether a file matters. Nothing here is proposed for deletion.'
                $(if (-not $recurse) { 'Only the top level of your user profile was examined. Use -DeepScanPath to look inside a specific directory.' } else { 'Only the directories you named were examined.' })
            )

        return @(@($finding) + $consumers)
    } | Out-Null
