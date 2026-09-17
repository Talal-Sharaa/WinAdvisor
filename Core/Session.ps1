<#
    Core/Session.ps1 - session lifecycle.

    A session carries the mode, the configuration, everything discovered, everything
    proposed and everything done. Its most important property is ReadOnly.

    ReadOnly is decided once, at construction, from the mode, and is never flipped
    afterwards. Choosing "Interactive Cleanup" from the menu creates a *new* session
    rather than promoting the read-only one, so there is no code path that turns an
    inspection session into one that can change the machine.
#>

# Modes that may never change the machine. Everything except Cleanup and Rollback.
$script:WaReadOnlyModes = @('Menu', 'ViewSpecs', 'Analyze', 'Storage', 'Startup', 'Plan', 'DryRun', 'Report')
$script:WaAllModes = @('Menu', 'ViewSpecs', 'Analyze', 'Storage', 'Startup', 'Plan', 'DryRun', 'Cleanup', 'Report', 'Rollback')

function New-WaSession {
    <#
    .SYNOPSIS
        Creates a session.

    .PARAMETER Mode
        Decides read-only status. Only Cleanup and Rollback produce a mutable session.

    .EXAMPLE
        $session = New-WaSession -Mode DryRun
        $session.ReadOnly   # True
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('Menu', 'ViewSpecs', 'Analyze', 'Storage', 'Startup', 'Plan', 'DryRun', 'Cleanup', 'Report', 'Rollback')][string]$Mode,
        $Config = $null,
        [string]$ConfigPath,
        [string]$ReportPath,
        [string[]]$DeepScanPath,
        [string[]]$IncludeProvider,
        [string[]]$ExcludeProvider,
        [switch]$NonInteractive
    )

    if ($null -eq $Config) {
        $Config = if ($ConfigPath) { Get-WaConfiguration -Path $ConfigPath } else { Get-WaConfiguration }
    }

    if ($DeepScanPath) {
        # An explicit -DeepScanPath is the authorisation for recursion. Configuration
        # alone never triggers a deep scan.
        $Config.DeepScanPaths = @($DeepScanPath | ForEach-Object { Get-WaNormalizedPath -Path $_ })
    }
    if ($IncludeProvider) { $Config.EnabledProviders  = @($IncludeProvider) }
    if ($ExcludeProvider) { $Config.DisabledProviders = @($Config.DisabledProviders + $ExcludeProvider | Select-Object -Unique) }
    if ($ReportPath)      { $Config.ReportDirectory   = $ReportPath }

    $session = [pscustomobject][ordered]@{
        PSTypeName      = 'WinAdvisor.Session'
        Id              = (New-WaIdentifier -Prefix 'WA')
        Version         = '2.0.0'
        Mode            = $Mode
        ReadOnly        = ($script:WaReadOnlyModes -contains $Mode)
        NonInteractive  = [bool]$NonInteractive
        StartedUtc      = (Get-WaUtcTimestamp)
        CompletedUtc    = $null
        IsAdministrator = (Test-WaAdministrator)
        PowerShell      = ('{0} {1}' -f $PSVersionTable.PSEdition, $PSVersionTable.PSVersion)

        Config          = $Config
        ApprovedRoots   = (New-Object 'System.Collections.Hashtable' ([StringComparer]::OrdinalIgnoreCase))
        ProviderState   = (New-Object 'System.Collections.Hashtable' ([StringComparer]::OrdinalIgnoreCase))

        MachineProfile  = $null
        Findings        = @()
        Recommendations = @()
        Questions       = @()
        Plan            = $null
        Results         = @()
        Baseline        = $null
        Verification    = $null
        RollbackRecords = @()

        LogPath           = $null
        JsonLogPath       = $null
        RollbackDirectory = $null
        ReportPaths       = @()
        Warnings          = @()
    }

    [void](Initialize-WaLog -Session $session)
    return $session
}

function Test-WaSessionReadOnly {
    <#
    .SYNOPSIS
        True when this session may not change the machine.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session)
    return [bool]$Session.ReadOnly
}

