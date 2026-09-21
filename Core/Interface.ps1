<#
    Core/Interface.ps1 - console presentation and the interactive menu.

    Presentation only. This file renders and prompts; it never decides whether something is
    allowed. Approval flows here call Grant-WaApproval, and execution calls Invoke-WaPlan,
    both of which enforce their own rules regardless of what the interface asks for.

    The menu itself runs in a read-only session. Choosing a cleanup mode creates a new,
    mutable session rather than promoting the current one, so there is no path by which
    browsing the menu leaves you in a session that can change the machine.
#>

function Write-WaHeading {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Text)
    Write-Host ''
    Write-Host ('  ' + $Text) -ForegroundColor Cyan
    Write-Host ('  ' + ('-' * [Math]::Min(76, $Text.Length + 4))) -ForegroundColor DarkGray
}

function Write-WaField {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Label, $Value, [int]$Width = 26)
    $text = if ($null -eq $Value -or [string]$Value -eq '') { 'unknown' } else { [string]$Value }
    $colour = if ($text -eq 'unknown') { 'DarkGray' } else { 'Gray' }
    Write-Host ('    {0} ' -f $Label.PadRight($Width)) -NoNewline -ForegroundColor DarkGray
    Write-Host $text -ForegroundColor $colour
}

function Get-WaRiskColour {
    [CmdletBinding()]
    param([string]$Risk)
    switch ($Risk) {
        'SAFE'        { 'Green' }
        'LOW'         { 'Green' }
        'MODERATE'    { 'Yellow' }
        'HIGH'        { 'Red' }
        'MANUAL-ONLY' { 'Magenta' }
        default       { 'Gray' }
    }
}

function Show-WaBanner {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session)

    Write-Host ''
    Write-Host '  WinAdvisor' -ForegroundColor Cyan -NoNewline
    Write-Host ('  {0}' -f $Session.Version) -ForegroundColor DarkGray
    Write-Host '  Adaptive Windows 11 maintenance advisor and cleanup orchestrator' -ForegroundColor DarkGray
    Write-Host '  Diagnose first. Recommend second. Execute last.' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host ('  Session {0}   {1}   {2}' -f
        $Session.Id,
        $(if ($Session.IsAdministrator) { 'elevated' } else { 'standard user' }),
        $(if ($Session.ReadOnly) { 'READ-ONLY' } else { 'CHANGES ENABLED' })
    ) -ForegroundColor $(if ($Session.ReadOnly) { 'DarkGray' } else { 'Yellow' })
}

