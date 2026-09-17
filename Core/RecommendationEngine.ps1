<#
    Core/RecommendationEngine.ps1 - turning measured candidates into recommendations.

    Providers know their domain; this file knows how a recommendation must be shaped. By
    routing every provider through these builders, the guarantees are written once:

      * an approved cleanup root is registered before any FileDelete can reference it;
      * evidence states what was measured, how, and whether the measurement was complete;
      * a command preview is generated from the command catalog, not from provider text;
      * consequence, reversibility and admin requirements come from the catalog entry;
      * risk floors are enforced before the recommendation is returned.
#>

function Get-WaBenefitStatement {
    <#
    .SYNOPSIS
        Phrases an estimated benefit honestly, including when the measurement is partial.
    #>
    [CmdletBinding()]
    param($Bytes, [bool]$Complete = $true, [string]$Unit = 'disk space')

    if ($null -eq $Bytes) { return "Unknown: this location could not be measured." }
    $formatted = Format-WaBytes $Bytes
    if ($Complete) { return "About $formatted of $Unit." }
    return "At least $formatted of $Unit. The scan hit its budget, so the real figure is higher."
}

function Get-WaCacheRootCandidate {
    <#
    .SYNOPSIS
        Measures one cache directory and returns a cleanup candidate, or $null.

    .DESCRIPTION
        The shared measurement step for every provider that cleans a directory of
        regenerable files. Applies the age threshold, respects the scan budget, and returns
        $null when the directory is absent, empty or has nothing old enough to qualify, so
        providers can simply enumerate their known locations without special-casing.

        AgeDays exists because a cache file written minutes ago is probably in use. Only
        files older than the threshold enter the manifest.

    .EXAMPLE
        Get-WaCacheRootCandidate -Session $s -Provider 'Browsers.Chromium' -Key 'chrome.cache' `
            -Title 'Chrome cache' -Category 'Browser caches' -Path $path -AgeDays 7 `
            -Risk 'LOW' -Confidence 'HIGH' -Explanation '...'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)][string]$Provider,
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Category,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Path,
        [int]$AgeDays = 0,
        [ValidateSet('SAFE', 'LOW', 'MODERATE', 'HIGH', 'MANUAL-ONLY')][string]$Risk = 'LOW',
        [ValidateSet('HIGH', 'MEDIUM', 'LOW', 'UNKNOWN')][string]$Confidence = 'HIGH',
        [Parameter(Mandatory)][string]$Explanation,
        [bool]$RequiresAdmin = $false,
        [string]$DataClass = 'RegenerableCache',
        [long]$MinimumBytes = 1MB
    )

    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }

    $config = $Session.Config
    $cutoff = if ($AgeDays -gt 0) { [datetime]::UtcNow.AddDays(-$AgeDays) } else { [datetime]::MaxValue }

    $inventory = Get-WaFileInventory -Root $Path -Config $config -CutoffUtc $cutoff
    if ($inventory.Status -eq 'Absent') { return $null }
    if ($inventory.Status -eq 'Blocked') { return $null }
    if ($inventory.FileCount -eq 0) { return $null }
    if ($inventory.EligibleBytes -lt $MinimumBytes) { return $null }

    New-WaCleanupCandidate `
        -Key $Key `
        -Provider $Provider `
        -Title $Title `
        -Category $Category `
        -Path $inventory.Root `
        -Bytes $inventory.EligibleBytes `
        -Complete $inventory.Complete `
        -Files $inventory.Files `
        -CutoffUtc $cutoff `
        -Risk $Risk `
        -Confidence $Confidence `
        -Explanation $Explanation `
        -RequiresAdmin $RequiresAdmin `
        -DataClass $DataClass
}

