<#
    Core/Inventory.ps1 - bounded filesystem measurement.

    Every size the toolkit reports comes from here, and every number carries a Complete
    flag. A scan that hits its entry or time budget returns Complete = $false and its
    total is a lower bound, which the analysis and reporting layers render as "at least",
    never as a total.

    Recursion is never implicit. Callers ask for a specific root; deep scanning of a user
    directory happens only when the user names it.
#>

# Analysis measures the same directories more than once: a provider reports a size in
# GetAnalysis and then builds a file manifest for the same root in GetCleanupCandidates.
# Rescanning a multi-gigabyte cache for the second answer is pure waste, so results are
# memoised for the duration of the analysis phase only.
#
# The cache is explicitly OFF outside that phase. Before/after verification must measure
# the real filesystem, and returning a cached pre-cleanup size as the post-cleanup result
# would fabricate the one number the whole report rests on.
$script:WaInventoryCache = @{}
$script:WaInventoryCacheEnabled = $false

function Enable-WaInventoryCache {
    [CmdletBinding()]
    param()
    $script:WaInventoryCache = @{}
    $script:WaInventoryCacheEnabled = $true
}

function Disable-WaInventoryCache {
    [CmdletBinding()]
    param()
    $script:WaInventoryCacheEnabled = $false
    $script:WaInventoryCache = @{}
}

function Get-WaInventoryCacheKey {
    <#
    .SYNOPSIS
        Cache key for a scan. Deliberately independent of the age cutoff.

    .DESCRIPTION
        The walk collects every policy-allowed file with its timestamps; the age cutoff is
        applied afterwards to split that list into eligible and too-recent. Keying on the
        cutoff as well would rescan the same directory for each threshold and gain nothing.
    #>
    [CmdletBinding()]
    param([string]$Root, [bool]$TopLevelOnly)
    return ('{0}|{1}' -f $Root.ToLowerInvariant(), $TopLevelOnly)
}

