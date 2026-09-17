<#
    Core/Reporting.ps1 - HTML and JSON reporting.

    The HTML report is a single self-contained file with no external resources: no CDN, no
    fonts, no scripts fetched at view time. A maintenance report describing a specific
    machine should not phone anywhere when it is opened, and it has to work on a machine
    with no network.

    Reports never contain process command lines, credentials, tokens or file contents.
    Machine serial numbers appear masked. Every string written passes the redaction filter.
#>

function ConvertTo-WaHtmlText {
    <#
    .SYNOPSIS
        HTML-encodes a value. Report content includes third-party strings, so everything
        that reaches the document is encoded.
    #>
    [CmdletBinding()]
    param([AllowNull()]$Value)

    if ($null -eq $Value) { return '<span class="muted">unknown</span>' }
    $text = [string]$Value
    if ([string]::IsNullOrEmpty($text)) { return '' }
    $text = Get-WaRedactedText -Text $text
    return ($text -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;' -replace '"', '&quot;' -replace "'", '&#39;')
}

function New-WaHtmlTable {
    <#
    .SYNOPSIS
        Renders rows as an HTML table using an ordered column specification.

    .PARAMETER Column
        Ordered dictionary of header text to a scriptblock producing the cell value.
    #>
    [CmdletBinding()]
    param(
        [object[]]$Row = @(),
        [Parameter(Mandatory)][System.Collections.IDictionary]$Column,
        [string]$EmptyMessage = 'Nothing to report.'
    )

    if (@($Row).Count -eq 0) {
        return ('<p class="muted">{0}</p>' -f (ConvertTo-WaHtmlText $EmptyMessage))
    }

    $builder = New-Object Text.StringBuilder
    [void]$builder.Append('<table><thead><tr>')
    foreach ($header in $Column.Keys) {
        [void]$builder.Append('<th>' + (ConvertTo-WaHtmlText $header) + '</th>')
    }
    [void]$builder.Append('</tr></thead><tbody>')

    foreach ($item in $Row) {
        [void]$builder.Append('<tr>')
        foreach ($header in $Column.Keys) {
            $cell = ''
            try { $cell = & $Column[$header] $item } catch { $cell = '' }
            [void]$builder.Append('<td>' + $cell + '</td>')
        }
        [void]$builder.Append('</tr>')
    }
    [void]$builder.Append('</tbody></table>')
    return $builder.ToString()
}

function New-WaRiskBadge {
    [CmdletBinding()]
    param([string]$Risk)
    $class = switch ($Risk) {
        'SAFE'        { 'badge safe' }
        'LOW'         { 'badge low' }
        'MODERATE'    { 'badge moderate' }
        'HIGH'        { 'badge high' }
        'MANUAL-ONLY' { 'badge manual' }
        default       { 'badge' }
    }
    return ('<span class="{0}">{1}</span>' -f $class, (ConvertTo-WaHtmlText $Risk))
}

function New-WaConfidenceBadge {
    [CmdletBinding()]
    param([string]$Confidence)
    $class = switch ($Confidence) {
        'HIGH'    { 'badge conf-high' }
        'MEDIUM'  { 'badge conf-medium' }
        'LOW'     { 'badge conf-low' }
        default   { 'badge conf-unknown' }
    }
    return ('<span class="{0}">{1}</span>' -f $class, (ConvertTo-WaHtmlText $Confidence))
}

function New-WaHtmlOutcomeSection {
    <#
    .SYNOPSIS
        The measured outcome of a run, as the opening section of the report.

    .DESCRIPTION
        What was recovered is the reason the report exists, so it is the headline rather
        than a footnote: everything below it in the report is the evidence behind it.

        The three figures are deliberately kept apart rather than reconciled into one
        number. Measured-during-execution is what each action counted as it worked and is
        the defensible figure; free-space change is the volume delta, which Windows moves
        continuously for reasons of its own; the prediction is what analysis expected before
        anything ran. Presenting them together is what makes the claim checkable.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Verification)

    $html = New-Object Text.StringBuilder

    [void]$html.Append('<h2>What this run recovered</h2>')
    [void]$html.Append(('<div class="cards"><div class="card"><div class="label">Measured during execution</div><div class="value">{0}</div><div class="sub">the defensible figure</div></div><div class="card"><div class="label">Free-space change</div><div class="value">{1}</div><div class="sub">context only; the system writes to disk throughout</div></div><div class="card"><div class="label">Predicted</div><div class="value">{2}</div><div class="sub">estimate before execution</div></div><div class="card"><div class="label">Actions</div><div class="value">{3}</div><div class="sub">succeeded / failed / skipped</div></div></div>' -f
        (ConvertTo-WaHtmlText (Format-WaBytes $Verification.ReportedBytesReclaimed)),
        (ConvertTo-WaHtmlText (Format-WaBytes $Verification.VolumeFreeSpaceDelta)),
        (ConvertTo-WaHtmlText (Format-WaBytes $Verification.EstimatedBytes)),
        (ConvertTo-WaHtmlText ('{0} / {1} / {2}' -f $Verification.Succeeded, $Verification.Failed, $Verification.Skipped))))

    [void]$html.Append((New-WaHtmlTable -Row @($Verification.Metrics | Where-Object { $_.Changed }) -Column ([ordered]@{
        'Metric' = { param($r) ConvertTo-WaHtmlText $r.Name }
        'Before' = { param($r) ConvertTo-WaHtmlText $r.BeforeText }
        'After'  = { param($r) ConvertTo-WaHtmlText $r.AfterText }
    }) -EmptyMessage 'No measured quantity changed.'))

    [void]$html.Append(('<div class="note">{0}</div>' -f (ConvertTo-WaHtmlText (@($Verification.Notes) -join ' '))))
    [void]$html.Append('<div class="note">Action by action, with what each one reported: <a href="#what-was-done">What was done</a>.</div>')

    return $html.ToString()
}

