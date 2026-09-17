<#
    Core/Common.ps1 - primitive helpers shared by every other component.

    Nothing in this file changes machine state. Invoke-WaNativeProcess starts external
    processes, but only with a fully-resolved executable path and a validated argument
    vector supplied by the command catalog; it never involves a shell.
#>

function Get-WaProperty {
    <#
    .SYNOPSIS
        Reads a property from an object, hashtable or CIM instance without throwing
        under Set-StrictMode when the member does not exist.
    #>
    [CmdletBinding()]
    param(
        $Object,
        [Parameter(Mandatory)][string]$Name,
        $Default = $null
    )
    if ($null -eq $Object) { return $Default }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $Default
    }
    $member = $Object.PSObject.Properties[$Name]
    if ($null -eq $member) { return $Default }
    $value = $member.Value
    if ($null -eq $value) { return $Default }
    return $value
}

function Test-WaAdministrator {
    <#
    .SYNOPSIS
        True when the current process holds the built-in Administrators role.
    #>
    [CmdletBinding()]
    param()
    try {
        $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

function Test-WaWindowsPlatform {
    <#
    .SYNOPSIS
        True on Windows. Used to fail discovery loudly rather than silently producing
        an empty machine profile on a non-Windows host.
    #>
    [CmdletBinding()]
    param()
    $windowsFlag = Get-Variable -Name 'IsWindows' -Scope Global -ErrorAction SilentlyContinue
    if ($null -ne $windowsFlag) { return [bool]$windowsFlag.Value }
    # Windows PowerShell 5.1 has no $IsWindows automatic variable and only runs on Windows.
    return ($env:OS -eq 'Windows_NT')
}

function Get-WaIdentity {
    [CmdletBinding()]
    param()
    $sid = $null
    try { $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value } catch { $sid = $null }
    [pscustomobject][ordered]@{
        MachineName = [Environment]::MachineName
        UserName    = [Environment]::UserName
        UserSid     = $sid
        Is64BitOS   = [Environment]::Is64BitOperatingSystem
        Is64BitProc = [Environment]::Is64BitProcess
    }
}

function Get-WaBasePaths {
    <#
    .SYNOPSIS
        Well-known roots resolved through the .NET special-folder API rather than by
        string-concatenating %USERPROFILE%, so redirected profiles resolve correctly.
    #>
    [CmdletBinding()]
    param()
    $windows = [Environment]::GetFolderPath('Windows')
    if ([string]::IsNullOrWhiteSpace($windows)) { $windows = $env:SystemRoot }
    $userProfile = [Environment]::GetFolderPath('UserProfile')
    [ordered]@{
        LocalAppData    = [Environment]::GetFolderPath('LocalApplicationData')
        RoamingAppData  = [Environment]::GetFolderPath('ApplicationData')
        ProgramData     = [Environment]::GetFolderPath('CommonApplicationData')
        UserProfile     = $userProfile
        ProgramFiles    = [Environment]::GetFolderPath('ProgramFiles')
        ProgramFilesX86 = [Environment]::GetFolderPath('ProgramFilesX86')
        Windows         = $windows
        System          = [Environment]::GetFolderPath('System')
        SystemDrive     = [IO.Path]::GetPathRoot($windows)
        Documents       = [Environment]::GetFolderPath('MyDocuments')
        Downloads       = (Join-Path $userProfile 'Downloads')
        Temp            = ([IO.Path]::GetTempPath()).TrimEnd('\')
    }
}

function Get-WaSystemExecutable {
    <#
    .SYNOPSIS
        Resolves a Windows system executable to a full path under %SystemRoot%\System32.

    .DESCRIPTION
        Never resolved through PATH: a writable PATH entry ahead of System32 would
        otherwise decide which binary the toolkit runs, potentially elevated.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('powercfg.exe', 'Dism.exe', 'wsl.exe', 'schtasks.exe', 'vssadmin.exe', 'fsutil.exe')]
        [string]$Name
    )

    $system = [Environment]::GetFolderPath('System')
    if ([string]::IsNullOrWhiteSpace($system)) { $system = Join-Path $env:SystemRoot 'System32' }

    # A 32-bit process on 64-bit Windows is redirected away from the real System32.
    if (-not [Environment]::Is64BitProcess -and [Environment]::Is64BitOperatingSystem) {
        $native = Join-Path $env:SystemRoot (Join-Path 'Sysnative' $Name)
        if (Test-Path -LiteralPath $native -PathType Leaf) { return $native }
    }
    return (Join-Path $system $Name)
}

function Resolve-WaCommandPath {
    <#
    .SYNOPSIS
        Resolves an external command (docker, dotnet, npm, ...) to a full executable path.

    .DESCRIPTION
        Returns $null when the command is absent, which is how providers report themselves
        unavailable. Only Application command types are accepted, so a PowerShell function
        or alias shadowing the name cannot be executed as though it were the real tool.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)

    if ($Name -match '[\\/]') { return $null }
    try {
        $command = Get-Command -Name $Name -CommandType Application -ErrorAction SilentlyContinue |
                   Select-Object -First 1
        if ($null -eq $command) { return $null }
        $path = [string]$command.Source
        if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
        return $path
    } catch {
        return $null
    }
}

