<#
    Providers/Containers.Wsl.ps1 - WSL, reported and explained, never modified.

    WSL is advisory by construction, and the reason is worth stating plainly.

    Microsoft's "How to manage WSL disk space" documents how to *expand* a WSL virtual hard
    disk. It documents no supported in-place shrink. The manual procedure people share
    involves diskpart compact vdisk or Optimize-VHD against ext4.vhdx, and Microsoft's own
    guidance on that page is explicit that WSL files under AppData should not be modified,
    moved or accessed with Windows tools, because doing so can corrupt the distribution.

    So there is no WSL mutation in the command catalog. Not a missing feature: there is no
    documented safe operation to expose. The provider measures the virtual disks, explains
    the situation, and leaves the decision with the person who owns the data.

    wsl --unregister is likewise never offered. It permanently destroys everything in a
    distribution, which is not a cleanup operation.
#>

function Get-WaWslDistribution {
    <#
    .SYNOPSIS
        Enumerates registered WSL distributions and measures their virtual disks.

    .DESCRIPTION
        The registry under HKCU\...\Lxss is the authoritative source for BasePath, which is
        how the documentation itself tells you to locate a distribution's ext4.vhdx.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session)

    $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'
    if (-not (Test-Path -LiteralPath $key)) { return @() }

    $distributions = New-Object 'System.Collections.Generic.List[object]'
    $children = @()
    try { $children = @(Get-ChildItem -LiteralPath $key -ErrorAction Stop) } catch { return @() }

    foreach ($child in $children) {
        $properties = $null
        try { $properties = Get-ItemProperty -LiteralPath $child.PSPath -ErrorAction Stop } catch { continue }

        $name = [string](Get-WaProperty -Object $properties -Name 'DistributionName')
        if (-not $name) { continue }

        $basePath = [string](Get-WaProperty -Object $properties -Name 'BasePath')
        # The registry records the path in the \\?\ extended-length form.
        if ($basePath -like '\\?\*') { $basePath = $basePath.Substring(4) }

        $diskBytes = $null
        $diskPath = ''
        if ($basePath -and (Test-Path -LiteralPath $basePath -PathType Container)) {
            foreach ($candidate in @('ext4.vhdx', 'ext4.vhd')) {
                $path = Join-Path $basePath $candidate
                if (Test-Path -LiteralPath $path -PathType Leaf) {
                    $diskPath = $path
                    try { $diskBytes = (Get-Item -LiteralPath $path -Force -ErrorAction Stop).Length } catch { $diskBytes = $null }
                    break
                }
            }
        }

        $distributions.Add([pscustomobject]@{
            Name      = $name
            BasePath  = $basePath
            Version   = (Get-WaProperty -Object $properties -Name 'Version')
            DiskPath  = $diskPath
            DiskBytes = $diskBytes
        })
    }
    return $distributions.ToArray()
}