function Show-WaSpecs {
    <#
    .SYNOPSIS
        Renders the full read-only machine specification.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session)

    $machineProfile = $Session.MachineProfile
    if ($null -eq $machineProfile) { $machineProfile = Get-WaMachineProfile -Session $Session }

    $operatingSystem = $machineProfile.OperatingSystem
    $hardware        = $machineProfile.Hardware

    Write-WaHeading 'System'
    Write-WaField 'Computer name'   (Get-WaProperty -Object $machineProfile.Identity -Name 'MachineName')
    Write-WaField 'Windows edition' (Get-WaProperty -Object $operatingSystem -Name 'ProductName')
    Write-WaField 'Version'         (Get-WaProperty -Object $operatingSystem -Name 'DisplayVersion')
    Write-WaField 'Build'           (Get-WaProperty -Object $operatingSystem -Name 'FullBuild')
    Write-WaField 'Architecture'    (Get-WaProperty -Object $operatingSystem -Name 'Architecture')
    Write-WaField 'Installed'       (Get-WaProperty -Object $operatingSystem -Name 'InstallDate')
    Write-WaField 'Uptime'          (Get-WaProperty -Object $operatingSystem -Name 'UptimeText')
    Write-WaField 'Manufacturer'    (Get-WaProperty -Object $hardware -Name 'Manufacturer')
    Write-WaField 'Model'           (Get-WaProperty -Object $hardware -Name 'Model')
    Write-WaField 'Chassis'         (Get-WaProperty -Object $hardware -Name 'ChassisType')
    Write-WaField 'Serial (masked)' (Get-WaProperty -Object $hardware -Name 'BiosSerialMasked')
    Write-WaField 'Firmware'        (Get-WaProperty -Object $hardware -Name 'FirmwareType')
    Write-WaField 'BIOS version'    ('{0} ({1})' -f (Get-WaProperty -Object $hardware -Name 'BiosVersion'), (Get-WaProperty -Object $hardware -Name 'BiosReleaseDate'))
    Write-WaField 'Secure Boot'     (Get-WaProperty -Object $hardware -Name 'SecureBoot')
    Write-WaField 'Hypervisor'      (Get-WaProperty -Object $hardware -Name 'HypervisorPresent')
    Write-WaField 'Domain joined'   (Get-WaProperty -Object $hardware -Name 'PartOfDomain')

    Write-WaHeading 'Processor'
    foreach ($processor in @($machineProfile.Processor)) {
        Write-WaField 'Model'        $processor.Name
        Write-WaField 'Architecture' $processor.Architecture
        Write-WaField 'Cores'        ('{0} physical, {1} logical' -f $processor.PhysicalCores, $processor.LogicalProcessors)
        Write-WaField 'Clock'        ('{0} MHz max, {1} MHz sampled' -f $processor.MaxClockMhz, $processor.CurrentClockMhz)
        Write-WaField 'Virtualization' $processor.VirtualizationFirmwareEnabled
    }

    $memory = $machineProfile.Memory
    if ($null -ne $memory) {
        Write-WaHeading 'Memory'
        Write-WaField 'Installed'  (Format-WaBytes $memory.TotalBytes)
        Write-WaField 'Available'  (Format-WaBytes $memory.AvailableBytes)
        Write-WaField 'Cached'     (Format-WaBytes $memory.CacheBytes)
        Write-WaField 'Commit charge' ('{0} of {1}{2}' -f (Format-WaBytes $memory.CommittedBytes), (Format-WaBytes $memory.CommitLimitBytes), $(if ($null -ne $memory.CommitPercent) { " ($($memory.CommitPercent)%)" } else { '' }))
        Write-WaField 'Modules'    $memory.ModuleCount
        foreach ($module in @($memory.Modules)) {
            Write-WaField ('  ' + [string]$module.Slot) ('{0} {1}, rated {2} MHz, running {3} MHz, {4}' -f
                (Format-WaBytes $module.CapacityBytes), $module.MemoryType, $module.RatedSpeedMhz, $module.ConfiguredMhz, $module.Manufacturer)
        }
        Write-Host ('    {0}' -f $memory.PressureNote) -ForegroundColor DarkGray
    }

    Write-WaHeading 'Graphics'
    foreach ($adapter in @($machineProfile.Graphics)) {
        Write-WaField $adapter.Name ('{0}, VRAM {1}, driver {2} ({3}){4}' -f
            $adapter.Vendor, (Format-WaBytes $adapter.VramBytes), $adapter.DriverVersion, $adapter.DriverDate,
            $(if ($adapter.Active) { ', active' } else { '' })) -Width 34
    }

    $storage = $machineProfile.Storage
    if ($null -ne $storage) {
        Write-WaHeading 'Storage'
        foreach ($disk in @($storage.PhysicalDisks)) {
            Write-WaField $disk.FriendlyName ('{0}, {1} over {2}, health {3}' -f
                (Format-WaBytes $disk.SizeBytes), $disk.DriveKind, $disk.BusType, $disk.HealthStatus) -Width 34
        }
        Write-Host ''
        foreach ($volume in @($storage.Volumes)) {
            $bitlocker = @($storage.BitLocker | Where-Object { $_.MountPoint -eq $volume.Drive }) | Select-Object -First 1
            Write-WaField ('Volume ' + $volume.Drive) ('{0} used of {1} ({2}%), {3} free, {4}{5}' -f
                (Format-WaBytes $volume.UsedBytes), (Format-WaBytes $volume.SizeBytes), $volume.UsedPercent,
                (Format-WaBytes $volume.FreeBytes), $volume.FileSystem,
                $(if ($null -ne $bitlocker) { ', BitLocker ' + $bitlocker.ProtectionStatus } else { '' })) -Width 34
        }
        if (@($storage.BitLocker).Count -eq 0 -and $storage.BitLockerNote) {
            Write-Host ('    {0}' -f $storage.BitLockerNote) -ForegroundColor DarkGray
        }
    }

    Write-WaHeading 'Windows configuration'
    $pagefile = $machineProfile.Pagefile
    Write-WaField 'Pagefile'     $(if ((Get-WaProperty -Object $pagefile -Name 'AutomaticManaged' -Default $false)) { 'System managed' } else { 'Manually configured' })
    foreach ($file in @(Get-WaProperty -Object $pagefile -Name 'Files' -Default @())) {
        Write-WaField ('  ' + [string]$file.Name) ('{0} MB allocated, {1} MB in use, {2} MB peak' -f $file.AllocatedBaseMb, $file.CurrentUsageMb, $file.PeakUsageMb)
    }
    Write-WaField 'Crash dump'   (Get-WaProperty -Object $pagefile -Name 'CrashDumpType')

    $hibernation = $machineProfile.Hibernation
    $hibernationEnabled = [bool](Get-WaProperty -Object $hibernation -Name 'Enabled' -Default $false)
    $hiberfilBytes = Get-WaProperty -Object $hibernation -Name 'HiberfilBytes'
    Write-WaField 'Hibernation'  $(if ($hibernationEnabled) { 'Enabled' } else { 'Disabled' })
    # 'not present' and 'unknown' are different answers: the first is a measurement.
    Write-WaField 'hiberfil.sys' $(
        if ($null -ne $hiberfilBytes) { Format-WaBytes $hiberfilBytes }
        elseif (-not $hibernationEnabled) { 'not present (hibernation is off)' }
        else { 'present but not measurable without elevation' }
    )
    Write-WaField 'Fast Startup' (Get-WaProperty -Object $hibernation -Name 'FastStartupEffective')
    Write-WaField 'Power plan'   (Get-WaProperty -Object $machineProfile.Power -Name 'ActivePlan')

    $protection = $machineProfile.SystemProtection
    Write-WaField 'Restore points' (Get-WaProperty -Object $protection -Name 'RestorePointCount')
    if ((Get-WaProperty -Object $protection -Name 'RestorePointError')) {
        Write-Host ('    {0}' -f (Get-WaProperty -Object $protection -Name 'RestorePointError')) -ForegroundColor DarkGray
    }

    $update = $machineProfile.Update
    Write-WaField 'Reboot pending'   (Get-WaProperty -Object $update -Name 'PendingReboot')
    Write-WaField 'Servicing active' (Get-WaProperty -Object $update -Name 'ServicingActive')

    $componentStore = $machineProfile.ComponentStore
    if ((Get-WaProperty -Object $componentStore -Name 'Analyzed' -Default $false)) {
        Write-WaField 'Component store' ('{0} actual, {1} reclaimable' -f
            (Format-WaBytes (Get-WaProperty -Object $componentStore -Name 'ActualSizeBytes')),
            (Format-WaBytes (Get-WaProperty -Object $componentStore -Name 'ReclaimableBytes')))
    } else {
        Write-WaField 'Component store' (Get-WaProperty -Object $componentStore -Name 'Reason')
    }

    Write-WaField 'Optional features' (@($machineProfile.OptionalFeatures).Count)

    Write-WaHeading 'Detected workloads'
    foreach ($group in (@($machineProfile.Workloads) | Group-Object Category | Sort-Object Name)) {
        Write-WaField $group.Name (($group.Group | ForEach-Object { $_.Name }) -join ', ') -Width 22
    }
    if (@($machineProfile.Workloads).Count -eq 0) { Write-Host '    No recognised workloads were detected.' -ForegroundColor DarkGray }

    Write-WaHeading 'Installed applications'
    Write-WaField 'Registered applications' (@($machineProfile.Applications).Count)
    Write-WaField 'Store packages'          (@($machineProfile.StoreApplications).Count)

    Write-WaHeading 'Startup'
    $startup = @($machineProfile.Startup)
    Write-WaField 'Discovered' $startup.Count
    Write-WaField 'Enabled'    @($startup | Where-Object { $_.Enabled }).Count
    foreach ($group in ($startup | Where-Object { $_.Enabled } | Group-Object Category | Sort-Object Count -Descending)) {
        Write-WaField ('  ' + $group.Name) $group.Count
    }

    $processes = $machineProfile.Processes
    if ($null -ne $processes) {
        Write-WaHeading 'Top memory consumers'
        Write-Host ('    {0} {1} {2} {3}' -f 'Application'.PadRight(28), 'Private'.PadLeft(12), 'Working set'.PadLeft(13), 'Procs'.PadLeft(6)) -ForegroundColor DarkGray
        foreach ($group in (@($processes.ProcessGroups) | Select-Object -First 15)) {
            Write-Host ('    {0} {1} {2} {3}  {4}' -f
                ([string]$group.Name).PadRight(28),
                (Format-WaBytes $group.PrivateBytes).PadLeft(12),
                (Format-WaBytes $group.WorkingSetBytes).PadLeft(13),
                ([string]$group.ProcessCount).PadLeft(6),
                $(if ($group.StartsAtLogon) { 'starts at logon' } else { '' })) -ForegroundColor Gray
        }
        Write-Host ('    {0}' -f $processes.Note) -ForegroundColor DarkGray
    }

    $support = $machineProfile.Support
    Write-WaHeading 'Support status'
    Write-WaField 'Changes permitted' $support.SupportedForExecution
    foreach ($reason in @($support.Reasons)) { Write-Host ('    {0}' -f $reason) -ForegroundColor Yellow }
    Write-Host ('    {0}' -f $support.Note) -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '  View Specs is strictly read-only. Nothing was changed.' -ForegroundColor DarkGray
}

function Show-WaFindings {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Analysis)

    Write-WaHeading 'Findings'
    if (@($Analysis.Findings).Count -eq 0) {
        Write-Host '    Nothing noteworthy was found.' -ForegroundColor DarkGray
        return
    }
    foreach ($finding in @($Analysis.Findings)) {
        Write-Host ''
        Write-Host ('    {0}' -f $finding.Title) -ForegroundColor White
        Write-Host ('      Category    {0}   Provider {1}   Confidence {2}' -f $finding.Category, $finding.Provider, $finding.Confidence) -ForegroundColor DarkGray
        if ($finding.Description) { Write-Host ('      {0}' -f $finding.Description) -ForegroundColor Gray }
        foreach ($evidence in (@($finding.Evidence) | Select-Object -First 8)) {
            Write-Host ('        - {0}' -f $evidence.Statement) -ForegroundColor DarkGray
        }
        foreach ($warning in @($finding.Warnings)) {
            Write-Host ('        ! {0}' -f $warning) -ForegroundColor Yellow
        }
    }
}