function Invoke-WaNativeProcess {
    <#
    .SYNOPSIS
        Runs an external executable with a validated argument vector and captured output.

    .DESCRIPTION
        Deliberately restrictive:
          * FilePath must be a rooted path to an existing file. No PATH lookup happens here.
          * No shell is used (UseShellExecute = false), so no argument can be interpreted
            as a redirection, pipeline or command separator.
          * Arguments containing a quote or newline are rejected outright, not escaped.
          * Output is captured asynchronously so a chatty tool cannot deadlock the pipe.
          * NeverKill is used for servicing operations (DISM) where terminating the
            process mid-flight can leave the component store needing repair.

    .PARAMETER OnHeartbeat
        Called with the elapsed TimeSpan roughly every HeartbeatSeconds while the process is
        still running. Presentation only: a command that produces no output for minutes is
        otherwise indistinguishable from a hang. Without it the wait is a single blocking
        call, exactly as before.

    .PARAMETER Environment
        Variables set for the child process on top of the inherited environment. This is how
        a documented tool setting that has no command-line form (uv's lock timeout, for
        example) reaches the tool. Names must be plain identifiers and values may not
        contain a newline.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$Arguments = @(),
        [int]$TimeoutSeconds = 120,
        [switch]$NeverKill,
        [string]$WorkingDirectory,
        [scriptblock]$OnHeartbeat,
        [ValidateRange(1, 3600)][int]$HeartbeatSeconds = 5,
        [System.Collections.IDictionary]$Environment = @{}
    )

    if (-not [IO.Path]::IsPathRooted($FilePath)) { throw "Native executable path must be rooted: $FilePath" }
    if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) { throw "Native executable not found: $FilePath" }

    foreach ($argument in $Arguments) {
        if ($null -eq $argument) { throw 'Null native argument rejected.' }
        if ($argument -match '["\r\n]') { throw "Native argument contains a quote or newline and was rejected: $argument" }
    }

    foreach ($name in @($Environment.Keys)) {
        if ([string]$name -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') { throw "Environment variable name was rejected: $name" }
        if ([string]$Environment[$name] -match '[\r\n]') { throw "Environment variable '$name' contains a newline and was rejected." }
    }

    $quoted = foreach ($argument in $Arguments) {
        if ($argument -eq '' -or $argument -match '\s') { '"' + $argument + '"' } else { $argument }
    }

    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName               = $FilePath
    $startInfo.Arguments              = ($quoted -join ' ')
    $startInfo.UseShellExecute        = $false
    $startInfo.CreateNoWindow         = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError  = $true
    if ($WorkingDirectory -and (Test-Path -LiteralPath $WorkingDirectory -PathType Container)) {
        $startInfo.WorkingDirectory = $WorkingDirectory
    }
    foreach ($name in @($Environment.Keys)) {
        $startInfo.EnvironmentVariables[[string]$name] = [string]$Environment[$name]
    }

    $process = New-Object Diagnostics.Process
    $process.StartInfo = $startInfo
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    try {
        [void]$process.Start()
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()

        # The timeout is the same whether or not anyone is watching: with a heartbeat the
        # single wait becomes a series of shorter ones that add up to it.
        $timeoutMs = [long]$TimeoutSeconds * 1000
        $exited = $false
        while (-not $exited) {
            $remainingMs = $timeoutMs - $stopwatch.ElapsedMilliseconds
            if ($remainingMs -le 0) { break }
            $sliceMs = if ($OnHeartbeat) { [Math]::Min([long]$HeartbeatSeconds * 1000, $remainingMs) } else { $remainingMs }
            $exited = $process.WaitForExit([int][Math]::Min($sliceMs, [int]::MaxValue))
            if (-not $exited -and $OnHeartbeat) {
                # A reporting fault must not change how the process itself is treated.
                try { [void](& $OnHeartbeat $stopwatch.Elapsed) } catch { }
            }
        }

        if (-not $exited) {
            if ($NeverKill) {
                throw ("'{0}' is still running after {1}s and was deliberately not terminated. Terminating a servicing operation can corrupt the component store; let it finish and inspect its log." -f [IO.Path]::GetFileName($FilePath), $TimeoutSeconds)
            }
            try { $process.Kill() } catch { }
            throw ("'{0}' exceeded its {1}s timeout and was terminated." -f [IO.Path]::GetFileName($FilePath), $TimeoutSeconds)
        }
        $stopwatch.Stop()

        [pscustomobject][ordered]@{
            FilePath   = $FilePath
            Arguments  = @($Arguments)
            ExitCode   = $process.ExitCode
            Output     = $stdoutTask.GetAwaiter().GetResult()
            Error      = $stderrTask.GetAwaiter().GetResult()
            DurationMs = [int]$stopwatch.Elapsed.TotalMilliseconds
        }
    } finally {
        $process.Dispose()
    }
}

