<#
    Core/Configuration.ps1 - configuration and policy loading.

    Two distinct inputs, deliberately kept apart:

      Config/defaults.json   user-tunable preferences. A user file supplied with
                             -ConfigPath is merged over these.
      Config/policies.json   the safety policy. Never overridable from a user config
                             file, because it is what decides whether an operation is
                             permitted at all.

    Both are flattened into typed objects at load time. Everything downstream reads
    well-known properties, so a typo in a config file surfaces here as a validation
    error rather than three layers later as a silent $null.
#>

# Declared up front: Set-StrictMode treats reading an unassigned variable as an error, and
# the policy cache is read on the first Get-WaPolicy call before anything has written it.
$script:WaPolicyCache = $null

function Get-WaConfigDirectory {
    [CmdletBinding()]
    param()
    return (Join-Path (Get-WaModuleRoot) 'Config')
}

function Expand-WaPathToken {
    <#
    .SYNOPSIS
        Expands {Windows}, {UserProfile}, ... tokens in a policy path against this machine.

    .DESCRIPTION
        Policy files are written in tokens rather than literal paths so they stay correct
        on machines with a redirected profile, a non-C: system drive or a localised
        Program Files. An unrecognised token is an error: silently leaving it unexpanded
        would produce a protected path that matches nothing.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [System.Collections.IDictionary]$BasePaths)

    if (-not $BasePaths) { $BasePaths = Get-WaBasePaths }

    $expanded = [regex]::Replace($Path, '\{(\w+)\}', {
        param($match)
        $token = $match.Groups[1].Value
        if (-not $BasePaths.Contains($token)) { throw "Unknown path token '{$token}' in policy path '$Path'." }
        return [string]$BasePaths[$token]
    })

    if ([string]::IsNullOrWhiteSpace($expanded)) { return $null }

    # A bare drive root must keep its separator: trimming 'C:\' to 'C:' produces a path
    # that is not absolute, which path normalisation then rejects, silently dropping the
    # protection that entry was there to provide.
    $trimmed = $expanded.TrimEnd('\')
    if ($trimmed -match '^[A-Za-z]:$') { return $trimmed + '\' }
    return $trimmed
}

function ConvertTo-WaHashtable {
    <#
    .SYNOPSIS
        Turns a ConvertFrom-Json PSCustomObject into a case-insensitive hashtable,
        dropping the _comment documentation keys that the JSON files carry.
    #>
    [CmdletBinding()]
    param([AllowNull()]$InputObject)

    if ($null -eq $InputObject) { return @{} }
    if ($InputObject -is [System.Collections.IDictionary]) {
        $copy = New-Object 'System.Collections.Hashtable' ([StringComparer]::OrdinalIgnoreCase)
        foreach ($key in $InputObject.Keys) {
            if ([string]$key -like '_*') { continue }
            $copy[$key] = $InputObject[$key]
        }
        return $copy
    }

    $result = New-Object 'System.Collections.Hashtable' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($property in $InputObject.PSObject.Properties) {
        if ($property.Name -like '_*') { continue }
        $result[$property.Name] = $property.Value
    }
    return $result
}

function Get-WaSection {
    <#
    .SYNOPSIS
        Reads one section of a parsed JSON config as a hashtable.
    #>
    [CmdletBinding()]
    param([AllowNull()]$Root, [Parameter(Mandatory)][string]$Name)
    $section = Get-WaProperty -Object $Root -Name $Name
    return (ConvertTo-WaHashtable -InputObject $section)
}

function Get-WaSectionValue {
    [CmdletBinding()]
    param([System.Collections.IDictionary]$Section, [Parameter(Mandatory)][string]$Name, $Default = $null)
    if ($null -eq $Section) { return $Default }
    if (-not $Section.Contains($Name)) { return $Default }
    $value = $Section[$Name]
    if ($null -eq $value) { return $Default }
    return $value
}

function Get-WaConfiguration {
    <#
    .SYNOPSIS
        Loads, merges and validates configuration into a flat, typed object.

    .PARAMETER Path
        Optional user configuration file merged over Config/defaults.json.

    .EXAMPLE
        $config = Get-WaConfiguration
        $config.MinimumTempAgeDays
    #>
    [CmdletBinding()]
    param([string]$Path)

    $defaultsPath = Join-Path (Get-WaConfigDirectory) 'defaults.json'
    $defaults = Get-WaJsonFile -Path $defaultsPath

    $user = $null
    if ($Path) {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Configuration file not found: $Path" }
        $user = Get-WaJsonFile -Path $Path
    }

    # Merge section by section: a user file may override individual keys without having
    # to restate an entire section.
    $sections = @('Scanning', 'Risk', 'Safety', 'Reporting', 'Logging', 'Providers')
    $merged = @{}
    foreach ($sectionName in $sections) {
        $section = Get-WaSection -Root $defaults -Name $sectionName
        if ($null -ne $user) {
            foreach ($entry in (Get-WaSection -Root $user -Name $sectionName).GetEnumerator()) {
                $section[$entry.Key] = $entry.Value
            }
        }
        $merged[$sectionName] = $section
    }

    $scanning   = $merged['Scanning']
    $risk       = $merged['Risk']
    $safety     = $merged['Safety']
    $reporting  = $merged['Reporting']
    $logging    = $merged['Logging']
    $providers  = $merged['Providers']

    $maximumAutoApprovable = [string](Get-WaSectionValue $risk 'MaximumAutoApprovableRisk' 'LOW')
    $individualThreshold   = [string](Get-WaSectionValue $risk 'RequireIndividualApprovalAtOrAbove' 'HIGH')
    # Validate against the model vocabulary; an unknown level here would otherwise make
    # every later comparison throw in the middle of a plan.
    [void](Get-WaRiskRank -Risk $maximumAutoApprovable)
    [void](Get-WaRiskRank -Risk $individualThreshold)

    $verbosity = [string](Get-WaSectionValue $logging 'Verbosity' 'Normal')
    if (@('Quiet', 'Normal', 'Verbose', 'Debug') -notcontains $verbosity) {
        throw "Logging.Verbosity must be Quiet, Normal, Verbose or Debug. Got '$verbosity'."
    }

    $formats = @(ConvertTo-WaArray (Get-WaSectionValue $reporting 'Formats' @('Html', 'Json')))
    foreach ($format in $formats) {
        if (@('Html', 'Json') -notcontains $format) { throw "Reporting.Formats may contain only Html and Json. Got '$format'." }
    }

    $basePaths = Get-WaBasePaths
    $excluded = @(
        foreach ($excludedPath in (ConvertTo-WaArray (Get-WaSectionValue $scanning 'ExcludedPaths' @()))) {
            $resolved = Expand-WaPathToken -Path ([string]$excludedPath) -BasePaths $basePaths
            if ($resolved) { $resolved }
        }
    )
    $deepScan = @(
        foreach ($deepPath in (ConvertTo-WaArray (Get-WaSectionValue $scanning 'DeepScanPaths' @()))) {
            $resolved = Expand-WaPathToken -Path ([string]$deepPath) -BasePaths $basePaths
            if ($resolved) { $resolved }
        }
    )

    $providerSettings = ConvertTo-WaHashtable -InputObject (Get-WaSectionValue $providers 'Settings' @{})

    # providers.json supplies the per-provider defaults; the user config Settings block
    # overlays them so a user only has to state what they are changing.
    $providerFilePath = Join-Path (Get-WaConfigDirectory) 'providers.json'
    $providerFile = Get-WaJsonFile -Path $providerFilePath
    $providerDefinitions = ConvertTo-WaHashtable -InputObject (Get-WaProperty -Object $providerFile -Name 'Providers')

    $providerConfig = New-Object 'System.Collections.Hashtable' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($providerName in $providerDefinitions.Keys) {
        $definition = ConvertTo-WaHashtable -InputObject $providerDefinitions[$providerName]
        $settings   = ConvertTo-WaHashtable -InputObject (Get-WaSectionValue $definition 'Settings' @{})
        if ($providerSettings.Contains($providerName)) {
            foreach ($entry in (ConvertTo-WaHashtable -InputObject $providerSettings[$providerName]).GetEnumerator()) {
                $settings[$entry.Key] = $entry.Value
            }
        }
        $providerConfig[$providerName] = [pscustomobject][ordered]@{
            Name     = $providerName
            Enabled  = [bool](Get-WaSectionValue $definition 'Enabled' $true)
            Settings = $settings
        }
    }

    $configuration = [pscustomobject][ordered]@{
        PSTypeName = 'WinAdvisor.Configuration'
        SchemaVersion = [int](Get-WaProperty -Object $defaults -Name 'SchemaVersion' -Default 2)
        SourcePath    = $defaultsPath
        UserPath      = $Path

        # Scanning
        MinimumTempAgeDays      = [int](Get-WaSectionValue $scanning 'MinimumTempAgeDays' 7)
        MinimumCacheAgeDays     = [int](Get-WaSectionValue $scanning 'MinimumCacheAgeDays' 14)
        LargeFileThresholdBytes = ([long](Get-WaSectionValue $scanning 'LargeFileThresholdMB' 1024)) * 1MB
        MaxEntriesPerRoot       = [int](Get-WaSectionValue $scanning 'MaxEntriesPerRoot' 50000)
        MaxScanSecondsPerRoot   = [int](Get-WaSectionValue $scanning 'MaxScanSecondsPerRoot' 8)
        MaxLargeFiles           = [int](Get-WaSectionValue $scanning 'MaxLargeFiles' 100)
        DeepScanPaths           = $deepScan
        ExcludedPaths           = $excluded

        # Risk
        MaximumAutoApprovableRisk          = $maximumAutoApprovable
        RequireIndividualApprovalAtOrAbove = $individualThreshold
        AllowManualOnlyExecution           = [bool](Get-WaSectionValue $risk 'AllowManualOnlyExecution' $false)

        # Safety
        CreateRestorePointBeforeHighRisk = [bool](Get-WaSectionValue $safety 'CreateRestorePointBeforeHighRisk' $true)
        RequireSupportedWindows          = [bool](Get-WaSectionValue $safety 'RequireSupportedWindowsForExecution' $true)
        AllowExternalTools               = [bool](Get-WaSectionValue $safety 'AllowExternalTools' $false)
        AllowDismAnalyze                 = [bool](Get-WaSectionValue $safety 'AllowDismAnalyze' $true)

        # Reporting
        ReportFormats           = $formats
        ReportDirectory         = [string](Get-WaSectionValue $reporting 'OutputDirectory' '')
        IncludeProcessPaths     = [bool](Get-WaSectionValue $reporting 'IncludeProcessPaths' $true)
        TopProcessCount         = [int](Get-WaSectionValue $reporting 'TopProcessCount' 25)
        TopStorageConsumerCount = [int](Get-WaSectionValue $reporting 'TopStorageConsumerCount' 40)

        # Logging
        LoggingVerbosity = $verbosity
        RetainSessions   = [int](Get-WaSectionValue $logging 'RetainSessions' 50)

        # Providers
        EnabledProviders  = @(ConvertTo-WaArray (Get-WaSectionValue $providers 'Enabled' @()))
        DisabledProviders = @(ConvertTo-WaArray (Get-WaSectionValue $providers 'Disabled' @()))
        ProviderConfig    = $providerConfig

        Policy = (Get-WaPolicy)
    }

    if ($configuration.MinimumTempAgeDays -lt 0)    { throw 'Scanning.MinimumTempAgeDays cannot be negative.' }
    if ($configuration.MinimumCacheAgeDays -lt 0)   { throw 'Scanning.MinimumCacheAgeDays cannot be negative.' }
    if ($configuration.MaxEntriesPerRoot -lt 1)     { throw 'Scanning.MaxEntriesPerRoot must be at least 1.' }
    if ($configuration.MaxScanSecondsPerRoot -lt 1) { throw 'Scanning.MaxScanSecondsPerRoot must be at least 1.' }

    return $configuration
}

function Get-WaPolicy {
    <#
    .SYNOPSIS
        Loads Config/policies.json and expands its path tokens for this machine.

    .DESCRIPTION
        Cached per session because it is consulted on every candidate file. The cache is
        keyed on nothing: the policy file is not reloaded mid-run on purpose, so policy
        cannot change between the moment a plan is approved and the moment it executes.
    #>
    [CmdletBinding()]
    param([switch]$Force)

    if ($script:WaPolicyCache -and -not $Force) { return $script:WaPolicyCache }

    $policyPath = Join-Path (Get-WaConfigDirectory) 'policies.json'
    $policyFile = Get-WaJsonFile -Path $policyPath
    $basePaths  = Get-WaBasePaths

    $operationPolicy = New-Object 'System.Collections.Hashtable' ([StringComparer]::OrdinalIgnoreCase)
    $rawOperations = ConvertTo-WaHashtable -InputObject (Get-WaProperty -Object $policyFile -Name 'OperationPolicy')
    foreach ($kind in $rawOperations.Keys) {
        $entry = ConvertTo-WaHashtable -InputObject $rawOperations[$kind]
        $minimumRisk = [string](Get-WaSectionValue $entry 'MinimumRisk' 'MANUAL-ONLY')
        [void](Get-WaRiskRank -Risk $minimumRisk)
        $operationPolicy[$kind] = [pscustomobject][ordered]@{
            Kind                       = $kind
            MinimumRisk                = $minimumRisk
            RequiresIndividualApproval = [bool](Get-WaSectionValue $entry 'RequiresIndividualApproval' $false)
            Reversible                 = [bool](Get-WaSectionValue $entry 'Reversible' $false)
            Note                       = [string](Get-WaSectionValue $entry 'Note' '')
        }
    }

    # Every operation kind the engine can perform must have a policy entry. A missing
    # entry would otherwise mean an unpoliced operation.
    foreach ($kind in (Get-WaOperationKinds)) {
        if (-not $operationPolicy.Contains($kind)) {
            throw "Config/policies.json has no OperationPolicy entry for operation kind '$kind'."
        }
    }

    $protectedSection = ConvertTo-WaHashtable -InputObject (Get-WaProperty -Object $policyFile -Name 'ProtectedPaths')
    $protectedPaths = @(
        foreach ($item in (ConvertTo-WaArray (Get-WaSectionValue $protectedSection 'Paths' @()))) {
            $resolved = Expand-WaPathToken -Path ([string]$item) -BasePaths $basePaths
            if ($resolved) { $resolved }
        }
    ) | Select-Object -Unique

    $allowExactRoots = @(
        foreach ($item in (ConvertTo-WaArray (Get-WaSectionValue $protectedSection 'AllowExactRootMatch' @()))) {
            $resolved = Expand-WaPathToken -Path ([string]$item) -BasePaths $basePaths
            if ($resolved) { $resolved }
        }
    ) | Select-Object -Unique

    # Protected as an exact path only. A cleanup root may not be one of these, but their
    # subdirectories stay reachable, which is what keeps per-user caches usable.
    $rootsOnly = @(
        foreach ($item in (ConvertTo-WaArray (Get-WaSectionValue $protectedSection 'RootsOnly' @()))) {
            $resolved = Expand-WaPathToken -Path ([string]$item) -BasePaths $basePaths
            if ($resolved) { $resolved }
        }
    ) | Select-Object -Unique

    $segmentSection = ConvertTo-WaHashtable -InputObject (Get-WaProperty -Object $policyFile -Name 'ProtectedPathSegments')
    $extensionSection = ConvertTo-WaHashtable -InputObject (Get-WaProperty -Object $policyFile -Name 'NeverDeleteExtensions')
    $serviceSection = ConvertTo-WaHashtable -InputObject (Get-WaProperty -Object $policyFile -Name 'ProtectedServices')
    $startupSection = ConvertTo-WaHashtable -InputObject (Get-WaProperty -Object $policyFile -Name 'ProtectedStartupPatterns')
    $serviceRecommendationSection = ConvertTo-WaHashtable -InputObject (Get-WaProperty -Object $policyFile -Name 'ServiceRecommendations')
    $personalSection = ConvertTo-WaHashtable -InputObject (Get-WaProperty -Object $policyFile -Name 'PersonalDataCategories')
    $securitySection = ConvertTo-WaHashtable -InputObject (Get-WaProperty -Object $policyFile -Name 'SecurityFeatures')

    $script:WaPolicyCache = [pscustomobject][ordered]@{
        PSTypeName               = 'WinAdvisor.Policy'
        SchemaVersion            = [int](Get-WaProperty -Object $policyFile -Name 'SchemaVersion' -Default 2)
        SourcePath               = $policyPath
        OperationPolicy          = $operationPolicy
        ProtectedPaths           = @($protectedPaths)
        ProtectedRootsOnly       = @($rootsOnly)
        AllowExactRootMatch      = @($allowExactRoots)
        ProtectedPathSegments    = @(ConvertTo-WaArray (Get-WaSectionValue $segmentSection 'Segments' @()))
        NeverDeleteExtensions    = @(ConvertTo-WaArray (Get-WaSectionValue $extensionSection 'Extensions' @()) | ForEach-Object { ([string]$_).ToLowerInvariant() })
        ProtectedServices        = @(ConvertTo-WaArray (Get-WaSectionValue $serviceSection 'Names' @()))
        ProtectedStartupPatterns = @(ConvertTo-WaArray (Get-WaSectionValue $startupSection 'Patterns' @()))
        ServiceRecommendations   = @(ConvertTo-WaArray (Get-WaSectionValue $serviceRecommendationSection 'Entries' @()))
        PersonalDataCategories   = @(ConvertTo-WaArray (Get-WaSectionValue $personalSection 'Categories' @()))
        SecurityFeatures         = @(ConvertTo-WaArray (Get-WaSectionValue $securitySection 'Names' @()))
    }
    return $script:WaPolicyCache
}

function Get-WaProviderSetting {
    <#
    .SYNOPSIS
        Reads one provider setting, falling back to a caller-supplied default.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$Provider,
        [Parameter(Mandatory)][string]$Name,
        $Default = $null
    )
    $providerConfig = $Config.ProviderConfig
    if (-not $providerConfig.Contains($Provider)) { return $Default }
    $settings = $providerConfig[$Provider].Settings
    return (Get-WaSectionValue -Section $settings -Name $Name -Default $Default)
}

function Test-WaProviderEnabled {
    <#
    .SYNOPSIS
        Decides whether a provider may run, from providers.json plus the user config.

    .DESCRIPTION
        Precedence, strictest first:
          1. Named in Providers.Disabled  -> never runs.
          2. Providers.Enabled is non-empty and this provider is not in it -> does not run.
          3. Enabled flag in providers.json.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string]$Provider)

    if ($Config.DisabledProviders -contains $Provider) { return $false }
    if ($Config.EnabledProviders.Count -gt 0 -and $Config.EnabledProviders -notcontains $Provider) { return $false }

    $providerConfig = $Config.ProviderConfig
    if ($providerConfig.Contains($Provider)) { return [bool]$providerConfig[$Provider].Enabled }
    return $true
}
