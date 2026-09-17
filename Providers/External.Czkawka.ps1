<#
    Providers/External.Czkawka.ps1 - duplicate file detection via Czkawka, advisory only.

    Duplicate detection is a good example of where delegating beats reimplementing.
    Czkawka's duplicate finder is fast, well tested and does size-then-hash grouping
    properly. Writing that in PowerShell would be slower and less correct.

    What this provider does NOT do is act on the result. Duplicates in personal data are
    exactly the case where a tool cannot know which copy matters: the "duplicate" may be the
    only backup, or the copy a running application has open. Czkawka is invoked in
    report-only mode, and the deletion arguments are not in the command catalog at all, so
    there is no configuration that turns this into a deleting provider.

    Three gates before it runs, all of which must pass:
      1. Providers.External.Czkawka.Enabled          (false by default)
      2. Safety.AllowExternalTools                   (false by default)
      3. czkawka_cli present on PATH                 (never installed by WinAdvisor)

    Czkawka is MIT-licensed, which permits this kind of invocation without any licence
    obligation on WinAdvisor. It is invoked as a separate process; no Czkawka code is
    copied or linked. See docs/RESEARCH.md.
#>

Register-WaProvider -Name 'External.Czkawka' -Order 500 `
    -Title 'Duplicate file detection (Czkawka)' `
    -Category 'Storage' `
    -Description 'Optional. Uses an already-installed Czkawka CLI to report duplicate files in a directory you name. Report only: no deletion argument is ever passed, and none exists in the command catalog.' `
    -ExternalDependency 'czkawka_cli' `
    -AdvisoryOnly $true `
    -Reference 'https://github.com/qarmin/czkawka/blob/master/czkawka_cli/README.md' `
    -TestAvailable {
        param($Session)
        if (-not $Session.Config.AllowExternalTools) {
            return (New-WaProviderAvailability -Available $false -Reason 'External tools are not enabled. Set Safety.AllowExternalTools to true in your configuration to allow them.')
        }
        $executableName = [string](Get-WaProviderSetting -Config $Session.Config -Provider 'External.Czkawka' -Name 'ExecutableName' -Default 'czkawka_cli')
        $path = Resolve-WaCommandPath -Name $executableName
        if (-not $path) {
            return (New-WaProviderAvailability -Available $false -Reason ("'{0}' was not found on PATH. WinAdvisor never downloads or installs it; install it yourself from the project's releases if you want duplicate detection." -f $executableName))
        }
        if (@($Session.Config.DeepScanPaths).Count -eq 0) {
            return (New-WaProviderAvailability -Available $false -Reason 'Duplicate detection needs a directory to examine. Rerun with -DeepScanPath pointing at one.')
        }
        New-WaProviderAvailability -Available $true -Reason ('Using {0}.' -f $path)
    } `
    -GetInventory {
        param($Session)
        $executableName = [string](Get-WaProviderSetting -Config $Session.Config -Provider 'External.Czkawka' -Name 'ExecutableName' -Default 'czkawka_cli')
        @(New-WaInstalledComponent -Name 'Czkawka CLI' -Category 'External tool' `
            -Executable (Resolve-WaCommandPath -Name $executableName) -DetectionMethod 'Command' -DetectionConfidence 'MEDIUM' `
            -Note 'User-installed. WinAdvisor never installs it.')
    } `
    -GetAnalysis {
        param($Session, $Inventory)
        $paths = @($Session.Config.DeepScanPaths)
        if ($paths.Count -eq 0) { return @() }

        $reportDirectory = Join-Path (Get-WaDataRoot -Create) 'Reports'
        if (-not (Test-Path -LiteralPath $reportDirectory -PathType Container)) {
            [void](New-Item -ItemType Directory -Path $reportDirectory -Force)
        }

        $findings = New-Object 'System.Collections.Generic.List[object]'
        foreach ($path in $paths) {
            $reportFile = Join-Path $reportDirectory ('duplicates-{0}-{1}.txt' -f $Session.Id, (Get-WaHash -Text $path).Substring(0, 8))

            $probe = $null
            try {
                $probe = Invoke-WaCatalogProbe -CommandId 'czkawka.duplicates' -Session $Session -Values @{
                    Directory  = $path
                    ReportFile = $reportFile
                }
            } catch {
                $findings.Add((New-WaFinding -Id ('external.czkawka.error.' + (Get-WaHash -Text $path).Substring(0, 8)) `
                    -Title 'Duplicate detection did not run' -Category 'Storage' -Provider 'External.Czkawka' `
                    -Description ('Czkawka could not be invoked for {0}: {1}' -f $path, $_.Exception.Message) `
                    -Confidence 'UNKNOWN' -Disposition 'Informational'))
                continue
            }

            if (-not $probe.Available -or $probe.ExitCode -ne 0) {
                $findings.Add((New-WaFinding -Id ('external.czkawka.failed.' + (Get-WaHash -Text $path).Substring(0, 8)) `
                    -Title 'Duplicate detection did not complete' -Category 'Storage' -Provider 'External.Czkawka' `
                    -Description ('Czkawka returned exit code {0} for {1}. No duplicate information is available, and nothing is proposed.' -f $probe.ExitCode, $path) `
                    -Evidence @(New-WaEvidence -Source 'czkawka_cli' -Method 'External tool' `
                        -Statement (Get-WaRedactedText -Text ([string]$probe.Error)) -Measured $false) `
                    -Confidence 'UNKNOWN' -Disposition 'Informational'))
                continue
            }

            # Output format belongs to Czkawka and can change between versions, so the
            # summary is extracted conservatively and the full report is left on disk for
            # the user to read rather than being reinterpreted here.
            $output = [string]$probe.Output
            $summaryLine = @($output -split "`r?`n" | Where-Object { $_ -match '(?i)found|duplicat' }) | Select-Object -First 1

            $findings.Add((New-WaFinding -Id ('external.czkawka.' + (Get-WaHash -Text $path).Substring(0, 8)) `
                -Title ('Duplicate files in {0}' -f $path) -Category 'Storage' -Provider 'External.Czkawka' `
                -Description 'Czkawka scanned this directory and wrote a report. WinAdvisor does not interpret which copy of a duplicate matters, and does not delete anything.' `
                -Evidence @(
                    New-WaEvidence -Source 'czkawka_cli' -Method 'External duplicate scan' `
                        -Statement $(if ($summaryLine) { $summaryLine.Trim() } else { 'Scan completed; see the report file for detail.' }) -Measured $true `
                        -Reference 'https://github.com/qarmin/czkawka/blob/master/czkawka_cli/README.md'
                    New-WaEvidence -Source $reportFile -Method 'Report file' `
                        -Statement ('Full duplicate report written to {0}.' -f $reportFile) -Measured $true
                ) `
                -CurrentImpact 'Duplicate detection is advisory. Deciding which copy to keep is yours alone.' `
                -Confidence 'MEDIUM' -Disposition 'Advisory' `
                -Warnings @(
                    'A duplicate may be the only backup of a file, or a copy an application currently has open.'
                    'WinAdvisor passes no deletion argument to Czkawka, and no such command exists in its catalog.'
                )))
        }

        return $findings.ToArray()
    } | Out-Null