function Get-WaReportStyle {
    <#
    .SYNOPSIS
        The report stylesheet. Inline, and respects the reader's colour-scheme preference.
    #>
    [CmdletBinding()]
    param()
@'
:root {
  --bg: #ffffff; --fg: #1a1c1f; --muted: #626a73; --line: #e3e6ea;
  --panel: #f7f8fa; --accent: #2c5aa0;
  --safe: #1f7a3d; --low: #3a7d44; --moderate: #9a6700; --high: #b3261e; --manual: #5b4bb5;
}
@media (prefers-color-scheme: dark) {
  :root {
    --bg: #14161a; --fg: #e6e8eb; --muted: #9aa3ad; --line: #2a2f36;
    --panel: #1b1e24; --accent: #7aa7e8;
    --safe: #4cc38a; --low: #5fbf7e; --moderate: #e0a300; --high: #ef6b62; --manual: #a99bf0;
  }
}
* { box-sizing: border-box; }
body {
  margin: 0; padding: 0 16px 64px; background: var(--bg); color: var(--fg);
  font: 15px/1.6 "Segoe UI", system-ui, -apple-system, sans-serif;
}
.wrap { max-width: 1100px; margin: 0 auto; }
header { padding: 32px 0 16px; border-bottom: 2px solid var(--line); margin-bottom: 24px; }
h1 { font-size: 26px; margin: 0 0 6px; letter-spacing: -0.02em; }
h2 { font-size: 19px; margin: 40px 0 10px; padding-bottom: 6px; border-bottom: 1px solid var(--line); }
h3 { font-size: 15px; margin: 22px 0 8px; color: var(--muted); text-transform: uppercase; letter-spacing: 0.06em; }
p { margin: 8px 0; }
.muted { color: var(--muted); }
.sub { color: var(--muted); font-size: 13px; }
table { width: 100%; border-collapse: collapse; margin: 10px 0 18px; font-size: 14px; }
th, td { text-align: left; padding: 7px 10px; border-bottom: 1px solid var(--line); vertical-align: top; }
th { font-weight: 600; color: var(--muted); font-size: 12px; text-transform: uppercase; letter-spacing: 0.04em; }
tbody tr:hover { background: var(--panel); }
.cards { display: flex; flex-wrap: wrap; gap: 12px; margin: 16px 0 8px; }
.card { flex: 1 1 200px; background: var(--panel); border: 1px solid var(--line); border-radius: 8px; padding: 14px 16px; }
.card .label { font-size: 12px; color: var(--muted); text-transform: uppercase; letter-spacing: 0.05em; }
.card .value { font-size: 22px; font-weight: 600; margin-top: 4px; }
.badge { display: inline-block; padding: 2px 8px; border-radius: 10px; font-size: 11px; font-weight: 700; letter-spacing: 0.04em; border: 1px solid currentColor; white-space: nowrap; }
.safe { color: var(--safe); } .low { color: var(--low); } .moderate { color: var(--moderate); }
.high { color: var(--high); } .manual { color: var(--manual); }
.conf-high { color: var(--safe); } .conf-medium { color: var(--moderate); }
.conf-low { color: var(--high); } .conf-unknown { color: var(--muted); }
.note { background: var(--panel); border-left: 3px solid var(--accent); padding: 10px 14px; margin: 14px 0; border-radius: 0 6px 6px 0; font-size: 14px; }
.warn { border-left-color: var(--high); }
code { background: var(--panel); border: 1px solid var(--line); border-radius: 4px; padding: 1px 5px; font-family: Consolas, "Cascadia Mono", monospace; font-size: 13px; word-break: break-all; }
ul { margin: 6px 0; padding-left: 20px; }
li { margin: 3px 0; }
footer { margin-top: 48px; padding-top: 16px; border-top: 1px solid var(--line); color: var(--muted); font-size: 13px; }
.bar { height: 7px; background: var(--line); border-radius: 4px; overflow: hidden; margin-top: 5px; }
.bar > span { display: block; height: 100%; background: var(--accent); }
@media (max-width: 640px) {
  table { font-size: 13px; } th, td { padding: 6px; }
  .card { flex-basis: 100%; }
}
'@
}

function Export-WaReport {
    <#
    .SYNOPSIS
        Writes the HTML and JSON reports for a session.

    .PARAMETER Format
        Html, Json, or both. Defaults to the configured Reporting.Formats.

    .EXAMPLE
        Export-WaReport -Session $session -Analysis $analysis
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Session,
        $Analysis = $null,
        [string]$Path,
        [ValidateSet('Html', 'Json')][string[]]$Format
    )

    if (-not $Format) { $Format = @($Session.Config.ReportFormats) }

    $directory = $Path
    if (-not $directory) { $directory = $Session.Config.ReportDirectory }
    if (-not $directory) { $directory = Join-Path (Get-WaDataRoot -Create) 'Reports' }
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        [void](New-Item -ItemType Directory -Path $directory -Force)
    }

    $written = New-Object 'System.Collections.Generic.List[string]'

    if ($Format -contains 'Html') {
        $htmlPath = Join-Path $directory ($Session.Id + '.html')
        $html = New-WaHtmlReport -Session $Session -Analysis $Analysis
        $encoding = New-Object Text.UTF8Encoding($false)
        [IO.File]::WriteAllText($htmlPath, $html, $encoding)
        $written.Add($htmlPath)
    }

    if ($Format -contains 'Json') {
        $jsonPath = Join-Path $directory ($Session.Id + '.json')
        [void](Set-WaJsonFile -Path $jsonPath -InputObject (New-WaReportObject -Session $Session -Analysis $Analysis) -Depth 14)
        $written.Add($jsonPath)
    }

    $Session.ReportPaths = @($Session.ReportPaths + $written)
    foreach ($file in $written) {
        Write-WaLog -Session $Session -Level 'Info' -Category 'Reporting' -Message ('Report written: {0}' -f $file)
    }
    return $written.ToArray()
}