function Get-WaFileInventory {
    <#
    .SYNOPSIS
        Measures a directory within a strict entry and time budget.

    .DESCRIPTION
        Iterative breadth-first walk with an explicit queue rather than Get-ChildItem
        -Recurse, so the budget can be enforced between entries and a single unreadable
        subtree cannot abort the whole scan.

        Files are excluded from the returned manifest when policy forbids deleting them,
        but their bytes are still counted toward the measured total and reported
        separately, so the storage picture stays honest even where cleanup is not offered.

    .PARAMETER CutoffUtc
        Only files last written and created before this instant enter the manifest. Files
        newer than the cutoff are counted in TotalBytes but not offered for deletion.

    .PARAMETER TopLevelOnly
        Measure only the immediate children. Used for cheap first-pass attribution.

    .OUTPUTS
        An object with Status (Absent | Blocked | Available | Partial), Complete,
        Files, EligibleBytes, TotalBytes, Warnings.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Root,
        [Parameter(Mandatory)]$Config,
        [datetime]$CutoffUtc = [datetime]::MaxValue,
        [switch]$TopLevelOnly,
        [switch]$MetadataOnly
    )

    $policy = $Config.Policy
    $empty = {
        param([string]$Status, [string[]]$Warnings, [bool]$Complete)
        [pscustomobject][ordered]@{
            PSTypeName      = 'WinAdvisor.Inventory'
            Root            = $Root
            Status          = $Status
            Complete        = $Complete
            Files           = @()
            FileCount       = 0
            DirectoryCount  = 0
            EligibleBytes   = [long]0
            TotalBytes      = [long]0
            ProtectedBytes  = [long]0
            RecentBytes     = [long]0
            Scanned         = 0
            Warnings        = @($Warnings)
        }
    }

    $normalizedRoot = $null
    try { $normalizedRoot = Get-WaNormalizedPath -Path $Root } catch {
        return (& $empty 'Blocked' @("Path rejected: $($_.Exception.Message)") $false)
    }

    $cacheKey = $null
    if ($script:WaInventoryCacheEnabled) {
        $cacheKey = Get-WaInventoryCacheKey -Root $normalizedRoot -TopLevelOnly ([bool]$TopLevelOnly)
        if ($script:WaInventoryCache.ContainsKey($cacheKey)) {
            return (Get-WaInventoryView -Scan $script:WaInventoryCache[$cacheKey] -CutoffUtc $CutoffUtc -MetadataOnly:$MetadataOnly)
        }
    }

    if (-not (Test-Path -LiteralPath $normalizedRoot -PathType Container)) {
        # Absent is a complete measurement: the directory genuinely holds nothing.
        if ($cacheKey) {
            $script:WaInventoryCache[$cacheKey] = [pscustomobject]@{
                Root = $normalizedRoot; Status = 'Absent'; Complete = $true; AllFiles = @(); DirectoryCount = 0
                TotalBytes = [long]0; ProtectedBytes = [long]0; Scanned = 0; Warnings = @(); ElapsedMs = 0
            }
        }
        return (& $empty 'Absent' @() $true)
    }
    if (-not (Test-WaPathUnlinked -Path $normalizedRoot)) {
        return (& $empty 'Blocked' @('Root is, or is reached through, a junction, symlink or cloud placeholder.') $false)
    }
    if (Test-WaExcludedPath -Path $normalizedRoot -Config $Config) {
        return (& $empty 'Blocked' @('Root is excluded by configuration.') $false)
    }

    # Precomputed once per scan rather than per file. The expensive protection checks
    # compare a path against every entry in the policy, and doing that for each of tens of
    # thousands of files is what made an earlier version of this scan manage roughly a
    # hundred entries per second.
    #
    # The root is checked against the full policy once. After that, the only protected or
    # excluded paths that can still matter are the ones nested *inside* the root, which is
    # normally an empty set, so the per-file check collapses to nothing.
    if (Test-WaProtectedPath -Path $normalizedRoot -Policy $policy) {
        return (& $empty 'Blocked' @('Root is a policy-protected location.') $false)
    }

    $rootPrefix = $normalizedRoot.TrimEnd('\') + '\'
    $nestedProtected = @(
        foreach ($protected in $policy.ProtectedPaths) {
            if (Test-WaPathWithin -Path $protected -Root $normalizedRoot) { (Get-WaNormalizedPath -Path $protected) + '\' }
        }
    )
    $nestedExcluded = @(
        foreach ($excluded in $Config.ExcludedPaths) {
            if (Test-WaPathWithin -Path $excluded -Root $normalizedRoot) { (Get-WaNormalizedPath -Path $excluded) + '\' }
        }
    )

    $bannedExtensions = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($extension in $policy.NeverDeleteExtensions) { [void]$bannedExtensions.Add([string]$extension) }

    $protectedSegments = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($segment in $policy.ProtectedPathSegments) { [void]$protectedSegments.Add([string]$segment) }

    $files      = New-Object 'System.Collections.Generic.List[object]'
    $warnings   = New-Object 'System.Collections.Generic.List[string]'
    $pending    = New-Object 'System.Collections.Generic.Queue[string]'
    $stopwatch  = [Diagnostics.Stopwatch]::StartNew()

    $complete        = $true
    $scanned         = 0
    $directoryCount  = 0
    $eligibleBytes   = [long]0
    $totalBytes      = [long]0
    $protectedBytes  = [long]0
    $recentBytes     = [long]0

    $pending.Enqueue($normalizedRoot)

    while ($pending.Count -gt 0) {
        if ($scanned -ge $Config.MaxEntriesPerRoot -or $stopwatch.Elapsed.TotalSeconds -ge $Config.MaxScanSecondsPerRoot) {
            $complete = $false
            $warnings.Add('Scan budget reached; reported sizes are lower bounds.')
            break
        }

        $directory = $pending.Dequeue()

        try {
            # EnumerateFileSystemInfos returns objects whose attributes, length and
            # timestamps are already populated from the directory entry, which avoids a
            # separate Get-Item round trip per file.
            $directoryInfo = New-Object 'IO.DirectoryInfo' $directory
            foreach ($item in $directoryInfo.EnumerateFileSystemInfos()) {
                $scanned++
                if ($scanned -ge $Config.MaxEntriesPerRoot -or $stopwatch.Elapsed.TotalSeconds -ge $Config.MaxScanSecondsPerRoot) {
                    $complete = $false
                    $warnings.Add('Scan budget reached; reported sizes are lower bounds.')
                    break
                }

                try {
                    $attributes = [long]$item.Attributes
                    if (($attributes -band $script:WaLinkedOrOfflineAttributeMask) -ne 0) {
                        # Never follow or measure links and cloud placeholders: the bytes
                        # are not really here, and touching a placeholder forces a download.
                        $complete = $false
                        continue
                    }

                    if (($attributes -band [long][IO.FileAttributes]::Directory) -ne 0) {
                        $directoryCount++
                        if (-not $TopLevelOnly) { $pending.Enqueue($item.FullName) }
                        continue
                    }

                    $length = [long]$item.Length
                    $totalBytes += $length

                    $fullPath = [string]$item.FullName

                    # Defensive: a race or a junction could hand back an entry outside the
                    # root. A prefix test is enough here because the root was normalised.
                    if (-not $fullPath.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) { continue }

                    $blocked = $false
                    foreach ($nested in $nestedProtected) {
                        if ($fullPath.StartsWith($nested, [StringComparison]::OrdinalIgnoreCase)) { $blocked = $true; break }
                    }
                    if (-not $blocked) {
                        foreach ($nested in $nestedExcluded) {
                            if ($fullPath.StartsWith($nested, [StringComparison]::OrdinalIgnoreCase)) { $blocked = $true; break }
                        }
                    }
                    if (-not $blocked -and $bannedExtensions.Count -gt 0) {
                        $extension = $item.Extension
                        if ($extension -and $bannedExtensions.Contains($extension)) { $blocked = $true }
                    }
                    if (-not $blocked -and $protectedSegments.Count -gt 0) {
                        foreach ($segment in $fullPath.Substring($rootPrefix.Length).Split([char]92)) {
                            if ($protectedSegments.Contains($segment)) { $blocked = $true; break }
                        }
                    }
                    if ($blocked) { $protectedBytes += $length; continue }

                    # The age cutoff is applied when the view is built, not here, so one
                    # walk can answer for any threshold a provider asks about.
                    $files.Add([pscustomobject][ordered]@{
                        Path            = $fullPath
                        Length          = $length
                        LastWriteUtc    = $item.LastWriteTimeUtc.ToString('o')
                        CreationUtc     = $item.CreationTimeUtc.ToString('o')
                        LastWriteUtcRaw = $item.LastWriteTimeUtc
                        CreationUtcRaw  = $item.CreationTimeUtc
                    })
                } catch {
                    # A file that vanished or denied access mid-walk makes the scan partial.
                    $complete = $false
                }
            }
        } catch {
            # An unreadable subdirectory is normal; record it and carry on with the rest.
            $complete = $false
            $warnings.Add('Some directory contents were not readable.')
        }
    }

    $stopwatch.Stop()
    if (-not $complete -and $warnings.Count -eq 0) {
        $warnings.Add('Scan was incomplete: links, unreadable entries or files that changed during the walk were skipped.')
    }

    $scan = [pscustomobject][ordered]@{
        Root           = $normalizedRoot
        Status         = $(if ($complete) { 'Available' } else { 'Partial' })
        Complete       = $complete
        AllFiles       = $files.ToArray()
        DirectoryCount = $directoryCount
        TotalBytes     = $totalBytes
        ProtectedBytes = $protectedBytes
        Scanned        = $scanned
        Warnings       = @($warnings | Select-Object -Unique)
        ElapsedMs      = [int]$stopwatch.Elapsed.TotalMilliseconds
    }
    if ($cacheKey) { $script:WaInventoryCache[$cacheKey] = $scan }
    return (Get-WaInventoryView -Scan $scan -CutoffUtc $CutoffUtc -MetadataOnly:$MetadataOnly)
}

function Get-WaInventoryView {
    <#
    .SYNOPSIS
        Applies an age cutoff to a completed scan and produces the inventory result.

    .DESCRIPTION
        Splitting the walk from the cutoff means a directory is measured once per session
        however many providers ask about it at different age thresholds.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Scan,
        [datetime]$CutoffUtc = [datetime]::MaxValue,
        [switch]$MetadataOnly
    )

    $eligible = New-Object 'System.Collections.Generic.List[object]'
    $eligibleBytes = [long]0
    $recentBytes = [long]0

    foreach ($file in $Scan.AllFiles) {
        if ($file.LastWriteUtcRaw -ge $CutoffUtc -or $file.CreationUtcRaw -ge $CutoffUtc) {
            $recentBytes += [long]$file.Length
            continue
        }
        $eligibleBytes += [long]$file.Length
        if (-not $MetadataOnly) {
            $eligible.Add([pscustomobject][ordered]@{
                Path         = $file.Path
                Length       = $file.Length
                LastWriteUtc = $file.LastWriteUtc
                CreationUtc  = $file.CreationUtc
            })
        }
    }

    [pscustomobject][ordered]@{
        PSTypeName     = 'WinAdvisor.Inventory'
        Root           = $Scan.Root
        # 'Absent' survives from the scan: a directory that does not exist must not come
        # back from the cache looking like one that exists and happens to be empty.
        Status         = [string]$Scan.Status
        Complete       = $Scan.Complete
        Files          = $eligible.ToArray()
        FileCount      = $eligible.Count
        DirectoryCount = $Scan.DirectoryCount
        EligibleBytes  = $eligibleBytes
        TotalBytes     = $Scan.TotalBytes
        ProtectedBytes = $Scan.ProtectedBytes
        RecentBytes    = $recentBytes
        Scanned        = $Scan.Scanned
        Warnings       = @($Scan.Warnings)
        ElapsedMs      = $Scan.ElapsedMs
    }
}

function Get-WaDirectorySize {
    <#
    .SYNOPSIS
        Measures a directory's total size without building a file manifest.

    .DESCRIPTION
        Cheaper than a full inventory when the answer is only "how big is this". Returns
        $null for Bytes when the directory could not be measured, which is distinct from
        0 for a directory that is genuinely empty.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Path,
        [Parameter(Mandatory)]$Config
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return [pscustomobject]@{ Path = $Path; Bytes = $null; Complete = $false; Status = 'Absent'; Exists = $false }
    }

    $inventory = Get-WaFileInventory -Root $Path -Config $Config -MetadataOnly
    $exists = ($inventory.Status -ne 'Absent')
    $bytes = $inventory.TotalBytes
    if ($inventory.Status -eq 'Blocked') { $bytes = $null }
    if (-not $exists) { $bytes = 0 }

    [pscustomobject][ordered]@{
        Path     = $Path
        Bytes    = $bytes
        Complete = $inventory.Complete
        Status   = $inventory.Status
        Exists   = $exists
        Warnings = $inventory.Warnings
    }
}