function Get-WaDirectoryConsumer {
    <#
    .SYNOPSIS
        Measures a directory and returns a StorageConsumer for the storage view.

    .DESCRIPTION
        Used for locations worth reporting whether or not they are cleanable, so the
        storage picture stays complete even where no action is offered.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Category,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Path,
        [Parameter(Mandatory)][string]$Provider,
        [ValidateSet('Actionable', 'Informational', 'ManualReview')][string]$Disposition = 'Informational',
        [string]$Note = ''
    )

    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    $size = Get-WaDirectorySize -Path $Path -Config $Session.Config
    if (-not $size.Exists) { return $null }

    New-WaStorageConsumer -Name $Name -Category $Category -Path $Path -Bytes $size.Bytes `
        -Complete $size.Complete -Provider $Provider -Disposition $Disposition `
        -Measurement 'Bounded filesystem enumeration' -Note $Note
}

function New-WaFileCleanupRecommendation {
    <#
    .SYNOPSIS
        Builds a FileDelete recommendation from a measured cleanup candidate.

    .DESCRIPTION
        Registers the candidate's directory as an approved cleanup root for this session,
        then produces an operation that references that root by key. The executor resolves
        the key against the session, so a plan cannot be edited to delete somewhere else.

        Returns $null when there is nothing eligible to delete, so a provider can call this
        unconditionally.

    .EXAMPLE
        New-WaFileCleanupRecommendation -Session $s -Candidate $candidate `
            -Consequence 'The cache is rebuilt the next time the application runs.'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)]$Candidate,
        [string]$Consequence = '',
        [string]$Mechanism = 'Deletes only the specific aged files in the reviewed manifest. Locked, linked, protected and recently changed files are skipped.',
        [ValidateSet('Reversible', 'PartiallyReversible', 'RegenerableOnly', 'Irreversible')][string]$Reversibility = 'RegenerableOnly',
        [string]$RollbackNote = 'Not available. Deleted cache content is regenerable, not restorable; this toolkit does not copy files before deleting them.',
        [string[]]$Warnings = @(),
        [string]$QuestionId = '',
        [string]$Reference = '',
        [bool]$AffectsPersonalData = $false
    )

    $files = @($Candidate.Files)
    if ($files.Count -eq 0) { return $null }

    $rootKey = 'root.{0}' -f $Candidate.Key
    [void](Register-WaApprovedRoot -Session $Session -RootKey $rootKey -Path $Candidate.Path -Provider $Candidate.Provider)

    $cutoff = $Candidate.CutoffUtc
    $ageDescription = if ($cutoff -eq [datetime]::MaxValue) {
        'no age threshold applies to this category'
    } else {
        'last written before {0:yyyy-MM-dd HH:mm} UTC' -f $cutoff
    }

    $evidence = @(
        New-WaEvidence -Source $Candidate.Path -Method 'Bounded filesystem enumeration' `
            -Statement ('{0} file(s) totalling {1} qualify: {2}.' -f $files.Count, (Format-WaBytes $Candidate.Bytes), $ageDescription) `
            -Value $Candidate.Bytes -Unit 'bytes' -Measured $true -Complete $Candidate.Complete
    )
    if (-not $Candidate.Complete) {
        $evidence += New-WaEvidence -Source $Candidate.Path -Method 'Scan budget' `
            -Statement 'The scan reached its entry or time budget, so the measured size is a lower bound.' `
            -Measured $true -Complete $false
    }

    $operation = New-WaOperation -Kind 'FileDelete' `
        -Description ('Delete {0} reviewed file(s) under {1}' -f $files.Count, $Candidate.Path) `
        -RequiresAdmin $Candidate.RequiresAdmin `
        -Parameters ([ordered]@{
            RootKey   = $rootKey
            Root      = $Candidate.Path
            CutoffUtc = $cutoff
            Files     = $files
        })

    New-WaRecommendation `
        -Id $Candidate.Key `
        -Title $Candidate.Title `
        -Category $Candidate.Category `
        -Provider $Candidate.Provider `
        -Description $Candidate.Explanation `
        -Evidence $evidence `
        -CurrentImpact ('{0} currently occupied by {1} eligible file(s).' -f (Format-WaBytes $Candidate.Bytes), $files.Count) `
        -EstimatedBytes $Candidate.Bytes `
        -BenefitClass 'Estimated' `
        -EstimatedBenefit (Get-WaBenefitStatement -Bytes $Candidate.Bytes -Complete $Candidate.Complete) `
        -EstimateComplete $Candidate.Complete `
        -Risk $Candidate.Risk `
        -Confidence $Candidate.Confidence `
        -Reversibility $Reversibility `
        -RollbackNote $RollbackNote `
        -Operations @($operation) `
        -CommandPreview ('Delete {0} file(s) under {1}' -f $files.Count, $Candidate.Path) `
        -Mechanism $Mechanism `
        -AdminRequired $Candidate.RequiresAdmin `
        -RestartRequired 'None' `
        -Warnings $Warnings `
        -Consequence $Consequence `
        -AffectsPersonalData $AffectsPersonalData `
        -QuestionId $QuestionId `
        -Reference $Reference
}

function New-WaCommandRecommendation {
    <#
    .SYNOPSIS
        Builds a NativeCommand recommendation from a command catalog entry.

    .DESCRIPTION
        The catalog supplies the executable, the arguments, the consequence, the admin
        requirement and the documentation reference, so a provider cannot describe a
        command as doing something other than what it does.

        Returns $null when the tool is not installed on this machine.

    .PARAMETER Risk
        May be higher than the catalog's floor for the entry, never lower.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$CommandId,
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Category,
        [Parameter(Mandatory)][string]$Provider,
        [Parameter(Mandatory)][string]$Description,
        [System.Collections.IDictionary]$Values = @{},

        [object[]]$Evidence = @(),
        [string]$CurrentImpact = '',
        $EstimatedBytes = $null,
        [bool]$EstimateComplete = $true,
        [ValidateSet('SAFE', 'LOW', 'MODERATE', 'HIGH', 'MANUAL-ONLY')][string]$Risk = 'LOW',
        [ValidateSet('HIGH', 'MEDIUM', 'LOW', 'UNKNOWN')][string]$Confidence = 'HIGH',
        [ValidateSet('Reversible', 'PartiallyReversible', 'RegenerableOnly', 'Irreversible')][string]$Reversibility = 'RegenerableOnly',
        [string]$RollbackNote = '',
        [string[]]$Warnings = @(),
        [string[]]$Prerequisites = @(),
        [string]$QuestionId = '',
        [ValidateSet('None', 'Restart', 'SignOut')][string]$RestartRequired = 'None'
    )

    $resolved = Resolve-WaCommand -CommandId $CommandId -Values $Values
    if (-not $resolved.Available) { return $null }

    # The catalog floor is authoritative; a provider may raise the risk but never lower it.
    $effectiveRisk = $Risk
    if ((Get-WaRiskRank -Risk $Risk) -lt (Get-WaRiskRank -Risk $resolved.MinimumRisk)) {
        $effectiveRisk = $resolved.MinimumRisk
    }

    $rollback = $RollbackNote
    if (-not $rollback) {
        $rollback = if ($resolved.Reverses) {
            "Reversible by running the documented counterpart command."
        } else {
            'Not available. The content removed is regenerable rather than restorable.'
        }
    }

    $operation = New-WaOperation -Kind 'NativeCommand' `
        -Description $resolved.Purpose `
        -RequiresAdmin $resolved.RequiresAdmin `
        -Restart $RestartRequired `
        -Parameters ([ordered]@{
            CommandId = $CommandId
            Values    = $Values
        })

    $allEvidence = @($Evidence)
    $allEvidence += New-WaEvidence -Source $resolved.Tool -Method 'Command catalog entry' `
        -Statement ("Runs the vendor-documented command: {0}" -f $resolved.Preview) `
        -Measured $false -Reference $resolved.Reference

    New-WaRecommendation `
        -Id $Id `
        -Title $Title `
        -Category $Category `
        -Provider $Provider `
        -Description $Description `
        -Evidence $allEvidence `
        -CurrentImpact $CurrentImpact `
        -EstimatedBytes $EstimatedBytes `
        -BenefitClass $(if ($null -eq $EstimatedBytes) { 'Unknown' } else { 'Estimated' }) `
        -EstimatedBenefit (Get-WaBenefitStatement -Bytes $EstimatedBytes -Complete $EstimateComplete) `
        -EstimateComplete $EstimateComplete `
        -Risk $effectiveRisk `
        -Confidence $Confidence `
        -Reversibility $Reversibility `
        -RollbackNote $rollback `
        -Operations @($operation) `
        -CommandPreview $resolved.Preview `
        -Mechanism ('Executed through the {0} command-line interface.' -f $resolved.Tool) `
        -AdminRequired $resolved.RequiresAdmin `
        -RestartRequired $RestartRequired `
        -Warnings $Warnings `
        -Prerequisites $Prerequisites `
        -Consequence $resolved.Consequence `
        -QuestionId $QuestionId `
        -Reference $resolved.Reference
}

