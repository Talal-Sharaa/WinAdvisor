<#
    Core/Models.ps1 - the internal data model.

    Every concept the toolkit reasons about has a constructor here. Components pass
    these objects around instead of ad-hoc hashtables, so a missing or misspelled field
    fails at construction rather than silently becoming $null three layers later.

    Vocabularies are validated at construction time:

      Risk         SAFE | LOW | MODERATE | HIGH | MANUAL-ONLY
      Confidence   HIGH | MEDIUM | LOW | UNKNOWN
      BenefitClass Measured | Estimated | Possible | Unknown
      Reversibility Reversible | PartiallyReversible | RegenerableOnly | Irreversible

    Risk and Confidence are deliberately independent: "clear the browser cache" is LOW
    risk and HIGH confidence, while "this 38 GB directory looks unused" may be HIGH risk
    and LOW confidence, which is exactly the combination that must never auto-execute.
#>

$script:WaRiskLevels = @('SAFE', 'LOW', 'MODERATE', 'HIGH', 'MANUAL-ONLY')
$script:WaConfidenceLevels = @('HIGH', 'MEDIUM', 'LOW', 'UNKNOWN')
$script:WaBenefitClasses = @('Measured', 'Estimated', 'Possible', 'Unknown')
$script:WaReversibilityClasses = @('Reversible', 'PartiallyReversible', 'RegenerableOnly', 'Irreversible')

# The complete set of operation kinds the execution engine knows how to perform.
# Anything not in this list cannot be executed, which is what keeps a provider from
# inventing a new way to change the machine.
$script:WaOperationKinds = @(
    'FileDelete'          # delete a reviewed manifest of specific files
    'NativeCommand'       # run one catalog entry with catalog-controlled arguments
    'RegistryValueSet'    # write a single named registry value, with a rollback record
    'ServiceStartupSet'   # change one service start mode, with a rollback record
    'ScheduledTaskState'  # enable/disable one scheduled task, with a rollback record
    'StartupItemState'    # enable/disable one startup item, with a rollback record
    'RestorePointCreate'  # create a System Restore checkpoint
)

function Get-WaRiskRank {
    <#
    .SYNOPSIS
        Numeric ordering for risk levels. Higher means more dangerous.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Risk)
    $index = [array]::IndexOf($script:WaRiskLevels, $Risk)
    if ($index -lt 0) { throw "Unknown risk level '$Risk'. Valid: $($script:WaRiskLevels -join ', ')" }
    return $index
}

function Get-WaConfidenceRank {
    <#
    .SYNOPSIS
        Numeric ordering for confidence. Higher means better evidence.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Confidence)
    switch -Exact ($Confidence) {
        'HIGH'    { return 3 }
        'MEDIUM'  { return 2 }
        'LOW'     { return 1 }
        'UNKNOWN' { return 0 }
        default   { throw "Unknown confidence level '$Confidence'. Valid: $($script:WaConfidenceLevels -join ', ')" }
    }
}

function New-WaEvidence {
    <#
    .SYNOPSIS
        One measured or observed fact behind a finding or recommendation.

    .DESCRIPTION
        Measured distinguishes a number the toolkit actually read from one it inferred.
        Complete distinguishes a full measurement from a lower bound produced by a scan
        that hit its budget. Both flags travel all the way into the report so a partial
        number is never presented as a total.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Method,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Statement,
        $Value = $null,
        [string]$Unit = '',
        [bool]$Measured = $true,
        [bool]$Complete = $true,
        [string]$Reference = ''
    )
    [pscustomobject][ordered]@{
        PSTypeName = 'WinAdvisor.Evidence'
        Source     = $Source
        Method     = $Method
        Statement  = $Statement
        Value      = $Value
        Unit       = $Unit
        Measured   = $Measured
        Complete   = $Complete
        Reference  = $Reference
    }
}

