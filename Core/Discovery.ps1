<#
    Core/Discovery.ps1 - read-only machine discovery.

    Builds the MachineProfile: hardware, firmware, storage, Windows configuration and
    support status. Software workloads, startup items and processes are gathered by
    Core/Workloads.ps1 and attached here.

    Nothing in this file changes machine state. Every step runs through Invoke-WaProbe,
    so a class that does not exist, a key that is denied or a cmdlet that is missing
    degrades that one measurement instead of ending discovery.

    Discovery is staged by cost:
      1  cheap inventory   CIM and registry
      2  targeted sizes    known locations only
      3  workload analysis providers, only for what was detected
      4  deep filesystem   only for directories the user named explicitly
#>

function Get-WaOperatingSystemInfo {
    <#
    .SYNOPSIS
        Windows edition, version, build, install date, architecture and uptime.
    #>
    [CmdletBinding()]
    param()

    $os = @(Get-WaCimData -ClassName 'Win32_OperatingSystem' -Property @(
        'Caption', 'Version', 'BuildNumber', 'OSArchitecture', 'InstallDate', 'LastBootUpTime',
        'ProductType', 'TotalVisibleMemorySize', 'FreePhysicalMemory', 'TotalVirtualMemorySize',
        'FreeVirtualMemory', 'SystemDrive', 'Locale', 'CountryCode'
    )) | Select-Object -First 1

    $current = $null
    try {
        $current = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
    } catch { $current = $null }

    $lastBoot = Get-WaProperty -Object $os -Name 'LastBootUpTime'
    $uptime = $null
    if ($lastBoot -is [datetime]) { $uptime = ([datetime]::Now - $lastBoot) }

    $build = [int](Get-WaProperty -Object $os -Name 'BuildNumber' -Default 0)
    $ubr   = Get-WaProperty -Object $current -Name 'UBR'

    # The CurrentVersion\ProductName registry value still reads "Windows 10 ..." on
    # Windows 11, which Microsoft left in place for application compatibility. Reporting it
    # verbatim would tell a Windows 11 user they are on Windows 10, so Win32_OperatingSystem
    # Caption is preferred and the raw registry value is kept alongside it.
    $caption = [string](Get-WaProperty -Object $os -Name 'Caption' -Default '')
    $registryProductName = [string](Get-WaProperty -Object $current -Name 'ProductName' -Default '')
    $productName = $caption -replace '^Microsoft\s+', ''
    if ([string]::IsNullOrWhiteSpace($productName)) {
        $productName = $registryProductName
        if ($build -ge 22000 -and $productName -like 'Windows 10*') {
            $productName = $productName -replace '^Windows 10', 'Windows 11'
        }
    }

    [pscustomobject][ordered]@{
        Caption             = $caption
        EditionId           = Get-WaProperty -Object $current -Name 'EditionID'
        ProductName         = $productName
        RegistryProductName = $registryProductName
        ProductNameNote     = 'Taken from Win32_OperatingSystem Caption. The CurrentVersion\ProductName registry value still reads "Windows 10" on Windows 11 and is recorded separately as RegistryProductName.'
        DisplayVersion  = Get-WaProperty -Object $current -Name 'DisplayVersion'
        Version         = Get-WaProperty -Object $os -Name 'Version'
        Build           = $build
        UpdateBuildRevision = $ubr
        FullBuild       = $(if ($null -ne $ubr) { '{0}.{1}' -f $build, $ubr } else { [string]$build })
        Architecture    = Get-WaProperty -Object $os -Name 'OSArchitecture'
        InstallationType = Get-WaProperty -Object $current -Name 'InstallationType'
        InstallDate     = Get-WaProperty -Object $os -Name 'InstallDate'
        LastBootUpTime  = $lastBoot
        Uptime          = $uptime
        UptimeText      = $(if ($null -ne $uptime) { Format-WaDuration -Duration $uptime } else { 'unknown' })
        # ProductType 1 is a workstation; 2 and 3 are domain controller and server.
        ProductType     = Get-WaProperty -Object $os -Name 'ProductType'
        IsClient        = ((Get-WaProperty -Object $os -Name 'ProductType' -Default 0) -eq 1)
        SystemDrive     = Get-WaProperty -Object $os -Name 'SystemDrive'
        Locale          = Get-WaProperty -Object $os -Name 'Locale'
    }
}