function Get-WaStorageCategory {
    <#
    .SYNOPSIS
        Attributes a path to a storage category from its location and file type.

    .DESCRIPTION
        Location wins over extension: a .zip inside a package-manager cache is developer
        tooling, not an archive. Anything that cannot be attributed is reported as
        Unknown rather than guessed into a category, because an "Unknown" line in a report
        is honest and a wrong category invites a bad decision.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $lower = $Path.ToLowerInvariant()

    switch -Regex ($lower) {
        '\\windows\.old(\\|$)'                              { return 'Update leftovers' }
        '\\windows\\softwaredistribution\\'                 { return 'Update leftovers' }
        '\\windows\\winsxs(\\|$)'                           { return 'Component store' }
        '\\windows\\(temp|logs|minidump)(\\|$)'             { return 'Temporary data' }
        '\\windows(\\|$)'                                   { return 'Windows' }
        '\\\$recycle\.bin(\\|$)'                            { return 'Recycle Bin' }
        '\\program files( \(x86\))?(\\|$)'                  { return 'Installed applications' }
        '\\(onedrive|dropbox|google drive|box)(\\|$)'       { return 'Cloud synchronization' }
        '\\(\.nuget|\.npm|\.cargo|\.gradle|\.m2|\.ivy2|\.pnpm-store|\.bun)(\\|$)' { return 'Package-manager caches' }
        '\\(node_modules|site-packages|\.venv)(\\|$)'       { return 'Developer tooling' }
        '\\packages\\.*\\localcache(\\|$)'                  { return 'Application caches' }
        '\\docker(\\|$)'                                    { return 'Containers' }
        '\\(hyper-v|virtualbox vms|vmware)(\\|$)'           { return 'Virtual machines' }
        '\\(crashdumps|wer|minidump)(\\|$)'                 { return 'Crash dumps' }
        '\\(temp|tmp)(\\|$)'                                { return 'Temporary data' }
        '\\downloads(\\|$)'                                 { return 'Downloads' }
        '\\(documents|desktop)(\\|$)'                       { return 'Documents' }
        '\\(pictures|videos|music)(\\|$)'                   { return 'Media' }
        '\\(cache|cache2|code cache|gpucache)(\\|$)'        { return 'Application caches' }
    }

    switch -Regex ([IO.Path]::GetExtension($lower)) {
        '^\.(vhdx?|avhdx|vmdk|vdi|qcow2)$'                  { return 'Virtual machines' }
        '^\.(zip|7z|rar|tar|gz|bz2|xz)$'                    { return 'Archives' }
        '^\.(msi|msix|appx|iso|cab|exe)$'                   { return 'Installers' }
        '^\.(mp4|mov|mkv|avi|mp3|flac|wav|jpg|jpeg|png|heic|raw|psd)$' { return 'Media' }
        '^\.(docx?|xlsx?|pptx?|pdf|txt|md|csv)$'            { return 'Documents' }
        '^\.(dmp|mdmp|hdmp)$'                               { return 'Crash dumps' }
        '^\.(pdb|nupkg|whl|jar|obj|lib|o|rlib)$'            { return 'Developer tooling' }
        '^\.(mdf|ldf|sqlite|sqlite3|db3)$'                  { return 'Databases' }
        '^\.(log|etl|evtx)$'                                { return 'Logs and diagnostics' }
    }

    return 'Unknown'
}