function Show-WaProviderStatus {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Analysis)

    Write-WaHeading 'Providers'
    foreach ($status in @($Analysis.ProviderStatus)) {
        $colour = if (-not $status.Available) { 'DarkGray' } elseif ($status.Degraded) { 'Yellow' } else { 'Gray' }
        Write-Host ('    {0} {1}' -f ([string]$status.Name).PadRight(28), $(
            if (-not $status.Available) { 'not applicable' }
            else { '{0} finding(s), {1} recommendation(s)' -f $status.Findings, $status.Recommendations }
        )) -ForegroundColor $colour
        foreach ($message in @($status.Messages)) {
            Write-Host ('        {0}' -f $message) -ForegroundColor DarkGray
        }
    }
}

function Show-WaDeepScanGap {
    <#
    .SYNOPSIS
        Names each -DeepScanPath scanner that did not run, and why.

    .DESCRIPTION
        The full provider status lives in System analysis and the report. The cleanup flow
        shows only this part of it: a scan the user asked for by name that quietly did not
        happen reads as "nothing found", which is a different claim.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)]$Analysis)

    $paths = @($Session.Config.DeepScanPaths)
    if ($paths.Count -eq 0) { return }
    $missed = @($Analysis.ProviderStatus | Where-Object {
        $provider = Get-WaProvider -Name $_.Name
        -not $_.Available -and $null -ne $provider -and $provider.UsesDeepScanPaths
    })
    if ($missed.Count -eq 0) { return }

    Write-WaHeading 'Deep scan not run'
    foreach ($status in $missed) {
        Write-Host ('    {0} did not scan {1}.' -f $status.Name, ($paths -join ', ')) -ForegroundColor Yellow
        foreach ($message in @($status.Messages)) {
            Write-Host ('      {0}' -f $message) -ForegroundColor DarkGray
        }
    }
}

function Show-WaStorageAnalysis {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)]$Analysis, [switch]$Deep)

    $storage = Get-WaStorageAnalysis -Session $Session -Analysis $Analysis -Deep:$Deep

    Write-WaHeading 'Volumes'
    foreach ($volume in @($storage.Volumes)) {
        Write-WaField ('Volume ' + $volume.Drive) ('{0} used of {1} ({2}%), {3} free' -f
            (Format-WaBytes $volume.UsedBytes), (Format-WaBytes $volume.SizeBytes), $volume.UsedPercent, (Format-WaBytes $volume.FreeBytes)) -Width 20
    }

    Write-WaHeading 'Where the space went'
    if (@($storage.Categories).Count -eq 0) {
        Write-Host '    Nothing was attributed. Enable more providers, or run a deep scan on a directory.' -ForegroundColor DarkGray
    }
    foreach ($category in @($storage.Categories)) {
        Write-Host ('    {0} {1} {2}' -f
            ([string]$category.Category).PadRight(30),
            (Format-WaBytes $category.Bytes).PadLeft(12),
            $(if ($category.Complete) { '' } else { '  (lower bound)' })) -ForegroundColor Gray
    }

    Write-Host ''
    Write-Host ('    Attributed {0} of {1} used ({2}%).' -f
        (Format-WaBytes $storage.AttributedBytes), (Format-WaBytes $storage.TotalUsedBytes), $storage.AttributedPercent) -ForegroundColor DarkGray
    Write-Host ('    {0}' -f $storage.Note) -ForegroundColor DarkGray

    Write-WaHeading 'Largest measured consumers'
    foreach ($consumer in (@($storage.Consumers) | Select-Object -First 20)) {
        Write-Host ('    {0} {1}  {2}' -f
            (Format-WaBytes $consumer.Bytes).PadLeft(12),
            ([string]$consumer.Category).PadRight(24),
            $consumer.Name) -ForegroundColor Gray
    }

    if ($null -ne $storage.DeepScan) {
        Write-WaHeading 'Large files (deep scan)'
        foreach ($file in (@($storage.DeepScan.Files) | Select-Object -First 25)) {
            Write-Host ('    {0}  {1}  {2}' -f (Format-WaBytes $file.Bytes).PadLeft(12), ([string]$file.Category).PadRight(22), $file.Path) -ForegroundColor Gray
        }
        Write-Host '    Large files are advisory only and are never proposed for deletion by size.' -ForegroundColor DarkGray
    } elseif (-not $Deep) {
        Write-Host ''
        Write-Host '    For a deeper look, rerun with -DeepScanPath pointing at a directory to examine.' -ForegroundColor DarkGray
    }
}

function Show-WaStartupAndMemory {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session)

    $machineProfile = $Session.MachineProfile
    $startup = @($machineProfile.Startup)

    Write-WaHeading 'Startup items'
    Write-Host ('    {0} {1} {2} {3}' -f 'Name'.PadRight(30), 'Category'.PadRight(22), 'State'.PadRight(9), 'Source') -ForegroundColor DarkGray
    foreach ($item in ($startup | Sort-Object Category, Name)) {
        $colour = if ($item.Protected) { 'DarkCyan' } elseif (-not $item.Enabled) { 'DarkGray' } else { 'Gray' }
        Write-Host ('    {0} {1} {2} {3}{4}' -f
            ([string]$item.Name).PadRight(30).Substring(0, 30),
            ([string]$item.Category).PadRight(22),
            $(if ($item.Enabled) { 'enabled ' } else { 'disabled' }).PadRight(9),
            $item.Source,
            $(if ($item.Protected) { '  [never touched]' } else { '' })) -ForegroundColor $colour
    }
    Write-Host ''
    Write-Host '    Security, device-management, accessibility and hardware items are never proposed for disabling.' -ForegroundColor DarkGray
    Write-Host '    Items that could not be classified are left alone: an unrecognised entry may be load-bearing.' -ForegroundColor DarkGray

    $processes = $machineProfile.Processes
    if ($null -ne $processes) {
        Write-WaHeading 'Memory analysis'
        Write-Host ('    {0} {1} {2} {3}  {4}' -f 'Application'.PadRight(28), 'Private'.PadLeft(12), 'Working set'.PadLeft(13), 'Procs'.PadLeft(6), 'Notes') -ForegroundColor DarkGray
        foreach ($group in @($processes.ProcessGroups)) {
            Write-Host ('    {0} {1} {2} {3}  {4}{5}' -f
                ([string]$group.Name).PadRight(28),
                (Format-WaBytes $group.PrivateBytes).PadLeft(12),
                (Format-WaBytes $group.WorkingSetBytes).PadLeft(13),
                ([string]$group.ProcessCount).PadLeft(6),
                $group.Category,
                $(if ($group.StartsAtLogon) { ', starts at logon' } else { '' })) -ForegroundColor Gray
        }
        Write-Host ''
        Write-Host ('    {0}' -f $processes.Note) -ForegroundColor DarkGray
        Write-Host '    WinAdvisor contains no RAM cleaner. Trimming working sets or purging the standby' -ForegroundColor DarkGray
        Write-Host '    list makes the free-memory number look better and the machine slower.' -ForegroundColor DarkGray
    }
}