function New-WaAdvisoryRecommendation {
    <#
    .SYNOPSIS
        Builds a MANUAL-ONLY recommendation: explained in full, never executed.

    .DESCRIPTION
        Used wherever the toolkit can measure and explain something but cannot responsibly
        act on it: Docker volumes, WSL virtual disks, duplicate personal files, large
        unknown directories, unknown services.

        By construction it carries no operations, so even if approval logic were somehow
        bypassed there would be nothing to run.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Category,
        [Parameter(Mandatory)][string]$Provider,
        [Parameter(Mandatory)][string]$Description,
        [object[]]$Evidence = @(),
        [string]$CurrentImpact = '',
        $EstimatedBytes = $null,
        [bool]$EstimateComplete = $true,
        [ValidateSet('HIGH', 'MEDIUM', 'LOW', 'UNKNOWN')][string]$Confidence = 'MEDIUM',
        [string[]]$Warnings = @(),
        [string]$ManualSteps = '',
        [string]$Reference = '',
        [bool]$AffectsPersonalData = $false
    )

    New-WaRecommendation `
        -Id $Id `
        -Title $Title `
        -Category $Category `
        -Provider $Provider `
        -Description $Description `
        -Evidence $Evidence `
        -CurrentImpact $CurrentImpact `
        -EstimatedBytes $EstimatedBytes `
        -BenefitClass 'Possible' `
        -EstimatedBenefit (Get-WaBenefitStatement -Bytes $EstimatedBytes -Complete $EstimateComplete) `
        -EstimateComplete $EstimateComplete `
        -Risk 'MANUAL-ONLY' `
        -Confidence $Confidence `
        -Reversibility 'Irreversible' `
        -RollbackNote 'Not applicable: this toolkit performs no action here.' `
        -Operations @() `
        -CommandPreview '(no command; manual review only)' `
        -Mechanism $(if ($ManualSteps) { $ManualSteps } else { 'Review and act on this yourself if you decide it is appropriate.' }) `
        -AdminRequired $false `
        -RestartRequired 'None' `
        -UserApprovalRequired $true `
        -Warnings $Warnings `
        -Consequence 'WinAdvisor takes no action on manual-review items.' `
        -AffectsPersonalData $AffectsPersonalData `
        -Reference $Reference
}

function New-WaStartupDisableRecommendation {
    <#
    .SYNOPSIS
        Builds a reversible recommendation to disable one startup item.

    .DESCRIPTION
        Uses the Explorer StartupApproved mechanism, the same one Task Manager's Startup
        tab uses. The original Run value or shortcut is left completely untouched, so
        re-enabling is a single value write and nothing is lost if the user changes their
        mind or the rollback record is discarded.

        Refuses, by returning $null, for any item that is protected by policy, is already
        disabled, or falls in a category the toolkit will not touch.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)]$Item,
        $MemoryBytes = $null,
        [string]$Rationale = ''
    )

    # Categories that are never proposed for disabling:
    #   Security, Device management, Accessibility  - disabling them weakens or breaks the machine
    #   Hardware and drivers, Windows system        - load-bearing for devices and the shell
    #   Cloud synchronization                       - stopping it silently stops files syncing,
    #                                                 which looks like working normally until
    #                                                 something is lost
    #   Unknown                                     - an unrecognised entry may be the thing
    #                                                 keeping a VPN or fingerprint reader alive
    if ($Item.Protected) { return $null }
    if (-not $Item.Enabled) { return $null }
    if (@('Security', 'Device management', 'Accessibility', 'Hardware and drivers',
          'Windows system', 'Cloud synchronization', 'Unknown') -contains $Item.Category) { return $null }
    if ($Item.SourceKind -eq 'ScheduledTask') { return $null }

    $evidence = @(
        New-WaEvidence -Source $Item.Source -Method 'Registry and Explorer StartupApproved state' `
            -Statement ('"{0}" starts automatically from {1}.' -f $Item.Name, $Item.Source) -Measured $true
    )
    if ($null -ne $MemoryBytes) {
        $evidence += New-WaEvidence -Source 'Get-Process' -Method 'Private bytes summed per executable' `
            -Statement ('It is currently resident using {0} of private memory.' -f (Format-WaBytes $MemoryBytes)) `
            -Value $MemoryBytes -Unit 'bytes'
    }

    $operation = New-WaOperation -Kind 'StartupItemState' `
        -Description ('Disable startup item "{0}"' -f $Item.Name) `
        -RequiresAdmin $Item.RequiresAdmin `
        -Parameters ([ordered]@{
            Name    = $Item.Name
            Scope   = $Item.ApprovalScope
            Hive    = $Item.ApprovalHive
            Enabled = $false
            Source  = $Item.Source
        })

    New-WaRecommendation `
        -Id ('startup.disable.{0}' -f (Get-WaHash -Text ('{0}|{1}' -f $Item.Source, $Item.Name)).Substring(0, 12)) `
        -Title ('Stop "{0}" from starting automatically' -f $Item.Name) `
        -Category 'Startup' `
        -Provider 'Windows.Startup' `
        -Description $(if ($Rationale) { $Rationale } else { ('{0} is an optional {1} item. Disabling it stops it launching at sign-in; the application still runs normally when opened.' -f $Item.Name, $Item.Category.ToLowerInvariant()) }) `
        -Evidence $evidence `
        -CurrentImpact $(if ($null -ne $MemoryBytes) { ('Resident at {0} of private memory.' -f (Format-WaBytes $MemoryBytes)) } else { 'Runs at every sign-in.' }) `
        -EstimatedBytes $null `
        -BenefitClass 'Possible' `
        -EstimatedBenefit 'Sign-in launches one fewer program. Any memory saving depends on whether you open the application anyway, so no figure is claimed.' `
        -Risk 'MODERATE' `
        -Confidence $(if ($Item.StateKnown) { 'HIGH' } else { 'MEDIUM' }) `
        -Reversibility 'Reversible' `
        -RollbackNote 'Fully reversible. The original startup entry is not modified; only its Explorer approval state changes, and the previous state is recorded.' `
        -Operations @($operation) `
        -CommandPreview ('Set Explorer StartupApproved state for "{0}" to disabled' -f $Item.Name) `
        -Mechanism 'Explorer StartupApproved, the same mechanism Task Manager uses. The Run value or shortcut itself is left intact.' `
        -AdminRequired $Item.RequiresAdmin `
        -RestartRequired 'SignOut' `
        -Warnings @('Sign out and back in for the change to take effect.') `
        -Consequence ('{0} no longer starts at sign-in. Features that depend on it running in the background, such as sync or notifications, stop until it is opened.' -f $Item.Name)
}
