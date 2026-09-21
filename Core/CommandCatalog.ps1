<#
    Core/CommandCatalog.ps1 - the complete allow-list of external commands.

    Providers never supply a command line. They reference a catalog entry by Id, and the
    catalog owns the executable and the argument vector. A provider can therefore choose
    *which* documented operation runs, but not *what* it runs.

    Parameterised entries declare placeholders with a validation pattern. A value that
    does not match its pattern is refused; there is no escaping or quoting path by which
    a distribution name could become another argument.

    ReadOnly entries are inspection commands and are the only ones permitted to run in a
    read-only session. Each entry cites the documentation it was written from; the
    consolidated list lives in docs/SOURCES.md.

    Two optional fields describe how a tool behaves when its data is in use:
      * Environment - variables set for the process, for documented settings that have no
        argument form. Names and values are validated by Invoke-WaNativeProcess.
      * BusyPattern / BusyAdvice - a regular expression that, matched against a failing
        command's output, identifies "another process holds this resource; nothing was
        changed". That outcome is reported as skipped rather than failed, with BusyAdvice
        explaining what usually holds the resource. WinAdvisor never forces such a lock.
#>

function Initialize-WaCommandCatalog {
    <#
    .SYNOPSIS
        Builds the command catalog. Called once per module load.
    #>
    [CmdletBinding()]
    param()

    $catalog = New-Object 'System.Collections.Specialized.OrderedDictionary' ([StringComparer]::OrdinalIgnoreCase)

    $add = {
        param(
            [string]$Id,
            [string]$Tool,
            [string]$Executable,
            [ValidateSet('System', 'Path')][string]$Resolution,
            [string[]]$Arguments,
            [string]$Purpose,
            [bool]$ReadOnly,
            [string]$MinimumRisk,
            [bool]$RequiresAdmin,
            [int]$TimeoutSeconds,
            [string]$Reference,
            [hashtable]$Placeholders = @{},
            [bool]$NeverKill = $false,
            [string]$Consequence = '',
            [string]$Reverses = '',
            [hashtable]$Environment = @{},
            [string]$BusyPattern = '',
            [string]$BusyAdvice = ''
        )
        [void](Get-WaRiskRank -Risk $MinimumRisk)
        if ($BusyPattern) { [void][regex]::new($BusyPattern) }
        $catalog[$Id] = [pscustomobject][ordered]@{
            Id             = $Id
            Tool           = $Tool
            Executable     = $Executable
            Resolution     = $Resolution
            Arguments      = @($Arguments)
            Placeholders   = $Placeholders
            Purpose        = $Purpose
            ReadOnly       = $ReadOnly
            MinimumRisk    = $MinimumRisk
            RequiresAdmin  = $RequiresAdmin
            TimeoutSeconds = $TimeoutSeconds
            NeverKill      = $NeverKill
            Consequence    = $Consequence
            Reverses       = $Reverses
            Environment    = $Environment
            BusyPattern    = $BusyPattern
            BusyAdvice     = $BusyAdvice
            Reference      = $Reference
        }
    }

    # ---------------------------------------------------------------- Windows: powercfg
    & $add -Id 'powercfg.sleepstates' -Tool 'powercfg' -Executable 'powercfg.exe' -Resolution 'System' `
        -Arguments @('/a') -Purpose 'Report which sleep states this machine supports.' `
        -ReadOnly $true -MinimumRisk 'SAFE' -RequiresAdmin $false -TimeoutSeconds 30 `
        -Reference 'https://learn.microsoft.com/en-us/windows-hardware/design/device-experiences/powercfg-command-line-options'

    & $add -Id 'powercfg.activescheme' -Tool 'powercfg' -Executable 'powercfg.exe' -Resolution 'System' `
        -Arguments @('/getactivescheme') -Purpose 'Report the active power plan.' `
        -ReadOnly $true -MinimumRisk 'SAFE' -RequiresAdmin $false -TimeoutSeconds 30 `
        -Reference 'https://learn.microsoft.com/en-us/windows-hardware/design/device-experiences/powercfg-command-line-options'

    & $add -Id 'powercfg.hibernate.off' -Tool 'powercfg' -Executable 'powercfg.exe' -Resolution 'System' `
        -Arguments @('/hibernate', 'off') -Purpose 'Disable hibernation and remove hiberfil.sys.' `
        -ReadOnly $false -MinimumRisk 'HIGH' -RequiresAdmin $true -TimeoutSeconds 120 `
        -Consequence 'Hibernate and Fast Startup both stop working. Laptops lose the ability to preserve state on critical battery.' `
        -Reverses 'powercfg.hibernate.on' `
        -Reference 'https://learn.microsoft.com/en-us/windows-hardware/design/device-experiences/powercfg-command-line-options'

    & $add -Id 'powercfg.hibernate.on' -Tool 'powercfg' -Executable 'powercfg.exe' -Resolution 'System' `
        -Arguments @('/hibernate', 'on') -Purpose 'Re-enable hibernation.' `
        -ReadOnly $false -MinimumRisk 'MODERATE' -RequiresAdmin $true -TimeoutSeconds 120 `
        -Consequence 'Recreates hiberfil.sys, consuming disk space again.' `
        -Reference 'https://learn.microsoft.com/en-us/windows-hardware/design/device-experiences/powercfg-command-line-options'

    # ------------------------------------------------------------------- Windows: DISM
    # Component-store servicing must go through DISM. Manually touching WinSxS is
    # documented by Microsoft as capable of leaving a machine unbootable.
    & $add -Id 'dism.analyzecomponentstore' -Tool 'DISM' -Executable 'Dism.exe' -Resolution 'System' `
        -Arguments @('/Online', '/Cleanup-Image', '/AnalyzeComponentStore') `
        -Purpose 'Measure the component store and report whether Windows recommends a cleanup.' `
        -ReadOnly $true -MinimumRisk 'SAFE' -RequiresAdmin $true -TimeoutSeconds 3600 -NeverKill $true `
        -Consequence 'Analysis only. Writes to the DISM log; changes no component.' `
        -Reference 'https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/clean-up-the-winsxs-folder'

    & $add -Id 'dism.startcomponentcleanup' -Tool 'DISM' -Executable 'Dism.exe' -Resolution 'System' `
        -Arguments @('/Online', '/Cleanup-Image', '/StartComponentCleanup') `
        -Purpose 'Remove superseded component versions through the supported servicing path.' `
        -ReadOnly $false -MinimumRisk 'MODERATE' -RequiresAdmin $true -TimeoutSeconds 3600 -NeverKill $true `
        -Consequence 'Previous versions of updated components are deleted immediately rather than after the usual 30-day grace period. Updates installed so far remain uninstallable-from.' `
        -Reference 'https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/clean-up-the-winsxs-folder'

    & $add -Id 'dism.startcomponentcleanup.resetbase' -Tool 'DISM' -Executable 'Dism.exe' -Resolution 'System' `
        -Arguments @('/Online', '/Cleanup-Image', '/StartComponentCleanup', '/ResetBase') `
        -Purpose 'Remove every superseded component version in the store.' `
        -ReadOnly $false -MinimumRisk 'HIGH' -RequiresAdmin $true -TimeoutSeconds 3600 -NeverKill $true `
        -Consequence 'Microsoft documents that no currently installed update can be uninstalled afterwards. Future updates remain uninstallable normally. This cannot be undone.' `
        -Reference 'https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/clean-up-the-winsxs-folder'

    # -------------------------------------------------------------------- Windows: WSL
    & $add -Id 'wsl.list' -Tool 'WSL' -Executable 'wsl.exe' -Resolution 'System' `
        -Arguments @('--list', '--verbose') -Purpose 'List installed distributions with state and WSL version.' `
        -ReadOnly $true -MinimumRisk 'SAFE' -RequiresAdmin $false -TimeoutSeconds 60 `
        -Reference 'https://learn.microsoft.com/en-us/windows/wsl/basic-commands'

    & $add -Id 'wsl.status' -Tool 'WSL' -Executable 'wsl.exe' -Resolution 'System' `
        -Arguments @('--status') -Purpose 'Report WSL configuration.' `
        -ReadOnly $true -MinimumRisk 'SAFE' -RequiresAdmin $false -TimeoutSeconds 60 `
        -Reference 'https://learn.microsoft.com/en-us/windows/wsl/basic-commands'

    & $add -Id 'wsl.version' -Tool 'WSL' -Executable 'wsl.exe' -Resolution 'System' `
        -Arguments @('--version') -Purpose 'Report WSL component versions.' `
        -ReadOnly $true -MinimumRisk 'SAFE' -RequiresAdmin $false -TimeoutSeconds 60 `
        -Reference 'https://learn.microsoft.com/en-us/windows/wsl/basic-commands'

    # No WSL mutation entry exists. Microsoft documents how to expand a WSL virtual disk
    # but publishes no supported in-place shrink on the disk-space page, and unregistering
    # a distribution is permanent data loss. The WSL provider is advisory by construction.

    # ----------------------------------------------------------------------- Docker
    & $add -Id 'docker.version' -Tool 'Docker' -Executable 'docker' -Resolution 'Path' `
        -Arguments @('version', '--format', '{{json .}}') -Purpose 'Report Docker client and engine versions.' `
        -ReadOnly $true -MinimumRisk 'SAFE' -RequiresAdmin $false -TimeoutSeconds 60 `
        -Reference 'https://docs.docker.com/reference/cli/docker/version/'

    & $add -Id 'docker.systemdf' -Tool 'Docker' -Executable 'docker' -Resolution 'Path' `
        -Arguments @('system', 'df', '--format', '{{json .}}') `
        -Purpose 'Report Docker disk usage and reclaimable space by category.' `
        -ReadOnly $true -MinimumRisk 'SAFE' -RequiresAdmin $false -TimeoutSeconds 180 `
        -Reference 'https://docs.docker.com/reference/cli/docker/system/df/'

    & $add -Id 'docker.systemdf.verbose' -Tool 'Docker' -Executable 'docker' -Resolution 'Path' `
        -Arguments @('system', 'df', '--verbose', '--format', '{{json .}}') `
        -Purpose 'Report per-item Docker disk usage.' `
        -ReadOnly $true -MinimumRisk 'SAFE' -RequiresAdmin $false -TimeoutSeconds 300 `
        -Reference 'https://docs.docker.com/reference/cli/docker/system/df/'

    & $add -Id 'docker.volume.ls' -Tool 'Docker' -Executable 'docker' -Resolution 'Path' `
        -Arguments @('volume', 'ls', '--format', '{{json .}}') -Purpose 'List Docker volumes for manual review.' `
        -ReadOnly $true -MinimumRisk 'SAFE' -RequiresAdmin $false -TimeoutSeconds 120 `
        -Reference 'https://docs.docker.com/reference/cli/docker/volume/ls/'

    & $add -Id 'docker.container.ls' -Tool 'Docker' -Executable 'docker' -Resolution 'Path' `
        -Arguments @('ps', '--all', '--format', '{{json .}}') -Purpose 'List containers including stopped ones.' `
        -ReadOnly $true -MinimumRisk 'SAFE' -RequiresAdmin $false -TimeoutSeconds 120 `
        -Reference 'https://docs.docker.com/reference/cli/docker/container/ls/'

    & $add -Id 'docker.builder.prune' -Tool 'Docker' -Executable 'docker' -Resolution 'Path' `
        -Arguments @('builder', 'prune', '--force') -Purpose 'Remove the build cache.' `
        -ReadOnly $false -MinimumRisk 'MODERATE' -RequiresAdmin $false -TimeoutSeconds 900 `
        -Consequence 'Subsequent builds repeat cached layers and will be slower until the cache is rebuilt. No image, container or volume is removed.' `
        -Reference 'https://docs.docker.com/reference/cli/docker/builder/prune/'

    & $add -Id 'docker.image.prune' -Tool 'Docker' -Executable 'docker' -Resolution 'Path' `
        -Arguments @('image', 'prune', '--force') -Purpose 'Remove dangling images only.' `
        -ReadOnly $false -MinimumRisk 'LOW' -RequiresAdmin $false -TimeoutSeconds 900 `
        -Consequence 'Removes untagged images not referenced by any container. Tagged images are untouched.' `
        -Reference 'https://docs.docker.com/reference/cli/docker/image/prune/'

    & $add -Id 'docker.image.prune.all' -Tool 'Docker' -Executable 'docker' -Resolution 'Path' `
        -Arguments @('image', 'prune', '--all', '--force') -Purpose 'Remove every image not used by an existing container.' `
        -ReadOnly $false -MinimumRisk 'MODERATE' -RequiresAdmin $false -TimeoutSeconds 1800 `
        -Consequence 'Tagged images are removed too. Anything not pulled from a registry you still have access to must be rebuilt.' `
        -Reference 'https://docs.docker.com/reference/cli/docker/image/prune/'

    & $add -Id 'docker.container.prune' -Tool 'Docker' -Executable 'docker' -Resolution 'Path' `
        -Arguments @('container', 'prune', '--force') -Purpose 'Remove stopped containers.' `
        -ReadOnly $false -MinimumRisk 'MODERATE' -RequiresAdmin $false -TimeoutSeconds 900 `
        -Consequence 'Stopped containers and their writable layers are deleted. Named volumes they used are not touched, but data written outside a volume is lost.' `
        -Reference 'https://docs.docker.com/reference/cli/docker/container/prune/'

    # No docker volume prune entry exists. Volumes are where containers keep the data they
    # were created to keep; they are surfaced for manual review and never pruned here.

    # ------------------------------------------------------------------ .NET and NuGet
    & $add -Id 'dotnet.sdks' -Tool 'dotnet' -Executable 'dotnet' -Resolution 'Path' `
        -Arguments @('--list-sdks') -Purpose 'List installed .NET SDKs.' `
        -ReadOnly $true -MinimumRisk 'SAFE' -RequiresAdmin $false -TimeoutSeconds 60 `
        -Reference 'https://learn.microsoft.com/en-us/dotnet/core/tools/dotnet'

    & $add -Id 'dotnet.runtimes' -Tool 'dotnet' -Executable 'dotnet' -Resolution 'Path' `
        -Arguments @('--list-runtimes') -Purpose 'List installed .NET runtimes.' `
        -ReadOnly $true -MinimumRisk 'SAFE' -RequiresAdmin $false -TimeoutSeconds 60 `
        -Reference 'https://learn.microsoft.com/en-us/dotnet/core/tools/dotnet'

    & $add -Id 'dotnet.nuget.locals.list' -Tool 'NuGet' -Executable 'dotnet' -Resolution 'Path' `
        -Arguments @('nuget', 'locals', 'all', '--list') -Purpose 'Report the location of every NuGet local cache.' `
        -ReadOnly $true -MinimumRisk 'SAFE' -RequiresAdmin $false -TimeoutSeconds 120 `
        -Reference 'https://learn.microsoft.com/en-us/nuget/reference/cli-reference/cli-ref-locals'

    foreach ($cache in @(
        @{ Name = 'global-packages'; Risk = 'LOW'; Consequence = 'Packages needed by a future build are downloaded again. Offline builds will fail until they are restored.' }
        @{ Name = 'http-cache';      Risk = 'LOW'; Consequence = 'Cached registry responses are fetched again on the next restore.' }
        @{ Name = 'temp';            Risk = 'LOW'; Consequence = 'Transient NuGet working files are removed.' }
        @{ Name = 'plugins-cache';   Risk = 'LOW'; Consequence = 'Authentication plugin metadata is rebuilt on next use.' }
    )) {
        & $add -Id ('dotnet.nuget.locals.clear.' + $cache.Name) -Tool 'NuGet' -Executable 'dotnet' -Resolution 'Path' `
            -Arguments @('nuget', 'locals', $cache.Name, '--clear') `
            -Purpose ("Clear the NuGet {0} cache through the official mechanism." -f $cache.Name) `
            -ReadOnly $false -MinimumRisk $cache.Risk -RequiresAdmin $false -TimeoutSeconds 1800 `
            -Consequence $cache.Consequence `
            -Reference 'https://learn.microsoft.com/en-us/nuget/reference/cli-reference/cli-ref-locals'
    }

    # ------------------------------------------------------------------- Node ecosystem
    & $add -Id 'npm.cache.path' -Tool 'npm' -Executable 'npm' -Resolution 'Path' `
        -Arguments @('config', 'get', 'cache') -Purpose 'Report the npm cache directory.' `
        -ReadOnly $true -MinimumRisk 'SAFE' -RequiresAdmin $false -TimeoutSeconds 120 `
        -Reference 'https://docs.npmjs.com/cli/v10/commands/npm-cache'

    & $add -Id 'npm.cache.clean' -Tool 'npm' -Executable 'npm' -Resolution 'Path' `
        -Arguments @('cache', 'clean', '--force') -Purpose 'Empty the npm content-addressable cache.' `
        -ReadOnly $false -MinimumRisk 'LOW' -RequiresAdmin $false -TimeoutSeconds 900 `
        -Consequence 'Package tarballs are downloaded again on the next install. npm treats the cache as disposable and self-heals.' `
        -Reference 'https://docs.npmjs.com/cli/v10/commands/npm-cache'

    & $add -Id 'pnpm.store.path' -Tool 'pnpm' -Executable 'pnpm' -Resolution 'Path' `
        -Arguments @('store', 'path') -Purpose 'Report the pnpm content-addressable store location.' `
        -ReadOnly $true -MinimumRisk 'SAFE' -RequiresAdmin $false -TimeoutSeconds 120 `
        -Reference 'https://pnpm.io/cli/store'

    & $add -Id 'pnpm.store.prune' -Tool 'pnpm' -Executable 'pnpm' -Resolution 'Path' `
        -Arguments @('store', 'prune') -Purpose 'Remove unreferenced packages from the pnpm store.' `
        -ReadOnly $false -MinimumRisk 'LOW' -RequiresAdmin $false -TimeoutSeconds 900 `
        -Consequence 'Only packages no project references are removed. The store must never be deleted by hand: installed projects hard-link into it.' `
        -Reference 'https://pnpm.io/cli/store'

    & $add -Id 'yarn.cache.dir' -Tool 'Yarn' -Executable 'yarn' -Resolution 'Path' `
        -Arguments @('cache', 'dir') -Purpose 'Report the Yarn Classic cache directory.' `
        -ReadOnly $true -MinimumRisk 'SAFE' -RequiresAdmin $false -TimeoutSeconds 120 `
        -Reference 'https://classic.yarnpkg.com/en/docs/cli/cache'

    & $add -Id 'yarn.cache.clean' -Tool 'Yarn' -Executable 'yarn' -Resolution 'Path' `
        -Arguments @('cache', 'clean') -Purpose 'Empty the Yarn cache.' `
        -ReadOnly $false -MinimumRisk 'LOW' -RequiresAdmin $false -TimeoutSeconds 900 `
        -Consequence 'Packages are downloaded again on the next install.' `
        -Reference 'https://classic.yarnpkg.com/en/docs/cli/cache'

    # ----------------------------------------------------------------- Python ecosystem
    & $add -Id 'pip.cache.dir' -Tool 'pip' -Executable 'pip' -Resolution 'Path' `
        -Arguments @('cache', 'dir') -Purpose 'Report the pip cache directory.' `
        -ReadOnly $true -MinimumRisk 'SAFE' -RequiresAdmin $false -TimeoutSeconds 120 `
        -Reference 'https://pip.pypa.io/en/stable/cli/pip_cache/'

    & $add -Id 'pip.cache.info' -Tool 'pip' -Executable 'pip' -Resolution 'Path' `
        -Arguments @('cache', 'info') -Purpose 'Report pip cache location and size.' `
        -ReadOnly $true -MinimumRisk 'SAFE' -RequiresAdmin $false -TimeoutSeconds 180 `
        -Reference 'https://pip.pypa.io/en/stable/cli/pip_cache/'

    & $add -Id 'pip.cache.purge' -Tool 'pip' -Executable 'pip' -Resolution 'Path' `
        -Arguments @('cache', 'purge') -Purpose 'Remove all wheels and HTTP responses from the pip cache.' `
        -ReadOnly $false -MinimumRisk 'LOW' -RequiresAdmin $false -TimeoutSeconds 900 `
        -Consequence 'Wheels are rebuilt or re-downloaded on the next install. Installed environments are unaffected.' `
        -Reference 'https://pip.pypa.io/en/stable/cli/pip_cache/'

    & $add -Id 'uv.cache.dir' -Tool 'uv' -Executable 'uv' -Resolution 'Path' `
        -Arguments @('cache', 'dir') -Purpose 'Report the uv cache directory.' `
        -ReadOnly $true -MinimumRisk 'SAFE' -RequiresAdmin $false -TimeoutSeconds 120 `
        -Reference 'https://docs.astral.sh/uv/reference/cli/'

    # uv takes an exclusive lock on the cache to prune or clean it, and waits UV_LOCK_TIMEOUT
    # seconds (300 by default) for other uv processes to let go. Tools started with uvx
    # (language servers, MCP servers) live in the cache and hold that lock for as long as
    # they run, so on a developer machine the wait would often be five minutes for nothing.
    # 30 seconds is enough for an ordinary install to finish; a lock held longer than that
    # is a running tool, and the honest outcome is "in use, try later", never --force.
    $uvCacheEnvironment = @{ UV_LOCK_TIMEOUT = '30' }
    $uvCacheBusyPattern = '(?i)cache is currently in-use|waiting for other uv processes|waiting for lock on'
    $uvCacheBusyAdvice  = 'uv keeps its cache locked while any uv or uvx process is running, including tools started through uvx such as language servers and MCP servers. Close those and run again, or leave the cache as it is. WinAdvisor does not force the lock, because that could disturb the process holding it.'

    & $add -Id 'uv.cache.prune' -Tool 'uv' -Executable 'uv' -Resolution 'Path' `
        -Arguments @('cache', 'prune') -Purpose 'Remove outdated entries from the uv cache.' `
        -ReadOnly $false -MinimumRisk 'LOW' -RequiresAdmin $false -TimeoutSeconds 900 `
        -Consequence 'Only entries uv considers unused are removed; current environments keep working.' `
        -Environment $uvCacheEnvironment -BusyPattern $uvCacheBusyPattern -BusyAdvice $uvCacheBusyAdvice `
        -Reference 'https://docs.astral.sh/uv/reference/cli/'

    & $add -Id 'uv.cache.clean' -Tool 'uv' -Executable 'uv' -Resolution 'Path' `
        -Arguments @('cache', 'clean') -Purpose 'Empty the uv cache completely.' `
        -ReadOnly $false -MinimumRisk 'LOW' -RequiresAdmin $false -TimeoutSeconds 900 `
        -Consequence 'Every cached distribution is re-downloaded on next use.' `
        -Environment $uvCacheEnvironment -BusyPattern $uvCacheBusyPattern -BusyAdvice $uvCacheBusyAdvice `
        -Reference 'https://docs.astral.sh/uv/reference/cli/'

    # ------------------------------------------------------------------------- External
    # Czkawka only scans. The execution engine deletes exact, reviewed JSON candidates.
    & $add -Id 'czkawka.version' -Tool 'Czkawka' -Executable 'czkawka_cli' -Resolution 'Path' `
        -Arguments @('--version') -Purpose 'Verify the supported Czkawka CLI version.' `
        -ReadOnly $true -MinimumRisk 'SAFE' -RequiresAdmin $false -TimeoutSeconds 30 `
        -Reference 'https://github.com/qarmin/czkawka/releases/tag/12.0.2'
    foreach ($scan in @(
        @{ Id = 'duplicates'; Command = 'dup'; Extra = @('--search-method', 'hash', '--hash-type', 'BLAKE3', '--minimal-file-size', '1') }
        @{ Id = 'empty-folders'; Command = 'empty-folders'; Extra = @() }
        @{ Id = 'empty-files'; Command = 'empty-files'; Extra = @() }
        @{ Id = 'temporary'; Command = 'temp'; Extra = @() }
        @{ Id = 'similar-images'; Command = 'image'; Extra = @('--minimal-file-size', '1', '--max-difference', '5') }
        @{ Id = 'broken-files'; Command = 'broken'; Extra = @() }
    )) {
    & $add -Id ('czkawka.' + $scan.Id) -Tool 'Czkawka' -Executable 'czkawka_cli' -Resolution 'Path' `
        -Arguments (@($scan.Command, '--directories', '{Directory}', '--compact-file-to-save', '{ReportFile}',
            '--disable-cache', '--ignore-error-code-on-found', '--do-not-print-results') + $scan.Extra) `
        -Placeholders @{
            Directory  = '^[A-Za-z]:\\[^"\r\n\*\?<>\|]{0,240}$'
            ReportFile = '^[A-Za-z]:\\[^"\r\n\*\?<>\|]{0,240}$'
        } `
        -Purpose ('Scan selected directories for {0} and write JSON.' -f $scan.Id) `
        -ReadOnly $true -MinimumRisk 'SAFE' -RequiresAdmin $false -TimeoutSeconds 1800 `
        -Consequence 'Produces a report only. No deletion argument is ever passed.' `
        -Reference 'https://github.com/qarmin/czkawka/blob/12.0.2/czkawka_cli/src/commands.rs'
    }

    return $catalog
}

$script:WaCommandCatalog = Initialize-WaCommandCatalog

function Get-WaCommandCatalog {
    <#
    .SYNOPSIS
        Returns every catalog entry, for documentation and tests.
    #>
    [CmdletBinding()]
    param()
    return @($script:WaCommandCatalog.Values)
}

function Get-WaCommandDefinition {
    <#
    .SYNOPSIS
        Returns one catalog entry, failing closed for an unknown id.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$CommandId)

    if (-not $script:WaCommandCatalog.Contains($CommandId)) {
        throw "Command '$CommandId' is not in the command catalog and cannot be run."
    }
    return $script:WaCommandCatalog[$CommandId]
}

function Resolve-WaCommand {
    <#
    .SYNOPSIS
        Turns a catalog id plus placeholder values into a concrete, validated invocation.

    .DESCRIPTION
        This is the only path from a provider's intent to an actual command line.
        It resolves the executable (System32 for Windows tools, PATH for third-party
        tools), substitutes placeholders after validating each against its declared
        pattern, and refuses anything unexpected.

    .PARAMETER Values
        Placeholder values. Every placeholder the entry declares must be supplied, and no
        value not declared as a placeholder is accepted.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$CommandId,
        [System.Collections.IDictionary]$Values = @{},
        $Session = $null
    )

    $definition = Get-WaCommandDefinition -CommandId $CommandId

    $executablePath = $null
    if ($definition.Tool -eq 'Czkawka' -and $null -ne $Session) {
        $executablePath = Resolve-WaCzkawkaExecutable -Session $Session
    } elseif ($definition.Resolution -eq 'System') {
        $executablePath = Get-WaSystemExecutable -Name $definition.Executable
    } else {
        $executablePath = Resolve-WaCommandPath -Name $definition.Executable
    }

    $available = ($null -ne $executablePath) -and (Test-Path -LiteralPath $executablePath -PathType Leaf)

    foreach ($supplied in $Values.Keys) {
        if (-not $definition.Placeholders.ContainsKey($supplied)) {
            throw "Command '$CommandId' does not declare a placeholder named '$supplied'."
        }
    }

    $arguments = @(
        foreach ($argument in $definition.Arguments) {
            $resolved = $argument
            foreach ($placeholder in $definition.Placeholders.Keys) {
                $token = '{' + $placeholder + '}'
                if ($resolved -notlike ('*' + $token + '*')) { continue }
                if (-not $Values.Contains($placeholder)) {
                    throw "Command '$CommandId' requires a value for placeholder '$placeholder'."
                }
                $value = [string]$Values[$placeholder]
                $pattern = [string]$definition.Placeholders[$placeholder]
                if ($value -notmatch $pattern) {
                    throw "Value for placeholder '$placeholder' of command '$CommandId' does not match its required pattern."
                }
                $resolved = $resolved.Replace($token, $value)
            }
            # A surviving brace means a placeholder was declared in the argument but not
            # in the Placeholders table; refuse rather than pass a literal '{Name}'.
            if ($resolved -match '\{[A-Za-z]+\}') {
                throw "Command '$CommandId' has an unresolved placeholder in argument '$argument'."
            }
            $resolved
        }
    )

    [pscustomobject][ordered]@{
        PSTypeName     = 'WinAdvisor.ResolvedCommand'
        CommandId      = $CommandId
        Tool           = $definition.Tool
        FilePath       = $executablePath
        Arguments      = @($arguments)
        Available      = $available
        ReadOnly       = $definition.ReadOnly
        RequiresAdmin  = $definition.RequiresAdmin
        MinimumRisk    = $definition.MinimumRisk
        TimeoutSeconds = $definition.TimeoutSeconds
        NeverKill      = $definition.NeverKill
        Environment    = $definition.Environment
        BusyPattern    = $definition.BusyPattern
        BusyAdvice     = $definition.BusyAdvice
        Purpose        = $definition.Purpose
        Consequence    = $definition.Consequence
        Reference      = $definition.Reference
        Preview        = ('{0} {1}' -f $definition.Executable, (($arguments | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' '))
    }
}

function Invoke-WaCatalogProbe {
    <#
    .SYNOPSIS
        Runs a read-only catalog command. Refuses anything not marked ReadOnly.

    .DESCRIPTION
        The inspection path. Because it will run in ViewSpecs, Analyze and DryRun sessions,
        it hard-refuses any catalog entry that is not declared read-only, independently of
        which session it was called from.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$CommandId,
        [System.Collections.IDictionary]$Values = @{},
        $Session = $null
    )

    $resolved = Resolve-WaCommand -CommandId $CommandId -Values $Values -Session $Session
    if (-not $resolved.ReadOnly) {
        throw "Command '$CommandId' is not a read-only probe and cannot be run during inspection."
    }
    if (-not $resolved.Available) {
        return [pscustomobject]@{
            CommandId = $CommandId
            Available = $false
            ExitCode  = $null
            Output    = ''
            Error     = ("'{0}' was not found on this machine." -f $resolved.Tool)
        }
    }
    if ($resolved.RequiresAdmin -and -not (Test-WaAdministrator)) {
        return [pscustomobject]@{
            CommandId = $CommandId
            Available = $false
            ExitCode  = $null
            Output    = ''
            Error     = ("'{0}' requires administrator rights; this session is not elevated." -f $resolved.Preview)
        }
    }

    if ($null -ne $Session) {
        Write-WaLog -Session $Session -Level 'Verbose' -Category 'Probe' -Message ("Running read-only probe: {0}" -f $resolved.Preview)
    }

    $result = Invoke-WaNativeProcess -FilePath $resolved.FilePath -Arguments $resolved.Arguments `
                -TimeoutSeconds $resolved.TimeoutSeconds -NeverKill:$resolved.NeverKill -Environment $resolved.Environment

    [pscustomobject]@{
        CommandId = $CommandId
        Available = $true
        ExitCode  = $result.ExitCode
        Output    = $result.Output
        Error     = $result.Error
        Preview   = $resolved.Preview
    }
}