function Show-WaQuestionSet {
    <#
    .SYNOPSIS
        Asks the adaptive questions and records the answers.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session)

    $questions = @($Session.Questions)
    if ($questions.Count -eq 0) { return }
    if ($Session.NonInteractive) {
        Write-Host ''
        Write-Host '  Non-interactive: the conservative default answer is used for each question.' -ForegroundColor DarkGray
        return
    }

    Write-WaHeading 'A few questions about this machine'
    Write-Host '  These are based on what was actually detected here.' -ForegroundColor DarkGray

    foreach ($question in $questions) {
        Write-Host ''
        Write-Host ('  {0}' -f $question.Prompt) -ForegroundColor White
        if ($question.Context) { Write-Host ('  {0}' -f $question.Context) -ForegroundColor Gray }
        foreach ($evidence in (@($question.Evidence) | Select-Object -First 5)) {
            Write-Host ('    - {0}' -f $evidence) -ForegroundColor DarkGray
        }
        Write-Host ''
        foreach ($option in @($question.Options)) {
            $marker = if ($option.Key -eq $question.DefaultOption) { '*' } else { ' ' }
            Write-Host ('   {0}[{1}] {2}' -f $marker, $option.Key, $option.Label) -ForegroundColor Gray
            if ($option.Description) { Write-Host ('        {0}' -f $option.Description) -ForegroundColor DarkGray }
        }

        $answer = Read-Host ('  Choose [{0}]' -f $question.DefaultOption)
        if ([string]::IsNullOrWhiteSpace($answer)) { $answer = $question.DefaultOption }
        try {
            [void](Set-WaQuestionAnswer -Question $question -OptionKey $answer.Trim())
        } catch {
            Write-Host ('    Not a valid choice; using the default ({0}).' -f $question.DefaultOption) -ForegroundColor Yellow
            [void](Set-WaQuestionAnswer -Question $question -OptionKey $question.DefaultOption)
        }
    }
}

function Show-WaPlan {
    <#
    .SYNOPSIS
        Renders a plan the way it must be read before approval.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Plan)

    $summary = $Plan.Summary

    Write-Host ''
    Write-Host '  MAINTENANCE PLAN' -ForegroundColor Cyan
    Write-Host ('  {0}' -f ('=' * 74)) -ForegroundColor DarkGray

    if (@($Plan.Actions).Count -eq 0) {
        Write-Host ''
        Write-Host '  Nothing to propose. No cleanup opportunity met the evidence bar on this machine.' -ForegroundColor Green
        return
    }

    foreach ($categoryGroup in (@($Plan.Actions) | Group-Object { $_.Recommendation.Category } | Sort-Object Name)) {
        Write-Host ''
        Write-Host ('  {0}' -f $categoryGroup.Name.ToUpperInvariant()) -ForegroundColor White
        Write-Host ('  {0}' -f ('-' * 74)) -ForegroundColor DarkGray

        foreach ($action in ($categoryGroup.Group | Sort-Object Order)) {
            $recommendation = $action.Recommendation
            $size = if ($null -eq $recommendation.EstimatedBytes) { 'n/a' } else { Format-WaBytes $recommendation.EstimatedBytes }
            if (-not $recommendation.EstimateComplete -and $null -ne $recommendation.EstimatedBytes) { $size = '>= ' + $size }

            # Titles are truncated rather than allowed to push the risk and confidence
            # columns out of alignment; the full title appears in the detail view.
            $title = [string]$recommendation.Title
            if ($title.Length -gt 46) { $title = $title.Substring(0, 43) + '...' }

            Write-Host ('  [{0,2}] {1}' -f $action.Order, $title.PadRight(46)) -NoNewline -ForegroundColor Gray
            Write-Host ('{0,13}  ' -f $size) -NoNewline -ForegroundColor Gray
            Write-Host ('{0,-13}' -f $recommendation.Risk) -NoNewline -ForegroundColor (Get-WaRiskColour -Risk $recommendation.Risk)
            Write-Host ('{0}' -f $recommendation.Confidence) -ForegroundColor DarkGray
        }
    }

    Write-Host ''
    Write-Host ('  {0}' -f ('=' * 74)) -ForegroundColor DarkGray
    Write-Host '  Storage outlook' -ForegroundColor White
    Write-Host ('    Well-evidenced and safe   {0}' -f (Format-WaBytes $summary.SafeBytes)) -ForegroundColor Green
    Write-Host ('    Needs a decision          {0}' -f (Format-WaBytes $summary.ReviewBytes)) -ForegroundColor Yellow
    Write-Host ('    Manual review only        {0}' -f (Format-WaBytes $summary.AdvisoryBytes)) -ForegroundColor Magenta
    Write-Host '    These are kept separate on purpose; adding them up would overstate what can be recovered.' -ForegroundColor DarkGray

    if (@($summary.AdminRequired).Count -gt 0) {
        Write-Host ''
        Write-Host '  Requires administrator:' -ForegroundColor Yellow
        foreach ($title in @($summary.AdminRequired)) { Write-Host ('    - {0}' -f $title) -ForegroundColor DarkGray }
    }
    if (@($summary.RestartRequired).Count -gt 0 -or @($summary.SignOutRequired).Count -gt 0) {
        Write-Host ''
        Write-Host '  Requires restart or sign-out:' -ForegroundColor Yellow
        foreach ($title in @($summary.RestartRequired)) { Write-Host ('    - {0} (restart)' -f $title) -ForegroundColor DarkGray }
        foreach ($title in @($summary.SignOutRequired)) { Write-Host ('    - {0} (sign out)' -f $title) -ForegroundColor DarkGray }
    }
    if (@($summary.Reversible).Count -gt 0) {
        Write-Host ''
        Write-Host '  Reversible (rollback state is recorded):' -ForegroundColor Green
        foreach ($title in @($summary.Reversible)) { Write-Host ('    - {0}' -f $title) -ForegroundColor DarkGray }
    }
    if (@($summary.RegenerableOnly).Count -gt 0) {
        Write-Host ''
        Write-Host '  Not reversible, but regenerable (caches rebuild themselves):' -ForegroundColor DarkGray
        foreach ($title in @($summary.RegenerableOnly)) { Write-Host ('    - {0}' -f $title) -ForegroundColor DarkGray }
    }
    if (@($summary.IndividualApproval).Count -gt 0) {
        Write-Host ''
        Write-Host '  Requires its own individual approval:' -ForegroundColor Red
        foreach ($title in @($summary.IndividualApproval)) { Write-Host ('    - {0}' -f $title) -ForegroundColor DarkGray }
    }
    Write-Host ''
}