function Invoke-WaProbe {
    <#
    .SYNOPSIS
        Runs one inspection step and converts any failure into a typed, non-fatal result.

    .DESCRIPTION
        Discovery must degrade rather than abort: a missing CIM class, a denied registry
        key or an absent optional tool are all normal on some machines. The distinction
        between "measured and empty" and "could not measure" is preserved in Status, so
        analysis never treats an unreadable location as a zero-byte one.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Script,
        [string]$Category = 'General'
    )
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    try {
        $data = @(& $Script)
        $stopwatch.Stop()
        [pscustomobject][ordered]@{
            Name       = $Name
            Category   = $Category
            Status     = 'Available'
            Data       = $data
            Error      = $null
            DurationMs = [int]$stopwatch.Elapsed.TotalMilliseconds
        }
    } catch {
        $stopwatch.Stop()
        Write-Verbose ("Probe '{0}' failed: {1}" -f $Name, $_.Exception.Message)
        [pscustomobject][ordered]@{
            Name       = $Name
            Category   = $Category
            Status     = 'Unavailable'
            Data       = @()
            Error      = ("{0}: {1}" -f $_.Exception.GetType().Name, $_.Exception.Message)
            DurationMs = [int]$stopwatch.Elapsed.TotalMilliseconds
        }
    }
}

function Get-WaCimData {
    <#
    .SYNOPSIS
        Queries CIM with a bounded timeout and an explicit property projection.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ClassName,
        [string[]]$Property,
        [string]$Namespace = 'root/cimv2',
        [string]$Filter,
        [int]$TimeoutSeconds = 20
    )
    $query = @{
        ClassName           = $ClassName
        Namespace           = $Namespace
        OperationTimeoutSec = $TimeoutSeconds
        ErrorAction         = 'Stop'
    }
    if ($Property) { $query.Property = $Property }
    if ($Filter)   { $query.Filter   = $Filter }

    $instances = Get-CimInstance @query
    if ($Property) { return @($instances | Select-Object -Property $Property) }
    return @($instances)
}

function Format-WaBytes {
    <#
    .SYNOPSIS
        Formats a byte count using binary units, or 'unknown' when the value is absent.

    .DESCRIPTION
        'unknown' and '0 B' render differently on purpose: a location that could not be
        measured must never look like a location that is empty.
    #>
    [CmdletBinding()]
    param($Bytes, [int]$Decimals = 2)

    if ($null -eq $Bytes) { return 'unknown' }
    try { $value = [double]$Bytes } catch { return 'unknown' }
    if ([double]::IsNaN($value) -or [double]::IsInfinity($value)) { return 'unknown' }

    $sign  = if ($value -lt 0) { '-' } else { '' }
    $value = [Math]::Abs($value)
    $units = @('B', 'KiB', 'MiB', 'GiB', 'TiB', 'PiB')
    $index = 0
    while ($value -ge 1024 -and $index -lt ($units.Count - 1)) {
        $value = $value / 1024
        $index++
    }
    if ($index -eq 0) { return ('{0}{1} B' -f $sign, [long]$value) }
    return ('{0}{1} {2}' -f $sign, [Math]::Round($value, $Decimals), $units[$index])
}

function Format-WaDuration {
    [CmdletBinding()]
    param([timespan]$Duration)
    if ($Duration.TotalDays -ge 1)    { return ('{0}d {1}h {2}m' -f [int]$Duration.Days, $Duration.Hours, $Duration.Minutes) }
    if ($Duration.TotalHours -ge 1)   { return ('{0}h {1}m' -f [int]$Duration.Hours, $Duration.Minutes) }
    if ($Duration.TotalMinutes -ge 1) { return ('{0}m {1}s' -f [int]$Duration.Minutes, $Duration.Seconds) }
    return ('{0}s' -f [int]$Duration.TotalSeconds)
}

function Get-WaHash {
    <#
    .SYNOPSIS
        SHA-256 of a UTF-8 string, used for action fingerprints and stable identifiers.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))
        return ([BitConverter]::ToString($bytes)).Replace('-', '').ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

function New-WaIdentifier {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Prefix)
    ('{0}-{1:yyyyMMdd-HHmmss}-{2}' -f $Prefix, [datetime]::Now, ([guid]::NewGuid().ToString('N').Substring(0, 8)))
}

function Get-WaUtcTimestamp {
    [CmdletBinding()]
    param()
    [datetime]::UtcNow.ToString('o')
}