function Get-WaHardwareInfo {
    <#
    .SYNOPSIS
        Manufacturer, model, chassis type, firmware and virtualization capability.

    .DESCRIPTION
        Serial numbers are recorded in masked form only. A machine serial identifies a
        specific device, and reports are routinely shared when asking for help.
    #>
    [CmdletBinding()]
    param()

    $computer = @(Get-WaCimData -ClassName 'Win32_ComputerSystem' -Property @(
        'Manufacturer', 'Model', 'SystemFamily', 'PCSystemType', 'TotalPhysicalMemory',
        'NumberOfProcessors', 'NumberOfLogicalProcessors', 'HypervisorPresent',
        'PartOfDomain', 'Domain', 'AutomaticManagedPagefile'
    )) | Select-Object -First 1

    $bios = @(Get-WaCimData -ClassName 'Win32_BIOS' -Property @(
        'Manufacturer', 'SMBIOSBIOSVersion', 'ReleaseDate', 'SerialNumber', 'Version'
    )) | Select-Object -First 1

    $board = @(Get-WaCimData -ClassName 'Win32_BaseBoard' -Property @('Manufacturer', 'Product', 'Version')) | Select-Object -First 1

    $mask = {
        param($Value)
        $text = [string]$Value
        if ([string]::IsNullOrWhiteSpace($text)) { return 'unknown' }
        $text = $text.Trim()
        if ($text.Length -le 4) { return '****' }
        return ('*' * ($text.Length - 4)) + $text.Substring($text.Length - 4)
    }

    # PCSystemType: 1 desktop, 2 mobile, 3 workstation, 4 enterprise server, 7 appliance.
    $systemType = [int](Get-WaProperty -Object $computer -Name 'PCSystemType' -Default 0)
    $chassis = switch ($systemType) {
        1 { 'Desktop' }
        2 { 'Laptop or tablet' }
        3 { 'Workstation' }
        4 { 'Enterprise server' }
        5 { 'SOHO server' }
        6 { 'Appliance PC' }
        7 { 'Performance server' }
        default { 'Unknown' }
    }

    $firmwareType = 'Unknown'
    try {
        # SecureBoot state is only meaningful on UEFI; the key exists there.
        $firmwareType = if (Test-Path -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State') { 'UEFI' } else { 'BIOS or unknown' }
    } catch { $firmwareType = 'Unknown' }

    $secureBoot = 'Unknown'
    try {
        $secureBoot = if (Confirm-SecureBootUEFI -ErrorAction Stop) { 'Enabled' } else { 'Disabled' }
    } catch {
        # Throws on non-UEFI machines and when not elevated on some builds.
        $secureBoot = 'Not reported (non-UEFI, or requires elevation)'
    }

    [pscustomobject][ordered]@{
        Manufacturer        = Get-WaProperty -Object $computer -Name 'Manufacturer'
        Model               = Get-WaProperty -Object $computer -Name 'Model'
        SystemFamily        = Get-WaProperty -Object $computer -Name 'SystemFamily'
        ChassisType         = $chassis
        IsPortable          = ($systemType -eq 2)
        BiosManufacturer    = Get-WaProperty -Object $bios -Name 'Manufacturer'
        BiosVersion         = Get-WaProperty -Object $bios -Name 'SMBIOSBIOSVersion'
        BiosReleaseDate     = Get-WaProperty -Object $bios -Name 'ReleaseDate'
        BiosSerialMasked    = (& $mask (Get-WaProperty -Object $bios -Name 'SerialNumber'))
        BaseBoardVendor     = Get-WaProperty -Object $board -Name 'Manufacturer'
        BaseBoardProduct    = Get-WaProperty -Object $board -Name 'Product'
        FirmwareType        = $firmwareType
        SecureBoot          = $secureBoot
        HypervisorPresent   = Get-WaProperty -Object $computer -Name 'HypervisorPresent' -Default $false
        PartOfDomain        = Get-WaProperty -Object $computer -Name 'PartOfDomain' -Default $false
        TotalPhysicalMemory = Get-WaProperty -Object $computer -Name 'TotalPhysicalMemory'
        SerialNote          = 'Serial numbers are masked to the final four characters so reports can be shared.'
    }
}

function Get-WaProcessorInfo {
    [CmdletBinding()]
    param()

    @(Get-WaCimData -ClassName 'Win32_Processor' -Property @(
        'Name', 'Manufacturer', 'Architecture', 'NumberOfCores', 'NumberOfLogicalProcessors',
        'MaxClockSpeed', 'CurrentClockSpeed', 'L2CacheSize', 'L3CacheSize',
        'VirtualizationFirmwareEnabled', 'SecondLevelAddressTranslationExtensions'
    ) | ForEach-Object {
        $architecture = switch ([int](Get-WaProperty -Object $_ -Name 'Architecture' -Default -1)) {
            0 { 'x86' } 5 { 'ARM' } 9 { 'x64' } 12 { 'ARM64' } default { 'Unknown' }
        }
        [pscustomobject][ordered]@{
            Name              = (Get-WaProperty -Object $_ -Name 'Name' -Default '').ToString().Trim()
            Manufacturer      = Get-WaProperty -Object $_ -Name 'Manufacturer'
            Architecture      = $architecture
            PhysicalCores     = Get-WaProperty -Object $_ -Name 'NumberOfCores'
            LogicalProcessors = Get-WaProperty -Object $_ -Name 'NumberOfLogicalProcessors'
            MaxClockMhz       = Get-WaProperty -Object $_ -Name 'MaxClockSpeed'
            CurrentClockMhz   = Get-WaProperty -Object $_ -Name 'CurrentClockSpeed'
            L2CacheKb         = Get-WaProperty -Object $_ -Name 'L2CacheSize'
            L3CacheKb         = Get-WaProperty -Object $_ -Name 'L3CacheSize'
            VirtualizationFirmwareEnabled = Get-WaProperty -Object $_ -Name 'VirtualizationFirmwareEnabled'
            SlatSupport       = Get-WaProperty -Object $_ -Name 'SecondLevelAddressTranslationExtensions'
            ClockNote         = 'CurrentClockSpeed is a point-in-time sample and varies with power and thermal state.'
        }
    })
}

function Get-WaMemoryInfo {
    <#
    .SYNOPSIS
        Installed modules, totals, and commit-based memory pressure.

    .DESCRIPTION
        Pressure is expressed as committed bytes against the commit limit, read from
        Win32_PerfRawData_PerfOS_Memory. That class uses language-neutral property names,
        unlike the localised performance counter paths.

        Available memory being low is not by itself a problem: Windows uses free memory
        for caching on purpose, and the standby cache is reclaimable on demand. Commit
        pressure is the number that indicates real memory scarcity.
    #>
    [CmdletBinding()]
    param()

    $os = @(Get-WaCimData -ClassName 'Win32_OperatingSystem' -Property @(
        'TotalVisibleMemorySize', 'FreePhysicalMemory', 'TotalVirtualMemorySize', 'FreeVirtualMemory'
    )) | Select-Object -First 1

    $modules = @(Get-WaCimData -ClassName 'Win32_PhysicalMemory' -Property @(
        'DeviceLocator', 'BankLabel', 'Capacity', 'Speed', 'ConfiguredClockSpeed',
        'Manufacturer', 'PartNumber', 'SMBIOSMemoryType', 'FormFactor'
    ) | ForEach-Object {
        $memoryType = switch ([int](Get-WaProperty -Object $_ -Name 'SMBIOSMemoryType' -Default 0)) {
            20 { 'DDR' } 21 { 'DDR2' } 24 { 'DDR3' } 26 { 'DDR4' } 34 { 'DDR5' } 35 { 'LPDDR5' }
            default { 'Unknown' }
        }
        [pscustomobject][ordered]@{
            Slot            = Get-WaProperty -Object $_ -Name 'DeviceLocator'
            Bank            = Get-WaProperty -Object $_ -Name 'BankLabel'
            CapacityBytes   = Get-WaProperty -Object $_ -Name 'Capacity'
            RatedSpeedMhz   = Get-WaProperty -Object $_ -Name 'Speed'
            ConfiguredMhz   = Get-WaProperty -Object $_ -Name 'ConfiguredClockSpeed'
            Manufacturer    = (Get-WaProperty -Object $_ -Name 'Manufacturer' -Default '').ToString().Trim()
            PartNumber      = (Get-WaProperty -Object $_ -Name 'PartNumber' -Default '').ToString().Trim()
            MemoryType      = $memoryType
        }
    })

    $perf = $null
    try {
        $perf = @(Get-WaCimData -ClassName 'Win32_PerfRawData_PerfOS_Memory' -Property @(
            'CommittedBytes', 'CommitLimit', 'AvailableBytes', 'CacheBytes',
            'PoolPagedBytes', 'PoolNonpagedBytes', 'StandbyCacheNormalPriorityBytes'
        )) | Select-Object -First 1
    } catch { $perf = $null }

    $totalBytes     = $(if ($null -ne $os) { [long](Get-WaProperty -Object $os -Name 'TotalVisibleMemorySize' -Default 0) * 1KB } else { $null })
    $freeBytes      = $(if ($null -ne $os) { [long](Get-WaProperty -Object $os -Name 'FreePhysicalMemory' -Default 0) * 1KB } else { $null })
    $committedBytes = Get-WaProperty -Object $perf -Name 'CommittedBytes'
    $commitLimit    = Get-WaProperty -Object $perf -Name 'CommitLimit'

    [pscustomobject][ordered]@{
        TotalBytes         = $totalBytes
        FreeBytes          = $freeBytes
        UsedBytes          = $(if ($null -ne $totalBytes -and $null -ne $freeBytes) { $totalBytes - $freeBytes } else { $null })
        UsedPercent        = (Get-WaPercentage -Part $(if ($null -ne $totalBytes -and $null -ne $freeBytes) { $totalBytes - $freeBytes } else { $null }) -Whole $totalBytes)
        AvailableBytes     = Get-WaProperty -Object $perf -Name 'AvailableBytes'
        CacheBytes         = Get-WaProperty -Object $perf -Name 'CacheBytes'
        StandbyCacheBytes  = Get-WaProperty -Object $perf -Name 'StandbyCacheNormalPriorityBytes'
        CommittedBytes     = $committedBytes
        CommitLimitBytes   = $commitLimit
        CommitPercent      = (Get-WaPercentage -Part $committedBytes -Whole $commitLimit)
        ModuleCount        = $modules.Count
        Modules            = $modules
        PressureNote       = 'Commit charge against the commit limit indicates memory scarcity. Low "free" memory does not: Windows uses unused memory as cache on purpose, and that cache is released on demand.'
    }
}

function Get-WaGraphicsInfo {
    <#
    .SYNOPSIS
        Display adapters, driver versions and VRAM.

    .DESCRIPTION
        Win32_VideoController.AdapterRAM is a signed 32-bit value and silently wraps above
        4 GB, so it reports nonsense on modern cards. The driver key's
        HardwareInformation.qwMemorySize is a 64-bit value and is preferred when present;
        AdapterRAM is kept alongside it and labelled as unreliable.
    #>
    [CmdletBinding()]
    param()

    $qwMemoryByDescription = @{}
    # SilentlyContinue, not Stop: some subkeys under the display class deny access to a
    # standard user, and Stop would throw away the adapters that are readable along with
    # the ones that are not.
    $classRoot = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
    foreach ($key in @(Get-ChildItem -LiteralPath $classRoot -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match '^\d{4}$' })) {
        $properties = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction SilentlyContinue
        if ($null -eq $properties) { continue }
        $description = Get-WaProperty -Object $properties -Name 'DriverDesc'
        $memory = Get-WaProperty -Object $properties -Name 'HardwareInformation.qwMemorySize'
        if ($description -and $null -ne $memory) { $qwMemoryByDescription[[string]$description] = [long]$memory }
    }

    @(Get-WaCimData -ClassName 'Win32_VideoController' -Property @(
        'Name', 'AdapterCompatibility', 'DriverVersion', 'DriverDate', 'AdapterRAM',
        'VideoProcessor', 'CurrentHorizontalResolution', 'CurrentVerticalResolution',
        'CurrentRefreshRate', 'Status'
    ) | ForEach-Object {
        $name = [string](Get-WaProperty -Object $_ -Name 'Name')
        $vram = $null
        if ($qwMemoryByDescription.ContainsKey($name)) { $vram = $qwMemoryByDescription[$name] }

        [pscustomobject][ordered]@{
            Name              = $name
            Vendor            = Get-WaProperty -Object $_ -Name 'AdapterCompatibility'
            VideoProcessor    = Get-WaProperty -Object $_ -Name 'VideoProcessor'
            DriverVersion     = Get-WaProperty -Object $_ -Name 'DriverVersion'
            DriverDate        = Get-WaProperty -Object $_ -Name 'DriverDate'
            VramBytes         = $vram
            VramSource        = $(if ($null -ne $vram) { 'Driver key HardwareInformation.qwMemorySize (64-bit)' } else { 'Not available' })
            AdapterRamRaw     = Get-WaProperty -Object $_ -Name 'AdapterRAM'
            AdapterRamNote    = 'Win32_VideoController.AdapterRAM is 32-bit and wraps above 4 GB; it is not authoritative VRAM capacity.'
            Resolution        = ('{0}x{1}' -f (Get-WaProperty -Object $_ -Name 'CurrentHorizontalResolution' -Default 0), (Get-WaProperty -Object $_ -Name 'CurrentVerticalResolution' -Default 0))
            RefreshRateHz     = Get-WaProperty -Object $_ -Name 'CurrentRefreshRate'
            Status            = Get-WaProperty -Object $_ -Name 'Status'
            Active            = ((Get-WaProperty -Object $_ -Name 'CurrentHorizontalResolution' -Default 0) -gt 0)
        }
    })
}

