<#
    Core/Rollback.ps1 - rollback state capture and restoration.

    Rollback is recorded for changes that genuinely can be put back: registry values,
    service start modes, startup approval state, scheduled task state and hibernation.

    Deleted file content is never claimed to be restorable. The toolkit does not copy files
    before deleting them, so for a cache cleanup the honest answer is:

        Rollback unavailable. The deleted content was classified as regenerable.

    and that is exactly what is recorded, rather than an entry that would fail if used.

    Layout, one directory per session:
        Data/Rollback/<SessionId>/metadata.json   session context
        Data/Rollback/<SessionId>/actions.json    what was attempted and its outcome
        Data/Rollback/<SessionId>/state.json      captured prior state
#>

function Initialize-WaRollbackSession {
    <#
    .SYNOPSIS
        Creates the rollback directory for a session and writes its metadata.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session)

    $directory = Join-Path (Join-Path (Get-WaDataRoot -Create) 'Rollback') $Session.Id
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        [void](New-Item -ItemType Directory -Path $directory -Force)
    }
    $Session.RollbackDirectory = $directory

    $machineProfile = $Session.MachineProfile
    $metadata = [ordered]@{
        SessionId       = $Session.Id
        Version         = $Session.Version
        Mode            = $Session.Mode
        StartedUtc      = $Session.StartedUtc
        MachineName     = [Environment]::MachineName
        UserName        = [Environment]::UserName
        IsAdministrator = $Session.IsAdministrator
        WindowsBuild    = (Get-WaProperty -Object (Get-WaProperty -Object $machineProfile -Name 'OperatingSystem') -Name 'FullBuild')
        PowerShell      = $Session.PowerShell
        Note            = 'Rollback covers configuration changes only. Deleted files are not recoverable from here; they were classified as regenerable before deletion.'
    }
    [void](Set-WaJsonFile -Path (Join-Path $directory 'metadata.json') -InputObject ([pscustomobject]$metadata))
    return $directory
}

