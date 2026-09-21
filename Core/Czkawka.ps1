<#
    Czkawka 12.0.2 is a scanner, never the deletion executor. Its JSON becomes a
    session-bound manifest. Personal folders are allowed only through this separate
    HIGH-risk, individually approved operation; ordinary cache policy is unchanged.

    Each scan type becomes one plan action. The user picks the exact items on the review
    screen (Core/CzkawkaReview.ps1), the action is rebuilt with only those, and that is what
    gets approved. Every member of a duplicate or similar-image group is a candidate; a
    member is deleted only while another member of its group was left unselected and is
    still unchanged.
#>

$script:WaCzkawkaModes = @('duplicates', 'empty-folders', 'empty-files', 'temporary', 'similar-images', 'broken-files')
$script:WaCzkawkaGroupModes = @('duplicates', 'similar-images')
$script:WaCzkawkaModeLabels = @{
    'duplicates' = 'Duplicate files'; 'similar-images' = 'Similar images'; 'empty-folders' = 'Empty folders'
    'empty-files' = 'Empty files'; 'temporary' = 'Temporary files'; 'broken-files' = 'Broken files'
}
$script:WaCzkawkaReference = 'https://github.com/qarmin/czkawka/releases/tag/12.0.2'

function Get-WaCzkawkaCanonicalPath {
    param([Parameter(Mandatory)][string]$Path)
    $normalized = Get-WaNormalizedPath $Path
    if (-not (Test-WaPathUnlinked $normalized)) { throw "Missing, linked or offline path: $Path" }
    # Czkawka expands Windows 8.3 names in its reports. Resolve both sides identically
    # before containment checks (TEMP commonly contains an abbreviated profile name).
    if (-not $normalized.Contains('~')) { return $normalized }
    $expanded = [IO.Path]::GetPathRoot($normalized)
    foreach ($segment in $normalized.Substring(3).Split('\')) {
        if ($segment.Contains('~')) {
            $expanded = (Get-Item -LiteralPath (Join-Path $expanded $segment) -Force -ErrorAction Stop).FullName
        } else { $expanded = Join-Path $expanded $segment }
    }
    return (Get-WaNormalizedPath $expanded)
}

function Resolve-WaCzkawkaExecutable {
    param([Parameter(Mandatory)]$Session)
    $configured = [string](Get-WaProviderSetting $Session.Config 'External.Czkawka' 'ExecutablePath' '')
    if ($configured) {
        $path = Get-WaNormalizedPath $configured
        if ([IO.Path]::GetExtension($path) -ne '.exe' -or -not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Czkawka ExecutablePath must point to an existing .exe: $path"
        }
        return $path
    }
    $local = Join-Path (Get-WaModuleRoot) 'Tools\Czkawka\windows_czkawka_cli.exe'
    if (Test-Path -LiteralPath $local -PathType Leaf) { return $local }
    $name = [string](Get-WaProviderSetting $Session.Config 'External.Czkawka' 'ExecutableName' 'czkawka_cli')
    $path = Resolve-WaCommandPath -Name $name
    if (-not $path) { $path = Resolve-WaCommandPath -Name 'windows_czkawka_cli.exe' }
    return $path
}

function Get-WaCzkawkaPathPolicy {
    param([Parameter(Mandatory)]$Session)
    $policy = $Session.Config.Policy
    $base = Get-WaBasePaths
    $personal = @($base.Documents)
    foreach ($name in @('Desktop', 'Pictures', 'Videos', 'Music', 'Downloads')) {
        $personal += Join-Path $base.UserProfile $name
    }
    # Only the listed personal folders lose their blanket protection. OS, application,
    # cloud, credentials, repository and extension protections remain in force.
    [pscustomobject]@{
        ProtectedPaths = @($policy.ProtectedPaths | Where-Object { $personal -notcontains $_ })
        ProtectedRootsOnly = $policy.ProtectedRootsOnly
        AllowExactRootMatch = $policy.AllowExactRootMatch
    }
}

function Assert-WaCzkawkaPath {
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)][string]$Path, [switch]$Root)
    $pathValue = Get-WaCzkawkaCanonicalPath $Path
    if ($pathValue -match '[\x00-\x1f]' -or @($pathValue.Split('\') | Where-Object { $_ -match '[ .]$' }).Count -gt 0) {
        throw "Ambiguous path rejected: $Path"
    }
    if (Test-WaProtectedPath $pathValue (Get-WaCzkawkaPathPolicy $Session)) { throw "Protected path: $Path" }
    if (Test-WaProtectedSegment $pathValue $Session.Config.Policy) { throw "Protected directory name: $Path" }
    foreach ($excluded in $Session.Config.ExcludedPaths) {
        $boundary = Get-WaNormalizedPath $excluded
        if (Test-WaPathUnlinked $boundary) { $boundary = Get-WaCzkawkaCanonicalPath $boundary }
        if (Test-WaPathWithin $pathValue $boundary -AllowEqual) { throw "Excluded path: $Path" }
    }
    if (-not (Test-WaPathUnlinked $pathValue)) { throw "Missing, linked or offline path: $Path" }
    $item = Get-Item -LiteralPath $pathValue -Force -ErrorAction Stop
    if ($Root -and -not $item.PSIsContainer) { throw "Scan root is not a directory: $Path" }
    if (-not $Root) {
        if ($Session.ProviderState['External.Czkawka'].Roots -contains $pathValue) { throw "A selected scan root cannot be deleted: $Path" }
        $inside = $false
        foreach ($scope in $Session.ProviderState['External.Czkawka'].Roots) {
            if (Test-WaPathWithin $pathValue $scope) { $inside = $true; break }
        }
        if (-not $inside) { throw "Target is outside the selected roots, or is a root itself: $Path" }
        if (-not $item.PSIsContainer -and (Test-WaProtectedExtension $pathValue $Session.Config.Policy)) {
            throw "Protected file type: $Path"
        }
    }
    $directory = if ($item.PSIsContainer) { $item } else { $item.Directory }
    while ($null -ne $directory) {
        foreach ($marker in @('.git', '.hg', '.svn')) {
            if (Test-Path -LiteralPath (Join-Path $directory.FullName $marker)) { throw "Source repository: $Path" }
        }
        $directory = $directory.Parent
    }
}

function Get-WaCzkawkaScanRoots {
    param([Parameter(Mandatory)]$Session, [System.Collections.Generic.List[string]]$Skipped)
    $useDefaults = @($Session.Config.DeepScanPaths).Count -eq 0
    $paths = if ($useDefaults) {
        @(Get-WaProviderSetting $Session.Config 'External.Czkawka' 'DefaultScanPaths' @())
    } else { @($Session.Config.DeepScanPaths) }
    $basePaths = Get-WaBasePaths
    $roots = @(foreach ($path in $paths) {
        try {
            $expanded = Expand-WaPathToken -Path $path -BasePaths $basePaths
            if ($useDefaults -and (-not $expanded -or -not (Test-Path -LiteralPath $expanded -PathType Container))) { continue }
            $root = Get-WaCzkawkaCanonicalPath $expanded
            Assert-WaCzkawkaPath $Session $root -Root
            $root
        } catch {
            # A rejected folder costs only that folder. Explicit paths never fall back to
            # the defaults, so scope can only shrink; the caller reports what was skipped.
            if ($null -ne $Skipped) { $Skipped.Add($_.Exception.Message) }
        }
    })
    return @($roots | Select-Object -Unique)
}

function Initialize-WaCzkawkaScan {
    param([Parameter(Mandatory)]$Session)
    if (-not $Session.Config.AllowExternalTools) { throw 'Enable Safety.AllowExternalTools to use Czkawka.' }
    if (-not (Test-WaProviderEnabled $Session.Config 'External.Czkawka')) { throw 'The Czkawka provider is disabled.' }
    $modes = @(Get-WaProviderSetting $Session.Config 'External.Czkawka' 'ScanTypes' $script:WaCzkawkaModes)
    if ($modes.Count -eq 0) { throw 'Select at least one Czkawka ScanTypes entry.' }
    foreach ($mode in $modes) {
        if ($script:WaCzkawkaModes -notcontains $mode) { throw "Unknown Czkawka scan type: $mode" }
    }
    $skipped = New-Object 'System.Collections.Generic.List[string]'
    $roots = @(Get-WaCzkawkaScanRoots $Session -Skipped $skipped)
    if ($roots.Count -eq 0) {
        $reasons = if ($skipped.Count -gt 0) { ' (' + ($skipped.ToArray() -join '; ') + ')' } else { '' }
        throw ('Czkawka has no eligible scan folders{0}. Use -DeepScanPath or configure External.Czkawka.DefaultScanPaths.' -f $reasons)
    }

    # Dependency setup is allowed in inspection modes too. It never changes scan targets.
    # Validate enablement and scope first, so disabled or empty scans do not download.
    if (-not (Resolve-WaCzkawkaExecutable $Session)) {
        if (-not [bool](Get-WaProviderSetting $Session.Config 'External.Czkawka' 'AutoDownload' $true)) {
            throw 'Czkawka CLI is missing and AutoDownload is disabled. Run Scripts\Install-Czkawka.ps1 or configure ExecutablePath.'
        }
        try {
            [void](Install-WaCzkawka -DestinationDirectory (Join-Path (Get-WaModuleRoot) 'Tools\Czkawka'))
        } catch {
            throw ('Czkawka automatic download failed: {0} Check internet access and write permission to Tools\Czkawka, then retry.' -f $_.Exception.Message)
        }
    }
    $version = Invoke-WaCatalogProbe -CommandId 'czkawka.version' -Session $Session
    if (-not $version.Available) { throw 'Czkawka CLI is still missing after dependency setup. Check ExecutablePath and Tools\Czkawka.' }
    if ($version.ExitCode -ne 0 -or $version.Output -notmatch '(?m)^czkawka 12\.0\.2\r?$') {
        throw 'This integration requires Czkawka CLI 12.0.2; the installed executable reported a different or unknown version.'
    }
    $Session.ProviderState['External.Czkawka'] = @{
        Roots = $roots; SkippedRoots = $skipped.ToArray(); Modes = @($modes | Select-Object -Unique)
        Candidates = @(); Groups = @{}; ReservedPaths = @{}; Manifests = @{}; Reports = @()
    }
}

function Get-WaCzkawkaFileSnapshot {
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)]$Entry)
    $path = Get-WaCzkawkaCanonicalPath ([string](Get-WaProperty $Entry 'path'))
    Assert-WaCzkawkaPath $Session $path
    $file = Get-Item -LiteralPath $path -Force -ErrorAction Stop
    if ($file.PSIsContainer) { throw "Expected a file: $path" }
    $size = Get-WaProperty $Entry 'size'
    $modified = Get-WaProperty $Entry 'modified_date'
    $epoch = [datetime]::SpecifyKind([datetime]'1970-01-01', [DateTimeKind]::Utc)
    $unixTime = [long][Math]::Floor(($file.LastWriteTimeUtc - $epoch).TotalSeconds)
    if ($null -eq $size -or $null -eq $modified -or [long]$size -ne $file.Length -or [long]$modified -ne $unixTime) {
        throw "File changed since the Czkawka scan: $path"
    }
    $snapshot = [ordered]@{
        Path = $path; Length = [long]$file.Length
        LastWriteUtc = $file.LastWriteTimeUtc.ToString('o'); CreationUtc = $file.CreationTimeUtc.ToString('o')
        Sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256 -ErrorAction Stop).Hash
    }
    # Similar-image reports carry dimensions; the review screen sorts by resolution.
    $width = Get-WaProperty $Entry 'width'
    if ($null -ne $width) {
        $snapshot.Width = [int]$width
        $snapshot.Height = [int](Get-WaProperty $Entry 'height' 0)
    }
    $file.Refresh()
    if ($file.Length -ne $snapshot.Length -or $file.LastWriteTimeUtc.ToString('o') -ne $snapshot.LastWriteUtc) {
        throw "File changed while preparing the review: $path"
    }
    return [pscustomobject]$snapshot
}