function Get-WaStorageInfo {
    <#
    .SYNOPSIS
        Physical disks, partitions, volumes, filesystem usage and BitLocker state.
    #>
    [CmdletBinding()]
    param()

    $physical = @()
    try {
        $physical = @(Get-PhysicalDisk -ErrorAction Stop | ForEach-Object {
            [pscustomobject][ordered]@{
                Number       = $_.DeviceId
                FriendlyName = $_.FriendlyName
                MediaType    = [string]$_.MediaType
                BusType      = [string]$_.BusType
                SizeBytes    = $_.Size
                HealthStatus = [string]$_.HealthStatus
                OperationalStatus = [string]$_.OperationalStatus
                SpindleSpeed = $(try { $_.SpindleSpeed } catch { $null })
                # MediaType often reports Unspecified for NVMe; BusType then carries the answer.
                DriveKind    = $(
                    if ([string]$_.BusType -eq 'NVMe') { 'NVMe SSD' }
                    elseif ([string]$_.MediaType -eq 'SSD') { 'SSD' }
                    elseif ([string]$_.MediaType -eq 'HDD') { 'HDD' }
                    else { 'Unspecified' }
                )
            }
        })
    } catch { $physical = @() }

    $partitions = @()
    try {
        $partitions = @(Get-Partition -ErrorAction Stop | ForEach-Object {
            [pscustomobject][ordered]@{
                DiskNumber      = $_.DiskNumber
                PartitionNumber = $_.PartitionNumber
                DriveLetter     = $(if ($_.DriveLetter) { [string]$_.DriveLetter } else { '' })
                Type            = [string]$_.Type
                SizeBytes       = $_.Size
                IsBoot          = $_.IsBoot
                IsSystem        = $_.IsSystem
            }
        })
    } catch { $partitions = @() }

    $volumes = @(Get-WaVolumeFreeSpace)

    $bitlocker = @()
    try {
        $bitlocker = @(Get-BitLockerVolume -ErrorAction Stop | ForEach-Object {
            [pscustomobject][ordered]@{
                MountPoint           = [string]$_.MountPoint
                VolumeStatus         = [string]$_.VolumeStatus
                ProtectionStatus     = [string]$_.ProtectionStatus
                EncryptionPercentage = $_.EncryptionPercentage
            }
        })
    } catch {
        $bitlocker = @()
    }

    [pscustomobject][ordered]@{
        PhysicalDisks = $physical
        Partitions    = $partitions
        Volumes       = $volumes
        BitLocker     = $bitlocker
        BitLockerNote = $(if ($bitlocker.Count -eq 0) { 'BitLocker state was not readable. The cmdlet needs an elevated session on most editions, and is absent on editions without BitLocker.' } else { '' })
    }
}

