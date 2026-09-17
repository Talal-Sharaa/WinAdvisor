<#
    Providers/Dev.Jvm.ps1 - Gradle, Maven and Coursier caches.

    These tools have no official "clear the cache" command, so their caches are handled as
    file manifests against explicitly named directories.

    The Maven local repository is treated as MODERATE rather than LOW, and the reason is
    specific: mvn install writes locally built artefacts into ~/.m2/repository, and those
    may exist nowhere else. A dependency resolved from Maven Central can always be fetched
    again; a snapshot someone built last week from a branch that has since been rebased
    cannot. That distinction is not visible from the filesystem, so the risk classification
    reflects it rather than pretending the whole directory is disposable.
#>

function Get-WaJvmCacheLocation {
    <#
    .SYNOPSIS
        JVM ecosystem cache directories present on this machine.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session)

    $base = Get-WaBasePaths
    $config = $Session.Config
    $locations = New-Object 'System.Collections.Generic.List[object]'

    if (Get-WaProviderSetting -Config $config -Provider 'Dev.Jvm' -Name 'IncludeGradle' -Default $true) {
        $gradleHome = Join-Path $base.UserProfile '.gradle'
        foreach ($entry in @(
            @{ Sub = 'caches\modules-2';    Title = 'Gradle dependency cache'; Risk = 'LOW';
               Explanation = 'Dependencies Gradle downloaded from remote repositories. Re-resolved on the next build.'
               Consequence = 'The next build of each project re-downloads its dependencies.' }
            @{ Sub = 'caches\build-cache-1'; Title = 'Gradle build cache'; Risk = 'LOW';
               Explanation = 'Cached task outputs Gradle reuses to skip work. Purely a build-time optimisation.'
               Consequence = 'The next build repeats work it would otherwise have skipped, so it takes longer.' }
            @{ Sub = 'daemon';               Title = 'Gradle daemon logs'; Risk = 'LOW';
               Explanation = 'Log files written by Gradle daemon processes.'
               Consequence = 'Historical daemon logs are lost. Keep them if you are debugging a daemon problem right now.' }
            @{ Sub = 'wrapper\dists';        Title = 'Gradle wrapper distributions'; Risk = 'MODERATE';
               Explanation = 'Gradle distributions downloaded by the wrapper, one per version a project has pinned. Each is tens of megabytes.'
               Consequence = 'The next build using a removed version re-downloads that distribution. An offline build of a project pinned to it will fail until then.' }
        )) {
            $path = Join-Path $gradleHome $entry.Sub
            if (-not (Test-Path -LiteralPath $path -PathType Container)) { continue }
            $locations.Add([pscustomobject]@{
                Key = ('dev.jvm.gradle.' + ($entry.Sub -replace '[^A-Za-z0-9]', ''))
                Title = $entry.Title; Path = $path; Risk = $entry.Risk
                Explanation = $entry.Explanation; Consequence = $entry.Consequence; Warnings = @()
            })
        }
    }

    if (Get-WaProviderSetting -Config $config -Provider 'Dev.Jvm' -Name 'IncludeMaven' -Default $true) {
        $mavenRepository = Join-Path $base.UserProfile '.m2\repository'
        if (Test-Path -LiteralPath $mavenRepository -PathType Container) {
            $locations.Add([pscustomobject]@{
                Key = 'dev.jvm.maven.repository'
                Title = 'Maven local repository'
                Path = $mavenRepository
                Risk = 'MODERATE'
                Explanation = 'Artefacts Maven downloaded from remote repositories, plus anything installed locally with mvn install.'
                Consequence = 'Downloaded dependencies are fetched again on the next build. Locally installed artefacts that exist nowhere else must be rebuilt from their source projects.'
                Warnings = @(
                    'mvn install writes locally built artefacts here. Those may not exist in any remote repository, and the filesystem gives no way to tell them apart from downloaded ones.'
                    'Classified MODERATE rather than LOW for exactly that reason. If you build and install snapshots locally, consider skipping this one.'
                )
            })
        }
    }

    if (Get-WaProviderSetting -Config $config -Provider 'Dev.Jvm' -Name 'IncludeCoursier' -Default $true) {
        foreach ($coursierPath in @(
            (Join-Path $base.LocalAppData 'Coursier\cache')
            (Join-Path $base.UserProfile 'AppData\Local\Coursier\Cache')
        )) {
            if (-not (Test-Path -LiteralPath $coursierPath -PathType Container)) { continue }
            $locations.Add([pscustomobject]@{
                Key = 'dev.jvm.coursier'
                Title = 'Coursier cache'
                Path = $coursierPath
                Risk = 'LOW'
                Explanation = 'Artefacts fetched by Coursier, used by sbt, Mill and the Scala toolchain.'
                Consequence = 'Dependencies are fetched again on the next build.'
                Warnings = @()
            })
            break
        }
    }

    return $locations.ToArray()
}