function Get-WaCzkawkaEmptyTree {
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)][string]$Path)
    $pending = New-Object 'System.Collections.Generic.Stack[string]'
    $directories = New-Object 'System.Collections.Generic.List[string]'
    $pending.Push((Get-WaCzkawkaCanonicalPath $Path))
    while ($pending.Count -gt 0) {
        $current = $pending.Pop()
        Assert-WaCzkawkaPath $Session $current
        if (-not (Test-Path -LiteralPath $current -PathType Container)) { throw "Directory disappeared: $current" }
        $directories.Add($current)
        if ($directories.Count -gt $Session.Config.MaxEntriesPerRoot) { throw 'Empty-folder tree exceeds the review budget.' }
        foreach ($child in @(Get-ChildItem -LiteralPath $current -Force -ErrorAction Stop)) {
            if (-not $child.PSIsContainer) { throw "Folder contains a file: $($child.FullName)" }
            $pending.Push($child.FullName)
        }
    }
    return @($directories.ToArray() | Sort-Object { $_.Length } -Descending)
}

function ConvertFrom-WaCzkawkaReport {
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)][string]$Mode, [Parameter(Mandatory)][string]$ReportFile)
    $json = Get-Content -LiteralPath $ReportFile -Raw -Encoding UTF8 -ErrorAction Stop
    if ([string]::IsNullOrWhiteSpace($json)) { throw 'Czkawka produced an empty report.' }
    # Preserve an outer array containing just one group on both PowerShell 5.1 and 7.
    $envelope = ConvertFrom-Json -InputObject ('{"results":' + $json + '}') -ErrorAction Stop
    $data = $envelope.results
    $groups = New-Object 'System.Collections.Generic.List[object]'
    if ($Mode -eq 'duplicates') {
        if (-not $json.TrimStart().StartsWith('{')) { throw 'Unexpected duplicate report schema.' }
        foreach ($property in $data.PSObject.Properties) {
            if ($property.Name -notmatch '^\d+$') { throw 'Unexpected duplicate size group.' }
            foreach ($group in $property.Value) { $groups.Add(@{ Entries = @($group) }) }
        }
    } else {
        if (-not $json.TrimStart().StartsWith('[')) { throw 'Unexpected Czkawka report schema.' }
        if ($Mode -eq 'similar-images') {
            foreach ($group in $data) { $groups.Add(@{ Entries = @($group) }) }
        } else {
            foreach ($entry in $data) { $groups.Add(@{ Entries = @($entry) }) }
        }
    }
    foreach ($group in $groups) {
        try {
            $diagnosis = ''
            if ($Mode -eq 'broken-files') {
                $errors = Get-WaProperty $group.Entries[0] 'errors'
                if ($null -eq $errors -or $errors -isnot [pscustomobject]) { throw 'Broken-file report has no validation errors.' }
                $details = @($errors.PSObject.Properties | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.Value) } | ForEach-Object { '{0}: {1}' -f $_.Name, $_.Value })
                if ($details.Count -eq 0) { throw 'Broken-file report has no validation errors.' }
                $diagnosis = $details -join '; '
            }
            if ($Mode -eq 'empty-folders') {
                if ($group.Entries[0] -isnot [string]) { throw 'Expected an empty-directory path.' }
                $path = Get-WaCzkawkaCanonicalPath $group.Entries[0]
                $targets = @($path)
                if ($Session.ProviderState['External.Czkawka'].Roots -contains $path) {
                    # Czkawka collapses a wholly empty tree to the selected root. Preserve
                    # that root and offer its empty children instead.
                    Assert-WaCzkawkaPath $Session $path -Root
                    $children = @(Get-ChildItem -LiteralPath $path -Force -ErrorAction Stop)
                    if (@($children | Where-Object { -not $_.PSIsContainer }).Count -gt 0) { throw 'Selected empty root now contains files.' }
                    $targets = @($children | ForEach-Object { $_.FullName })
                }
                foreach ($target in $targets) {
                    $tree = @(Get-WaCzkawkaEmptyTree $Session $target)
                    [pscustomobject]@{ Mode = $Mode; Target = [pscustomobject]@{ Path = $target; Length = 0 }; Group = ''; Directories = $tree; ReportFile = $ReportFile; Diagnosis = '' }
                }
                continue
            }
            $files = @($group.Entries | ForEach-Object { Get-WaCzkawkaFileSnapshot $Session $_ })
            $groupKey = ''
            if ($script:WaCzkawkaGroupModes -contains $Mode) {
                if ($files.Count -lt 2 -or @($files.Path | Select-Object -Unique).Count -ne $files.Count) { throw 'Invalid or repeated group members.' }
                if ($Mode -eq 'duplicates' -and @($files.Sha256 | Select-Object -Unique).Count -ne 1) { throw 'Duplicate content no longer matches.' }
                # Every member is a candidate: which copy stays is chosen on the review screen.
                $files = @($files | Sort-Object Path)
                $groupKey = $Mode + ':' + (Get-WaHash -Text ($files.Path -join "`n")).Substring(0, 16)
            }
            foreach ($file in $files) {
                if ($Mode -eq 'empty-files' -and $file.Length -ne 0) { throw 'Empty-file report includes a nonempty file.' }
                if ($Mode -eq 'temporary') {
                    $cutoff = [datetime]::UtcNow.AddDays(-[Math]::Max(0, $Session.Config.MinimumTempAgeDays))
                    if ([datetime]$file.LastWriteUtc -gt $cutoff -or [datetime]$file.CreationUtc -gt $cutoff) { continue }
                }
                [pscustomobject]@{ Mode = $Mode; Target = $file; Group = $groupKey; Directories = @(); ReportFile = $ReportFile; Diagnosis = $diagnosis }
            }
        } catch {
            Write-WaLog -Session $Session -Level 'Warning' -Category 'Czkawka' -Message ('Report group left for manual review: ' + $_.Exception.Message)
            Add-WaSessionWarning -Session $Session -Message ('Czkawka: ' + $_.Exception.Message)
        }
    }
}