function Get-WaLargeFile {
    <#
    .SYNOPSIS
        Finds files above the configured large-file threshold under explicitly named roots.

    .DESCRIPTION
        Advisory only. Large files are reported with an attributed category so a person can
        decide; nothing here ever proposes deleting one, because size alone says nothing
        about whether a file matters.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$Path,
        [Parameter(Mandatory)]$Config,
        [switch]$Recurse
    )

    $results = New-Object 'System.Collections.Generic.List[object]'
    $status  = New-Object 'System.Collections.Generic.List[object]'

    foreach ($root in ($Path | Select-Object -Unique)) {
        $inventory = Get-WaFileInventory -Root $root -Config $Config -TopLevelOnly:(-not $Recurse)
        $status.Add([pscustomobject]@{
            Path      = $root
            Recursive = [bool]$Recurse
            Status    = $inventory.Status
            Complete  = $inventory.Complete
            Warnings  = $inventory.Warnings
        })

        foreach ($file in $inventory.Files) {
            if ($file.Length -lt $Config.LargeFileThresholdBytes) { continue }
            $results.Add([pscustomobject][ordered]@{
                Path       = $file.Path
                Bytes      = $file.Length
                Category   = (Get-WaStorageCategory -Path $file.Path)
                LastWrite  = $file.LastWriteUtc
                Disposition = 'Advisory only; never proposed for deletion by size.'
            })
        }
    }

    [pscustomobject]@{
        Files      = @($results | Sort-Object Bytes -Descending | Select-Object -First $Config.MaxLargeFiles)
        ScanStatus = $status.ToArray()
    }
}