Register-WaProvider -Name 'Dev.Jvm' -Order 330 `
    -Title 'JVM build tool caches' `
    -Category 'Developer tooling' `
    -Description 'Gradle, Maven and Coursier caches. Project directories, build outputs and source trees are never touched.' `
    -Reference 'https://docs.gradle.org/current/userguide/directory_layout.html' `
    -TestAvailable {
        param($Session)
        $locations = @(Get-WaJvmCacheLocation -Session $Session)
        $Session.ProviderState['Dev.Jvm'] = $locations
        if ($locations.Count -eq 0) {
            return (New-WaProviderAvailability -Available $false -Reason 'No Gradle, Maven or Coursier cache directory was found.')
        }
        New-WaProviderAvailability -Available $true -Reason ('{0} cache location(s).' -f $locations.Count)
    } `
    -GetInventory {
        param($Session)
        @(foreach ($location in @($Session.ProviderState['Dev.Jvm'])) {
            $size = Get-WaDirectorySize -Path $location.Path -Config $Session.Config
            New-WaInstalledComponent -Name $location.Title -Category 'Package cache' `
                -InstallPath $location.Path -DetectionMethod 'Directory' -DetectionConfidence 'HIGH' `
                -Note ('{0} measured' -f (Format-WaBytes $size.Bytes))
        })
    } `
    -GetAnalysis {
        param($Session, $Inventory)
        $locations = @($Session.ProviderState['Dev.Jvm'])
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
                -Path $location.Path -Bytes $size.Bytes -Complete $size.Complete -Provider 'Dev.Jvm' -Disposition 'Actionable' `
                -Note $location.Explanation))
        }

        if ($totalBytes -eq 0) { return $output.ToArray() }

        $output.Add((New-WaFinding -Id 'dev.jvm.caches' `
            -Title 'JVM build tool caches' -Category 'Developer tooling' -Provider 'Dev.Jvm' `
            -Description ('Gradle, Maven and Coursier caches hold {0}.' -f (Format-WaBytes $totalBytes)) `
            -Evidence $evidence.ToArray() `
            -CurrentImpact ('{0} of cached dependencies and build outputs.' -f (Format-WaBytes $totalBytes)) `
            -Confidence 'HIGH' -Disposition 'Actionable' -Bytes $totalBytes `
            -Warnings @('The Maven local repository can contain locally built artefacts that exist nowhere else, which is why it is classified MODERATE.')))

        return $output.ToArray()
    } `
    -GetCleanupCandidates {
        param($Session, $Inventory)
        $age = $Session.Config.MinimumCacheAgeDays
        @(foreach ($location in @($Session.ProviderState['Dev.Jvm'])) {
            Get-WaCacheRootCandidate -Session $Session -Provider 'Dev.Jvm' `
                -Key $location.Key -Title $location.Title -Category 'Package-manager caches' `
                -Path $location.Path -AgeDays $age -Risk $location.Risk -Confidence 'HIGH' `
                -Explanation $location.Explanation
        })
    } `
    -GetCleanupPlan {
        param($Session, $Candidates)
        $byKey = @{}
        foreach ($location in @($Session.ProviderState['Dev.Jvm'])) { $byKey[$location.Key] = $location }

        @(foreach ($candidate in $Candidates) {
            $location = $byKey[$candidate.Key]
            if ($null -eq $location) { continue }
            New-WaFileCleanupRecommendation -Session $Session -Candidate $candidate `
                -Consequence $location.Consequence `
                -Warnings @(@($location.Warnings) + @('Project directories, build output and source trees are never included in these manifests.')) `
                -QuestionId 'devtools'
        })
    } `
    -TestResult {
        param($Session, $Results)
        @(foreach ($location in @($Session.ProviderState['Dev.Jvm'])) {
            $size = Get-WaDirectorySize -Path $location.Path -Config $Session.Config
            [pscustomobject]@{
                Provider = 'Dev.Jvm'
                Verified = $true
                Message  = ('{0} now measures {1}.' -f $location.Title, (Format-WaBytes $size.Bytes))
            }
        })
    } | Out-Null
