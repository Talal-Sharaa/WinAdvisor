<# Czkawka 12.0.2 discovery with individually reviewed cleanup through the core engine. #>

Register-WaProvider -Name 'External.Czkawka' -Order 500 `
    -Title 'Duplicates, empty items, temporary files, similar images and broken files (Czkawka)' `
    -Category 'Storage' `
    -Description 'Scans the six standard personal folders by default, or supplied DeepScanPaths, using Czkawka CLI 12.0.2. Each result type is one HIGH-risk action: you choose the exact items on a review screen, with Czkawka''s bulk selection rules, and approve that list. At least one file in every duplicate or similar-image group is always kept.' `
    -ExternalDependency 'czkawka_cli' `
    -UsesDeepScanPaths $true `
    -Reference 'https://github.com/qarmin/czkawka/releases/tag/12.0.2' `
    -TestAvailable {
        param($Session)
        try {
            Initialize-WaCzkawkaScan -Session $Session
            New-WaProviderAvailability -Available $true -Reason ('Using Czkawka 12.0.2: ' + (Resolve-WaCzkawkaExecutable $Session))
        } catch {
            New-WaProviderAvailability -Available $false -Reason $_.Exception.Message
        }
    } `
    -GetInventory {
        param($Session)
        New-WaInstalledComponent -Name 'Czkawka CLI' -Category 'External tool' -Version '12.0.2' `
            -Executable (Resolve-WaCzkawkaExecutable $Session) -DetectionMethod 'Version probe' -DetectionConfidence 'HIGH'
    } `
    -GetAnalysis {
        param($Session, $Inventory)
        Invoke-WaCzkawkaScans -Session $Session
    } `
    -GetCleanupCandidates {
        param($Session, $Inventory)
        $Session.ProviderState['External.Czkawka'].Candidates
    } `
    -GetCleanupPlan {
        param($Session, $Candidates)
        New-WaCzkawkaPlanRecommendations -Session $Session -Candidates $Candidates
    } | Out-Null