function ConvertTo-WaReportRecommendation {
    <#
    .SYNOPSIS
        Projects a recommendation for the report, summarising its operations.

    .DESCRIPTION
        A FileDelete operation carries a manifest that can hold tens of thousands of paths.
        Embedding those would make the report enormous and, more to the point, would turn a
        maintenance report into an inventory of the user's disk, which is the reason session
        records summarise rather than dump. The manifest is replaced by its shape: how many
        files, how many bytes, and under which root.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Recommendation)

    $operations = @(foreach ($operation in $Recommendation.Operations) {
        $summary = [ordered]@{
            Kind          = $operation.Kind
            Description   = $operation.Description
            RequiresAdmin = $operation.RequiresAdmin
            Restart       = $operation.Restart
        }
        $parameters = $operation.Parameters
        if ($null -ne $parameters) {
            foreach ($key in @($parameters.Keys)) {
                if ($key -eq 'Files') {
                    $files = @($parameters[$key])
                    $summary['FileCount'] = $files.Count
                    $summary['FileBytes'] = [long](($files | ForEach-Object { [long]$_.Length }) | Measure-Object -Sum).Sum
                    continue
                }
                $value = $parameters[$key]
                if ($value -is [datetime]) { $value = $value.ToString('o') }
                $summary[$key] = $value
            }
        }
        [pscustomobject]$summary
    })

    [pscustomobject][ordered]@{
        Id                         = $Recommendation.Id
        Title                      = $Recommendation.Title
        Category                   = $Recommendation.Category
        Provider                   = $Recommendation.Provider
        Description                = $Recommendation.Description
        Evidence                   = @($Recommendation.Evidence)
        CurrentImpact              = $Recommendation.CurrentImpact
        EstimatedBytes             = $Recommendation.EstimatedBytes
        BenefitClass               = $Recommendation.BenefitClass
        EstimatedBenefit           = $Recommendation.EstimatedBenefit
        EstimateComplete           = $Recommendation.EstimateComplete
        MeasuredBytes              = $Recommendation.MeasuredBytes
        MeasuredBenefit            = $Recommendation.MeasuredBenefit
        Risk                       = $Recommendation.Risk
        Confidence                 = $Recommendation.Confidence
        Reversibility              = $Recommendation.Reversibility
        RollbackNote               = $Recommendation.RollbackNote
        Operations                 = $operations
        CommandPreview             = (Get-WaRedactedText -Text $Recommendation.CommandPreview)
        Mechanism                  = $Recommendation.Mechanism
        AdminRequired              = $Recommendation.AdminRequired
        RestartRequired            = $Recommendation.RestartRequired
        IndividualApprovalRequired = $Recommendation.IndividualApprovalRequired
        Prerequisites              = @($Recommendation.Prerequisites)
        Warnings                   = @($Recommendation.Warnings)
        Consequence                = $Recommendation.Consequence
        AffectsPersonalData        = $Recommendation.AffectsPersonalData
        QuestionId                 = $Recommendation.QuestionId
        Reference                  = $Recommendation.Reference
    }
}

function New-WaReportObject {
    <#
    .SYNOPSIS
        The structured report: the same content as the HTML, for machine consumption.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session, $Analysis = $null)

    $machineProfile = $Session.MachineProfile

    [pscustomobject][ordered]@{
        SchemaVersion = 2
        Generator     = ('WinAdvisor {0}' -f $Session.Version)
        GeneratedUtc  = (Get-WaUtcTimestamp)
        Session = [ordered]@{
            Id              = $Session.Id
            Mode            = $Session.Mode
            ReadOnly        = $Session.ReadOnly
            StartedUtc      = $Session.StartedUtc
            CompletedUtc    = $Session.CompletedUtc
            IsAdministrator = $Session.IsAdministrator
            PowerShell      = $Session.PowerShell
        }
        Machine = $(if ($null -ne $machineProfile) {
            [ordered]@{
                Identity             = $machineProfile.Identity
                OperatingSystem      = $machineProfile.OperatingSystem
                Hardware             = $machineProfile.Hardware
                Processor            = $machineProfile.Processor
                Memory               = $machineProfile.Memory
                Graphics             = $machineProfile.Graphics
                Storage              = $machineProfile.Storage
                Pagefile             = $machineProfile.Pagefile
                Hibernation          = $machineProfile.Hibernation
                Power                = $machineProfile.Power
                SystemProtection     = $machineProfile.SystemProtection
                Update               = $machineProfile.Update
                ComponentStore       = $machineProfile.ComponentStore
                OptionalFeatures     = $machineProfile.OptionalFeatures
                DeliveryOptimization = $machineProfile.DeliveryOptimization
                Workloads            = $machineProfile.Workloads
                Startup              = $machineProfile.Startup
                Processes            = $machineProfile.Processes
                Support              = $machineProfile.Support
            }
        } else { $null })
        Findings        = @($Session.Findings)
        # Projected rather than dumped: see ConvertTo-WaReportRecommendation.
        Recommendations = @($Session.Recommendations | ForEach-Object { ConvertTo-WaReportRecommendation -Recommendation $_ })
        Questions       = @($Session.Questions | ForEach-Object {
            [ordered]@{ Id = $_.Id; Prompt = $_.Prompt; Context = $_.Context; Answer = (Get-WaProperty -Object $_.Answer -Name 'Label') }
        })
        Plan            = $(if ($null -ne $Session.Plan) { $Session.Plan.Summary } else { $null })
        Results         = @($Session.Results)
        Verification    = $Session.Verification
        RollbackRecords = @($Session.RollbackRecords | ForEach-Object {
            [ordered]@{ Id = $_.Id; Kind = $_.Kind; Target = $_.Target; RestoreDescription = $_.RestoreDescription; Restored = $_.Restored }
        })
        ProviderStatus  = $(if ($null -ne $Analysis) { @($Analysis.ProviderStatus) } else { @() })
        StorageAnalysis = $(if ($null -ne $Analysis) { Get-WaStorageAnalysis -Session $Session -Analysis $Analysis } else { $null })
        Warnings        = @($Session.Warnings)
        Disclaimers     = @(
            'Storage figures are logical file sizes and may differ from physical allocation on compressed, deduplicated or sparse volumes.'
            'A location that could not be measured is reported as unknown, never as zero.'
            'No performance improvement is claimed anywhere in this report. Storage recovered and configuration changed are measured; speed is not.'
            'File manifests are summarised by count and size rather than listed. A maintenance report should not become an inventory of your disk.'
        )
    }
}