function Show-WaRecommendationDetail {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Recommendation)

    Write-Host ''
    Write-Host ('  {0}' -f $Recommendation.Title) -ForegroundColor White
    Write-Host ('  {0}' -f ('-' * 74)) -ForegroundColor DarkGray
    Write-Host ('  {0}' -f $Recommendation.Description) -ForegroundColor Gray
    Write-Host ''
    Write-Host '  Evidence' -ForegroundColor DarkCyan
    foreach ($evidence in @($Recommendation.Evidence)) {
        $suffix = if (-not $evidence.Complete) { ' (lower bound: the scan hit its budget)' } elseif (-not $evidence.Measured) { ' (not measured)' } else { '' }
        Write-Host ('    - {0}{1}' -f $evidence.Statement, $suffix) -ForegroundColor Gray
        if ($evidence.Reference) { Write-Host ('      {0}' -f $evidence.Reference) -ForegroundColor DarkGray }
    }
    Write-Host ''
    Write-WaField 'Risk'            $Recommendation.Risk
    Write-WaField 'Confidence'      $Recommendation.Confidence
    Write-WaField 'Estimated saving' (Get-WaProperty -Object $Recommendation -Name 'EstimatedBenefit')
    Write-WaField 'Mechanism'       $Recommendation.Mechanism
    Write-WaField 'Command'         $Recommendation.CommandPreview
    Write-WaField 'Consequence'     $Recommendation.Consequence
    Write-WaField 'Reversibility'   $Recommendation.Reversibility
    Write-WaField 'Rollback'        $Recommendation.RollbackNote
    Write-WaField 'Personal data'   $(if ($Recommendation.AffectsPersonalData) { 'YES - affects personal data' } else { 'No' })
    Write-WaField 'Administrator'   $(if ($Recommendation.AdminRequired) { 'Required' } else { 'Not required' })
    Write-WaField 'Restart'         $Recommendation.RestartRequired
    if ($Recommendation.Reference) { Write-WaField 'Reference' $Recommendation.Reference }
    foreach ($warning in @($Recommendation.Warnings)) {
        Write-Host ('    ! {0}' -f $warning) -ForegroundColor Yellow
    }
}

function Invoke-WaInteractiveApproval {
    <#
    .SYNOPSIS
        Walks the user through approving a plan.

    .DESCRIPTION
        Offers a batch approval capped at the configured ceiling, a per-item review, or
        cancelling. HIGH-risk and manual-review items are never included in a batch: the
        approval layer refuses them, and this only presents what it will accept.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)]$Plan)

    if (@($Plan.Actions).Count -eq 0) { return $false }
    if ($Session.NonInteractive) {
        Write-Host ''
        Write-Host '  Non-interactive: nothing is approved, so nothing will run.' -ForegroundColor Yellow
        Write-Host '  Every change needs an interactive approval.' -ForegroundColor DarkGray
        return $false
    }

    $ceiling = $Session.Config.MaximumAutoApprovableRisk
    Write-Host ('  [A] Approve everything up to {0} risk in one go' -f $ceiling) -ForegroundColor Gray
    Write-Host   '  [R] Review every item individually' -ForegroundColor Gray
    Write-Host   '  [C] Cancel and change nothing' -ForegroundColor Gray
    Write-Host ''
    $choice = (Read-Host '  Choose [C]').Trim().ToUpperInvariant()
    if ([string]::IsNullOrWhiteSpace($choice)) { $choice = 'C' }

    switch ($choice) {
        'A' {
            $outcome = Grant-WaBatchApproval -Session $Session -Plan $Plan
            Write-Host ''
            Write-Host ('  Approved {0} item(s) at or below {1} risk.' -f @($outcome.Approved).Count, $outcome.MaximumRisk) -ForegroundColor Green
            foreach ($item in @($outcome.Approved)) { Write-Host ('    + {0}' -f $item.Title) -ForegroundColor DarkGray }

            if (@($outcome.Skipped).Count -gt 0) {
                Write-Host ''
                Write-Host ('  Left unapproved ({0}):' -f @($outcome.Skipped).Count) -ForegroundColor Yellow
                foreach ($item in @($outcome.Skipped)) {
                    Write-Host ('    - {0} [{1}] {2}' -f $item.Title, $item.Risk, $item.Reason) -ForegroundColor DarkGray
                }
                Write-Host ''
                $reviewHigher = (Read-Host '  Review the remaining items individually? [y/N]').Trim().ToUpperInvariant()
                if ($reviewHigher -eq 'Y') {
                    [void](Invoke-WaPerItemApproval -Session $Session -Plan $Plan -OnlyUnapproved)
                }
            }
            return $true
        }
        'R' {
            return (Invoke-WaPerItemApproval -Session $Session -Plan $Plan)
        }
        default {
            Write-Host ''
            Write-Host '  Cancelled. Nothing was changed.' -ForegroundColor Green
            return $false
        }
    }
}

function Invoke-WaPerItemApproval {
    <#
    .SYNOPSIS
        Presents each action in full and asks for a decision on it.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)]$Plan, [switch]$OnlyUnapproved)

    $approvedAny = $false
    foreach ($action in (@($Plan.Actions) | Sort-Object Order)) {
        $recommendation = $action.Recommendation

        if ($OnlyUnapproved -and $null -ne $action.Approval) { continue }

        # Czkawka results are chosen item by item on their own screen, then approved as a list.
        if (Test-WaCzkawkaReviewAction -Action $action) {
            if (Invoke-WaCzkawkaSelection -Session $Session -Plan $Plan -Action $action) { $approvedAny = $true }
            continue
        }

        if ($recommendation.Risk -eq 'MANUAL-ONLY') {
            Show-WaRecommendationDetail -Recommendation $recommendation
            Write-Host ''
            Write-Host '  This is manual review only. WinAdvisor will not act on it, and it cannot be approved.' -ForegroundColor Magenta
            continue
        }

        Show-WaRecommendationDetail -Recommendation $recommendation

        if ($recommendation.AdminRequired -and -not $Session.IsAdministrator) {
            Write-Host ''
            Write-Host ('  Administrator rights are required and this session does not have them. {0}' -f (Get-WaElevationReason -Recommendation $recommendation)) -ForegroundColor Yellow
            Write-Host '  It cannot be approved here. Restart WinAdvisor elevated to act on it.' -ForegroundColor DarkGray
            continue
        }

        Write-Host ''
        if ($recommendation.Risk -eq 'HIGH') {
            Write-Host '  This is a HIGH-risk change. Review the consequence and exact target above.' -ForegroundColor Red
            Write-Host '  Type the word YES in full to approve it. Anything else declines.' -ForegroundColor Red
            $answer = (Read-Host '  Approve?').Trim()
            $decision = if ($answer -ceq 'YES') { 'Approved' } else { 'Declined' }
        } else {
            $answer = (Read-Host '  Approve this item? [y/N]').Trim().ToUpperInvariant()
            $decision = if ($answer -eq 'Y') { 'Approved' } else { 'Declined' }
        }

        try {
            [void](Grant-WaApproval -Session $Session -Plan $Plan -ActionId $action.Id -Decision $decision -Scope 'Individual')
            if ($decision -eq 'Approved') {
                $approvedAny = $true
                Write-Host '  Approved.' -ForegroundColor Green
            } else {
                Write-Host '  Declined.' -ForegroundColor DarkGray
            }
        } catch {
            Write-Host ('  Could not approve: {0}' -f $_.Exception.Message) -ForegroundColor Yellow
        }
    }
    return $approvedAny
}

# ---------------------------------------------------------------------------------------
# Execution progress
#
# Invoke-WaPlan reports every step it takes; this is the only code that decides how those
# steps look. Two kinds of line are printed:
#
#   * a transient line, rewritten in place, showing what is happening right now
#   * one permanent line per action, left on screen when it finishes
#
# Where the console cannot rewrite a line (output redirected, a host without a raw UI, a
# non-interactive run) the transient line becomes an occasional plain line instead, so a
# transcript still shows progress without thousands of repeats.
# ---------------------------------------------------------------------------------------