function New-WaInstalledComponent {
    <#
    .SYNOPSIS
        A detected workload, runtime, application or tool on this machine.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Category,
        [string]$Vendor = '',
        [string]$Version = '',
        [string]$InstallPath = '',
        [string]$Executable = '',
        [bool]$Detected = $true,
        [ValidateSet('HIGH', 'MEDIUM', 'LOW', 'UNKNOWN')][string]$DetectionConfidence = 'HIGH',
        [string]$DetectionMethod = '',
        [string]$Note = ''
    )
    [pscustomobject][ordered]@{
        PSTypeName          = 'WinAdvisor.InstalledComponent'
        Name                = $Name
        Category            = $Category
        Vendor              = $Vendor
        Version             = $Version
        InstallPath         = $InstallPath
        Executable          = $Executable
        Detected            = $Detected
        DetectionConfidence = $DetectionConfidence
        DetectionMethod     = $DetectionMethod
        Note                = $Note
    }
}

function New-WaStorageConsumer {
    <#
    .SYNOPSIS
        A measured (or unmeasurable) consumer of disk space, attributed to a category.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Category,
        [string]$Path = '',
        $Bytes = $null,
        [bool]$Complete = $true,
        [string]$Provider = 'Core',
        [string]$Measurement = 'Filesystem enumeration',
        [ValidateSet('Actionable', 'Informational', 'ManualReview')][string]$Disposition = 'Informational',
        [string]$Note = ''
    )
    [pscustomobject][ordered]@{
        PSTypeName  = 'WinAdvisor.StorageConsumer'
        Name        = $Name
        Category    = $Category
        Path        = $Path
        Bytes       = $Bytes
        Complete    = $Complete
        Provider    = $Provider
        Measurement = $Measurement
        Disposition = $Disposition
        Note        = $Note
    }
}

function New-WaFinding {
    <#
    .SYNOPSIS
        An observation about the machine. Findings never propose an action; a finding
        plus policy produces a recommendation.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Category,
        [Parameter(Mandatory)][string]$Provider,
        [string]$Description = '',
        [object[]]$Evidence = @(),
        [string]$CurrentImpact = '',
        [ValidateSet('HIGH', 'MEDIUM', 'LOW', 'UNKNOWN')][string]$Confidence = 'MEDIUM',
        [ValidateSet('Informational', 'Advisory', 'Actionable')][string]$Disposition = 'Informational',
        $Bytes = $null,
        [string[]]$Warnings = @()
    )
    [pscustomobject][ordered]@{
        PSTypeName    = 'WinAdvisor.Finding'
        Id            = $Id
        Title         = $Title
        Category      = $Category
        Provider      = $Provider
        Description   = $Description
        Evidence      = @($Evidence)
        CurrentImpact = $CurrentImpact
        Confidence    = $Confidence
        Disposition   = $Disposition
        Bytes         = $Bytes
        Warnings      = @($Warnings)
        CreatedUtc    = (Get-WaUtcTimestamp)
    }
}

function New-WaOperation {
    <#
    .SYNOPSIS
        A single typed, executable step.

    .DESCRIPTION
        Providers describe what they want done; they never perform it. The execution
        engine is the only code that interprets an operation, and it only understands
        the kinds listed in $script:WaOperationKinds.

        Parameters carry kind-specific data:
          FileDelete         RootKey, Root, Files (manifest), CutoffUtc
          NativeCommand      CommandId (resolved against the command catalog), plus any
                             catalog-declared placeholder values
          RegistryValueSet   Path, Name, Type, Value
          ServiceStartupSet  ServiceName, StartupType
          ScheduledTaskState TaskPath, TaskName, Enabled
          StartupItemState   Source, Name, Enabled
          RestorePointCreate Description
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Kind,
        [Parameter(Mandatory)][string]$Description,
        [System.Collections.IDictionary]$Parameters = @{},
        [bool]$RequiresAdmin = $false,
        [ValidateSet('None', 'Restart', 'SignOut')][string]$Restart = 'None'
    )
    if ($script:WaOperationKinds -notcontains $Kind) {
        throw "Unknown operation kind '$Kind'. Valid: $($script:WaOperationKinds -join ', ')"
    }
    [pscustomobject][ordered]@{
        PSTypeName    = 'WinAdvisor.Operation'
        Kind          = $Kind
        Description   = $Description
        Parameters    = $Parameters
        RequiresAdmin = $RequiresAdmin
        Restart       = $Restart
    }
}