function New-WaHtmlReport {
    <#
    .SYNOPSIS
        Builds the complete self-contained HTML report.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session, $Analysis = $null)

    $machineProfile = $Session.MachineProfile
    $body = New-Object Text.StringBuilder

    $append = { param([string]$Html) [void]$body.Append($Html) }

    # ------------------------------------------------------------------ header
    $operatingSystem = Get-WaProperty -Object $machineProfile -Name 'OperatingSystem'
    $hardware        = Get-WaProperty -Object $machineProfile -Name 'Hardware'
    $identity        = Get-WaProperty -Object $machineProfile -Name 'Identity'

    & $append ('<header><h1>WinAdvisor maintenance report</h1><p class="sub">{0} &middot; session {1} &middot; {2} mode{3} &middot; generated {4}</p></header>' -f
        (ConvertTo-WaHtmlText (Get-WaProperty -Object $identity -Name 'MachineName' -Default 'this machine')),
        (ConvertTo-WaHtmlText $Session.Id),
        (ConvertTo-WaHtmlText $Session.Mode),
        $(if ($Session.ReadOnly) { ' <span class="badge safe">READ-ONLY</span>' } else { '' }),
        (ConvertTo-WaHtmlText (Get-WaUtcTimestamp)))

    if ($Session.ReadOnly) {
        & $append '<div class="note">This was a read-only session. Nothing on this machine was changed.</div>'
    }

    # ----------------------------------------------------------------- outcome
    # First, because it is the answer to the question the reader opened the report with.
    # Everything after it is the evidence: what ran, what it measured, and how to undo it.
    if ($null -ne $Session.Verification) {
        & $append (New-WaHtmlOutcomeSection -Verification $Session.Verification)
    }

    # ---------------------------------------------------------- machine overview
    & $append '<h2>Machine overview</h2>'
    & $append (New-WaHtmlTable -Row @(
        [pscustomobject]@{ K = 'Windows';        V = ('{0} {1} (build {2})' -f (Get-WaProperty -Object $operatingSystem -Name 'ProductName'), (Get-WaProperty -Object $operatingSystem -Name 'DisplayVersion'), (Get-WaProperty -Object $operatingSystem -Name 'FullBuild')) }
        [pscustomobject]@{ K = 'Edition';        V = (Get-WaProperty -Object $operatingSystem -Name 'EditionId') }
        [pscustomobject]@{ K = 'Architecture';   V = (Get-WaProperty -Object $operatingSystem -Name 'Architecture') }
        [pscustomobject]@{ K = 'Installed';      V = (Get-WaProperty -Object $operatingSystem -Name 'InstallDate') }
        [pscustomobject]@{ K = 'Uptime';         V = (Get-WaProperty -Object $operatingSystem -Name 'UptimeText') }
        [pscustomobject]@{ K = 'Manufacturer';   V = (Get-WaProperty -Object $hardware -Name 'Manufacturer') }
        [pscustomobject]@{ K = 'Model';          V = (Get-WaProperty -Object $hardware -Name 'Model') }
        [pscustomobject]@{ K = 'Chassis';        V = (Get-WaProperty -Object $hardware -Name 'ChassisType') }
        [pscustomobject]@{ K = 'Firmware';       V = ('{0}, BIOS {1} ({2})' -f (Get-WaProperty -Object $hardware -Name 'FirmwareType'), (Get-WaProperty -Object $hardware -Name 'BiosVersion'), (Get-WaProperty -Object $hardware -Name 'BiosReleaseDate')) }
        [pscustomobject]@{ K = 'Secure Boot';    V = (Get-WaProperty -Object $hardware -Name 'SecureBoot') }
        [pscustomobject]@{ K = 'Hypervisor';     V = (Get-WaProperty -Object $hardware -Name 'HypervisorPresent') }
        [pscustomobject]@{ K = 'Serial (masked)'; V = (Get-WaProperty -Object $hardware -Name 'BiosSerialMasked') }
        [pscustomobject]@{ K = 'Domain joined';  V = (Get-WaProperty -Object $hardware -Name 'PartOfDomain') }
        [pscustomobject]@{ K = 'Run elevated';   V = $Session.IsAdministrator }
        [pscustomobject]@{ K = 'PowerShell';     V = $Session.PowerShell }
    ) -Column ([ordered]@{
        'Property' = { param($r) '<strong>' + (ConvertTo-WaHtmlText $r.K) + '</strong>' }
        'Value'    = { param($r) ConvertTo-WaHtmlText $r.V }
    }))

    # --------------------------------------------------------------- hardware
    & $append '<h2>Hardware</h2><h3>Processor</h3>'
    & $append (New-WaHtmlTable -Row @($machineProfile.Processor) -Column ([ordered]@{
        'Model'       = { param($r) ConvertTo-WaHtmlText $r.Name }
        'Arch'        = { param($r) ConvertTo-WaHtmlText $r.Architecture }
        'Cores'       = { param($r) ConvertTo-WaHtmlText $r.PhysicalCores }
        'Threads'     = { param($r) ConvertTo-WaHtmlText $r.LogicalProcessors }
        'Max clock'   = { param($r) ConvertTo-WaHtmlText (('{0} MHz' -f $r.MaxClockMhz)) }
        'Virtualization' = { param($r) ConvertTo-WaHtmlText $r.VirtualizationFirmwareEnabled }
    }))

    $memory = $machineProfile.Memory
    if ($null -ne $memory) {
        & $append '<h3>Memory</h3>'
        & $append ('<div class="cards"><div class="card"><div class="label">Installed</div><div class="value">{0}</div></div><div class="card"><div class="label">Available</div><div class="value">{1}</div></div><div class="card"><div class="label">Commit charge</div><div class="value">{2}</div><div class="sub">{3} of {4}</div></div></div>' -f
            (ConvertTo-WaHtmlText (Format-WaBytes $memory.TotalBytes)),
            (ConvertTo-WaHtmlText (Format-WaBytes $memory.AvailableBytes)),
            (ConvertTo-WaHtmlText $(if ($null -ne $memory.CommitPercent) { ('{0}%' -f $memory.CommitPercent) } else { 'unknown' })),
            (ConvertTo-WaHtmlText (Format-WaBytes $memory.CommittedBytes)),
            (ConvertTo-WaHtmlText (Format-WaBytes $memory.CommitLimitBytes)))
        & $append ('<div class="note">{0}</div>' -f (ConvertTo-WaHtmlText $memory.PressureNote))
        & $append (New-WaHtmlTable -Row @($memory.Modules) -Column ([ordered]@{
            'Slot'       = { param($r) ConvertTo-WaHtmlText $r.Slot }
            'Capacity'   = { param($r) ConvertTo-WaHtmlText (Format-WaBytes $r.CapacityBytes) }
            'Type'       = { param($r) ConvertTo-WaHtmlText $r.MemoryType }
            'Rated'      = { param($r) ConvertTo-WaHtmlText (('{0} MHz' -f $r.RatedSpeedMhz)) }
            'Configured' = { param($r) ConvertTo-WaHtmlText (('{0} MHz' -f $r.ConfiguredMhz)) }
            'Vendor'     = { param($r) ConvertTo-WaHtmlText $r.Manufacturer }
        } ) -EmptyMessage 'Memory module detail was not readable.')
    }

    & $append '<h3>Graphics</h3>'
    & $append (New-WaHtmlTable -Row @($machineProfile.Graphics) -Column ([ordered]@{
        'Adapter'     = { param($r) ConvertTo-WaHtmlText $r.Name }
        'Vendor'      = { param($r) ConvertTo-WaHtmlText $r.Vendor }
        'VRAM'        = { param($r) ConvertTo-WaHtmlText (Format-WaBytes $r.VramBytes) }
        'Driver'      = { param($r) ConvertTo-WaHtmlText $r.DriverVersion }
        'Driver date' = { param($r) ConvertTo-WaHtmlText $r.DriverDate }
        'Active'      = { param($r) ConvertTo-WaHtmlText $r.Active }
    }))

    # ---------------------------------------------------------------- storage
    $storage = $machineProfile.Storage
    if ($null -ne $storage) {
        & $append '<h2>Storage</h2><h3>Physical disks</h3>'
        & $append (New-WaHtmlTable -Row @($storage.PhysicalDisks) -Column ([ordered]@{
            'Disk'   = { param($r) ConvertTo-WaHtmlText $r.FriendlyName }
            'Kind'   = { param($r) ConvertTo-WaHtmlText $r.DriveKind }
            'Bus'    = { param($r) ConvertTo-WaHtmlText $r.BusType }
            'Size'   = { param($r) ConvertTo-WaHtmlText (Format-WaBytes $r.SizeBytes) }
            'Health' = { param($r) ConvertTo-WaHtmlText $r.HealthStatus }
        }) -EmptyMessage 'Physical disk detail was not readable.')

        & $append '<h3>Volumes</h3>'
        & $append (New-WaHtmlTable -Row @($storage.Volumes) -Column ([ordered]@{
            'Volume' = { param($r) ConvertTo-WaHtmlText (('{0} {1}' -f $r.Drive, $r.VolumeName)) }
            'File system' = { param($r) ConvertTo-WaHtmlText $r.FileSystem }
            'Size'   = { param($r) ConvertTo-WaHtmlText (Format-WaBytes $r.SizeBytes) }
            'Used'   = { param($r) ConvertTo-WaHtmlText (Format-WaBytes $r.UsedBytes) }
            'Free'   = { param($r) ConvertTo-WaHtmlText (Format-WaBytes $r.FreeBytes) }
            'Utilisation' = { param($r)
                $percent = $r.UsedPercent
                if ($null -eq $percent) { return '<span class="muted">unknown</span>' }
                ('{0}%<div class="bar"><span style="width:{0}%"></span></div>' -f $percent)
            }
        }))

        if (@($storage.BitLocker).Count -gt 0) {
            & $append '<h3>BitLocker</h3>'
            & $append (New-WaHtmlTable -Row @($storage.BitLocker) -Column ([ordered]@{
                'Mount point' = { param($r) ConvertTo-WaHtmlText $r.MountPoint }
                'Status'      = { param($r) ConvertTo-WaHtmlText $r.VolumeStatus }
                'Protection'  = { param($r) ConvertTo-WaHtmlText $r.ProtectionStatus }
                'Encrypted %' = { param($r) ConvertTo-WaHtmlText $r.EncryptionPercentage }
            }))
        } elseif ($storage.BitLockerNote) {
            & $append ('<h3>BitLocker</h3><p class="muted">{0}</p>' -f (ConvertTo-WaHtmlText $storage.BitLockerNote))
        }
    }

    if ($null -ne $Analysis) {
        $storageAnalysis = Get-WaStorageAnalysis -Session $Session -Analysis $Analysis
        & $append '<h3>Storage attribution</h3>'
        & $append (New-WaHtmlTable -Row @($storageAnalysis.Categories) -Column ([ordered]@{
            'Category' = { param($r) ConvertTo-WaHtmlText $r.Category }
            'Measured' = { param($r) ConvertTo-WaHtmlText (Format-WaBytes $r.Bytes) }
            'Items'    = { param($r) ConvertTo-WaHtmlText $r.Items }
            'Complete' = { param($r) if ($r.Complete) { 'yes' } else { '<span class="muted">partial (lower bound)</span>' } }
        }) -EmptyMessage 'No storage categories were measured.')
        & $append ('<div class="note">Attributed {0} of {1} used space ({2}%). The remainder is applications, user data and Windows itself. {3}</div>' -f
            (ConvertTo-WaHtmlText (Format-WaBytes $storageAnalysis.AttributedBytes)),
            (ConvertTo-WaHtmlText (Format-WaBytes $storageAnalysis.TotalUsedBytes)),
            (ConvertTo-WaHtmlText $storageAnalysis.AttributedPercent),
            (ConvertTo-WaHtmlText $storageAnalysis.Note))
    }

    # ------------------------------------------------------ Windows configuration
    & $append '<h2>Windows configuration</h2>'
    $hibernation = $machineProfile.Hibernation
    $pagefile    = $machineProfile.Pagefile
    $protection  = $machineProfile.SystemProtection
    $update      = $machineProfile.Update

    & $append (New-WaHtmlTable -Row @(
        [pscustomobject]@{ K = 'Active power plan'; V = (Get-WaProperty -Object $machineProfile.Power -Name 'ActivePlan') }
        [pscustomobject]@{ K = 'Pagefile';          V = $(if ((Get-WaProperty -Object $pagefile -Name 'AutomaticManaged' -Default $false)) { 'System managed' } else { 'Manually configured' }) }
        [pscustomobject]@{ K = 'Crash dump';        V = (Get-WaProperty -Object $pagefile -Name 'CrashDumpType') }
        [pscustomobject]@{ K = 'Hibernation';       V = $(if ((Get-WaProperty -Object $hibernation -Name 'Enabled' -Default $false)) { ('Enabled, hiberfil.sys is ' + (Format-WaBytes (Get-WaProperty -Object $hibernation -Name 'HiberfilBytes'))) } else { 'Disabled' }) }
        [pscustomobject]@{ K = 'Fast Startup';      V = (Get-WaProperty -Object $hibernation -Name 'FastStartupEffective') }
        [pscustomobject]@{ K = 'Restore points';    V = (Get-WaProperty -Object $protection -Name 'RestorePointCount') }
        [pscustomobject]@{ K = 'Reboot pending';    V = (Get-WaProperty -Object $update -Name 'PendingReboot') }
        [pscustomobject]@{ K = 'Servicing active';  V = (Get-WaProperty -Object $update -Name 'ServicingActive') }
        [pscustomobject]@{ K = 'Component store';   V = $(
            $componentStore = $machineProfile.ComponentStore
            if ((Get-WaProperty -Object $componentStore -Name 'Analyzed' -Default $false)) {
                ('Actual size {0}, reclaimable {1}, cleanup recommended: {2}' -f
                    (Format-WaBytes (Get-WaProperty -Object $componentStore -Name 'ActualSizeBytes')),
                    (Format-WaBytes (Get-WaProperty -Object $componentStore -Name 'ReclaimableBytes')),
                    (Get-WaProperty -Object $componentStore -Name 'CleanupRecommended'))
            } else {
                (Get-WaProperty -Object $componentStore -Name 'Reason' -Default 'Not analysed')
            }
        ) }
    ) -Column ([ordered]@{
        'Setting' = { param($r) '<strong>' + (ConvertTo-WaHtmlText $r.K) + '</strong>' }
        'State'   = { param($r) ConvertTo-WaHtmlText $r.V }
    }))
    & $append ('<p class="sub">{0}</p>' -f (ConvertTo-WaHtmlText (Get-WaProperty -Object $protection -Name 'Note')))

    # ------------------------------------------------------------- workloads
    & $append '<h2>Detected workloads</h2>'
    & $append (New-WaHtmlTable -Row @($machineProfile.Workloads) -Column ([ordered]@{
        'Component'  = { param($r) ConvertTo-WaHtmlText $r.Name }
        'Category'   = { param($r) ConvertTo-WaHtmlText $r.Category }
        'Vendor'     = { param($r) ConvertTo-WaHtmlText $r.Vendor }
        'Detected by' = { param($r) ConvertTo-WaHtmlText $r.DetectionMethod }
        'Confidence' = { param($r) New-WaConfidenceBadge -Confidence $r.DetectionConfidence }
        'Evidence'   = { param($r) '<code>' + (ConvertTo-WaHtmlText $r.Note) + '</code>' }
    }) -EmptyMessage 'No recognised workloads were detected.')

    # --------------------------------------------------------- memory consumers
    $processes = $machineProfile.Processes
    if ($null -ne $processes) {
        & $append '<h2>Memory consumers</h2>'
        & $append (New-WaHtmlTable -Row @($processes.ProcessGroups) -Column ([ordered]@{
            'Application' = { param($r) ConvertTo-WaHtmlText $r.Name }
            'Private'     = { param($r) ConvertTo-WaHtmlText (Format-WaBytes $r.PrivateBytes) }
            'Working set' = { param($r) ConvertTo-WaHtmlText (Format-WaBytes $r.WorkingSetBytes) }
            'Processes'   = { param($r) ConvertTo-WaHtmlText $r.ProcessCount }
            'Category'    = { param($r) ConvertTo-WaHtmlText $r.Category }
            'At logon'    = { param($r) if ($r.StartsAtLogon) { 'yes' } else { '<span class="muted">no</span>' } }
        }))
        & $append ('<div class="note">{0} {1}</div>' -f (ConvertTo-WaHtmlText $processes.Note), (ConvertTo-WaHtmlText $processes.CommandLineNote))
    }

    # ------------------------------------------------------------ startup items
    & $append '<h2>Startup items</h2>'
    & $append (New-WaHtmlTable -Row @($machineProfile.Startup) -Column ([ordered]@{
        'Name'      = { param($r) ConvertTo-WaHtmlText $r.Name }
        'Category'  = { param($r) ConvertTo-WaHtmlText $r.Category }
        'Source'    = { param($r) ConvertTo-WaHtmlText $r.Source }
        'Executable' = { param($r) '<code>' + (ConvertTo-WaHtmlText $r.Executable) + '</code>' }
        'State'     = { param($r) if ($r.Enabled) { 'enabled' } else { '<span class="muted">disabled</span>' } }
        'Protected' = { param($r) if ($r.Protected) { '<span class="badge safe">never touched</span>' } else { '' } }
    }) -EmptyMessage 'No startup items were found.')

    # ---------------------------------------------------------------- findings
    & $append '<h2>Findings</h2>'
    & $append (New-WaHtmlTable -Row @($Session.Findings) -Column ([ordered]@{
        'Finding'    = { param($r) '<strong>' + (ConvertTo-WaHtmlText $r.Title) + '</strong><br><span class="sub">' + (ConvertTo-WaHtmlText $r.Description) + '</span>' }
        'Category'   = { param($r) ConvertTo-WaHtmlText $r.Category }
        'Provider'   = { param($r) ConvertTo-WaHtmlText $r.Provider }
        'Confidence' = { param($r) New-WaConfidenceBadge -Confidence $r.Confidence }
        'Measured'   = { param($r) ConvertTo-WaHtmlText (Format-WaBytes $r.Bytes) }
        'Evidence'   = { param($r)
            $lines = @($r.Evidence | ForEach-Object { '<li>' + (ConvertTo-WaHtmlText $_.Statement) + '</li>' })
            if ($lines.Count -eq 0) { return '' }
            '<ul>' + ($lines -join '') + '</ul>'
        }
    }) -EmptyMessage 'No findings were produced.')

    # --------------------------------------------------------- recommendations
    & $append '<h2>Recommendations</h2>'
    if (@($Session.Recommendations).Count -eq 0) {
        & $append '<p class="muted">No recommendations were produced. Nothing meeting the evidence bar was found.</p>'
    } else {
        $summary = $(if ($null -ne $Session.Plan) { $Session.Plan.Summary } elseif ($null -ne $Analysis) { $Analysis.Summary } else { $null })
        if ($null -ne $summary) {
            & $append ('<div class="cards"><div class="card"><div class="label">Well-evidenced and safe</div><div class="value">{0}</div><div class="sub">low risk, high confidence, fully measured</div></div><div class="card"><div class="label">Needs a decision</div><div class="value">{1}</div><div class="sub">executable, but a judgement call</div></div><div class="card"><div class="label">Manual review only</div><div class="value">{2}</div><div class="sub">never executed by WinAdvisor</div></div></div>' -f
                (ConvertTo-WaHtmlText (Format-WaBytes (Get-WaProperty -Object $summary -Name 'SafeBytes' -Default 0))),
                (ConvertTo-WaHtmlText (Format-WaBytes (Get-WaProperty -Object $summary -Name 'ReviewBytes' -Default 0))),
                (ConvertTo-WaHtmlText (Format-WaBytes (Get-WaProperty -Object $summary -Name 'AdvisoryBytes' -Default 0))))
            & $append '<div class="note">These three totals are kept separate on purpose. Only the first is both well-evidenced and completely measured; adding them together would overstate what can actually be recovered.</div>'
        }

        & $append (New-WaHtmlTable -Row @($Session.Recommendations) -Column ([ordered]@{
            'Recommendation' = { param($r) '<strong>' + (ConvertTo-WaHtmlText $r.Title) + '</strong><br><span class="sub">' + (ConvertTo-WaHtmlText $r.Description) + '</span>' }
            'Risk'       = { param($r) New-WaRiskBadge -Risk $r.Risk }
            'Confidence' = { param($r) New-WaConfidenceBadge -Confidence $r.Confidence }
            'Estimated'  = { param($r)
                $text = ConvertTo-WaHtmlText (Format-WaBytes $r.EstimatedBytes)
                if (-not $r.EstimateComplete) { $text += ' <span class="sub">(at least)</span>' }
                $text
            }
            'Measured'   = { param($r) if ($null -ne $r.MeasuredBytes) { ConvertTo-WaHtmlText (Format-WaBytes $r.MeasuredBytes) } else { '<span class="muted">not run</span>' } }
            'Command'    = { param($r) '<code>' + (ConvertTo-WaHtmlText $r.CommandPreview) + '</code>' }
            'Reversible' = { param($r) ConvertTo-WaHtmlText $r.Reversibility }
            'Needs'      = { param($r)
                $needs = @()
                if ($r.AdminRequired) { $needs += 'administrator' }
                if ($r.RestartRequired -eq 'Restart') { $needs += 'restart' }
                if ($r.RestartRequired -eq 'SignOut') { $needs += 'sign out' }
                if ($r.IndividualApprovalRequired) { $needs += 'individual approval' }
                if ($needs.Count -eq 0) { return '<span class="muted">nothing</span>' }
                ConvertTo-WaHtmlText ($needs -join ', ')
            }
        }))

        & $append '<h3>Consequences and evidence</h3>'
        foreach ($recommendation in @($Session.Recommendations)) {
            $evidenceList = @($recommendation.Evidence | ForEach-Object {
                $suffix = if (-not $_.Complete) { ' <span class="sub">(lower bound)</span>' } elseif (-not $_.Measured) { ' <span class="sub">(not measured)</span>' } else { '' }
                '<li>' + (ConvertTo-WaHtmlText $_.Statement) + $suffix + '</li>'
            })
            $warningList = @($recommendation.Warnings | ForEach-Object { '<li>' + (ConvertTo-WaHtmlText $_) + '</li>' })

            & $append ('<div class="note{0}"><strong>{1}</strong> {2} {3}<br><span class="sub">Mechanism: {4}</span><br><span class="sub">Consequence: {5}</span><br><span class="sub">Rollback: {6}</span>{7}{8}</div>' -f
                $(if ($recommendation.Risk -in @('HIGH', 'MANUAL-ONLY')) { ' warn' } else { '' }),
                (ConvertTo-WaHtmlText $recommendation.Title),
                (New-WaRiskBadge -Risk $recommendation.Risk),
                (New-WaConfidenceBadge -Confidence $recommendation.Confidence),
                (ConvertTo-WaHtmlText $recommendation.Mechanism),
                (ConvertTo-WaHtmlText $recommendation.Consequence),
                (ConvertTo-WaHtmlText $recommendation.RollbackNote),
                $(if ($evidenceList.Count -gt 0) { '<br><span class="sub">Evidence:</span><ul>' + ($evidenceList -join '') + '</ul>' } else { '' }),
                $(if ($warningList.Count -gt 0) { '<span class="sub">Warnings:</span><ul>' + ($warningList -join '') + '</ul>' } else { '' }))
        }
    }

    # ------------------------------------------------------------------ results
    if (@($Session.Results).Count -gt 0) {
        & $append '<h2 id="what-was-done">What was done</h2>'
        & $append (New-WaHtmlTable -Row @($Session.Results) -Column ([ordered]@{
            'Action'   = { param($r) ConvertTo-WaHtmlText $r.Summary }
            'Provider' = { param($r) ConvertTo-WaHtmlText $r.Provider }
            'Status'   = { param($r)
                $class = switch ($r.Status) {
                    'Succeeded' { 'badge safe' } 'PartiallySucceeded' { 'badge moderate' }
                    'Failed' { 'badge high' } 'Blocked' { 'badge high' }
                    'Simulated' { 'badge low' } default { 'badge' }
                }
                ('<span class="{0}">{1}</span>' -f $class, (ConvertTo-WaHtmlText $r.Status))
            }
            'Reclaimed' = { param($r) if ($null -ne $r.BytesReclaimed) { ConvertTo-WaHtmlText (Format-WaBytes $r.BytesReclaimed) } else { '<span class="muted">n/a</span>' } }
            'Duration'  = { param($r) ConvertTo-WaHtmlText (('{0} ms' -f $r.DurationMs)) }
            'Detail'    = { param($r)
                $lines = @($r.Messages | ForEach-Object { '<li>' + (ConvertTo-WaHtmlText $_) + '</li>' })
                $errorLine = if ($r.Error) { '<li><strong>' + (ConvertTo-WaHtmlText $r.Error) + '</strong></li>' } else { '' }
                if ($lines.Count -eq 0 -and -not $errorLine) { return '' }
                '<ul>' + ($lines -join '') + $errorLine + '</ul>'
            }
        }))
    }

    # ---------------------------------------------------------------- rollback
    & $append '<h2>Rollback</h2>'
    & $append (New-WaHtmlTable -Row @($Session.RollbackRecords) -Column ([ordered]@{
        'Change'  = { param($r) ConvertTo-WaHtmlText $r.Kind }
        'Target'  = { param($r) '<code>' + (ConvertTo-WaHtmlText $r.Target) + '</code>' }
        'Before'  = { param($r) ConvertTo-WaHtmlText $r.BeforeValue }
        'Restore' = { param($r) ConvertTo-WaHtmlText $r.RestoreDescription }
    }) -EmptyMessage 'No reversible change was made, so there is no rollback state.')
    & $append '<div class="note">Rollback covers configuration changes only. Deleted cache files are not recoverable from here: they were classified as regenerable, and WinAdvisor does not copy files before deleting them. Restore with <code>Invoke-WaRollback -SessionId &lt;id&gt;</code>.</div>'

    # ---------------------------------------------------------- provider status
    if ($null -ne $Analysis) {
        & $append '<h2>Provider status</h2>'
        & $append (New-WaHtmlTable -Row @($Analysis.ProviderStatus) -Column ([ordered]@{
            'Provider'  = { param($r) ConvertTo-WaHtmlText $r.Name }
            'Available' = { param($r) if ($r.Available) { 'yes' } else { '<span class="muted">no</span>' } }
            'Findings'  = { param($r) ConvertTo-WaHtmlText $r.Findings }
            'Recommendations' = { param($r) ConvertTo-WaHtmlText $r.Recommendations }
            'Notes'     = { param($r)
                $lines = @($r.Messages | ForEach-Object { '<li>' + (ConvertTo-WaHtmlText $_) + '</li>' })
                if ($lines.Count -eq 0) { return '' }
                '<ul>' + ($lines -join '') + '</ul>'
            }
        }))
    }

    if (@($Session.Warnings).Count -gt 0) {
        & $append '<h2>Warnings</h2><ul>'
        foreach ($warning in @($Session.Warnings)) { & $append ('<li>' + (ConvertTo-WaHtmlText $warning) + '</li>') }
        & $append '</ul>'
    }

    & $append ('<footer><p>Generated by WinAdvisor {0} on {1}. Session {2}.</p><p>Storage figures are logical file sizes and may differ from physical allocation on compressed, deduplicated or sparse volumes. A location that could not be measured is reported as unknown, never as zero. No performance improvement is claimed anywhere in this report: storage recovered and configuration changed are measured, speed is not.</p></footer>' -f
        (ConvertTo-WaHtmlText $Session.Version),
        (ConvertTo-WaHtmlText (Get-WaUtcTimestamp)),
        (ConvertTo-WaHtmlText $Session.Id))

    $title = 'WinAdvisor report - {0}' -f (Get-WaProperty -Object $identity -Name 'MachineName' -Default 'machine')
    return @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>$(ConvertTo-WaHtmlText $title)</title>
<style>
$(Get-WaReportStyle)
</style>
</head>
<body>
<div class="wrap">
$($body.ToString())
</div>
</body>
</html>
"@
}