# Width of the transient line currently on screen, or 0 when there is none.
$script:WaTransientWidth = 0

# How often a host that cannot rewrite lines is allowed to print a progress line.
$script:WaPlainProgressIntervalMs = 15000
$script:WaPlainProgressClock = $null

# Whether the current run may rewrite the transient line. Held here rather than captured in
# the sink itself: GetNewClosure would rebind the scriptblock to a new dynamic module, where
# none of the functions below are visible.
$script:WaProgressInPlace = $false

function Test-WaTransientConsole {
    <#
    .SYNOPSIS
        True when the console can overwrite the current line in place.
    #>
    [CmdletBinding()]
    param()
    try {
        if ([Console]::IsOutputRedirected) { return $false }
        if ($null -eq $Host.UI.RawUI) { return $false }
        return ($Host.UI.RawUI.WindowSize.Width -gt 20)
    } catch {
        return $false
    }
}

function Get-WaConsoleWidth {
    <#
    .SYNOPSIS
        Usable width for a transient line, with a safe default for hosts that have none.
    #>
    [CmdletBinding()]
    param()
    try { return [Math]::Max(20, $Host.UI.RawUI.WindowSize.Width - 1) } catch { return 78 }
}

function Write-WaTransientLine {
    <#
    .SYNOPSIS
        Draws the "happening right now" line, replacing whatever was there before.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $width = Get-WaConsoleWidth
    $line = if ($Text.Length -gt $width) { $Text.Substring(0, $width - 3) + '...' } else { $Text }
    Write-Host ("`r" + $line.PadRight($width)) -NoNewline -ForegroundColor DarkGray
    $script:WaTransientWidth = $width
}

function Clear-WaTransientLine {
    <#
    .SYNOPSIS
        Removes the transient line so the next permanent line starts on clean ground.
    #>
    [CmdletBinding()]
    param()
    if ($script:WaTransientWidth -le 0) { return }
    Write-Host ("`r" + (' ' * $script:WaTransientWidth) + "`r") -NoNewline
    $script:WaTransientWidth = 0
}

function Get-WaProgressStatusWord {
    <#
    .SYNOPSIS
        The short word and colour shown for a finished action.
    #>
    [CmdletBinding()]
    param([string]$Status)

    switch ($Status) {
        'Succeeded'          { return [pscustomobject]@{ Word = 'done';    Colour = 'Green' } }
        'PartiallySucceeded' { return [pscustomobject]@{ Word = 'partial'; Colour = 'Yellow' } }
        'Failed'             { return [pscustomobject]@{ Word = 'failed';  Colour = 'Red' } }
        'Blocked'            { return [pscustomobject]@{ Word = 'blocked'; Colour = 'Red' } }
        'Skipped'            { return [pscustomobject]@{ Word = 'skipped'; Colour = 'DarkGray' } }
        'Simulated'          { return [pscustomobject]@{ Word = 'dry run'; Colour = 'Cyan' } }
        default              { return [pscustomobject]@{ Word = ([string]$Status).ToLowerInvariant(); Colour = 'Gray' } }
    }
}

function Show-WaLiveActivity {
    <#
    .SYNOPSIS
        Shows what is happening right now, in place where the host allows it.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Text, [switch]$InPlace)

    if ($InPlace) {
        Write-WaTransientLine -Text $Text
        return
    }

    # Nothing can be rewritten here, so print rarely: often enough to show the run is
    # alive, not so often that a transcript becomes unreadable.
    if ($null -eq $script:WaPlainProgressClock) {
        $script:WaPlainProgressClock = [Diagnostics.Stopwatch]::StartNew()
    } elseif ($script:WaPlainProgressClock.ElapsedMilliseconds -lt $script:WaPlainProgressIntervalMs) {
        return
    } else {
        $script:WaPlainProgressClock.Restart()
    }
    Write-Host $Text -ForegroundColor DarkGray
}

function Show-WaExecutionProgress {
    <#
    .SYNOPSIS
        Renders one execution progress event.

    .DESCRIPTION
        Called by Invoke-WaPlan through the sink Get-WaExecutionProgressSink builds.
        Display only: it is told what happened and has no say in what happens next.

    .PARAMETER InPlace
        Rewrite the current activity on one line. Off for hosts that cannot do it, which
        get an occasional plain line instead.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$ProgressEvent, [switch]$InPlace)

    $index = [int]$ProgressEvent.Index
    $total = [int]$ProgressEvent.Total
    $digits = [Math]::Max(1, ([string]$total).Length)
    $counter = if ($total -gt 0) { '[{0}/{1}] ' -f ([string]$index).PadLeft($digits), $total } else { '' }

    switch ($ProgressEvent.Phase) {

        'Start' {
            Clear-WaTransientLine
            Write-Host ('  {0}' -f $ProgressEvent.Message) -ForegroundColor Cyan
        }

        'Baseline' {
            Show-WaLiveActivity -Text ('  {0}' -f $ProgressEvent.Message) -InPlace:$InPlace
        }

        'Verify' {
            Show-WaLiveActivity -Text ('  {0}' -f $ProgressEvent.Message) -InPlace:$InPlace
        }

        'RestorePoint' {
            Clear-WaTransientLine
            Write-Host ('  {0}. This can take a minute.' -f $ProgressEvent.Message) -ForegroundColor Yellow
        }

        'Action' {
            $text = '  {0}{1}' -f $counter, $ProgressEvent.Title
            if ($ProgressEvent.Message) { $text = '{0} - {1}' -f $text, $ProgressEvent.Message }
            Show-WaLiveActivity -Text $text -InPlace:$InPlace
        }

        'Operation' {
            $text = '  {0}{1} - {2}' -f $counter, $ProgressEvent.Title, $ProgressEvent.Message
            Show-WaLiveActivity -Text $text -InPlace:$InPlace
        }

        'ActionComplete' {
            Clear-WaTransientLine
            $status = Get-WaProgressStatusWord -Status $ProgressEvent.Status

            # Titles are truncated to keep the columns aligned, as in the plan listing.
            $title = [string]$ProgressEvent.Title
            if ($title.Length -gt 46) { $title = $title.Substring(0, 43) + '...' }

            $size = if ($null -eq $ProgressEvent.BytesReclaimed) { '' } else { Format-WaBytes $ProgressEvent.BytesReclaimed }
            $elapsed = if ($ProgressEvent.ElapsedMs -ge 1000) { '{0:N1}s' -f ($ProgressEvent.ElapsedMs / 1000) } else { '' }

            Write-Host ('  {0}' -f $counter) -NoNewline -ForegroundColor DarkGray
            Write-Host ($title.PadRight(46)) -NoNewline -ForegroundColor Gray
            Write-Host ('{0,11}  ' -f $size) -NoNewline -ForegroundColor Gray
            Write-Host ('{0,-8}' -f $status.Word) -NoNewline -ForegroundColor $status.Colour
            Write-Host ('{0}' -f $elapsed) -ForegroundColor DarkGray
        }

        'Complete' {
            Clear-WaTransientLine
        }
    }
}