function Get-WaPagefileInfo {
    <#
    .SYNOPSIS
        Pagefile configuration, current usage and crash-dump requirements.

    .DESCRIPTION
        Reported, never "optimised". A system-managed pagefile is correct for almost every
        machine; disabling it breaks kernel crash dumps and causes commit exhaustion under
        exactly the workloads that make people want to disable it.
    #>
    [CmdletBinding()]
    param()

    $computer = @(Get-WaCimData -ClassName 'Win32_ComputerSystem' -Property @('AutomaticManagedPagefile')) | Select-Object -First 1
    $usage    = @(Get-WaCimData -ClassName 'Win32_PageFileUsage' -Property @('Name', 'AllocatedBaseSize', 'CurrentUsage', 'PeakUsage', 'TempPageFile'))
    $settings = @(Get-WaCimData -ClassName 'Win32_PageFileSetting' -Property @('Name', 'InitialSize', 'MaximumSize'))

    $crashControl = $null
    try {
        $crashControl = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl' -ErrorAction Stop
    } catch { $crashControl = $null }

    $dumpType = switch ([int](Get-WaProperty -Object $crashControl -Name 'CrashDumpEnabled' -Default -1)) {
        0 { 'None' }
        1 { 'Complete memory dump' }
        2 { 'Kernel memory dump' }
        3 { 'Small memory dump (minidump)' }
        7 { 'Automatic memory dump' }
        default { 'Unknown' }
    }

    [pscustomobject][ordered]@{
        AutomaticManaged = Get-WaProperty -Object $computer -Name 'AutomaticManagedPagefile' -Default $false
        Files = @($usage | ForEach-Object {
            [pscustomobject][ordered]@{
                Name             = Get-WaProperty -Object $_ -Name 'Name'
                AllocatedBaseMb  = Get-WaProperty -Object $_ -Name 'AllocatedBaseSize'
                CurrentUsageMb   = Get-WaProperty -Object $_ -Name 'CurrentUsage'
                PeakUsageMb      = Get-WaProperty -Object $_ -Name 'PeakUsage'
                Temporary        = Get-WaProperty -Object $_ -Name 'TempPageFile'
            }
        })
        Settings = @($settings | ForEach-Object {
            [pscustomobject][ordered]@{
                Name       = Get-WaProperty -Object $_ -Name 'Name'
                InitialMb  = Get-WaProperty -Object $_ -Name 'InitialSize'
                MaximumMb  = Get-WaProperty -Object $_ -Name 'MaximumSize'
            }
        })
        CrashDumpType = $dumpType
        DumpFile      = Get-WaProperty -Object $crashControl -Name 'DumpFile'
        MinidumpDir   = Get-WaProperty -Object $crashControl -Name 'MinidumpDir'
        Note          = 'The pagefile is reported, not tuned. A system-managed pagefile satisfies crash-dump requirements and adapts to commit demand; disabling it is not a supported optimisation.'
    }
}