function New-WaRecommendation {
    <#
    .SYNOPSIS
        A proposed course of action, with the evidence, risk, confidence and consequences
        needed for a person to decide.

    .DESCRIPTION
        The field set answers the questions every recommendation must answer: what was
        detected, how it was measured, what exactly will run, what changes, what could go
        wrong, whether it can be undone, and who has to approve it.

        EstimatedBytes is what analysis predicts. MeasuredBytes stays $null until the
        verification pass fills it in from a real before/after comparison, so a prediction
        can never be reported as a result.
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
        [ValidateSet('Measured', 'Estimated', 'Possible', 'Unknown')][string]$BenefitClass = 'Estimated',
        [string]$EstimatedBenefit = '',
        [bool]$EstimateComplete = $true,

        [Parameter(Mandatory)][ValidateSet('SAFE', 'LOW', 'MODERATE', 'HIGH', 'MANUAL-ONLY')][string]$Risk,
        [Parameter(Mandatory)][ValidateSet('HIGH', 'MEDIUM', 'LOW', 'UNKNOWN')][string]$Confidence,
        [ValidateSet('Reversible', 'PartiallyReversible', 'RegenerableOnly', 'Irreversible')][string]$Reversibility = 'RegenerableOnly',
        [string]$RollbackNote = '',

        [object[]]$Operations = @(),
        [string]$CommandPreview = '',
        [string]$Mechanism = '',

        [bool]$AdminRequired = $false,
        [ValidateSet('None', 'Restart', 'SignOut')][string]$RestartRequired = 'None',
        [bool]$UserApprovalRequired = $true,
        [bool]$IndividualApprovalRequired = $false,

        [string[]]$Prerequisites = @(),
        [string[]]$Warnings = @(),
        [string]$Consequence = '',
        [bool]$AffectsPersonalData = $false,
        [string]$QuestionId = '',
        [string]$Reference = ''
    )

    # HIGH and MANUAL-ONLY can never be blanket-approved, whatever a provider asks for.
    $individual = $IndividualApprovalRequired
    if ($Risk -eq 'HIGH' -or $Risk -eq 'MANUAL-ONLY') { $individual = $true }

    [pscustomobject][ordered]@{
        PSTypeName                 = 'WinAdvisor.Recommendation'
        Id                         = $Id
        Title                      = $Title
        Category                   = $Category
        Provider                   = $Provider
        Description                = $Description

        Evidence                   = @($Evidence)
        CurrentImpact              = $CurrentImpact

        EstimatedBytes             = $EstimatedBytes
        BenefitClass               = $BenefitClass
        EstimatedBenefit           = $EstimatedBenefit
        EstimateComplete           = $EstimateComplete
        MeasuredBytes              = $null      # filled in only by the verification pass
        MeasuredBenefit            = ''

        Risk                       = $Risk
        Confidence                 = $Confidence
        Reversibility              = $Reversibility
        RollbackNote               = $RollbackNote

        Operations                 = @($Operations)
        CommandPreview             = $CommandPreview
        Mechanism                  = $Mechanism

        AdminRequired              = $AdminRequired
        RestartRequired            = $RestartRequired
        UserApprovalRequired       = $UserApprovalRequired
        IndividualApprovalRequired = $individual

        Prerequisites              = @($Prerequisites)
        Warnings                   = @($Warnings)
        Consequence                = $Consequence
        AffectsPersonalData        = $AffectsPersonalData
        QuestionId                 = $QuestionId
        Reference                  = $Reference
        CreatedUtc                 = (Get-WaUtcTimestamp)
    }
}