Register-WaProvider -Name 'Containers.Wsl' -Order 210 `
    -Title 'Windows Subsystem for Linux' `
    -Category 'Containers' `
    -Description 'Reports WSL distributions and virtual disk sizes. Performs no WSL operation: Microsoft documents disk expansion but no supported in-place shrink, and unregistering a distribution destroys its data.' `
    -AdvisoryOnly $true `
    -Reference 'https://learn.microsoft.com/en-us/windows/wsl/disk-space' `
    -TestAvailable {
        param($Session)
        $distributions = @(Get-WaWslDistribution -Session $Session)
        if ($distributions.Count -eq 0) {
            # The wsl.exe executable ships with Windows whether or not anything is installed,
            # so its presence alone is not evidence of a WSL workload.
            return (New-WaProviderAvailability -Available $false -Reason 'No WSL distribution is registered for this user.')
        }
        $Session.ProviderState['Containers.Wsl'] = $distributions
        New-WaProviderAvailability -Available $true -Reason ('{0} distribution(s) registered.' -f $distributions.Count)
    } `
    -GetInventory {
        param($Session)
        @(foreach ($distribution in @($Session.ProviderState['Containers.Wsl'])) {
            New-WaInstalledComponent -Name ('WSL: ' + $distribution.Name) -Category 'Container storage' `
                -InstallPath $distribution.BasePath -DetectionMethod 'Registry' -DetectionConfidence 'HIGH' `
                -Note ('WSL version {0}, virtual disk {1}' -f $distribution.Version, (Format-WaBytes $distribution.DiskBytes))
        })
    } `
    -GetAnalysis {
        param($Session, $Inventory)
        $distributions = @($Session.ProviderState['Containers.Wsl'])
        if ($distributions.Count -eq 0) { return @() }

        $output = New-Object 'System.Collections.Generic.List[object]'
        $evidence = New-Object 'System.Collections.Generic.List[object]'
        $totalBytes = [long]0

        foreach ($distribution in $distributions) {
            if ($null -ne $distribution.DiskBytes) { $totalBytes += [long]$distribution.DiskBytes }
            $evidence.Add((New-WaEvidence -Source $distribution.DiskPath -Method 'File length' `
                -Statement ('{0}: virtual disk is {1} (WSL {2}).' -f $distribution.Name, (Format-WaBytes $distribution.DiskBytes), $distribution.Version) `
                -Value $distribution.DiskBytes -Unit 'bytes'))

            $output.Add((New-WaStorageConsumer -Name ('WSL distribution: ' + $distribution.Name) -Category 'Virtual machines' `
                -Path $distribution.DiskPath -Bytes $distribution.DiskBytes -Provider 'Containers.Wsl' `
                -Measurement 'Virtual disk file length' -Disposition 'ManualReview' `
                -Note 'A WSL virtual disk grows to its high-water mark and does not shrink when files inside are deleted. The file size is therefore the most it has ever used, not what is in use now.'))
        }

        $statusProbe = Invoke-WaCatalogProbe -CommandId 'wsl.list' -Session $Session
        if ($statusProbe.Available -and $statusProbe.ExitCode -eq 0) {
            # wsl.exe emits UTF-16, which arrives with interleaved null characters.
            $listing = ([string]$statusProbe.Output) -replace "`0", ''
            $evidence.Add((New-WaEvidence -Source 'wsl --list --verbose' -Method 'WSL CLI' `
                -Statement (($listing -split "`r?`n" | Where-Object { $_.Trim() }) -join ' | ') -Measured $true `
                -Reference 'https://learn.microsoft.com/en-us/windows/wsl/basic-commands'))
        }

        $output.Add((New-WaFinding -Id 'containers.wsl.disks' `
            -Title 'WSL virtual disks' -Category 'Containers' -Provider 'Containers.Wsl' `
            -Description ('{0} WSL distribution(s) occupy {1} in virtual disk files. A WSL virtual disk only ever grows: deleting files inside the distribution frees space for Linux but does not shrink the .vhdx on Windows.' -f $distributions.Count, (Format-WaBytes $totalBytes)) `
            -Evidence $evidence.ToArray() `
            -CurrentImpact ('{0} across {1} virtual disk(s).' -f (Format-WaBytes $totalBytes), $distributions.Count) `
            -Confidence 'HIGH' -Disposition 'Advisory' -Bytes $totalBytes `
            -Warnings @(
                'Microsoft documents how to expand a WSL virtual disk but publishes no supported in-place shrink procedure.'
                'Microsoft also advises against modifying, moving or accessing WSL files under AppData with Windows tools, because it can corrupt the distribution.'
                'WinAdvisor therefore performs no WSL operation at all.'
            )))

        return $output.ToArray()
    } `
    -GetCleanupCandidates {
        param($Session, $Inventory)
        @(New-WaCleanupCandidate -Key 'containers.wsl' -Provider 'Containers.Wsl' `
            -Title 'WSL' -Category 'Containers' -Risk 'MANUAL-ONLY' `
            -Explanation 'WSL storage is advisory only.')
    } `
    -GetCleanupPlan {
        param($Session, $Candidates)
        $distributions = @($Session.ProviderState['Containers.Wsl'])
        if ($distributions.Count -eq 0) { return @() }

        $totalBytes = [long](($distributions | Where-Object { $null -ne $_.DiskBytes } | ForEach-Object { [long]$_.DiskBytes }) | Measure-Object -Sum).Sum

        @(New-WaAdvisoryRecommendation `
            -Id 'containers.wsl.reclaim' `
            -Title 'WSL virtual disks are not shrunk automatically' `
            -Category 'Containers' -Provider 'Containers.Wsl' `
            -Description ('{0} of WSL virtual disk. Freeing space inside a distribution does not shrink the .vhdx file on Windows; it stays at its high-water mark. WinAdvisor does not attempt to reclaim it, because Microsoft documents no supported in-place shrink and warns against touching WSL files with Windows tools.' -f (Format-WaBytes $totalBytes)) `
            -Evidence @(foreach ($distribution in $distributions) {
                New-WaEvidence -Source $distribution.DiskPath -Method 'File length' `
                    -Statement ('{0}: {1}.' -f $distribution.Name, (Format-WaBytes $distribution.DiskBytes)) `
                    -Value $distribution.DiskBytes -Unit 'bytes' `
                    -Reference 'https://learn.microsoft.com/en-us/windows/wsl/disk-space'
            }) `
            -CurrentImpact ('{0} occupied by WSL virtual disks.' -f (Format-WaBytes $totalBytes)) `
            -EstimatedBytes $null `
            -Confidence 'HIGH' `
            -ManualSteps @'
First reclaim space inside the distribution, which is the part that is both safe and documented: remove package caches, old container images and build artefacts from within Linux.

To shrink the .vhdx afterwards you have two options, both of which you should research against current Microsoft guidance before running, and neither of which WinAdvisor will do for you:

  * Enable sparse mode for the distribution so Windows honours TRIM from the guest and deallocates freed ranges over time.
  * Shut WSL down completely with wsl --shutdown, then compact the virtual disk offline with diskpart or Hyper-V tooling.

Back up anything you cannot lose first: wsl --export writes a distribution to a tar or .vhdx file.
'@ `
            -Warnings @(
                'Never delete an ext4.vhdx file. It is the whole distribution.'
                'Never run wsl --unregister to save space. It permanently destroys everything in that distribution.'
                'Compacting requires WSL to be fully shut down. Compacting a disk that is still attached can corrupt it.'
            ) `
            -Reference 'https://learn.microsoft.com/en-us/windows/wsl/disk-space')
    } | Out-Null