function Get-WaExecutionProgressSink {
    <#
    .SYNOPSIS
        Builds the callback Invoke-WaPlan uses to report progress to the console.

    .EXAMPLE
        $sink = Get-WaExecutionProgressSink -Session $session
        $results = Invoke-WaPlan -Session $session -Plan $plan -OnProgress $sink
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session)

    $script:WaProgressInPlace = (-not $Session.NonInteractive) -and (Test-WaTransientConsole)
    $script:WaTransientWidth = 0
    $script:WaPlainProgressClock = $null

    return {
        param($ProgressEvent)
        Show-WaExecutionProgress -ProgressEvent $ProgressEvent -InPlace:$script:WaProgressInPlace
    }
}

function Show-WaResults {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session, [object[]]$Results = @())

    Write-WaHeading 'Results'
    if (@($Results).Count -eq 0) {
        Write-Host '    Nothing ran.' -ForegroundColor DarkGray
        return
    }

    foreach ($result in @($Results)) {
        $colour = switch ($result.Status) {
            'Succeeded'          { 'Green' }
            'PartiallySucceeded' { 'Yellow' }
            'Failed'             { 'Red' }
            'Blocked'            { 'Red' }
            'Simulated'          { 'Cyan' }
            default              { 'DarkGray' }
        }
        Write-Host ('    {0} {1}{2}' -f
            ([string]$result.Status).PadRight(20),
            $result.Summary,
            $(if ($null -ne $result.BytesReclaimed) { '  (' + (Format-WaBytes $result.BytesReclaimed) + ')' } else { '' })) -ForegroundColor $colour
        # One action can carry a line per deleted file; the report keeps all of them.
        $messages = @($result.Messages)
        foreach ($message in @($messages | Select-Object -First 12)) {
            Write-Host ('        {0}' -f $message) -ForegroundColor DarkGray
        }
        if ($messages.Count -gt 12) {
            Write-Host ('        ... and {0} more. The report lists every one.' -f ($messages.Count - 12)) -ForegroundColor DarkGray
        }
        if ($result.Error) { Write-Host ('        {0}' -f $result.Error) -ForegroundColor Red }
    }

    $verification = $Session.Verification
    if ($null -ne $verification) {
        Write-WaHeading 'Before and after'
        Write-WaField 'Measured during execution' (Format-WaBytes $verification.ReportedBytesReclaimed)
        Write-WaField 'Free-space change'         (Format-WaBytes $verification.VolumeFreeSpaceDelta)
        Write-WaField 'Predicted beforehand'      (Format-WaBytes $verification.EstimatedBytes)
        Write-WaField 'Succeeded / failed / skipped' ('{0} / {1} / {2}' -f $verification.Succeeded, $verification.Failed, $verification.Skipped)
        foreach ($note in @($verification.Notes)) { Write-Host ('    {0}' -f $note) -ForegroundColor DarkGray }
    }

    if (@($Session.RollbackRecords).Count -gt 0) {
        Write-WaHeading 'Rollback'
        Write-Host ('    {0} reversible change(s) recorded under session {1}.' -f @($Session.RollbackRecords).Count, $Session.Id) -ForegroundColor Gray
        Write-Host ('    Restore with: Invoke-WaRollback -SessionId {0}' -f $Session.Id) -ForegroundColor DarkGray
    }
}

function Show-WaSettings {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session)

    $config = $Session.Config
    Write-WaHeading 'Settings'
    Write-WaField 'Configuration file'   $config.SourcePath
    Write-WaField 'User override'        $(if ($config.UserPath) { $config.UserPath } else { 'none' })
    Write-WaField 'Policy file'          $config.Policy.SourcePath
    Write-Host ''
    Write-WaField 'Minimum temp age'     ('{0} days' -f $config.MinimumTempAgeDays)
    Write-WaField 'Minimum cache age'    ('{0} days' -f $config.MinimumCacheAgeDays)
    Write-WaField 'Large file threshold' (Format-WaBytes $config.LargeFileThresholdBytes)
    Write-WaField 'Scan budget'          ('{0} entries or {1}s per directory' -f $config.MaxEntriesPerRoot, $config.MaxScanSecondsPerRoot)
    Write-WaField 'Deep scan paths'      $(if (@($config.DeepScanPaths).Count -gt 0) { @($config.DeepScanPaths) -join ', ' } else { 'none (Czkawka uses its default personal folders)' })
    Write-WaField 'Excluded paths'       $(if (@($config.ExcludedPaths).Count -gt 0) { @($config.ExcludedPaths) -join ', ' } else { 'none' })
    Write-Host ''
    Write-WaField 'Batch approval up to' $config.MaximumAutoApprovableRisk
    Write-WaField 'Individual approval'  ('at or above {0}' -f $config.RequireIndividualApprovalAtOrAbove)
    Write-WaField 'Restore point first'  $config.CreateRestorePointBeforeHighRisk
    Write-WaField 'External tools'       $(if ($config.AllowExternalTools) { 'allowed' } else { 'not allowed' })
    Write-WaField 'DISM analysis'        $(if ($config.AllowDismAnalyze) { 'allowed' } else { 'not allowed' })
    Write-WaField 'Report formats'       (@($config.ReportFormats) -join ', ')
    Write-WaField 'Logging verbosity'    $config.LoggingVerbosity

    Write-WaHeading 'Providers'
    foreach ($provider in (Get-WaProvider)) {
        $enabled = Test-WaProviderEnabled -Config $config -Provider $provider.Name
        Write-Host ('    {0} {1} {2}' -f
            ([string]$provider.Name).PadRight(28),
            $(if ($enabled) { 'enabled ' } else { 'disabled' }),
            $provider.Title) -ForegroundColor $(if ($enabled) { 'Gray' } else { 'DarkGray' })
        if ($provider.ExternalDependency) {
            Write-Host ('        needs the external tool "{0}"; WinAdvisor never installs it for you' -f $provider.ExternalDependency) -ForegroundColor DarkGray
        }
    }

    Write-Host ''
    Write-Host '  Settings are file-based. Copy Config/defaults.json, edit the copy, and pass it' -ForegroundColor DarkGray
    Write-Host '  with -ConfigPath. Config/policies.json holds the safety policy and is not' -ForegroundColor DarkGray
    Write-Host '  overridable from a user configuration file.' -ForegroundColor DarkGray
}

function Show-WaReportList {
    [CmdletBinding()]
    param()

    Write-WaHeading 'Recent sessions'
    $sessions = @(Get-WaSessionRecord -Last 15)
    if ($sessions.Count -eq 0) {
        Write-Host '    No sessions have been recorded yet.' -ForegroundColor DarkGray
        return
    }
    foreach ($record in $sessions) {
        Write-Host ('    {0}  {1}  {2} recommendation(s), {3} result(s)' -f
            (Get-WaProperty -Object $record -Name 'Id'),
            ([string](Get-WaProperty -Object $record -Name 'Mode')).PadRight(10),
            @(ConvertTo-WaArray (Get-WaProperty -Object $record -Name 'Recommendations')).Count,
            @(ConvertTo-WaArray (Get-WaProperty -Object $record -Name 'Results')).Count) -ForegroundColor Gray
        foreach ($path in @(ConvertTo-WaArray (Get-WaProperty -Object $record -Name 'ReportPaths'))) {
            Write-Host ('        {0}' -f $path) -ForegroundColor DarkGray
        }
    }
}