function New-WaCleanupCandidate {
    <#
    .SYNOPSIS
        A measured location a provider believes is a cleanup opportunity, before policy
        has decided whether it becomes a recommendation.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$Provider,
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Category,
        [string]$Path = '',
        $Bytes = $null,
        [bool]$Complete = $true,
        [object[]]$Files = @(),
        [datetime]$CutoffUtc = [datetime]::MaxValue,
        [ValidateSet('SAFE', 'LOW', 'MODERATE', 'HIGH', 'MANUAL-ONLY')][string]$Risk = 'MANUAL-ONLY',
        [ValidateSet('HIGH', 'MEDIUM', 'LOW', 'UNKNOWN')][string]$Confidence = 'MEDIUM',
        [string]$Explanation = '',
        [bool]$RequiresAdmin = $false,
        [string]$DataClass = 'Unknown'
    )
    [pscustomobject][ordered]@{
        PSTypeName    = 'WinAdvisor.CleanupCandidate'
        Key           = $Key
        Provider      = $Provider
        Title         = $Title
        Category      = $Category
        Path          = $Path
        Bytes         = $Bytes
        Complete      = $Complete
        Files         = @($Files)
        CutoffUtc     = $CutoffUtc
        Risk          = $Risk
        Confidence    = $Confidence
        Explanation   = $Explanation
        RequiresAdmin = $RequiresAdmin
        DataClass     = $DataClass
    }
}

function New-WaPlannedAction {
    <#
    .SYNOPSIS
        A recommendation that has been selected into a plan, carrying its approval state.

    .DESCRIPTION
        Fingerprint binds the approval to the exact content of the recommendation. If any
        field changes between approval and execution the fingerprint no longer matches and
        the executor refuses, so an approval can never be replayed against different work.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Recommendation,
        [int]$Order = 0,
        [bool]$Selected = $false
    )
    [pscustomobject][ordered]@{
        PSTypeName     = 'WinAdvisor.PlannedAction'
        Id             = $Recommendation.Id
        Order          = $Order
        Recommendation = $Recommendation
        Selected       = $Selected
        Fingerprint    = (Get-WaActionFingerprint -Recommendation $Recommendation)
        Approval       = $null
        Status         = 'Pending'
    }
}

function New-WaExecutionResult {
    <#
    .SYNOPSIS
        The outcome of attempting one planned action.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ActionId,
        [Parameter(Mandatory)][string]$Provider,
        [Parameter(Mandatory)][ValidateSet('Succeeded', 'PartiallySucceeded', 'Failed', 'Skipped', 'Simulated', 'Blocked')][string]$Status,
        [string]$Summary = '',
        $BeforeState = $null,
        $AfterState = $null,
        $BytesReclaimed = $null,
        [string[]]$Messages = @(),
        [string]$Error = '',
        [int]$DurationMs = 0,
        [string]$RollbackId = '',
        [object[]]$OperationResults = @()
    )
    [pscustomobject][ordered]@{
        PSTypeName       = 'WinAdvisor.ExecutionResult'
        ActionId         = $ActionId
        Provider         = $Provider
        Status           = $Status
        Summary          = $Summary
        BeforeState      = $BeforeState
        AfterState       = $AfterState
        BytesReclaimed   = $BytesReclaimed
        Messages         = @($Messages)
        Error            = $Error
        DurationMs       = $DurationMs
        RollbackId       = $RollbackId
        OperationResults = @($OperationResults)
        CompletedUtc     = (Get-WaUtcTimestamp)
    }
}

function New-WaRollbackRecord {
    <#
    .SYNOPSIS
        Captured prior state for a reversible change.

    .DESCRIPTION
        Only created for changes that genuinely can be put back: registry values, service
        start modes, startup entries, scheduled task state, hibernation. Deleted file
        content is never claimed to be restorable.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$ActionId,
        [Parameter(Mandatory)][string]$Kind,
        [Parameter(Mandatory)][string]$Target,
        $BeforeValue = $null,
        $AfterValue = $null,
        [bool]$Existed = $true,
        [string]$RestoreDescription = '',
        [System.Collections.IDictionary]$RestoreParameters = @{}
    )
    [pscustomobject][ordered]@{
        PSTypeName         = 'WinAdvisor.RollbackRecord'
        Id                 = $Id
        ActionId           = $ActionId
        Kind               = $Kind
        Target             = $Target
        BeforeValue        = $BeforeValue
        AfterValue         = $AfterValue
        Existed            = $Existed
        RestoreDescription = $RestoreDescription
        RestoreParameters  = $RestoreParameters
        CapturedUtc        = (Get-WaUtcTimestamp)
        Restored           = $false
        RestoredUtc        = $null
    }
}