function Invoke-WaCzkawkaScans {
    param([Parameter(Mandatory)]$Session)
    $state = $Session.ProviderState['External.Czkawka']
    # A fresh analysis invalidates all earlier manifests, even when a new scan fails.
    $state.Candidates = @(); $state.Groups = @{}; $state.ReservedPaths = @{}; $state.Manifests = @{}; $state.Reports = @()
    $all = New-Object 'System.Collections.Generic.List[object]'
    $reportDirectory = Join-Path (Get-WaDataRoot -Create) ('Reports\Czkawka\' + $Session.Id)
    [void](New-Item -ItemType Directory -Path $reportDirectory -Force)
    Write-Host '  Czkawka scan folders:' -ForegroundColor DarkGray
    foreach ($root in $state.Roots) { Write-Host ('    ' + $root) -ForegroundColor DarkGray }
    $skipped = @(Get-WaProperty $state 'SkippedRoots' @())
    foreach ($reason in $skipped) { Write-Host ('    not scanned: ' + $reason) -ForegroundColor Yellow }
    if ($skipped.Count -gt 0) {
        New-WaFinding -Id 'external.czkawka.skipped-folders' -Title 'Czkawka skipped some scan folders' -Category 'Storage' -Provider 'External.Czkawka' `
            -Description ('{0} folder(s) were not scanned. The other {1} were scanned as usual.' -f $skipped.Count, @($state.Roots).Count) `
            -Evidence @(foreach ($reason in $skipped) {
                New-WaEvidence -Source 'Czkawka scan folder check' -Method 'WinAdvisor path policy' -Statement $reason
            }) `
            -Confidence 'HIGH' -Disposition 'Informational'
    }
    foreach ($mode in $state.Modes) {
        $report = Join-Path $reportDirectory ($mode + '-' + [guid]::NewGuid().ToString('N') + '.json')
        try {
            $resolved = Resolve-WaCommand -CommandId ('czkawka.' + $mode) -Session $Session -Values @{ Directory = $state.Roots[0]; ReportFile = $report }
            $arguments = @($resolved.Arguments)
            foreach ($root in @($state.Roots | Select-Object -Skip 1)) { $arguments += @('--directories', $root) }
            foreach ($excluded in @($Session.Config.ExcludedPaths) + @((Get-WaCzkawkaPathPolicy $Session).ProtectedPaths)) {
                $arguments += @('--excluded-directories', (Get-WaNormalizedPath $excluded))
            }
            foreach ($segment in $Session.Config.Policy.ProtectedPathSegments) {
                $arguments += @('--excluded-items', ('*\' + $segment + '\*'))
            }
            Write-Host ('  Czkawka: scanning {0} in {1} folder(s)...' -f $mode, $state.Roots.Count) -ForegroundColor DarkGray
            $probe = Invoke-WaNativeProcess -FilePath $resolved.FilePath -Arguments $arguments -TimeoutSeconds $resolved.TimeoutSeconds `
                -OnHeartbeat { param($elapsed) Write-Host ('    Czkawka is still scanning ({0:N0}s).' -f $elapsed.TotalSeconds) -ForegroundColor DarkGray } -HeartbeatSeconds 15
            if ($probe.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $report -PathType Leaf)) {
                throw ('Scan failed or JSON report is missing (exit {0}). {1}' -f $probe.ExitCode, $probe.Error)
            }
            $candidates = @(ConvertFrom-WaCzkawkaReport $Session $mode $report)
            foreach ($candidate in $candidates) { $all.Add($candidate) }
            $state.Reports += $report
            New-WaFinding -Id ('external.czkawka.' + $mode) -Title ('Czkawka: ' + $mode) -Category 'Storage' -Provider 'External.Czkawka' `
                -Description ('Scan completed; {0} candidate(s) before overlap filtering. Report: {1}' -f $candidates.Count, $report) `
                -Confidence 'HIGH' -Disposition 'Advisory' -Evidence @(
                    New-WaEvidence -Source $report -Method 'Czkawka 12.0.2 JSON' -Statement 'Exact paths are chosen on the review screen before deletion.' -Measured $true
                ) -Warnings @($(if ($probe.Error) { $probe.Error.Trim() }))
        } catch {
            New-WaFinding -Id ('external.czkawka.failed.' + $mode) -Title ('Czkawka scan failed: ' + $mode) -Category 'Storage' -Provider 'External.Czkawka' `
                -Description $_.Exception.Message -Confidence 'UNKNOWN' -Disposition 'Informational'
        }
    }
    Register-WaCzkawkaCandidates -Session $Session -Candidates $all.ToArray()
}

function Register-WaCzkawkaCandidates {
    <#
        Records the session's candidates and the members of each group. A path can turn up
        under several scan types (an exact duplicate is usually also a similar image); the
        first type claims it, and a group left with one member has nothing to compare.
    #>
    param([Parameter(Mandatory)]$Session, [object[]]$Candidates = @())
    $state = $Session.ProviderState['External.Czkawka']
    $state.Groups = @{}
    $byGroup = New-Object 'System.Collections.Specialized.OrderedDictionary'
    foreach ($candidate in $Candidates) {
        $key = if ($candidate.Group) { $candidate.Group } else { 'item:' + $candidate.Mode + ':' + $candidate.Target.Path }
        if (-not $byGroup.Contains($key)) { $byGroup[$key] = New-Object 'System.Collections.Generic.List[object]' }
        $byGroup[$key].Add($candidate)
    }
    $seen = @{}
    $kept = New-Object 'System.Collections.Generic.List[object]'
    foreach ($key in $byGroup.Keys) {
        $members = @($byGroup[$key].ToArray() | Where-Object { -not $seen.ContainsKey($_.Target.Path) })
        $grouped = [bool]$byGroup[$key][0].Group
        if ($members.Count -eq 0 -or ($grouped -and $members.Count -lt 2)) { continue }
        foreach ($member in $members) { $seen[$member.Target.Path] = $true; $kept.Add($member) }
        if ($grouped) { $state.Groups[$key] = @($members | ForEach-Object { $_.Target }) }
    }
    $state.Candidates = $kept.ToArray()
}

function Test-WaCzkawkaGroupMode {
    param([string]$Mode)
    return ($script:WaCzkawkaGroupModes -contains $Mode)
}

function Get-WaCzkawkaModeLabel {
    param([Parameter(Mandatory)][string]$Mode)
    return [string]$script:WaCzkawkaModeLabels[$Mode]
}

function New-WaCzkawkaOperation {
    <# One exact deletion, registered in the session manifest so it cannot be edited later. #>
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)]$Candidate)
    $parameters = [ordered]@{
        Mode = $Candidate.Mode; Target = $Candidate.Target; Group = [string](Get-WaProperty $Candidate 'Group' '')
        Directories = @($Candidate.Directories); Diagnosis = [string](Get-WaProperty $Candidate 'Diagnosis' '')
        ReportFile = [string]$Candidate.ReportFile
    }
    $operation = New-WaOperation -Kind 'CzkawkaDelete' -Description ('Delete exactly ' + $Candidate.Target.Path) -Parameters $parameters
    $signature = Get-WaHash -Text (ConvertTo-WaJson (Get-WaOperationFingerprintMaterial $operation) -Depth 16 -Compress)
    $Session.ProviderState['External.Czkawka'].Manifests[$Candidate.Target.Path] = $signature
    return $operation
}

function New-WaCzkawkaPlanRecommendations {
    <# One recommendation per scan type, holding every candidate of that type. #>
    param([Parameter(Mandatory)]$Session, [object[]]$Candidates = @())
    foreach ($mode in $script:WaCzkawkaModes) {
        $operations = @($Candidates | Where-Object { $_.Mode -eq $mode } | ForEach-Object { New-WaCzkawkaOperation $Session $_ })
        if ($operations.Count -gt 0) { New-WaCzkawkaModeRecommendation -Session $Session -Mode $mode -Operations $operations }
    }
}

function New-WaCzkawkaModeRecommendation {
    <#
        At plan time Operations is every candidate of one scan type. After the review screen
        it is only the selected ones, with CandidateCount set to how many were offered; that
        narrowed recommendation is the one that gets approved and run.
    #>
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)][string]$Mode,
        [Parameter(Mandatory)][object[]]$Operations,
        [int]$CandidateCount = 0
    )
    $label = Get-WaCzkawkaModeLabel $Mode
    $count = $Operations.Count
    $noun = if ($Mode -eq 'empty-folders') { 'folder(s)' } else { 'file(s)' }
    $bytes = [long](($Operations | ForEach-Object { [long]$_.Parameters.Target.Length }) | Measure-Object -Sum).Sum
    $groupCount = @($Operations | ForEach-Object { $_.Parameters.Group } | Where-Object { $_ } | Select-Object -Unique).Count
    $inGroups = if ($groupCount -gt 0) { ' in {0} group(s)' -f $groupCount } else { '' }
    $narrowed = $CandidateCount -gt 0

    $warning = switch ($Mode) {
        'similar-images' { 'Visual similarity is not byte equality. Compare the images in a group before selecting; they may be different photographs.' }
        'duplicates' { 'An identical copy may be an intentional backup. Leave a path unselected if it is still needed.' }
        'empty-folders' { 'Applications may expect these empty directories to exist.' }
        'empty-files' { 'An empty file may be a marker, lock or application placeholder.' }
        'temporary' { 'Czkawka classifies temporary files by name. Review whether each file is disposable.' }
        'broken-files' { 'A validation or decoding error does not prove a file is unrecoverable. Inspect or back up a file before selecting it.' }
    }
    $warnings = @($warning)
    if (Test-WaCzkawkaGroupMode $Mode) {
        $warnings += 'A file is deleted only while another file in its group was left unselected and is still unchanged. Selecting every file in a group is refused.'
    }

    if ($narrowed) {
        $title = '{0}: delete {1} of {2}' -f $label, $count, $CandidateCount
        $description = 'Permanently delete the {0} {1}{2} selected on the review screen.' -f $count, $noun, $inGroups
        $preview = 'Delete {0} literal path(s) chosen on the review screen.' -f $count
    } else {
        $title = '{0}: {1} {2}{3}' -f $label, $count, $noun, $inGroups
        $description = 'Czkawka found {0} {1}{2}. Nothing is deleted until you select exact items on the review screen and confirm.' -f $count, $noun, $inGroups
        $preview = 'Delete only the literal paths you select on the review screen.'
    }

    # Evidence is capped so a large result set does not flood the report; the Czkawka
    # JSON report named here holds the complete list.
    $shown = 50
    $evidence = @(foreach ($operation in @($Operations | Select-Object -First $shown)) {
        $p = $operation.Parameters
        New-WaEvidence -Source $p.ReportFile -Method 'Czkawka 12.0.2 JSON and local revalidation' `
            -Statement ('{0} ({1}){2}' -f $p.Target.Path, (Format-WaBytes ([long]$p.Target.Length)), $(if ($p.Diagnosis) { ' Validation error: ' + $p.Diagnosis })) `
            -Value ([long]$p.Target.Length) -Unit 'bytes'
    })
    if ($count -gt $shown) {
        $evidence += New-WaEvidence -Source $Operations[0].Parameters.ReportFile -Method 'Czkawka 12.0.2 JSON' `
            -Statement ('... and {0} more; the Czkawka report lists every one.' -f ($count - $shown))
    }

    New-WaRecommendation -Id ('external.czkawka.delete.' + $Mode) -Title $title -Category 'Storage' -Provider 'External.Czkawka' `
        -Description $description -Risk 'HIGH' `
        -Confidence $(if ($Mode -in @('similar-images', 'broken-files')) { 'MEDIUM' } else { 'HIGH' }) `
        -EstimatedBytes $bytes -EstimatedBenefit ('Remove up to {0} of logical file data; actual free-space change is measured separately.' -f (Format-WaBytes $bytes)) `
        -Operations $Operations -CommandPreview $preview `
        -Mechanism 'Czkawka JSON discovery; WinAdvisor validates and deletes each exact approved target.' `
        -IndividualApprovalRequired $true -AffectsPersonalData $true -Reversibility 'Irreversible' `
        -RollbackNote 'No rollback or Recycle Bin recovery. System Restore does not restore these files.' `
        -Consequence 'The selected content is permanently removed.' -Warnings $warnings `
        -Evidence $evidence -Reference $script:WaCzkawkaReference
}

function Assert-WaCzkawkaSnapshot {
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)]$Snapshot)
    Assert-WaCzkawkaPath $Session $Snapshot.Path
    $file = Get-Item -LiteralPath $Snapshot.Path -Force -ErrorAction Stop
    if ($file.PSIsContainer -or $file.Length -ne $Snapshot.Length -or
        $file.LastWriteTimeUtc.ToString('o') -ne $Snapshot.LastWriteUtc -or $file.CreationTimeUtc.ToString('o') -ne $Snapshot.CreationUtc -or
        (Get-FileHash -LiteralPath $Snapshot.Path -Algorithm SHA256 -ErrorAction Stop).Hash -ne $Snapshot.Sha256) {
        throw "File changed since review: $($Snapshot.Path)"
    }
}

function Get-WaCzkawkaRetainedCopy {
    <#
        The group member that stays when the target is deleted: one the user left unselected
        (reserved, so nothing in this session can delete it), still present and unchanged,
        and for duplicates still byte-identical. With -Keeper only that member is accepted.
    #>
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)]$Parameters, $Keeper = $null)
    $state = $Session.ProviderState['External.Czkawka']
    $target = $Parameters.Target
    $members = @()
    if ($Parameters.Group -and $state.Groups.ContainsKey($Parameters.Group)) { $members = @($state.Groups[$Parameters.Group]) }
    if (@($members | Where-Object { $_.Path -eq $target.Path }).Count -ne 1) { throw 'Target is not a member of a scanned group.' }
    $kept = @($members | Where-Object { $_.Path -ne $target.Path -and $state.ReservedPaths.ContainsKey($_.Path) })
    if ($null -ne $Keeper) { $kept = @($kept | Where-Object { $_.Path -eq $Keeper.Path }) }
    if ($kept.Count -eq 0) { throw 'No other file in this group was left unselected to keep.' }
    $reasons = New-Object 'System.Collections.Generic.List[string]'
    foreach ($copy in $kept) {
        try {
            Assert-WaCzkawkaSnapshot $Session $copy
            if ($Parameters.Mode -eq 'duplicates' -and $copy.Sha256 -ne $target.Sha256) { throw "Duplicate contents no longer match: $($copy.Path)" }
            return $copy
        } catch {
            $reasons.Add($_.Exception.Message)
        }
    }
    throw ('No kept file in this group is still present and unchanged. ' + ($reasons.ToArray() -join ' '))
}

function Assert-WaCzkawkaCandidate {
    <# Throws unless the operation may run now. Returns the kept copy for group modes. #>
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)]$Operation, $Keeper = $null)
    if (-not $Session.Config.AllowExternalTools -or -not (Test-WaProviderEnabled $Session.Config 'External.Czkawka')) { throw 'Czkawka is disabled.' }
    $state = $Session.ProviderState['External.Czkawka']
    if ($null -eq $state) { throw 'No Czkawka scan exists in this session.' }
    $parameters = $Operation.Parameters
    $target = $parameters.Target
    $signature = Get-WaHash -Text (ConvertTo-WaJson (Get-WaOperationFingerprintMaterial $Operation) -Depth 16 -Compress)
    if (-not $state.Manifests.ContainsKey($target.Path) -or $state.Manifests[$target.Path] -ne $signature) { throw 'Candidate does not match the session scan manifest.' }
    $configuredRoots = @(Get-WaCzkawkaScanRoots $Session)
    foreach ($root in $state.Roots) {
        if ($configuredRoots -notcontains $root) { throw 'Selected scan roots changed; scan again.' }
        Assert-WaCzkawkaPath $Session $root -Root
    }
    Assert-WaCzkawkaPath $Session $target.Path
    if ($state.ReservedPaths.ContainsKey($target.Path)) { throw 'This file is reserved as a retained copy.' }
    if ($parameters.Mode -eq 'empty-folders') {
        $current = @(Get-WaCzkawkaEmptyTree $Session $target.Path)
        if (@(Compare-Object $current @($parameters.Directories)).Count -ne 0) { throw 'Empty-directory tree changed since review.' }
    } else {
        Assert-WaCzkawkaSnapshot $Session $target
        if ($parameters.Mode -eq 'empty-files' -and $target.Length -ne 0) { throw 'File is no longer empty.' }
        if ($parameters.Mode -eq 'temporary') {
            $cutoff = [datetime]::UtcNow.AddDays(-[Math]::Max(0, $Session.Config.MinimumTempAgeDays))
            if ([datetime]$target.LastWriteUtc -gt $cutoff -or [datetime]$target.CreationUtc -gt $cutoff) { throw 'Temporary file is too recent.' }
        }
        if (Test-WaCzkawkaGroupMode $parameters.Mode) {
            return (Get-WaCzkawkaRetainedCopy -Session $Session -Parameters $parameters -Keeper $Keeper)
        }
    }
}
