<#
    Tests/TestHelpers.ps1 - shared test support.

    Imports the module and gives tests a way to reach internal functions, because the
    invariants worth testing (path safety, policy gates, the execution engine) are
    deliberately not part of the public surface.

    Every test that touches the filesystem works inside a temporary sandbox created by
    New-WaTestSandbox and removed afterwards. No test writes outside it.
#>

$script:WaTestProjectRoot = Split-Path -Parent $PSScriptRoot

function Import-WaForTest {
    <#
    .SYNOPSIS
        Imports WinAdvisor and returns the module, for calling internal functions.
    #>
    [CmdletBinding()]
    param()
    $manifest = Join-Path $script:WaTestProjectRoot 'WinAdvisor.psd1'
    Import-Module $manifest -Force -ErrorAction Stop
    return (Get-Module WinAdvisor)
}

function Invoke-WaInternal {
    <#
    .SYNOPSIS
        Runs a script block inside the module's session state.

    .DESCRIPTION
        Trailing arguments are passed positionally to the script block. Note that an array
        passed this way is flattened by PowerShell's remaining-argument binding, so a
        script block that needs to receive an array whole must be given it through -Bundle.

    .EXAMPLE
        Invoke-WaInternal { Get-WaNormalizedPath -Path 'C:\Temp\..\Windows' }

    .EXAMPLE
        Invoke-WaInternal { param($b) $b.Items.Count } -Bundle @{ Items = @(1, 2, 3) }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][scriptblock]$ScriptBlock,
        [hashtable]$Bundle,
        [Parameter(ValueFromRemainingArguments)][object[]]$ArgumentList = @()
    )
    $module = Get-Module WinAdvisor
    if ($null -eq $module) { $module = Import-WaForTest }

    if ($PSBoundParameters.ContainsKey('Bundle')) {
        # A single object argument: arrays inside it survive intact.
        return (& $module $ScriptBlock $Bundle)
    }
    return (& $module $ScriptBlock @ArgumentList)
}

function New-WaTestSandbox {
    <#
    .SYNOPSIS
        Creates an isolated directory tree for a test, with files of controlled ages.

    .DESCRIPTION
        Returns the sandbox root. Files named old-*.tmp are backdated well past any age
        threshold; new-*.tmp are current. That lets a test assert that age filtering is
        doing real work rather than passing by accident.
    #>
    [CmdletBinding()]
    param([int]$OldFileCount = 3, [int]$NewFileCount = 2, [int]$OldFileAgeDays = 90)

    $root = Join-Path ([IO.Path]::GetTempPath()) ('WaTest-' + [guid]::NewGuid().ToString('N').Substring(0, 12))
    [void](New-Item -ItemType Directory -Path $root -Force)

    $cacheDirectory = Join-Path $root 'cache'
    [void](New-Item -ItemType Directory -Path $cacheDirectory -Force)

    $oldTimestamp = [datetime]::UtcNow.AddDays(-$OldFileAgeDays)
    for ($i = 1; $i -le $OldFileCount; $i++) {
        $path = Join-Path $cacheDirectory ("old-$i.tmp")
        Set-Content -LiteralPath $path -Value ('x' * 1024) -Encoding ASCII
        $item = Get-Item -LiteralPath $path
        $item.LastWriteTimeUtc = $oldTimestamp
        $item.CreationTimeUtc = $oldTimestamp
    }
    for ($i = 1; $i -le $NewFileCount; $i++) {
        $path = Join-Path $cacheDirectory ("new-$i.tmp")
        Set-Content -LiteralPath $path -Value ('y' * 1024) -Encoding ASCII
    }

    return $root
}

function Remove-WaTestSandbox {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    if (-not $Path.StartsWith([IO.Path]::GetTempPath(), [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove a test sandbox outside the temp directory: $Path"
    }
    Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
}

function New-WaTestSession {
    <#
    .SYNOPSIS
        Creates a session for tests, defaulting to a read-only mode.
    #>
    [CmdletBinding()]
    param([string]$Mode = 'DryRun')
    return (Invoke-WaInternal { param($m) New-WaSession -Mode $m } $Mode)
}

function New-WaTestRecommendation {
    <#
    .SYNOPSIS
        Builds a recommendation for approval and execution tests.
    #>
    [CmdletBinding()]
    param(
        [string]$Id = 'test.recommendation',
        [string]$Risk = 'LOW',
        [string]$Confidence = 'HIGH',
        [object[]]$Operations = @(),
        [bool]$AdminRequired = $false
    )
    return (Invoke-WaInternal {
        param($b)
        New-WaRecommendation -Id $b.Id -Title ('Test ' + $b.Id) -Category 'Test' -Provider 'Test' `
            -Description 'A recommendation constructed by the test suite.' `
            -Risk $b.Risk -Confidence $b.Confidence -Operations $b.Operations -AdminRequired $b.AdminRequired
    } -Bundle @{
        Id = $Id; Risk = $Risk; Confidence = $Confidence
        Operations = $Operations; AdminRequired = $AdminRequired
    })
}

function New-WaTestPlan {
    <#
    .SYNOPSIS
        Wraps recommendations into a plan object for approval and execution tests.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object[]]$Recommendation, [string]$Mode = 'Cleanup')

    return (Invoke-WaInternal {
        param($b)
        $actions = New-Object 'System.Collections.Generic.List[object]'
        $order = 0
        foreach ($item in $b.Recommendations) {
            $order++
            $actions.Add((New-WaPlannedAction -Recommendation $item -Order $order))
        }
        [pscustomobject]@{
            Id = 'PLAN-TEST'; SessionId = 'S'; CreatedUtc = (Get-WaUtcTimestamp); Mode = $b.Mode
            Actions = $actions.ToArray(); Questions = @(); Summary = $null
        }
    } -Bundle @{ Recommendations = $Recommendation; Mode = $Mode })
}

function New-WaTestFileOperation {
    <#
    .SYNOPSIS
        A FileDelete operation with an empty manifest, for approval tests.
    #>
    [CmdletBinding()]
    param([string]$Root = 'C:\Temp\WaTest')
    return (Invoke-WaInternal {
        param($r)
        New-WaOperation -Kind 'FileDelete' -Description 'delete test files' `
            -Parameters ([ordered]@{ RootKey = 'root.test'; Root = $r; Files = @() })
    } $Root)
}

function New-WaTestHighRiskOperation {
    <#
    .SYNOPSIS
        A HIGH-risk native command operation, for approval tests.
    #>
    [CmdletBinding()]
    param()
    return (Invoke-WaInternal {
        New-WaOperation -Kind 'NativeCommand' -Description 'disable hibernation' -RequiresAdmin $true `
            -Parameters ([ordered]@{ CommandId = 'powercfg.hibernate.off'; Values = @{} })
    })
}

function Set-WaTestMachineProfile {
    <#
    .SYNOPSIS
        Attaches a minimal machine profile so execution-path tests can run without
        performing real discovery.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session)
    $Session.MachineProfile = [pscustomobject]@{
        Support     = [pscustomobject]@{ SupportedForExecution = $true; Reasons = @() }
        Hibernation = $null
        Startup     = @()
        Storage     = [pscustomobject]@{ Volumes = @() }
        Identity    = [pscustomobject]@{ MachineName = 'TEST'; UserSid = $null }
        OperatingSystem = [pscustomobject]@{ FullBuild = '26100.0' }
    }
    return $Session
}