function New-WaQuestion {
    <#
    .SYNOPSIS
        An adaptive, device-specific question raised only because something was detected.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Provider,
        [Parameter(Mandatory)][string]$Prompt,
        [Parameter(Mandatory)][object[]]$Options,
        [string]$Context = '',
        [string]$DefaultOption = '',
        [string[]]$Evidence = @()
    )
    [pscustomobject][ordered]@{
        PSTypeName    = 'WinAdvisor.Question'
        Id            = $Id
        Provider      = $Provider
        Prompt        = $Prompt
        Context       = $Context
        Options       = @($Options)
        DefaultOption = $DefaultOption
        Evidence      = @($Evidence)
        Answer        = $null
    }
}

function New-WaQuestionOption {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$Label,
        [string]$Description = '',
        [ValidateSet('Inspect', 'Analyze', 'Skip')][string]$Effect = 'Inspect'
    )
    [pscustomobject][ordered]@{
        PSTypeName  = 'WinAdvisor.QuestionOption'
        Key         = $Key
        Label       = $Label
        Description = $Description
        Effect      = $Effect
    }
}

function New-WaBaselineMetric {
    <#
    .SYNOPSIS
        One before/after measurable quantity.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Unit,
        $Value = $null,
        [bool]$Measured = $true,
        [string]$Source = ''
    )
    [pscustomobject][ordered]@{
        PSTypeName = 'WinAdvisor.BaselineMetric'
        Key        = $Key
        Name       = $Name
        Unit       = $Unit
        Value      = $Value
        Measured   = $Measured
        Source     = $Source
        CapturedUtc = (Get-WaUtcTimestamp)
    }
}

function Get-WaActionFingerprint {
    <#
    .SYNOPSIS
        Stable hash over the parts of a recommendation that determine what will happen.

    .DESCRIPTION
        Covers identity, risk, privilege and the operations themselves. Presentation-only
        fields (description text, evidence prose) are excluded so that re-rendering a plan
        does not invalidate an approval, while any change to what would actually run does.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Recommendation)

    $material = [ordered]@{
        Id            = $Recommendation.Id
        Provider      = $Recommendation.Provider
        Risk          = $Recommendation.Risk
        Confidence    = $Recommendation.Confidence
        AdminRequired = $Recommendation.AdminRequired
        Restart       = $Recommendation.RestartRequired
        Operations    = @(
            foreach ($operation in $Recommendation.Operations) {
                [ordered]@{
                    Kind       = $operation.Kind
                    Parameters = (Get-WaOperationFingerprintMaterial -Operation $operation)
                }
            }
        )
    }
    return (Get-WaHash -Text (ConvertTo-WaJson -InputObject $material -Depth 16 -Compress))
}

function Get-WaOperationFingerprintMaterial {
    <#
    .SYNOPSIS
        Reduces an operation's parameters to the values that decide its effect.

    .DESCRIPTION
        A FileDelete manifest is summarised by count plus a hash of the file list rather
        than the whole list, which keeps fingerprints small while still changing if a
        single path in the manifest changes.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Operation)

    $parameters = $Operation.Parameters
    if ($null -eq $parameters) { return @{} }

    $material = [ordered]@{}
    foreach ($key in @($parameters.Keys | Sort-Object)) {
        if ($key -eq 'Files') {
            $files = @($parameters[$key])
            $manifest = ($files | ForEach-Object { ('{0}|{1}|{2}' -f $_.Path, $_.Length, $_.LastWriteUtc) }) -join "`n"
            $material['FileCount'] = $files.Count
            $material['FileManifestHash'] = (Get-WaHash -Text $manifest)
            continue
        }
        $value = $parameters[$key]
        if ($value -is [datetime]) { $value = $value.ToString('o') }
        $material[$key] = $value
    }
    return $material
}

function Get-WaRiskLevels {
    [CmdletBinding()]
    param()
    return @($script:WaRiskLevels)
}

function Get-WaConfidenceLevels {
    [CmdletBinding()]
    param()
    return @($script:WaConfidenceLevels)
}

function Get-WaOperationKinds {
    [CmdletBinding()]
    param()
    return @($script:WaOperationKinds)
}
