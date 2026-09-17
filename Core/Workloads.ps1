<#
    Core/Workloads.ps1 - installed software, workload detection, startup and processes.

    This is what makes the analysis device-specific. A machine with Docker, WSL and four
    package managers gets a different set of questions and recommendations from an office
    laptop, because this file establishes which of them are actually present.

    Detection records how it concluded something is installed. "The executable is on PATH"
    and "the service is running with three registered distributions" are both detections,
    but they do not deserve the same confidence, and the difference is preserved.
#>

function Get-WaInstalledApplication {
    <#
    .SYNOPSIS
        Enumerates installed applications from the uninstall registry.

    .DESCRIPTION
        Reads the 64-bit and 32-bit machine hives plus the current user hive. Entries
        without a display name, and update/patch entries marked SystemComponent, are
        skipped because they are servicing artefacts rather than applications.

        Not exhaustive by construction: an application extracted to a folder and run
        without an installer leaves no registry entry. That limitation is reported rather
        than hidden.
    #>
    [CmdletBinding()]
    param()

    $hives = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
    )

    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $applications = New-Object 'System.Collections.Generic.List[object]'

    foreach ($hive in $hives) {
        if (-not (Test-Path -LiteralPath $hive)) { continue }
        $keys = @()
        try { $keys = @(Get-ChildItem -LiteralPath $hive -ErrorAction Stop) } catch { continue }

        foreach ($key in $keys) {
            $properties = $null
            try { $properties = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction Stop } catch { continue }

            $displayName = [string](Get-WaProperty -Object $properties -Name 'DisplayName' -Default '')
            if ([string]::IsNullOrWhiteSpace($displayName)) { continue }
            if ([int](Get-WaProperty -Object $properties -Name 'SystemComponent' -Default 0) -eq 1) { continue }
            if (Get-WaProperty -Object $properties -Name 'ParentKeyName') { continue }

            $version = [string](Get-WaProperty -Object $properties -Name 'DisplayVersion' -Default '')
            $identity = '{0}|{1}' -f $displayName, $version
            if (-not $seen.Add($identity)) { continue }

            $installDate = [string](Get-WaProperty -Object $properties -Name 'InstallDate' -Default '')
            $parsedDate = $null
            if ($installDate -match '^\d{8}$') {
                $candidate = [datetime]::MinValue
                if ([datetime]::TryParseExact($installDate, 'yyyyMMdd', $null, [Globalization.DateTimeStyles]::None, [ref]$candidate)) {
                    $parsedDate = $candidate
                }
            }

            # EstimatedSize is in KB and is supplied by the installer, so it is a hint
            # rather than a measurement.
            $estimatedSize = Get-WaProperty -Object $properties -Name 'EstimatedSize'

            $applications.Add([pscustomobject][ordered]@{
                Name            = $displayName.Trim()
                Version         = $version
                Publisher       = [string](Get-WaProperty -Object $properties -Name 'Publisher' -Default '')
                InstallLocation = [string](Get-WaProperty -Object $properties -Name 'InstallLocation' -Default '')
                InstallDate     = $parsedDate
                EstimatedBytes  = $(if ($null -ne $estimatedSize) { [long]$estimatedSize * 1KB } else { $null })
                Scope           = $(if ($hive -like 'HKCU:*') { 'Current user' } else { 'Machine' })
                Architecture    = $(if ($hive -like '*WOW6432Node*') { 'x86' } else { 'native' })
                Source          = 'Uninstall registry'
                SizeNote        = 'EstimatedSize is declared by the installer, not measured from disk.'
            })
        }
    }

    return @($applications | Sort-Object Name)
}