function Get-WaVolumeFreeSpace {
    <#
    .SYNOPSIS
        Current size and free space for every fixed local volume.

    .DESCRIPTION
        The basis of before/after storage verification. Uses Win32_LogicalDisk with
        DriveType 3 so removable and network drives never appear in a storage total.
    #>
    [CmdletBinding()]
    param()

    @(Get-WaCimData -ClassName 'Win32_LogicalDisk' -Filter 'DriveType=3' `
        -Property @('DeviceID', 'Size', 'FreeSpace', 'FileSystem', 'VolumeName', 'VolumeSerialNumber') |
        ForEach-Object {
            [pscustomobject][ordered]@{
                Drive        = $_.DeviceID
                VolumeName   = $_.VolumeName
                FileSystem   = $_.FileSystem
                SizeBytes    = $_.Size
                FreeBytes    = $_.FreeSpace
                UsedBytes    = $(if ($null -ne $_.Size -and $null -ne $_.FreeSpace) { [long]$_.Size - [long]$_.FreeSpace } else { $null })
                UsedPercent  = (Get-WaPercentage -Part $(if ($null -ne $_.Size -and $null -ne $_.FreeSpace) { [long]$_.Size - [long]$_.FreeSpace } else { $null }) -Whole $_.Size)
                SerialNumber = $_.VolumeSerialNumber
            }
        })
}
