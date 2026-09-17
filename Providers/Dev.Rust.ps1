<#
    Providers/Dev.Rust.ps1 - Cargo registry caches.

    Cargo has no official cache-clearing command in the standard toolchain, so these are
    handled as file manifests against explicitly named directories under CARGO_HOME.

    Scope is the registry cache and extracted sources only. Deliberately excluded:

      target/          project build output. It is per-project, it is not under CARGO_HOME,
                       and deciding it is disposable is a project owner's call, not a
                       maintenance tool's.
      .cargo/bin       installed binaries from cargo install. Removing them uninstalls
                       working tools.
      .cargo/git       checkouts of git dependencies, which may reference commits no longer
                       reachable from any branch. Reported, never proposed.
#>

function Get-WaCargoCacheLocation {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session)

    $cargoHome = $env:CARGO_HOME
    if ([string]::IsNullOrWhiteSpace($cargoHome)) {
        $cargoHome = Join-Path (Get-WaBasePaths).UserProfile '.cargo'
    }
    if (-not (Test-Path -LiteralPath $cargoHome -PathType Container)) { return @() }

    $locations = New-Object 'System.Collections.Generic.List[object]'
    foreach ($entry in @(
        @{ Sub = 'registry\cache'; Title = 'Cargo registry archive cache'; Risk = 'LOW'
           Explanation = 'Compressed .crate archives downloaded from the registry. Re-downloaded on demand.'
           Consequence = 'The next build re-downloads the crates it needs.' }
        @{ Sub = 'registry\src'; Title = 'Cargo extracted crate sources'; Risk = 'LOW'
           Explanation = 'Crate sources extracted from the downloaded archives. Cargo re-extracts them from the archive cache, or re-downloads if that is gone too.'
           Consequence = 'The next build re-extracts or re-downloads crate sources.' }
        @{ Sub = 'registry\index'; Title = 'Cargo registry index cache'; Risk = 'LOW'
           Explanation = 'Cached registry index metadata. Refetched automatically.'
           Consequence = 'The next build refreshes the registry index, which takes a little longer.' }
    )) {
        $path = Join-Path $cargoHome $entry.Sub
        if (-not (Test-Path -LiteralPath $path -PathType Container)) { continue }
        $locations.Add([pscustomobject]@{
            Key = ('dev.rust.' + ($entry.Sub -replace '[^A-Za-z0-9]', ''))
            Title = $entry.Title; Path = $path; Risk = $entry.Risk
            Explanation = $entry.Explanation; Consequence = $entry.Consequence
        })
    }

    return $locations.ToArray()
}

Register-WaProvider -Name 'Dev.Rust' -Order 340 `
    -Title 'Cargo caches' `
    -Category 'Developer tooling' `
    -Description 'Cargo registry archive, source and index caches. Project target directories, installed binaries and git dependency checkouts are never touched.' `
    -Reference 'https://doc.rust-lang.org/cargo/guide/cargo-home.html' `
    -TestAvailable {
        param($Session)
        $locations = @(Get-WaCargoCacheLocation -Session $Session)
        $Session.ProviderState['Dev.Rust'] = $locations
        if ($locations.Count -eq 0) {
            return (New-WaProviderAvailability -Available $false -Reason 'No Cargo home directory with caches was found.')
        }
        New-WaProviderAvailability -Available $true -Reason ('{0} cache location(s).' -f $locations.Count)
    } `
    -GetInventory {
        param($Session)
        @(foreach ($location in @($Session.ProviderState['Dev.Rust'])) {
            $size = Get-WaDirectorySize -Path $location.Path -Config $Session.Config
            New-WaInstalledComponent -Name $location.Title -Category 'Package cache' `
                -Vendor 'Rust' -InstallPath $location.Path -DetectionMethod 'Directory' `
                -Note ('{0} measured' -f (Format-WaBytes $size.Bytes))
        })
    } `
    -GetAnalysis {
        param($Session, $Inventory)
        $locations = @($Session.ProviderState['Dev.Rust'])
        if ($locations.Count -eq 0) { return @() }

        $output = New-Object 'System.Collections.Generic.List[object]'
        $evidence = New-Object 'System.Collections.Generic.List[object]'
        $totalBytes = [long]0

        foreach ($location in $locations) {
            $size = Get-WaDirectorySize -Path $location.Path -Config $Session.Config
            if ($null -eq $size.Bytes) { continue }
            $totalBytes += [long]$size.Bytes
            $evidence.Add((New-WaEvidence -Source $location.Path -Method 'Bounded filesystem enumeration' `
                -Statement ('{0}: {1}.' -f $location.Title, (Format-WaBytes $size.Bytes)) -Value $size.Bytes -Unit 'bytes' -Complete $size.Complete))
            $output.Add((New-WaStorageConsumer -Name $location.Title -Category 'Package-manager caches' `
                -Path $location.Path -Bytes $size.Bytes -Complete $size.Complete -Provider 'Dev.Rust' -Disposition 'Actionable' `
                -Note $location.Explanation))
        }

        if ($totalBytes -eq 0) { return $output.ToArray() }

        $output.Add((New-WaFinding -Id 'dev.rust.caches' `
            -Title 'Cargo caches' -Category 'Developer tooling' -Provider 'Dev.Rust' `
            -Description ('Cargo registry caches hold {0}.' -f (Format-WaBytes $totalBytes)) `
            -Evidence $evidence.ToArray() `
            -CurrentImpact ('{0} of downloaded and extracted crate data.' -f (Format-WaBytes $totalBytes)) `
            -Confidence 'HIGH' -Disposition 'Actionable' -Bytes $totalBytes `
            -Warnings @(
                'Project target directories are usually far larger than these caches and are never touched: they are project state, and cargo clean is the right tool for them.'
                'Git dependency checkouts under .cargo/git are also excluded, because they can reference commits no longer reachable from any branch.'
            )))

        return $output.ToArray()
    } `
    -GetCleanupCandidates {
        param($Session, $Inventory)
        $age = $Session.Config.MinimumCacheAgeDays
        @(foreach ($location in @($Session.ProviderState['Dev.Rust'])) {
            Get-WaCacheRootCandidate -Session $Session -Provider 'Dev.Rust' `
                -Key $location.Key -Title $location.Title -Category 'Package-manager caches' `
                -Path $location.Path -AgeDays $age -Risk $location.Risk -Confidence 'HIGH' `
                -Explanation $location.Explanation
        })
    } `
    -GetCleanupPlan {
        param($Session, $Candidates)
        $byKey = @{}
        foreach ($location in @($Session.ProviderState['Dev.Rust'])) { $byKey[$location.Key] = $location }

        @(foreach ($candidate in $Candidates) {
            $location = $byKey[$candidate.Key]
            if ($null -eq $location) { continue }
            New-WaFileCleanupRecommendation -Session $Session -Candidate $candidate `
                -Consequence $location.Consequence `
                -Warnings @('An offline build will fail until the crates are downloaded again.') `
                -QuestionId 'devtools'
        })
    } `
    -TestResult {
        param($Session, $Results)
        @(foreach ($location in @($Session.ProviderState['Dev.Rust'])) {
            $size = Get-WaDirectorySize -Path $location.Path -Config $Session.Config
            [pscustomobject]@{
                Provider = 'Dev.Rust'
                Verified = $true
                Message  = ('{0} now measures {1}.' -f $location.Title, (Format-WaBytes $size.Bytes))
            }
        })
    } | Out-Null