function Get-WaStoreApplication {
    <#
    .SYNOPSIS
        Microsoft Store packages for the current user.
    #>
    [CmdletBinding()]
    param()

    try {
        return @(Get-AppxPackage -ErrorAction Stop | ForEach-Object {
            [pscustomobject][ordered]@{
                Name            = $_.Name
                Version         = [string]$_.Version
                Publisher       = $_.Publisher
                InstallLocation = $_.InstallLocation
                IsFramework     = $_.IsFramework
                NonRemovable    = $(try { $_.NonRemovable } catch { $null })
            }
        } | Sort-Object Name)
    } catch {
        return @()
    }
}

function Test-WaPathExists {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    try { return (Test-Path -LiteralPath $Path) } catch { return $false }
}

function Get-WaWorkloadDefinition {
    <#
    .SYNOPSIS
        The workload detection table.

    .DESCRIPTION
        One entry per workload the toolkit can reason about. Each declares how it may be
        detected; the strongest successful signal decides the recorded confidence.

        Signals, strongest first:
          Directory  a known install or data directory exists          HIGH
          Registry   a vendor registry key exists                      HIGH
          Feature    a Windows optional feature is enabled             HIGH
          Command    the executable resolves on PATH                   MEDIUM
    #>
    [CmdletBinding()]
    param()

    $base = Get-WaBasePaths

    @(
        # --- Browsers ---------------------------------------------------------------
        @{ Name = 'Google Chrome';  Category = 'Browser'; Vendor = 'Google';    Directories = @((Join-Path $base.LocalAppData 'Google\Chrome\User Data')); Registry = @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe') }
        @{ Name = 'Microsoft Edge'; Category = 'Browser'; Vendor = 'Microsoft'; Directories = @((Join-Path $base.LocalAppData 'Microsoft\Edge\User Data')) }
        @{ Name = 'Mozilla Firefox'; Category = 'Browser'; Vendor = 'Mozilla';  Directories = @((Join-Path $base.RoamingAppData 'Mozilla\Firefox')) }
        @{ Name = 'Brave';          Category = 'Browser'; Vendor = 'Brave';     Directories = @((Join-Path $base.LocalAppData 'BraveSoftware\Brave-Browser\User Data')) }
        @{ Name = 'Vivaldi';        Category = 'Browser'; Vendor = 'Vivaldi';   Directories = @((Join-Path $base.LocalAppData 'Vivaldi\User Data')) }
        @{ Name = 'Opera';          Category = 'Browser'; Vendor = 'Opera';     Directories = @((Join-Path $base.RoamingAppData 'Opera Software')) }

        # --- Containers and virtualization -------------------------------------------
        @{ Name = 'Docker';     Category = 'Containers'; Vendor = 'Docker'; Commands = @('docker'); Directories = @((Join-Path $base.LocalAppData 'Docker'), (Join-Path $base.RoamingAppData 'Docker')) }
        @{ Name = 'Podman';     Category = 'Containers'; Vendor = 'Red Hat'; Commands = @('podman') }
        @{ Name = 'WSL';        Category = 'Containers'; Vendor = 'Microsoft'; Commands = @('wsl'); Registry = @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'); Features = @('Microsoft-Windows-Subsystem-Linux', 'VirtualMachinePlatform') }
        @{ Name = 'Hyper-V';    Category = 'Virtualization'; Vendor = 'Microsoft'; Features = @('Microsoft-Hyper-V', 'Microsoft-Hyper-V-All', 'Microsoft-Hyper-V-Hypervisor') }
        @{ Name = 'VMware Workstation'; Category = 'Virtualization'; Vendor = 'VMware'; Registry = @('HKLM:\SOFTWARE\VMware, Inc.\VMware Workstation') }
        @{ Name = 'VirtualBox'; Category = 'Virtualization'; Vendor = 'Oracle'; Registry = @('HKLM:\SOFTWARE\Oracle\VirtualBox'); Commands = @('VBoxManage') }

        # --- Developer runtimes and SDKs ---------------------------------------------
        @{ Name = '.NET SDK';       Category = 'Developer runtime'; Vendor = 'Microsoft'; Commands = @('dotnet'); Directories = @((Join-Path $base.ProgramFiles 'dotnet\sdk')) }
        @{ Name = 'Node.js';        Category = 'Developer runtime'; Vendor = 'OpenJS';    Commands = @('node') }
        @{ Name = 'Python';         Category = 'Developer runtime'; Vendor = 'Python';    Commands = @('python', 'py') }
        @{ Name = 'Java';           Category = 'Developer runtime'; Vendor = 'Various';   Commands = @('java') }
        @{ Name = 'Rust';           Category = 'Developer runtime'; Vendor = 'Rust';      Commands = @('cargo', 'rustc'); Directories = @((Join-Path $base.UserProfile '.cargo')) }
        @{ Name = 'Go';             Category = 'Developer runtime'; Vendor = 'Google';    Commands = @('go') }

        # --- Package managers ---------------------------------------------------------
        @{ Name = 'npm';    Category = 'Package manager'; Vendor = 'OpenJS';   Commands = @('npm');  Directories = @((Join-Path $base.RoamingAppData 'npm-cache'), (Join-Path $base.LocalAppData 'npm-cache')) }
        @{ Name = 'pnpm';   Category = 'Package manager'; Vendor = 'pnpm';     Commands = @('pnpm') }
        @{ Name = 'Yarn';   Category = 'Package manager'; Vendor = 'Yarn';     Commands = @('yarn') }
        @{ Name = 'Bun';    Category = 'Package manager'; Vendor = 'Oven';     Commands = @('bun'); Directories = @((Join-Path $base.UserProfile '.bun')) }
        @{ Name = 'pip';    Category = 'Package manager'; Vendor = 'PyPA';     Commands = @('pip') }
        @{ Name = 'uv';     Category = 'Package manager'; Vendor = 'Astral';   Commands = @('uv') }
        @{ Name = 'NuGet';  Category = 'Package manager'; Vendor = 'Microsoft'; Directories = @((Join-Path $base.UserProfile '.nuget\packages')) }
        @{ Name = 'Gradle'; Category = 'Package manager'; Vendor = 'Gradle';   Directories = @((Join-Path $base.UserProfile '.gradle')) }
        @{ Name = 'Maven';  Category = 'Package manager'; Vendor = 'Apache';   Directories = @((Join-Path $base.UserProfile '.m2')) }
        @{ Name = 'winget'; Category = 'Package manager'; Vendor = 'Microsoft'; Commands = @('winget') }
        @{ Name = 'Chocolatey'; Category = 'Package manager'; Vendor = 'Chocolatey'; Commands = @('choco') }
        @{ Name = 'Scoop';  Category = 'Package manager'; Vendor = 'Scoop';    Directories = @((Join-Path $base.UserProfile 'scoop')) }

        # --- Editors and IDEs ---------------------------------------------------------
        @{ Name = 'Visual Studio'; Category = 'IDE'; Vendor = 'Microsoft'; Directories = @((Join-Path $base.ProgramFilesX86 'Microsoft Visual Studio'), (Join-Path $base.ProgramFiles 'Microsoft Visual Studio')) }
        @{ Name = 'Visual Studio Code'; Category = 'IDE'; Vendor = 'Microsoft'; Directories = @((Join-Path $base.RoamingAppData 'Code')); Commands = @('code') }
        @{ Name = 'JetBrains IDEs'; Category = 'IDE'; Vendor = 'JetBrains'; Directories = @((Join-Path $base.LocalAppData 'JetBrains'), (Join-Path $base.RoamingAppData 'JetBrains')) }

        # --- Databases -----------------------------------------------------------------
        @{ Name = 'PostgreSQL';  Category = 'Database'; Vendor = 'PostgreSQL'; Registry = @('HKLM:\SOFTWARE\PostgreSQL') }
        @{ Name = 'SQL Server';  Category = 'Database'; Vendor = 'Microsoft';  Registry = @('HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server') }
        @{ Name = 'MySQL';       Category = 'Database'; Vendor = 'Oracle';     Registry = @('HKLM:\SOFTWARE\MySQL AB') }

        # --- Gaming ---------------------------------------------------------------------
        @{ Name = 'Steam';        Category = 'Gaming'; Vendor = 'Valve';  Registry = @('HKCU:\Software\Valve\Steam') }
        @{ Name = 'Epic Games';   Category = 'Gaming'; Vendor = 'Epic';   Directories = @((Join-Path $base.LocalAppData 'EpicGamesLauncher')) }
        @{ Name = 'Xbox / Game Bar'; Category = 'Gaming'; Vendor = 'Microsoft'; Registry = @('HKCU:\Software\Microsoft\GameBar') }

        # --- Cloud sync ------------------------------------------------------------------
        @{ Name = 'OneDrive'; Category = 'Cloud sync'; Vendor = 'Microsoft'; Directories = @((Join-Path $base.LocalAppData 'Microsoft\OneDrive')) }
        @{ Name = 'Dropbox';  Category = 'Cloud sync'; Vendor = 'Dropbox';   Directories = @((Join-Path $base.LocalAppData 'Dropbox')) }
        @{ Name = 'Google Drive'; Category = 'Cloud sync'; Vendor = 'Google'; Directories = @((Join-Path $base.LocalAppData 'Google\DriveFS')) }

        # --- GPU utilities -----------------------------------------------------------------
        @{ Name = 'NVIDIA software'; Category = 'GPU utility'; Vendor = 'NVIDIA'; Directories = @((Join-Path $base.ProgramData 'NVIDIA Corporation'), (Join-Path $base.LocalAppData 'NVIDIA')) }
        @{ Name = 'AMD software';    Category = 'GPU utility'; Vendor = 'AMD';    Directories = @((Join-Path $base.LocalAppData 'AMD')) }
        @{ Name = 'Intel Graphics';  Category = 'GPU utility'; Vendor = 'Intel';  Directories = @((Join-Path $base.LocalAppData 'Intel')) }
    )
}

function Get-WaDetectedWorkload {
    <#
    .SYNOPSIS
        Runs the detection table and returns one InstalledComponent per workload found.

    .DESCRIPTION
        Only detected workloads are returned. Analysis and questioning then key off this
        list, which is how the toolkit avoids offering Docker cleanup on a machine with no
        Docker, or asking about hibernation on a desktop that never had it enabled.
    #>
    [CmdletBinding()]
    param()

    $enabledFeatures = @{}
    try {
        foreach ($feature in (Get-WaCimData -ClassName 'Win32_OptionalFeature' -Property @('Name', 'InstallState'))) {
            if ([int](Get-WaProperty -Object $feature -Name 'InstallState' -Default 0) -eq 1) {
                $enabledFeatures[[string](Get-WaProperty -Object $feature -Name 'Name')] = $true
            }
        }
    } catch { }

    $detected = New-Object 'System.Collections.Generic.List[object]'

    # A missing hashtable key yields $null, and @($null) is an array containing one null
    # element rather than an empty array. Iterating that passes $null into the body, which
    # is how a single missing key used to abort the whole detection pass.
    $asList = {
        param($Value)
        if ($null -eq $Value) { return @() }
        return @($Value | Where-Object { $null -ne $_ -and '' -ne $_ })
    }

    foreach ($definition in (Get-WaWorkloadDefinition)) {
        $method     = ''
        $confidence = 'UNKNOWN'
        $evidence   = ''
        $installPath = ''
        $executable  = ''

        foreach ($directory in (& $asList $definition['Directories'])) {
            if (Test-WaPathExists -Path $directory) {
                $method = 'Directory'; $confidence = 'HIGH'; $evidence = $directory; $installPath = $directory
                break
            }
        }

        if ($confidence -eq 'UNKNOWN') {
            foreach ($key in (& $asList $definition['Registry'])) {
                if (Test-WaPathExists -Path $key) {
                    $method = 'Registry'; $confidence = 'HIGH'; $evidence = $key
                    break
                }
            }
        }

        if ($confidence -eq 'UNKNOWN') {
            foreach ($feature in (& $asList $definition['Features'])) {
                if ($enabledFeatures.ContainsKey([string]$feature)) {
                    $method = 'OptionalFeature'; $confidence = 'HIGH'; $evidence = ("Windows optional feature '{0}' is enabled" -f $feature)
                    break
                }
            }
        }

        if ($confidence -eq 'UNKNOWN') {
            foreach ($command in (& $asList $definition['Commands'])) {
                $path = Resolve-WaCommandPath -Name ([string]$command)
                if ($path) {
                    # PATH resolution is a weaker signal: a shim or a stale entry can resolve
                    # for a tool that is no longer usable.
                    $method = 'Command'; $confidence = 'MEDIUM'; $evidence = $path; $executable = $path
                    break
                }
            }
        }

        if ($confidence -eq 'UNKNOWN') { continue }

        $detected.Add((New-WaInstalledComponent `
            -Name $definition['Name'] `
            -Category $definition['Category'] `
            -Vendor ([string]$definition['Vendor']) `
            -InstallPath $installPath `
            -Executable $executable `
            -Detected $true `
            -DetectionConfidence $confidence `
            -DetectionMethod $method `
            -Note $evidence))
    }

    return @($detected | Sort-Object Category, Name)
}

function Get-WaStartupCategory {
    <#
    .SYNOPSIS
        Classifies a startup item from its name, publisher and command.

    .DESCRIPTION
        Classification decides whether an item is even eligible to be proposed for
        disabling. Anything that cannot be classified stays Unknown, and Unknown is never
        proposed: an unrecognised startup entry might be the thing keeping a fingerprint
        reader or a VPN working.
    #>
    [CmdletBinding()]
    param([string]$Name = '', [string]$Command = '', [string]$Publisher = '')

    $subject = ('{0} {1} {2}' -f $Name, $Command, $Publisher).ToLowerInvariant()

    switch -Regex ($subject) {
        'defender|securityhealth|msmpeng|crowdstrike|csfalcon|sentinelone|carbonblack|cylance|sophos|eset|mcafee|symantec|trendmicro|kaspersky|bitdefender' { return 'Security' }
        'intune|companyportal|ccmexec|sccm|workspace one|airwatch|jamf' { return 'Device management' }
        'narrator|magnify|osk|accessibility|nvda|jaws' { return 'Accessibility' }
        'synaptics|syntp|etdctrl|elan|touchpad|realtek|rtkaudio|ravcpl|rtkngui|igfxtray|hkcmd|nvidia|amd|radeon|intel\(r\)|iastor|rstmw|logitech|razer|corsair|steelseries' { return 'Hardware and drivers' }
        'onedrive|dropbox|googledrive|drivefs|box sync|nextcloud|megasync|icloud' { return 'Cloud synchronization' }
        'teams|slack|discord|zoom|skype|webex|telegram|whatsapp|signal' { return 'Communication' }
        'steam|epicgames|epiclauncher|gog|origin|ubisoft|battle\.net|riot|ea desktop|xbox|gamebar' { return 'Gaming' }
        'docker|wsl|visual studio|vscode|code\.exe|jetbrains|postman|git|node|python|dotnet' { return 'Development tools' }
        'dell|hp |hewlett|lenovo|asus|acer|msi |razer|alienware|vantage|support assist|supportassist|armoury|myasus|mycomputer' { return 'OEM utility' }
        'adobe|acrobat|creative cloud|spotify|java update|jusched|quicktime|itunes|ccleaner' { return 'Optional user application' }
        'windows|microsoft\\windows|securityhealthsystray|explorer\.exe|ctfmon|rundll32' { return 'Windows system' }
    }
    return 'Unknown'
}

function Get-WaStartupApprovedState {
    <#
    .SYNOPSIS
        Reads the Explorer StartupApproved state for a startup entry.

    .DESCRIPTION
        Windows records whether a startup item is enabled in
        ...\Explorer\StartupApproved\*, which is the same mechanism Task Manager's Startup
        tab uses. The first byte of the binary value carries the state: an even value means
        enabled, an odd value means disabled.

        This is why disabling a startup item here does not delete the original Run value:
        the entry is left intact and only its approval state changes, so re-enabling it is
        a single value write.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][ValidateSet('Run', 'Run32', 'StartupFolder')][string]$Scope, [ValidateSet('User', 'Machine')][string]$Hive = 'User')

    $keyName = switch ($Scope) {
        'Run'           { 'Run' }
        'Run32'         { 'Run32' }
        'StartupFolder' { 'StartupFolder' }
    }
    $root = if ($Hive -eq 'User') { 'HKCU:' } else { 'HKLM:' }
    $path = "$root\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\$keyName"

    try {
        if (-not (Test-Path -LiteralPath $path)) { return [pscustomobject]@{ Known = $false; Enabled = $true; KeyPath = $path } }
        $properties = Get-ItemProperty -LiteralPath $path -ErrorAction Stop
        $value = Get-WaProperty -Object $properties -Name $Name
        if ($null -eq $value) { return [pscustomobject]@{ Known = $false; Enabled = $true; KeyPath = $path } }
        $bytes = @($value)
        if ($bytes.Count -eq 0) { return [pscustomobject]@{ Known = $false; Enabled = $true; KeyPath = $path } }
        return [pscustomobject]@{ Known = $true; Enabled = (([int]$bytes[0] % 2) -eq 0); KeyPath = $path }
    } catch {
        return [pscustomobject]@{ Known = $false; Enabled = $true; KeyPath = $path }
    }
}

function Get-WaStartupInventory {
    <#
    .SYNOPSIS
        Enumerates startup items from Run keys, startup folders and logon scheduled tasks.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config)

    $policy = $Config.Policy
    $items = New-Object 'System.Collections.Generic.List[object]'
    $base  = Get-WaBasePaths

    $runKeys = @(
        @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run';              Scope = 'Run';   Hive = 'Machine'; Source = 'Machine Run key' }
        @{ Path = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run';  Scope = 'Run32'; Hive = 'Machine'; Source = 'Machine Run key (32-bit)' }
        @{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run';              Scope = 'Run';   Hive = 'User';    Source = 'User Run key' }
        @{ Path = 'HKCU:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run';  Scope = 'Run32'; Hive = 'User';    Source = 'User Run key (32-bit)' }
    )

    foreach ($runKey in $runKeys) {
        if (-not (Test-WaPathExists -Path $runKey.Path)) { continue }
        $properties = $null
        try { $properties = Get-ItemProperty -LiteralPath $runKey.Path -ErrorAction Stop } catch { continue }

        foreach ($property in $properties.PSObject.Properties) {
            if ($property.Name -like 'PS*') { continue }
            $command = [string]$property.Value
            if ([string]::IsNullOrWhiteSpace($command)) { continue }

            $approved = Get-WaStartupApprovedState -Name $property.Name -Scope $runKey.Scope -Hive $runKey.Hive
            $category = Get-WaStartupCategory -Name $property.Name -Command $command

            $items.Add([pscustomobject][ordered]@{
                Name        = $property.Name
                Command     = $command
                Executable  = (Get-WaExecutableFromCommand -Command $command)
                Source      = $runKey.Source
                SourceKind  = 'RegistryRun'
                RegistryPath = $runKey.Path
                ApprovalScope = $runKey.Scope
                ApprovalHive  = $runKey.Hive
                Enabled     = $approved.Enabled
                StateKnown  = $approved.Known
                Category    = $category
                Protected   = (Test-WaProtectedStartupItem -Name $property.Name -Command $command -Policy $policy)
                RequiresAdmin = ($runKey.Hive -eq 'Machine')
            })
        }
    }

    $startupFolders = @(
        @{ Path = (Join-Path $base.RoamingAppData 'Microsoft\Windows\Start Menu\Programs\Startup'); Hive = 'User';    Source = 'User startup folder' }
        @{ Path = (Join-Path $base.ProgramData 'Microsoft\Windows\Start Menu\Programs\Startup');    Hive = 'Machine'; Source = 'Common startup folder' }
    )

    foreach ($folder in $startupFolders) {
        if (-not (Test-WaPathExists -Path $folder.Path)) { continue }
        $entries = @()
        try { $entries = @(Get-ChildItem -LiteralPath $folder.Path -File -ErrorAction Stop) } catch { continue }

        foreach ($entry in $entries) {
            if ($entry.Name -ieq 'desktop.ini') { continue }
            $approved = Get-WaStartupApprovedState -Name $entry.Name -Scope 'StartupFolder' -Hive $folder.Hive
            $category = Get-WaStartupCategory -Name $entry.BaseName -Command $entry.FullName

            $items.Add([pscustomobject][ordered]@{
                Name        = $entry.Name
                Command     = $entry.FullName
                Executable  = $entry.FullName
                Source      = $folder.Source
                SourceKind  = 'StartupFolder'
                RegistryPath = ''
                ApprovalScope = 'StartupFolder'
                ApprovalHive  = $folder.Hive
                Enabled     = $approved.Enabled
                StateKnown  = $approved.Known
                Category    = $category
                Protected   = (Test-WaProtectedStartupItem -Name $entry.BaseName -Command $entry.FullName -Policy $policy)
                RequiresAdmin = ($folder.Hive -eq 'Machine')
            })
        }
    }

    if (Get-WaProviderSetting -Config $Config -Provider 'Windows.Startup' -Name 'IncludeScheduledTasks' -Default $true) {
        try {
            foreach ($task in (Get-ScheduledTask -ErrorAction Stop)) {
                $triggers = @($task.Triggers | Where-Object { $null -ne $_ })
                $isLogonOrBoot = @($triggers | Where-Object {
                    $_.CimClass.CimClassName -in @('MSFT_TaskLogonTrigger', 'MSFT_TaskBootTrigger')
                }).Count -gt 0
                if (-not $isLogonOrBoot) { continue }
                # Microsoft's own maintenance tasks are infrastructure, not startup clutter.
                if ($task.TaskPath -like '\Microsoft\Windows\*') { continue }

                $action = @($task.Actions | Where-Object { $_.PSObject.Properties['Execute'] }) | Select-Object -First 1
                $execute = [string](Get-WaProperty -Object $action -Name 'Execute' -Default '')

                $items.Add([pscustomobject][ordered]@{
                    Name        = $task.TaskName
                    Command     = $execute
                    Executable  = (Get-WaExecutableFromCommand -Command $execute)
                    Source      = ('Scheduled task {0}{1}' -f $task.TaskPath, $task.TaskName)
                    SourceKind  = 'ScheduledTask'
                    RegistryPath = ''
                    ApprovalScope = 'ScheduledTask'
                    ApprovalHive  = 'Machine'
                    Enabled     = ($task.State -ne 'Disabled')
                    StateKnown  = $true
                    Category    = (Get-WaStartupCategory -Name $task.TaskName -Command $execute)
                    Protected   = (Test-WaProtectedStartupItem -Name $task.TaskName -Command $execute -Policy $policy)
                    RequiresAdmin = $true
                    TaskPath    = $task.TaskPath
                })
            }
        } catch { }
    }

    return @($items | Sort-Object Category, Name)
}

function Get-WaExecutableFromCommand {
    <#
    .SYNOPSIS
        Extracts the executable path from a Run-key command line.

    .DESCRIPTION
        Only the executable is kept. The remainder of a startup command line is discarded
        rather than stored, because arguments routinely contain tokens and account names
        and there is no reason for a maintenance report to hold them.
    #>
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Command)

    if ([string]::IsNullOrWhiteSpace($Command)) { return '' }
    $trimmed = $Command.Trim()

    if ($trimmed.StartsWith('"')) {
        $end = $trimmed.IndexOf('"', 1)
        if ($end -gt 1) { return $trimmed.Substring(1, $end - 1) }
    }

    $space = $trimmed.IndexOf(' ')
    if ($space -lt 0) { return $trimmed }

    # An unquoted path with spaces: take the longest prefix that exists on disk.
    $candidate = $trimmed
    while ($space -gt 0) {
        $prefix = $trimmed.Substring(0, $space)
        if (Test-WaPathExists -Path $prefix) { return $prefix }
        $space = $trimmed.IndexOf(' ', $space + 1)
    }
    return $candidate.Split(' ')[0]
}

function Get-WaProcessInventory {
    <#
    .SYNOPSIS
        Groups running processes by application and reports their memory footprint.

    .DESCRIPTION
        Grouped by executable name, because a browser is one application spread over
        dozens of processes and reporting each separately answers nothing.

        Both working set and private bytes are reported. Working set is what Task Manager
        shows, but it counts shared pages in every process that maps them, so the total
        across a process group overstates real consumption. Private bytes is the figure
        that reflects memory that would actually be freed.

        Command lines are never collected.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config, [object[]]$StartupItems = @())

    $startupExecutables = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($item in $StartupItems) {
        $executable = [string](Get-WaProperty -Object $item -Name 'Executable' -Default '')
        if ($executable) { [void]$startupExecutables.Add([IO.Path]::GetFileName($executable)) }
    }

    $processes = @()
    try { $processes = @(Get-Process -ErrorAction SilentlyContinue) } catch { $processes = @() }

    $groups = $processes | Where-Object { $null -ne $_ } | Group-Object -Property ProcessName

    $result = New-Object 'System.Collections.Generic.List[object]'
    foreach ($group in $groups) {
        $workingSet = [long]0
        $privateBytes = [long]0
        $path = ''
        $company = ''

        foreach ($process in $group.Group) {
            try { $workingSet += [long]$process.WorkingSet64 } catch { }
            try { $privateBytes += [long]$process.PrivateMemorySize64 } catch { }
            if (-not $path) {
                # Path and company are unavailable for protected processes; that is normal.
                try { $path = [string]$process.Path } catch { $path = '' }
                try { $company = [string]$process.Company } catch { $company = '' }
            }
        }

        $executableName = $group.Name + '.exe'
        $category = Get-WaStartupCategory -Name $group.Name -Command $path -Publisher $company

        $result.Add([pscustomobject][ordered]@{
            Name              = $group.Name
            ProcessCount      = $group.Count
            WorkingSetBytes   = $workingSet
            PrivateBytes      = $privateBytes
            Company           = $company
            Path              = $(if ($Config.IncludeProcessPaths) { $path } else { '' })
            Category          = $category
            StartsAtLogon     = $startupExecutables.Contains($executableName)
        })
    }

    $ranked = @($result | Sort-Object PrivateBytes -Descending)
    $totalWorkingSet = [long]0
    $totalPrivate = [long]0
    foreach ($entry in $ranked) { $totalWorkingSet += $entry.WorkingSetBytes; $totalPrivate += $entry.PrivateBytes }

    [pscustomobject][ordered]@{
        ProcessGroups      = @($ranked | Select-Object -First $Config.TopProcessCount)
        TotalGroups        = $ranked.Count
        TotalProcesses     = $processes.Count
        TotalWorkingSetBytes = $totalWorkingSet
        TotalPrivateBytes  = $totalPrivate
        Note               = 'Working set counts shared pages in every process that maps them, so a group total overstates real consumption. Private bytes is the closer measure of memory that would be released. Neither figure is a performance measurement, and no process is terminated by this toolkit.'
        CommandLineNote    = 'Process command lines are deliberately not collected: they frequently contain credentials and access tokens.'
    }
}