function Get-WaRedactedText {
    <#
    .SYNOPSIS
        Masks values that look like secrets in text destined for a log or report.

    .DESCRIPTION
        Defence in depth. The toolkit does not deliberately collect command lines,
        environment variables or credential stores, but provider output is third-party
        text; anything resembling a token, key or password is masked before it is written.
    #>
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$Text)

    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    $patterns = @(
        '(?i)(password|passwd|pwd|secret|token|api[_-]?key|apikey|access[_-]?key|client[_-]?secret|bearer|authorization)\s*[:=]\s*\S+'
        '(?i)\bgh[pousr]_[A-Za-z0-9]{20,}\b'
        '(?i)\bxox[baprs]-[A-Za-z0-9-]{10,}\b'
        '\bAKIA[0-9A-Z]{16}\b'
        '\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b'
        '-----BEGIN [A-Z ]*PRIVATE KEY-----'
    )
    $result = $Text
    foreach ($pattern in $patterns) {
        $result = [regex]::Replace($result, $pattern, '[redacted]')
    }
    return $result
}

function ConvertTo-WaJson {
    <#
    .SYNOPSIS
        ConvertTo-Json with a depth that survives the nested data model, on 5.1 and 7.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)][AllowNull()]$InputObject,
        [int]$Depth = 12,
        [switch]$Compress
    )
    process {
        $arguments = @{ Depth = $Depth; ErrorAction = 'Stop' }
        if ($Compress) { $arguments.Compress = $true }
        $InputObject | ConvertTo-Json @arguments
    }
}

function Get-WaJsonFile {
    <#
    .SYNOPSIS
        Reads and parses a UTF-8 JSON file, failing with the file name in the message.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "JSON file not found: $Path" }
    try {
        $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { throw 'File is empty.' }
        return ($raw | ConvertFrom-Json -ErrorAction Stop)
    } catch {
        throw ("Could not parse JSON file '{0}': {1}" -f $Path, $_.Exception.Message)
    }
}

function Set-WaJsonFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowNull()]$InputObject,
        [int]$Depth = 12
    )
    $directory = Split-Path -Parent $Path
    if ($directory -and -not (Test-Path -LiteralPath $directory -PathType Container)) {
        [void](New-Item -ItemType Directory -Path $directory -Force)
    }
    $json = ConvertTo-WaJson -InputObject $InputObject -Depth $Depth
    # UTF-8 without BOM keeps the files readable by non-Windows tooling.
    $encoding = New-Object Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($Path, $json, $encoding)
    return $Path
}

function Get-WaModuleRoot {
    [CmdletBinding()]
    param()
    if ($script:WaModuleRoot) { return $script:WaModuleRoot }
    return (Split-Path -Parent $PSScriptRoot)
}

function Get-WaDataRoot {
    <#
    .SYNOPSIS
        Root directory for runtime output (logs, reports, sessions, rollback state).
    #>
    [CmdletBinding()]
    param([switch]$Create)
    $root = Join-Path (Get-WaModuleRoot) 'Data'
    if ($Create -and -not (Test-Path -LiteralPath $root -PathType Container)) {
        [void](New-Item -ItemType Directory -Path $root -Force)
    }
    return $root
}

function Get-WaPercentage {
    [CmdletBinding()]
    param($Part, $Whole, [int]$Decimals = 1)
    if ($null -eq $Part -or $null -eq $Whole) { return $null }
    try {
        $total = [double]$Whole
        if ($total -le 0) { return $null }
        return [Math]::Round((([double]$Part) / $total) * 100, $Decimals)
    } catch { return $null }
}

function ConvertTo-WaArray {
    <#
    .SYNOPSIS
        Normalises a scalar, $null or collection into a plain array.

    .DESCRIPTION
        JSON round-tripping turns single-element arrays into scalars; this keeps
        downstream .Count and foreach handling uniform under Set-StrictMode.
    #>
    [CmdletBinding()]
    param([AllowNull()]$InputObject)

    if ($null -eq $InputObject) { return @() }
    if ($InputObject -is [string]) { return @($InputObject) }
    if ($InputObject -is [object[]]) { return $InputObject }

    # PowerShell 7.6 fails to bind @() around a System.Collections.Generic.List with
    # "ArgumentException: Argument types do not match", so generic lists are converted
    # through their own ToArray() rather than the array subexpression operator.
    $toArray = $InputObject.PSObject.Methods['ToArray']
    if ($null -ne $toArray) {
        try { return @($toArray.Invoke()) } catch { }
    }

    if ($InputObject -is [System.Collections.IEnumerable]) {
        $result = New-Object 'System.Collections.ArrayList'
        foreach ($item in $InputObject) { [void]$result.Add($item) }
        return $result.ToArray()
    }
    return @($InputObject)
}