function Get-WaHibernationInfo {
    <#
    .SYNOPSIS
        Hibernation state, hiberfil.sys size and Fast Startup configuration.
    #>
    [CmdletBinding()]
    param()

    $power = $null
    $sessionPower = $null
    try { $power = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' -ErrorAction Stop } catch { }
    try { $sessionPower = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -ErrorAction Stop } catch { }

    $basePaths = Get-WaBasePaths
    $hiberfil = Join-Path $basePaths.SystemDrive 'hiberfil.sys'
    $size = $null
    try { $size = (Get-Item -LiteralPath $hiberfil -Force -ErrorAction Stop).Length } catch { $size = $null }

    $enabled = Get-WaProperty -Object $power -Name 'HibernateEnabled'
    $hiberbootRaw = Get-WaProperty -Object $sessionPower -Name 'HiberbootEnabled'

    # HiberFileType: 1 reduced (Fast Startup only), 2 full (Fast Startup and Hibernate).
    $fileTypeRaw = Get-WaProperty -Object $power -Name 'HiberFileType'
    $fileType = switch ([int]($fileTypeRaw | ForEach-Object { if ($null -eq $_) { -1 } else { $_ } })) {
        1 { 'Reduced (supports Fast Startup only)' }
        2 { 'Full (supports Fast Startup and Hibernate)' }
        default { 'Not reported' }
    }

    [pscustomobject][ordered]@{
        Enabled            = [bool]$enabled
        HiberfilPath       = $hiberfil
        HiberfilBytes      = $size
        HiberFileType      = $fileType
        HiberFileSizePercent = Get-WaProperty -Object $power -Name 'HiberFileSizePercent'
        # Fast Startup only actually applies when hibernation is enabled as well.
        FastStartupConfigured = $(if ($null -eq $hiberbootRaw) { $null } else { [bool]$hiberbootRaw })
        FastStartupEffective  = ([bool]$enabled -and ($null -eq $hiberbootRaw -or [bool]$hiberbootRaw))
        Note = 'Disabling hibernation removes hiberfil.sys and also disables Fast Startup, because Fast Startup writes the kernel session to that same file.'
    }
}

function Get-WaPowerInfo {
    [CmdletBinding()]
    param()

    $scheme = Invoke-WaCatalogProbe -CommandId 'powercfg.activescheme'
    $states = Invoke-WaCatalogProbe -CommandId 'powercfg.sleepstates'

    $activeName = 'Unknown'
    if ($scheme.Available -and $scheme.ExitCode -eq 0 -and $scheme.Output -match '\(([^)]+)\)') {
        $activeName = $Matches[1]
    }

    [pscustomobject][ordered]@{
        ActivePlan          = $activeName
        ActivePlanRaw       = $(if ($scheme.Available) { ([string]$scheme.Output).Trim() } else { '' })
        AvailableSleepStates = $(if ($states.Available) { ([string]$states.Output).Trim() } else { 'Not reported.' })
    }
}

function Get-WaSystemProtectionInfo {
    <#
    .SYNOPSIS
        System Protection state, restore points and shadow-copy storage allocation.

    .DESCRIPTION
        Restore points are reported and never removed. The count and the storage allocation
        come from different sources and can disagree: shadow storage is shared with other
        VSS consumers, so its size is not a restore-point total.
    #>
    [CmdletBinding()]
    param()

    $restorePoints = @()
    $restoreError = ''
    try {
        $restorePoints = @(Get-WaCimData -ClassName 'SystemRestore' -Namespace 'root/default' `
            -Property @('SequenceNumber', 'Description', 'CreationTime', 'RestorePointType') |
            ForEach-Object {
                [pscustomobject][ordered]@{
                    Sequence     = Get-WaProperty -Object $_ -Name 'SequenceNumber'
                    Description  = Get-WaProperty -Object $_ -Name 'Description'
                    CreationTime = Get-WaProperty -Object $_ -Name 'CreationTime'
                    Type         = Get-WaProperty -Object $_ -Name 'RestorePointType'
                }
            })
    } catch {
        $restoreError = 'Restore points could not be enumerated. This query needs an elevated session.'
    }

    $shadowStorage = @()
    try {
        $shadowStorage = @(Get-WaCimData -ClassName 'Win32_ShadowStorage' -Property @('Volume', 'UsedSpace', 'AllocatedSpace', 'MaxSpace') |
            ForEach-Object {
                [pscustomobject][ordered]@{
                    UsedBytes      = Get-WaProperty -Object $_ -Name 'UsedSpace'
                    AllocatedBytes = Get-WaProperty -Object $_ -Name 'AllocatedSpace'
                    MaxBytes       = Get-WaProperty -Object $_ -Name 'MaxSpace'
                }
            })
    } catch { $shadowStorage = @() }

    $disabled = $null
    try {
        $systemRestore = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore' -ErrorAction Stop
        $disabled = Get-WaProperty -Object $systemRestore -Name 'DisableSR'
    } catch { $disabled = $null }

    [pscustomobject][ordered]@{
        RestorePointCount = $restorePoints.Count
        RestorePoints     = $restorePoints
        RestorePointError = $restoreError
        DisableSrValue    = $disabled
        ShadowStorage     = $shadowStorage
        Note              = 'System Restore is not a general undo. It does not restore personal files, protection can be off per volume, and Windows discards old restore points when the shadow-storage allocation fills.'
    }
}

function Get-WaUpdateInfo {
    <#
    .SYNOPSIS
        Local servicing indicators. Windows Update is never contacted.
    #>
    [CmdletBinding()]
    param()

    $pendingReasons = New-Object 'System.Collections.Generic.List[string]'
    foreach ($key in @(
        @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'; Reason = 'Component servicing has a reboot pending.' }
        @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'; Reason = 'Windows Update has a reboot pending.' }
    )) {
        try { if (Test-Path -LiteralPath $key.Path -ErrorAction Stop) { $pendingReasons.Add($key.Reason) } } catch { }
    }
    try {
        $sessionManager = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -ErrorAction Stop
        if (Get-WaProperty -Object $sessionManager -Name 'PendingFileRenameOperations') {
            $pendingReasons.Add('File rename operations are queued for the next restart.')
        }
    } catch { }

    $servicingProcesses = @(Get-Process -Name 'TiWorker', 'TrustedInstaller', 'MoUsoCoreWorker', 'Dism' -ErrorAction SilentlyContinue)

    $hotfixes = @()
    try {
        $hotfixes = @(Get-HotFix -ErrorAction Stop | Sort-Object InstalledOn -Descending | Select-Object -First 15 |
            ForEach-Object {
                [pscustomobject][ordered]@{
                    Id          = $_.HotFixID
                    Description = $_.Description
                    InstalledOn = $_.InstalledOn
                }
            })
    } catch { $hotfixes = @() }

    [pscustomobject][ordered]@{
        PendingReboot    = ($pendingReasons.Count -gt 0)
        PendingReasons   = $pendingReasons.ToArray()
        ServicingActive  = ($servicingProcesses.Count -gt 0)
        ServicingProcesses = @($servicingProcesses | ForEach-Object { $_.Name } | Select-Object -Unique)
        RecentHotfixes   = $hotfixes
        Note             = 'Local indicators only. Windows Update is not contacted, so the absence of a pending reboot is not evidence that the machine is fully patched.'
    }
}

function Get-WaComponentStoreInfo {
    <#
    .SYNOPSIS
        Component store analysis via DISM, when permitted and elevated.

    .DESCRIPTION
        WinSxS cannot be measured by adding up directory sizes: most of its content is
        hard links to files that also live in System32, so a naive sum counts the same
        bytes many times over. DISM /AnalyzeComponentStore is the supported measurement
        and is the only one used here.

        The command is read-only. It does write to the DISM log, which is why it is behind
        a configuration flag and is never run from View Specs.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config, [switch]$Allow)

    if (-not $Allow -or -not $Config.AllowDismAnalyze) {
        return [pscustomobject][ordered]@{
            Analyzed = $false
            Reason   = 'Component-store analysis was not requested in this mode.'
            Note     = 'WinSxS size cannot be derived from directory sizes: hard links make any such sum meaningless. Run System Analysis elevated to measure it with DISM.'
        }
    }
    if (-not (Test-WaAdministrator)) {
        return [pscustomobject][ordered]@{
            Analyzed = $false
            Reason   = 'DISM component-store analysis requires an elevated session.'
            Note     = 'Restart WinAdvisor as administrator to measure the component store.'
        }
    }

    $probe = Invoke-WaCatalogProbe -CommandId 'dism.analyzecomponentstore'
    if (-not $probe.Available -or $probe.ExitCode -ne 0) {
        return [pscustomobject][ordered]@{
            Analyzed = $false
            Reason   = ("DISM analysis did not complete. {0}" -f (Get-WaRedactedText -Text ([string]$probe.Error)))
            Note     = 'The component store was not measured.'
        }
    }

    # DISM output is localised, so values are matched by position on the line rather than
    # by an English label.
    $parse = {
        param([string]$Text, [string]$Pattern)
        $line = @($Text -split "`r?`n" | Where-Object { $_ -match $Pattern }) | Select-Object -First 1
        if (-not $line) { return $null }
        if ($line -match '(?<value>[\d.,]+)\s*(?<unit>KB|MB|GB|TB)') {
            $number = [double]($Matches['value'] -replace ',', '')
            switch ($Matches['unit']) {
                'KB' { return [long]($number * 1KB) }
                'MB' { return [long]($number * 1MB) }
                'GB' { return [long]($number * 1GB) }
                'TB' { return [long]($number * 1TB) }
            }
        }
        return $null
    }

    $output = [string]$probe.Output
    $recommendedLine = @($output -split "`r?`n" | Where-Object { $_ -match '(?i)cleanup|recommend' }) | Select-Object -First 1
    $recommended = $false
    # ASCII-only pattern: a non-ASCII literal here would be misread on Windows PowerShell
    # 5.1, which reads a BOM-less UTF-8 script as ANSI. Non-Latin locales fall back to the
    # reclaimable-bytes threshold below rather than to a corrupted string match.
    if ($recommendedLine -match '(?i)\b(yes|ja|oui|si|sim|tak|da)\b') { $recommended = $true }

    [pscustomobject][ordered]@{
        Analyzed             = $true
        ActualSizeBytes      = (& $parse $output '(?i)actual size')
        SharedWithWindows    = (& $parse $output '(?i)shared with windows')
        BackupsAndDisabled   = (& $parse $output '(?i)backups and disabled')
        CacheAndTemporary    = (& $parse $output '(?i)cache and temporary')
        ReclaimableBytes     = (& $parse $output '(?i)reclaimable')
        CleanupRecommended   = $recommended
        RawOutput            = (Get-WaRedactedText -Text $output.Trim())
        Note                 = 'Measured with DISM /Online /Cleanup-Image /AnalyzeComponentStore, the supported mechanism. Shared-with-Windows bytes are hard links also counted in System32 and are not recoverable.'
    }
}

function Get-WaOptionalFeatureInfo {
    [CmdletBinding()]
    param()

    @(Get-WaCimData -ClassName 'Win32_OptionalFeature' -Property @('Name', 'Caption', 'InstallState') |
        Where-Object { [int](Get-WaProperty -Object $_ -Name 'InstallState' -Default 0) -eq 1 } |
        ForEach-Object {
            [pscustomobject][ordered]@{
                Name    = Get-WaProperty -Object $_ -Name 'Name'
                Caption = Get-WaProperty -Object $_ -Name 'Caption'
                State   = 'Enabled'
            }
        } | Sort-Object Name)
}

function Get-WaDeliveryOptimizationInfo {
    [CmdletBinding()]
    param()

    $status = @()
    try {
        # WarningAction: the cmdlet emits a warning when there are no jobs, which is the
        # normal state and not something to put in front of the user.
        $status = @(Get-DeliveryOptimizationStatus -ErrorAction Stop -WarningAction SilentlyContinue | ForEach-Object {
            [pscustomobject][ordered]@{
                FileId              = ([string](Get-WaProperty -Object $_ -Name 'FileId' -Default '')).Substring(0, [Math]::Min(12, ([string](Get-WaProperty -Object $_ -Name 'FileId' -Default '')).Length))
                FileSize            = Get-WaProperty -Object $_ -Name 'FileSize'
                TotalBytesDownloaded = Get-WaProperty -Object $_ -Name 'TotalBytesDownloaded'
                Status              = Get-WaProperty -Object $_ -Name 'Status'
            }
        })
    } catch { $status = @() }

    $cachePath = Join-Path (Get-WaBasePaths).Windows 'SoftwareDistribution\DeliveryOptimization'

    [pscustomobject][ordered]@{
        ActiveDownloads = $status.Count
        Downloads       = @($status | Select-Object -First 10)
        CachePath       = $cachePath
        Note            = 'Delivery Optimization manages its own cache and trims it automatically. Windows exposes Delete-DeliveryOptimizationCache for manual clearing; deleting the directory by hand is not supported.'
    }
}

function Get-WaMachineProfile {
    <#
    .SYNOPSIS
        Builds the complete read-only machine profile.

    .DESCRIPTION
        This is the foundation for everything else, and it never changes the machine.
        Running it is the whole of View Specs.

    .PARAMETER IncludeComponentStore
        Permit DISM component-store analysis. Off for View Specs, on for System Analysis.

    .EXAMPLE
        $profile = Get-WaMachineProfile -Session $session
        $profile.OperatingSystem.FullBuild
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Session,
        [switch]$IncludeComponentStore
    )

    if (-not (Test-WaWindowsPlatform)) {
        throw 'WinAdvisor inspects Windows. This host is not Windows, so discovery cannot produce a meaningful profile.'
    }

    $config = $Session.Config
    Write-WaLog -Session $Session -Level 'Info' -Category 'Discovery' -Message 'Starting read-only machine discovery.'

    $probes = [ordered]@{}
    $step = 0
    $totalSteps = 14
    $progress = {
        param([string]$Status)
        $script:WaDiscoveryStep = $script:WaDiscoveryStep + 1
        Write-Progress -Activity 'WinAdvisor discovery' -Status $Status -PercentComplete ([Math]::Min(99, ($script:WaDiscoveryStep / $totalSteps) * 100))
    }
    $script:WaDiscoveryStep = $step

    & $progress 'Operating system'
    $probes['OperatingSystem'] = Invoke-WaProbe -Name 'OperatingSystem' -Category 'System' -Script { Get-WaOperatingSystemInfo }

    & $progress 'Hardware and firmware'
    $probes['Hardware'] = Invoke-WaProbe -Name 'Hardware' -Category 'System' -Script { Get-WaHardwareInfo }

    & $progress 'Processor'
    $probes['Processor'] = Invoke-WaProbe -Name 'Processor' -Category 'Hardware' -Script { Get-WaProcessorInfo }

    & $progress 'Memory'
    $probes['Memory'] = Invoke-WaProbe -Name 'Memory' -Category 'Hardware' -Script { Get-WaMemoryInfo }

    & $progress 'Graphics'
    $probes['Graphics'] = Invoke-WaProbe -Name 'Graphics' -Category 'Hardware' -Script { Get-WaGraphicsInfo }

    & $progress 'Storage devices and volumes'
    $probes['Storage'] = Invoke-WaProbe -Name 'Storage' -Category 'Hardware' -Script { Get-WaStorageInfo }

    & $progress 'Pagefile'
    $probes['Pagefile'] = Invoke-WaProbe -Name 'Pagefile' -Category 'Windows' -Script { Get-WaPagefileInfo }

    & $progress 'Hibernation and Fast Startup'
    $probes['Hibernation'] = Invoke-WaProbe -Name 'Hibernation' -Category 'Windows' -Script { Get-WaHibernationInfo }

    & $progress 'Power configuration'
    $probes['Power'] = Invoke-WaProbe -Name 'Power' -Category 'Windows' -Script { Get-WaPowerInfo }

    & $progress 'System Protection'
    $probes['SystemProtection'] = Invoke-WaProbe -Name 'SystemProtection' -Category 'Windows' -Script { Get-WaSystemProtectionInfo }

    & $progress 'Servicing state'
    $probes['Update'] = Invoke-WaProbe -Name 'Update' -Category 'Windows' -Script { Get-WaUpdateInfo }

    & $progress 'Optional features and Delivery Optimization'
    $probes['OptionalFeatures'] = Invoke-WaProbe -Name 'OptionalFeatures' -Category 'Windows' -Script { Get-WaOptionalFeatureInfo }
    $probes['DeliveryOptimization'] = Invoke-WaProbe -Name 'DeliveryOptimization' -Category 'Windows' -Script { Get-WaDeliveryOptimizationInfo }

    & $progress 'Installed software and workloads'
    $probes['Applications'] = Invoke-WaProbe -Name 'Applications' -Category 'Software' -Script { Get-WaInstalledApplication }
    $probes['StoreApplications'] = Invoke-WaProbe -Name 'StoreApplications' -Category 'Software' -Script { Get-WaStoreApplication }
    $probes['Workloads'] = Invoke-WaProbe -Name 'Workloads' -Category 'Software' -Script { Get-WaDetectedWorkload }

    & $progress 'Startup items and processes'
    $probes['Startup'] = Invoke-WaProbe -Name 'Startup' -Category 'Startup' -Script { Get-WaStartupInventory -Config $config }
    $probes['Processes'] = Invoke-WaProbe -Name 'Processes' -Category 'Runtime' -Script {
        Get-WaProcessInventory -Config $config -StartupItems @($probes['Startup'].Data)
    }

    if ($IncludeComponentStore) {
        & $progress 'Component store (DISM)'
        $probes['ComponentStore'] = Invoke-WaProbe -Name 'ComponentStore' -Category 'Windows' -Script {
            Get-WaComponentStoreInfo -Config $config -Allow
        }
    } else {
        $probes['ComponentStore'] = Invoke-WaProbe -Name 'ComponentStore' -Category 'Windows' -Script {
            Get-WaComponentStoreInfo -Config $config
        }
    }

    Write-Progress -Activity 'WinAdvisor discovery' -Completed

    $operatingSystem = @($probes['OperatingSystem'].Data) | Select-Object -First 1
    $hardware        = @($probes['Hardware'].Data) | Select-Object -First 1

    $build    = [int](Get-WaProperty -Object $operatingSystem -Name 'Build' -Default 0)
    $isClient = [bool](Get-WaProperty -Object $operatingSystem -Name 'IsClient' -Default $false)
    $is64Bit  = [Environment]::Is64BitOperatingSystem

    $supportReasons = New-Object 'System.Collections.Generic.List[string]'
    if ($build -lt 22000) { $supportReasons.Add("Build $build is not Windows 11 (build 22000 or later).") }
    if (-not $isClient)   { $supportReasons.Add('This is not a Windows client edition.') }
    if (-not $is64Bit)    { $supportReasons.Add('This is not a 64-bit installation.') }

    $machineProfile = [pscustomobject][ordered]@{
        PSTypeName      = 'WinAdvisor.MachineProfile'
        SchemaVersion   = 2
        CapturedUtc     = (Get-WaUtcTimestamp)
        SessionId       = $Session.Id
        Identity        = (Get-WaIdentity)
        IsAdministrator = $Session.IsAdministrator

        OperatingSystem = $operatingSystem
        Hardware        = $hardware
        Processor       = @($probes['Processor'].Data)
        Memory          = (@($probes['Memory'].Data) | Select-Object -First 1)
        Graphics        = @($probes['Graphics'].Data)
        Storage         = (@($probes['Storage'].Data) | Select-Object -First 1)

        Pagefile             = (@($probes['Pagefile'].Data) | Select-Object -First 1)
        Hibernation          = (@($probes['Hibernation'].Data) | Select-Object -First 1)
        Power                = (@($probes['Power'].Data) | Select-Object -First 1)
        SystemProtection     = (@($probes['SystemProtection'].Data) | Select-Object -First 1)
        Update               = (@($probes['Update'].Data) | Select-Object -First 1)
        ComponentStore       = (@($probes['ComponentStore'].Data) | Select-Object -First 1)
        OptionalFeatures     = @($probes['OptionalFeatures'].Data)
        DeliveryOptimization = (@($probes['DeliveryOptimization'].Data) | Select-Object -First 1)

        Applications      = @($probes['Applications'].Data)
        StoreApplications = @($probes['StoreApplications'].Data)
        Workloads         = @($probes['Workloads'].Data)
        Startup           = @($probes['Startup'].Data)
        Processes         = (@($probes['Processes'].Data) | Select-Object -First 1)

        Support = [pscustomobject][ordered]@{
            SupportedForExecution = ($supportReasons.Count -eq 0)
            Reasons               = $supportReasons.ToArray()
            Note                  = 'Analysis runs on any Windows installation. Changes are limited to 64-bit Windows 11 client builds, which is what the providers were written and verified against.'
        }

        Probes = $probes
        Notes  = @(
            'Sizes are logical file sizes. They are not identical to the physical allocation recovered on a compressed, deduplicated or sparse volume.'
            'A location that could not be read is reported as unknown, never as zero.'
            'Installed software is enumerated from the uninstall registry and the current user Store packages; portable applications extracted to a folder will not appear.'
        )
    }

    Write-WaLog -Session $Session -Level 'Info' -Category 'Discovery' -Message (
        'Discovery complete: {0} build {1}, {2} application(s), {3} workload(s), {4} startup item(s).' -f
            (Get-WaProperty -Object $operatingSystem -Name 'Caption' -Default 'Windows'),
            (Get-WaProperty -Object $operatingSystem -Name 'FullBuild' -Default '?'),
            @($machineProfile.Applications).Count,
            @($machineProfile.Workloads | Where-Object { $_.Detected }).Count,
            @($machineProfile.Startup).Count
    )

    $Session.MachineProfile = $machineProfile
    return $machineProfile
}
