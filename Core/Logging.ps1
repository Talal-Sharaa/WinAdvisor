<#
    Core/Logging.ps1 - human-readable and structured logging.

    Two sinks per session:
      Data/Logs/<SessionId>.log    human-readable, one line per event
      Data/Logs/<SessionId>.jsonl  one JSON object per line, for machine consumption

    Every string written through here passes Get-WaRedactedText first. The toolkit does
    not deliberately collect secrets, but provider stdout/stderr is third-party text and
    is treated as untrusted for logging purposes.
#>

$script:WaLogLevels = @{
    'Debug'   = 0
    'Verbose' = 1
    'Info'    = 2
    'Warning' = 3
    'Error'   = 4
}

function Initialize-WaLog {
    <#
    .SYNOPSIS
        Creates the log files for a session and records the opening banner.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session)

    $logDirectory = Join-Path (Get-WaDataRoot -Create) 'Logs'
    if (-not (Test-Path -LiteralPath $logDirectory -PathType Container)) {
        [void](New-Item -ItemType Directory -Path $logDirectory -Force)
    }

    $Session.LogPath     = Join-Path $logDirectory ($Session.Id + '.log')
    $Session.JsonLogPath = Join-Path $logDirectory ($Session.Id + '.jsonl')

    Write-WaLog -Session $Session -Level 'Info' -Category 'Session' -Message (
        'WinAdvisor {0} session {1} started in {2} mode (read-only: {3}, administrator: {4}).' -f
            $Session.Version, $Session.Id, $Session.Mode, $Session.ReadOnly, $Session.IsAdministrator
    )
    return $Session
}

function Get-WaLogThreshold {
    [CmdletBinding()]
    param($Session)
    $verbosity = 'Normal'
    if ($null -ne $Session) {
        $configured = Get-WaProperty -Object (Get-WaProperty -Object $Session -Name 'Config') -Name 'LoggingVerbosity'
        if ($configured) { $verbosity = [string]$configured }
    }
    switch -Exact ($verbosity) {
        'Quiet'    { return $script:WaLogLevels['Warning'] }
        'Normal'   { return $script:WaLogLevels['Info'] }
        'Verbose'  { return $script:WaLogLevels['Verbose'] }
        'Debug'    { return $script:WaLogLevels['Debug'] }
        default    { return $script:WaLogLevels['Info'] }
    }
}

function Write-WaLog {
    <#
    .SYNOPSIS
        Writes one event to both log sinks.

    .PARAMETER Data
        Optional structured payload. It is emitted only to the JSON sink, and is expected
        to already be free of file contents, credentials and command lines.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Session,
        [ValidateSet('Debug', 'Verbose', 'Info', 'Warning', 'Error')][string]$Level = 'Info',
        [Parameter(Mandatory)][AllowEmptyString()][string]$Message,
        [string]$Category = 'General',
        $Data = $null
    )

    if ($null -eq $Session) { return }

    $safeMessage = Get-WaRedactedText -Text $Message
    $timestamp   = Get-WaUtcTimestamp

    # The JSON sink always records everything; the text sink honours the verbosity setting.
    $record = [ordered]@{
        Timestamp = $timestamp
        SessionId = $Session.Id
        Level     = $Level
        Category  = $Category
        Message   = $safeMessage
        Mode      = $Session.Mode
        Data      = $Data
    }

    $jsonPath = Get-WaProperty -Object $Session -Name 'JsonLogPath'
    if ($jsonPath) {
        try {
            $line = ConvertTo-WaJson -InputObject ([pscustomobject]$record) -Depth 12 -Compress
            Add-Content -LiteralPath $jsonPath -Value $line -Encoding UTF8 -ErrorAction Stop
        } catch {
            Write-Verbose ("Structured log write failed: {0}" -f $_.Exception.Message)
        }
    }

    if ($script:WaLogLevels[$Level] -lt (Get-WaLogThreshold -Session $Session)) { return }

    $textPath = Get-WaProperty -Object $Session -Name 'LogPath'
    if ($textPath) {
        $line = '{0}  {1,-7}  {2,-16}  {3}' -f $timestamp, $Level.ToUpperInvariant(), $Category, $safeMessage
        try {
            Add-Content -LiteralPath $textPath -Value $line -Encoding UTF8 -ErrorAction Stop
        } catch {
            Write-Verbose ("Text log write failed: {0}" -f $_.Exception.Message)
        }
    }

    switch ($Level) {
        'Warning' { Write-Warning $safeMessage }
        'Error'   { Write-Verbose ("ERROR: {0}" -f $safeMessage) }
        default   { Write-Verbose $safeMessage }
    }
}

function Write-WaActionLog {
    <#
    .SYNOPSIS
        Records the full audit trail for one attempted action.

    .DESCRIPTION
        This is the record that answers "what did the toolkit do to this machine, when,
        with what authority, and what happened". It captures the before state, the exact
        requested operation, the result and the after state.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)]$Action,
        [Parameter(Mandatory)]$Result
    )

    $recommendation = $Action.Recommendation
    $payload = [ordered]@{
        Timestamp        = Get-WaUtcTimestamp
        SessionId        = $Session.Id
        Mode             = $Session.Mode
        ActionId         = $Action.Id
        Fingerprint      = $Action.Fingerprint
        Provider         = $recommendation.Provider
        Title            = $recommendation.Title
        Category         = $recommendation.Category
        Risk             = $recommendation.Risk
        Confidence       = $recommendation.Confidence
        Reversibility    = $recommendation.Reversibility
        AdminRequired    = $recommendation.AdminRequired
        RestartRequired  = $recommendation.RestartRequired
        Operations       = @($recommendation.Operations | ForEach-Object { '{0}: {1}' -f $_.Kind, $_.Description })
        CommandPreview   = (Get-WaRedactedText -Text $recommendation.CommandPreview)
        ApprovalDecision = (Get-WaProperty -Object $Action.Approval -Name 'Decision' -Default 'None')
        ApprovalScope    = (Get-WaProperty -Object $Action.Approval -Name 'Scope' -Default 'None')
        BeforeState      = $Result.BeforeState
        AfterState       = $Result.AfterState
        Status           = $Result.Status
        BytesReclaimed   = $Result.BytesReclaimed
        Error            = (Get-WaRedactedText -Text $Result.Error)
        DurationMs       = $Result.DurationMs
        RollbackId       = $Result.RollbackId
    }

    Write-WaLog -Session $Session -Level 'Info' -Category 'Action' -Data $payload -Message (
        '{0} [{1}] {2} -> {3}{4}' -f
            $recommendation.Provider,
            $recommendation.Risk,
            $recommendation.Title,
            $Result.Status,
            $(if ($null -ne $Result.BytesReclaimed) { ' (' + (Format-WaBytes $Result.BytesReclaimed) + ' reclaimed)' } else { '' })
    )
}

function Get-WaSessionLogPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session, [ValidateSet('Text', 'Json')][string]$Kind = 'Text')
    if ($Kind -eq 'Json') { return (Get-WaProperty -Object $Session -Name 'JsonLogPath') }
    return (Get-WaProperty -Object $Session -Name 'LogPath')
}