function Show-WaRollbackMenu {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session)

    Write-WaHeading 'Rollback and recovery'
    $rollbackSessions = @(Get-WaRollbackSession)
    if ($rollbackSessions.Count -eq 0) {
        Write-Host '    No rollback state has been recorded. Nothing reversible has been changed.' -ForegroundColor DarkGray
        return
    }

    $index = 0
    foreach ($rollbackSession in $rollbackSessions) {
        $index++
        Write-Host ('    [{0}] {1}  {2} record(s), {3} not yet restored  ({4})' -f
            $index, $rollbackSession.SessionId, $rollbackSession.RecordCount, $rollbackSession.PendingCount, $rollbackSession.StartedUtc) -ForegroundColor Gray
        foreach ($record in (@($rollbackSession.Records) | Select-Object -First 6)) {
            Write-Host ('          {0} on {1}: {2}' -f
                (Get-WaProperty -Object $record -Name 'Kind'),
                (Get-WaProperty -Object $record -Name 'Target'),
                (Get-WaProperty -Object $record -Name 'RestoreDescription')) -ForegroundColor DarkGray
        }
    }

    Write-Host ''
    Write-Host '    Deleted cache files are not listed here and are not recoverable: they were' -ForegroundColor DarkGray
    Write-Host '    classified as regenerable, and WinAdvisor does not copy files before deleting.' -ForegroundColor DarkGray

    if ($Session.NonInteractive) { return }

    Write-Host ''
    $choice = (Read-Host '  Restore which session? (number, or Enter to go back)').Trim()
    if ([string]::IsNullOrWhiteSpace($choice)) { return }

    $selection = 0
    if (-not [int]::TryParse($choice, [ref]$selection) -or $selection -lt 1 -or $selection -gt $rollbackSessions.Count) {
        Write-Host '  Not a valid selection.' -ForegroundColor Yellow
        return
    }

    $target = $rollbackSessions[$selection - 1]
    Write-Host ''
    Write-Host ('  This restores {0} recorded change(s) from session {1}.' -f $target.RecordCount, $target.SessionId) -ForegroundColor Yellow
    $confirm = (Read-Host '  Type YES to proceed').Trim()
    if ($confirm -cne 'YES') {
        Write-Host '  Cancelled.' -ForegroundColor Green
        return
    }

    $outcome = Invoke-WaRollback -SessionId $target.SessionId -Confirm:$false
    Write-Host ''
    Write-Host ('  Restored {0}, skipped {1}, failed {2}.' -f $outcome.Restored, $outcome.Skipped, $outcome.Failed) -ForegroundColor Green
    foreach ($result in @($outcome.Results)) {
        Write-Host ('    {0}  {1}: {2}' -f ([string]$result.Status).PadRight(10), $result.Target, $result.Message) -ForegroundColor DarkGray
    }
}

function Show-WaMenu {
    <#
    .SYNOPSIS
        The interactive menu.

    .DESCRIPTION
        Runs in a read-only session. Cleanup and rollback options create their own sessions,
        so nothing reached from browsing can change the machine by accident.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session)

    $running = $true
    while ($running) {
        Write-Host ''
        # ASCII only, deliberately. Windows PowerShell 5.1 reads a BOM-less UTF-8 script as
        # ANSI, which turns box-drawing characters into mojibake and can corrupt the string
        # literals around them. Every source file in this project stays 7-bit ASCII.
        Write-Host '  +-- WinAdvisor ---------------------------------------------------+' -ForegroundColor DarkCyan
        Write-Host '  |                                                                 |' -ForegroundColor DarkCyan
        Write-Host '  |   READ-ONLY                                                     |' -ForegroundColor DarkCyan
        Write-Host '  |    [1]  View specs                  full machine inventory      |' -ForegroundColor DarkCyan
        Write-Host '  |    [2]  System analysis             findings and evidence       |' -ForegroundColor DarkCyan
        Write-Host '  |    [3]  Storage analysis            where the space went        |' -ForegroundColor DarkCyan
        Write-Host '  |    [4]  Startup and memory          what runs and what it costs |' -ForegroundColor DarkCyan
        Write-Host '  |    [5]  Generate maintenance plan   proposed actions only       |' -ForegroundColor DarkCyan
        Write-Host '  |    [8]  Dry run                     full pipeline, no changes   |' -ForegroundColor DarkCyan
        Write-Host '  |                                                                 |' -ForegroundColor DarkCyan
        Write-Host '  |   CHANGES THE MACHINE                                           |' -ForegroundColor DarkCyan
        Write-Host '  |    [6]  Interactive cleanup         approve, then execute       |' -ForegroundColor DarkCyan
        Write-Host '  |    [7]  Custom cleanup              choose providers first      |' -ForegroundColor DarkCyan
        Write-Host '  |   [10]  Rollback and recovery       restore recorded state      |' -ForegroundColor DarkCyan
        Write-Host '  |                                                                 |' -ForegroundColor DarkCyan
        Write-Host '  |    [9]  Reports and sessions        [11] Settings      [0] Exit |' -ForegroundColor DarkCyan
        Write-Host '  +-----------------------------------------------------------------+' -ForegroundColor DarkCyan
        Write-Host ''

        $choice = (Read-Host '  Choose').Trim()

        switch ($choice) {
            '1' {
                [void](Get-WaMachineProfile -Session $Session)
                Show-WaSpecs -Session $Session
            }
            '2' {
                $analysis = Get-WaAnalysis -Session $Session -IncludeComponentStore
                Show-WaFindings -Analysis $analysis
                Show-WaProviderStatus -Analysis $analysis
            }
            '3' {
                $analysis = Get-WaAnalysis -Session $Session
                Show-WaStorageAnalysis -Session $Session -Analysis $analysis -Deep:(@($Session.Config.DeepScanPaths).Count -gt 0)
            }
            '4' {
                if ($null -eq $Session.MachineProfile) { [void](Get-WaMachineProfile -Session $Session) }
                Show-WaStartupAndMemory -Session $Session
            }
            '5' {
                $analysis = Get-WaAnalysis -Session $Session -IncludeComponentStore
                Show-WaQuestionSet -Session $Session
                $plan = New-WaPlan -Session $Session -Analysis $analysis
                Show-WaPlan -Plan $plan
                Write-Host '  This is a plan only. Nothing was changed. Use [6] to act on it.' -ForegroundColor DarkGray
            }
            '6' { [void](Invoke-WaCleanupFlow -ParentSession $Session) }
            '7' { [void](Invoke-WaCleanupFlow -ParentSession $Session -Custom) }
            '8' {
                $dryRunSession = New-WaSession -Mode 'DryRun' -Config $Session.Config -NonInteractive:$Session.NonInteractive
                [void](Invoke-WaDryRun -Session $dryRunSession)
                [void](Complete-WaSession -Session $dryRunSession)
            }
            '9' {
                Show-WaReportList
                if ($null -ne $Session.MachineProfile) {
                    Write-Host ''
                    $export = (Read-Host '  Export a report for the current session? [y/N]').Trim().ToUpperInvariant()
                    if ($export -eq 'Y') {
                        $paths = Export-WaReport -Session $Session
                        foreach ($path in $paths) { Write-Host ('    written: {0}' -f $path) -ForegroundColor Green }
                    }
                }
            }
            '10' { Show-WaRollbackMenu -Session $Session }
            '11' { Show-WaSettings -Session $Session }
            '0' { $running = $false }
            default { Write-Host '  Not a valid choice.' -ForegroundColor Yellow }
        }
    }
    Write-Host ''
    Write-Host '  Goodbye.' -ForegroundColor DarkGray
}