function Add-WaSessionWarning {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)][string]$Message)
    $Session.Warnings = @($Session.Warnings + $Message | Select-Object -Unique)
    Write-WaLog -Session $Session -Level 'Warning' -Category 'Session' -Message $Message
}

function Complete-WaSession {
    <#
    .SYNOPSIS
        Marks a session finished and writes its record to Data/Sessions.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session)

    $Session.CompletedUtc = Get-WaUtcTimestamp
    Write-WaLog -Session $Session -Level 'Info' -Category 'Session' -Message (
        'Session {0} finished. {1} finding(s), {2} recommendation(s), {3} executed action(s).' -f
            $Session.Id, @($Session.Findings).Count, @($Session.Recommendations).Count, @($Session.Results).Count
    )
    [void](Save-WaSession -Session $Session)
    return $Session
}

function Save-WaSession {
    <#
    .SYNOPSIS
        Persists a session summary to Data/Sessions/<id>.json.

    .DESCRIPTION
        Deliberately a summary, not a full dump: file manifests can hold tens of thousands
        of paths, and persisting them would turn a session record into an inventory of the
        user's disk. What is kept is enough to reconstruct what was proposed and done.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session)

    $directory = Join-Path (Get-WaDataRoot -Create) 'Sessions'
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        [void](New-Item -ItemType Directory -Path $directory -Force)
    }

    $record = [ordered]@{
        Id              = $Session.Id
        Version         = $Session.Version
        Mode            = $Session.Mode
        ReadOnly        = $Session.ReadOnly
        StartedUtc      = $Session.StartedUtc
        CompletedUtc    = $Session.CompletedUtc
        IsAdministrator = $Session.IsAdministrator
        PowerShell      = $Session.PowerShell
        Machine         = (Get-WaProperty -Object (Get-WaProperty -Object $Session.MachineProfile -Name 'Identity') -Name 'MachineName')
        Findings        = @($Session.Findings | ForEach-Object {
            [ordered]@{ Id = $_.Id; Title = $_.Title; Category = $_.Category; Provider = $_.Provider; Confidence = $_.Confidence; Bytes = $_.Bytes }
        })
        Recommendations = @($Session.Recommendations | ForEach-Object {
            [ordered]@{
                Id = $_.Id; Title = $_.Title; Provider = $_.Provider; Risk = $_.Risk; Confidence = $_.Confidence
                EstimatedBytes = $_.EstimatedBytes; MeasuredBytes = $_.MeasuredBytes
                AdminRequired = $_.AdminRequired; RestartRequired = $_.RestartRequired
                CommandPreview = (Get-WaRedactedText -Text $_.CommandPreview)
            }
        })
        Results = @($Session.Results | ForEach-Object {
            [ordered]@{
                ActionId = $_.ActionId; Provider = $_.Provider; Status = $_.Status
                BytesReclaimed = $_.BytesReclaimed; Error = (Get-WaRedactedText -Text $_.Error)
                DurationMs = $_.DurationMs; RollbackId = $_.RollbackId
            }
        })
        Warnings    = @($Session.Warnings)
        ReportPaths = @($Session.ReportPaths)
        LogPath     = $Session.LogPath
    }

    $path = Join-Path $directory ($Session.Id + '.json')
    return (Set-WaJsonFile -Path $path -InputObject ([pscustomobject]$record) -Depth 10)
}

function Get-WaSessionRecord {
    <#
    .SYNOPSIS
        Lists persisted session records, newest first.
    #>
    [CmdletBinding()]
    param([int]$Last = 20)

    $directory = Join-Path (Get-WaDataRoot) 'Sessions'
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) { return @() }

    @(Get-ChildItem -LiteralPath $directory -Filter '*.json' -File |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First $Last |
        ForEach-Object {
            try { Get-WaJsonFile -Path $_.FullName } catch { $null }
        } | Where-Object { $null -ne $_ })
}