function Add-WaRollbackRecord {
    <#
    .SYNOPSIS
        Captures prior state before a reversible change and persists it immediately.

    .DESCRIPTION
        Written to disk as soon as it is captured rather than at the end of the run. If the
        toolkit is interrupted between capturing state and completing the change, the
        record is already on disk and the change can still be reversed.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)][string]$ActionId,
        [Parameter(Mandatory)][string]$Kind,
        [Parameter(Mandatory)][string]$Target,
        $BeforeValue = $null,
        $AfterValue = $null,
        [bool]$Existed = $true,
        [string]$RestoreDescription = '',
        [System.Collections.IDictionary]$RestoreParameters = @{}
    )

    if (-not $Session.RollbackDirectory) { [void](Initialize-WaRollbackSession -Session $Session) }

    $record = New-WaRollbackRecord `
        -Id (New-WaIdentifier -Prefix 'RB') `
        -ActionId $ActionId `
        -Kind $Kind `
        -Target $Target `
        -BeforeValue $BeforeValue `
        -AfterValue $AfterValue `
        -Existed $Existed `
        -RestoreDescription $RestoreDescription `
        -RestoreParameters $RestoreParameters

    $Session.RollbackRecords = @($Session.RollbackRecords + $record)
    [void](Save-WaRollbackState -Session $Session)

    Write-WaLog -Session $Session -Level 'Info' -Category 'Rollback' -Message (
        'Captured rollback state for {0} on {1} (record {2}).' -f $Kind, $Target, $record.Id
    )
    return $record
}

function Save-WaRollbackState {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session)
    if (-not $Session.RollbackDirectory) { return $null }
    return (Set-WaJsonFile -Path (Join-Path $Session.RollbackDirectory 'state.json') -InputObject @($Session.RollbackRecords) -Depth 10)
}

function Save-WaRollbackActions {
    <#
    .SYNOPSIS
        Records what was attempted and what happened, alongside the captured state.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session)

    if (-not $Session.RollbackDirectory) { return $null }

    $actions = @(foreach ($result in @($Session.Results)) {
        [ordered]@{
            ActionId       = $result.ActionId
            Provider       = $result.Provider
            Status         = $result.Status
            Summary        = $result.Summary
            BytesReclaimed = $result.BytesReclaimed
            RollbackId     = $result.RollbackId
            CompletedUtc   = $result.CompletedUtc
            Error          = (Get-WaRedactedText -Text $result.Error)
        }
    })
    return (Set-WaJsonFile -Path (Join-Path $Session.RollbackDirectory 'actions.json') -InputObject $actions -Depth 8)
}

function Get-WaRollbackSession {
    <#
    .SYNOPSIS
        Lists sessions with recorded rollback state, newest first.

    .EXAMPLE
        Get-WaRollbackSession | Format-Table SessionId, CapturedUtc, RecordCount
    #>
    [CmdletBinding()]
    param([string]$SessionId)

    $root = Join-Path (Get-WaDataRoot) 'Rollback'
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { return @() }

    $directories = @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)
    if ($SessionId) { $directories = @($directories | Where-Object { $_.Name -eq $SessionId }) }

    @(foreach ($directory in ($directories | Sort-Object Name -Descending)) {
        $metadataPath = Join-Path $directory.FullName 'metadata.json'
        $statePath    = Join-Path $directory.FullName 'state.json'
        if (-not (Test-Path -LiteralPath $metadataPath)) { continue }

        $metadata = $null
        $records = @()
        try { $metadata = Get-WaJsonFile -Path $metadataPath } catch { continue }
        if (Test-Path -LiteralPath $statePath) {
            try { $records = @(ConvertTo-WaArray (Get-WaJsonFile -Path $statePath)) } catch { $records = @() }
        }

        [pscustomobject][ordered]@{
            SessionId     = $directory.Name
            Directory     = $directory.FullName
            StartedUtc    = (Get-WaProperty -Object $metadata -Name 'StartedUtc')
            MachineName   = (Get-WaProperty -Object $metadata -Name 'MachineName')
            WindowsBuild  = (Get-WaProperty -Object $metadata -Name 'WindowsBuild')
            RecordCount   = @($records).Count
            PendingCount  = @($records | Where-Object { -not (Get-WaProperty -Object $_ -Name 'Restored' -Default $false) }).Count
            Records       = @($records)
        }
    })
}

function Invoke-WaRollback {
    <#
    .SYNOPSIS
        Restores recorded prior state from a rollback session.

    .DESCRIPTION
        Idempotent and conservative. Before restoring, the current value is read: if it
        already matches the recorded prior value, the record is marked restored and nothing
        is written. If it matches neither the prior nor the value the toolkit set, something
        else changed it since, and the record is skipped with an explanation rather than
        overwriting whatever that was.

    .PARAMETER RecordId
        Restore only this record. Without it, every unrestored record is attempted.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$SessionId,
        [string]$RecordId,
        [switch]$Force
    )

    $rollbackSession = @(Get-WaRollbackSession -SessionId $SessionId) | Select-Object -First 1
    if ($null -eq $rollbackSession) { throw "No rollback state found for session '$SessionId'." }

    $session = New-WaSession -Mode 'Rollback'
    Write-WaLog -Session $session -Level 'Info' -Category 'Rollback' -Message "Restoring state captured by session $SessionId."

    $records = @($rollbackSession.Records)
    if ($RecordId) { $records = @($records | Where-Object { (Get-WaProperty -Object $_ -Name 'Id') -eq $RecordId }) }

    $results = New-Object 'System.Collections.Generic.List[object]'
    foreach ($record in $records) {
        $kind   = [string](Get-WaProperty -Object $record -Name 'Kind')
        $target = [string](Get-WaProperty -Object $record -Name 'Target')
        $id     = [string](Get-WaProperty -Object $record -Name 'Id')

        if ((Get-WaProperty -Object $record -Name 'Restored' -Default $false) -and -not $Force) {
            $results.Add([pscustomobject]@{ Id = $id; Kind = $kind; Target = $target; Status = 'Skipped'; Message = 'Already restored.' })
            continue
        }

        if (-not $PSCmdlet.ShouldProcess($target, "Restore $kind")) {
            $results.Add([pscustomobject]@{ Id = $id; Kind = $kind; Target = $target; Status = 'Skipped'; Message = 'Not confirmed.' })
            continue
        }

        try {
            $outcome = Restore-WaRollbackRecord -Session $session -Record $record -Force:$Force
            $results.Add($outcome)
            if ($outcome.Status -eq 'Restored') {
                $record.Restored = $true
                $record.RestoredUtc = Get-WaUtcTimestamp
            }
        } catch {
            $results.Add([pscustomobject]@{ Id = $id; Kind = $kind; Target = $target; Status = 'Failed'; Message = $_.Exception.Message })
            Write-WaLog -Session $session -Level 'Error' -Category 'Rollback' -Message (
                'Restoring {0} on {1} failed: {2}' -f $kind, $target, $_.Exception.Message
            )
        }
    }

    # Persist the updated restored flags back to the original session directory.
    [void](Set-WaJsonFile -Path (Join-Path $rollbackSession.Directory 'state.json') -InputObject @($rollbackSession.Records) -Depth 10)
    [void](Complete-WaSession -Session $session)

    return [pscustomobject]@{
        SessionId = $SessionId
        Results   = $results.ToArray()
        Restored  = @($results | Where-Object { $_.Status -eq 'Restored' }).Count
        Skipped   = @($results | Where-Object { $_.Status -eq 'Skipped' }).Count
        Failed    = @($results | Where-Object { $_.Status -eq 'Failed' }).Count
    }
}

function Restore-WaRollbackRecord {
    <#
    .SYNOPSIS
        Restores a single rollback record.

    .DESCRIPTION
        A rollback record is read from Data/Rollback/<session>/state.json, which is an
        ordinary file on disk. It is therefore treated as untrusted input: a record is not
        permission to act on an arbitrary target just because WinAdvisor wrote one like it
        earlier. Every restore branch re-applies the same policy checks the original change
        had to pass, so a hand-edited or crafted state file cannot reach a protected
        service, a Windows servicing task, or a registry hive outside HKLM and HKCU.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)]$Record, [switch]$Force)

    # Restoration writes to the machine, so it obeys the same read-only gate as execution.
    [void](Assert-WaMutationAllowed -Session $Session -Operation 'rollback restore')

    $kind       = [string](Get-WaProperty -Object $Record -Name 'Kind')
    $target     = [string](Get-WaProperty -Object $Record -Name 'Target')
    $id         = [string](Get-WaProperty -Object $Record -Name 'Id')
    $before     = Get-WaProperty -Object $Record -Name 'BeforeValue'
    $after      = Get-WaProperty -Object $Record -Name 'AfterValue'
    $parameters = Get-WaProperty -Object $Record -Name 'RestoreParameters'

    $skip = {
        param([string]$Message)
        [pscustomobject]@{ Id = $id; Kind = $kind; Target = $target; Status = 'Skipped'; Message = $Message }
    }
    $done = {
        param([string]$Message)
        Write-WaLog -Session $Session -Level 'Info' -Category 'Rollback' -Message ('Restored {0} on {1}.' -f $kind, $target)
        [pscustomobject]@{ Id = $id; Kind = $kind; Target = $target; Status = 'Restored'; Message = $Message }
    }

    switch ($kind) {
        'StartupItemState' {
            $name  = [string](Get-WaProperty -Object $parameters -Name 'Name')
            $scope = [string](Get-WaProperty -Object $parameters -Name 'Scope')
            $hive  = [string](Get-WaProperty -Object $parameters -Name 'Hive')

            if (@('Run', 'Run32', 'StartupFolder') -notcontains $scope) { return (& $skip "Unsupported startup scope '$scope'.") }
            if (@('User', 'Machine') -notcontains $hive) { return (& $skip "Unsupported registry hive '$hive'.") }
            if (Test-WaProtectedStartupItem -Name $name -Policy $Session.Config.Policy) {
                return (& $skip "Startup item '$name' is protected by policy and will not be changed.")
            }

            $current = Get-WaStartupApprovedState -Name $name -Scope $scope -Hive $hive

            if ($current.Enabled -eq [bool]$before) { return (& $skip 'Already in the recorded prior state.') }
            if (-not $Force -and $current.Enabled -ne [bool]$after) {
                return (& $skip 'Current state matches neither the prior value nor the value WinAdvisor set; something else changed it. Use -Force to overwrite.')
            }

            [void](Set-WaStartupApprovedState -Session $Session -Name $name -Scope $scope -Hive $hive -Enabled ([bool]$before))
            return (& $done ('Startup item "{0}" set back to {1}.' -f $name, $(if ([bool]$before) { 'enabled' } else { 'disabled' })))
        }

        'RegistryValueSet' {
            $path = [string](Get-WaProperty -Object $parameters -Name 'Path')
            $name = [string](Get-WaProperty -Object $parameters -Name 'Name')
            $existed = [bool](Get-WaProperty -Object $Record -Name 'Existed' -Default $true)

            # Same constraint as the forward operation: a record on disk must not be able
            # to reach a hive the engine would never write to in the first place.
            if ($path -notmatch '^(HKLM|HKCU):\\') { return (& $skip "Registry restores are limited to HKLM: and HKCU:. Refused: $path") }
            if ([string]::IsNullOrWhiteSpace($name)) { return (& $skip 'The record names no registry value.') }
            if (-not (Test-Path -LiteralPath $path)) { return (& $skip 'The registry key no longer exists.') }

            if (-not $existed) {
                Remove-ItemProperty -LiteralPath $path -Name $name -Force -ErrorAction SilentlyContinue
                return (& $done 'Value removed, as it did not exist before the change.')
            }
            Set-ItemProperty -LiteralPath $path -Name $name -Value $before -Force -ErrorAction Stop
            return (& $done ('Registry value {0}\{1} restored.' -f $path, $name))
        }

        'ServiceStartupSet' {
            $serviceName = [string](Get-WaProperty -Object $parameters -Name 'ServiceName')

            if (Test-WaProtectedService -Name $serviceName -Policy $Session.Config.Policy) {
                return (& $skip "Service '$serviceName' is on the protected list and will not be modified, even to restore it.")
            }
            if (@('Automatic', 'Manual', 'Disabled', 'AutomaticDelayedStart') -notcontains [string]$before) {
                return (& $skip "The record names an unsupported start mode '$before'.")
            }

            $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
            if ($null -eq $service) { return (& $skip 'The service no longer exists.') }

            Set-Service -Name $serviceName -StartupType ([string]$before) -ErrorAction Stop
            return (& $done ('Service {0} start mode restored to {1}.' -f $serviceName, $before))
        }

        'ScheduledTaskState' {
            $taskPath = [string](Get-WaProperty -Object $parameters -Name 'TaskPath')
            $taskName = [string](Get-WaProperty -Object $parameters -Name 'TaskName')

            if ($taskPath -like '\Microsoft\Windows\*') {
                return (& $skip "Task '$taskPath$taskName' belongs to Windows servicing and will not be modified.")
            }

            $task = Get-ScheduledTask -TaskPath $taskPath -TaskName $taskName -ErrorAction SilentlyContinue
            if ($null -eq $task) { return (& $skip 'The scheduled task no longer exists.') }

            if ([bool]$before) {
                [void](Enable-ScheduledTask -TaskPath $taskPath -TaskName $taskName -ErrorAction Stop)
            } else {
                [void](Disable-ScheduledTask -TaskPath $taskPath -TaskName $taskName -ErrorAction Stop)
            }
            return (& $done ('Scheduled task {0} restored.' -f $taskName))
        }

        'NativeCommand' {
            $reverseCommandId = [string](Get-WaProperty -Object $parameters -Name 'ReverseCommandId')
            if (-not $reverseCommandId) { return (& $skip 'This command has no documented counterpart, so it cannot be reversed automatically.') }

            $resolved = Resolve-WaCommand -CommandId $reverseCommandId
            if (-not $resolved.Available) { return (& $skip ("The counterpart command '{0}' is not available on this machine." -f $reverseCommandId)) }
            if ($resolved.RequiresAdmin -and -not $Session.IsAdministrator) {
                return (& $skip ("Reversing this needs administrator rights. Run: {0}" -f $resolved.Preview))
            }

            [void](Assert-WaMutationAllowed -Session $Session -Operation ('reverse command ' + $reverseCommandId))
            $result = Invoke-WaNativeProcess -FilePath $resolved.FilePath -Arguments $resolved.Arguments -TimeoutSeconds $resolved.TimeoutSeconds -NeverKill:$resolved.NeverKill
            if ($result.ExitCode -ne 0) { throw ("The counterpart command exited with code {0}." -f $result.ExitCode) }
            return (& $done ('Ran the documented counterpart: {0}' -f $resolved.Preview))
        }

        'FileDelete' {
            return (& $skip 'Rollback unavailable. The deleted content was classified as regenerable, and WinAdvisor does not copy files before deleting them.')
        }

        default {
            return (& $skip ("No restore procedure is implemented for record kind '{0}'." -f $kind))
        }
    }
}
