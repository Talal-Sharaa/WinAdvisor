<#
    Core/Questions.ps1 - adaptive, device-specific questioning.

    A question is only raised because something was detected on this machine. There is no
    fixed questionnaire: a machine without Docker is never asked about Docker, a desktop
    with hibernation already off is never asked about hiberfil.sys, and a machine with no
    developer tooling is never asked about package caches.

    Each question carries the evidence that caused it, so the user can see why they are
    being asked. Answers map onto recommendations through QuestionId:

      Skip     drop every recommendation tied to this question
      Inspect  keep the advisory findings, drop the executable recommendations
      Analyze  keep everything, still subject to individual approval
#>

function Get-WaQuestion {
    <#
    .SYNOPSIS
        Builds the set of questions this specific machine warrants.

    .EXAMPLE
        $questions = Get-WaQuestion -Session $session -Analysis $analysis
        $questions | ForEach-Object { $_.Prompt }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)]$Analysis
    )

    $machineProfile = $Session.MachineProfile
    $questions = New-Object 'System.Collections.Generic.List[object]'

    $workloadsByName = @{}
    foreach ($workload in @($machineProfile.Workloads)) { $workloadsByName[$workload.Name] = $workload }

    $bytesFor = {
        param([string]$QuestionId)
        $matching = @($Analysis.Recommendations | Where-Object { $_.QuestionId -eq $QuestionId -and $null -ne $_.EstimatedBytes })
        if ($matching.Count -eq 0) { return $null }
        return [long](($matching | ForEach-Object { [long]$_.EstimatedBytes }) | Measure-Object -Sum).Sum
    }

    # ---------------------------------------------------------------------- Docker
    if ($workloadsByName.ContainsKey('Docker')) {
        $dockerBytes = & $bytesFor 'docker'
        $context = if ($null -ne $dockerBytes) {
            'Docker is installed and its reclaimable storage measures {0}.' -f (Format-WaBytes $dockerBytes)
        } else {
            'Docker is installed. Its storage has not been measured yet, usually because the engine is not running.'
        }

        $questions.Add((New-WaQuestion -Id 'docker' -Provider 'Containers.Docker' `
            -Prompt 'How should Docker storage be handled?' `
            -Context $context `
            -Evidence @($workloadsByName['Docker'].Note) `
            -DefaultOption '1' `
            -Options @(
                (New-WaQuestionOption -Key '1' -Label 'Inspect only' -Effect 'Inspect' -Description 'Report what Docker is using. Propose nothing.')
                (New-WaQuestionOption -Key '2' -Label 'Analyse and propose cleanup' -Effect 'Analyze' -Description 'Also propose build-cache and unused-image cleanup. Volumes stay manual-review regardless.')
                (New-WaQuestionOption -Key '3' -Label 'Skip Docker entirely' -Effect 'Skip' -Description 'Leave Docker out of this run.')
            )))
    }

    # ------------------------------------------------------------------------- WSL
    if ($workloadsByName.ContainsKey('WSL')) {
        $questions.Add((New-WaQuestion -Id 'wsl' -Provider 'Containers.Wsl' `
            -Prompt 'Should WSL be inspected?' `
            -Context 'WSL is present. Distributions and their virtual disks are reported only: Microsoft documents how to expand a WSL virtual disk but publishes no supported in-place shrink, and unregistering a distribution destroys its data permanently.' `
            -Evidence @($workloadsByName['WSL'].Note) `
            -DefaultOption '1' `
            -Options @(
                (New-WaQuestionOption -Key '1' -Label 'Inspect and report' -Effect 'Inspect' -Description 'Report distributions, versions and virtual disk sizes.')
                (New-WaQuestionOption -Key '2' -Label 'Skip WSL' -Effect 'Skip' -Description 'Leave WSL out of this run.')
            )))
    }

    # ------------------------------------------------------------ Developer tooling
    $developerWorkloads = @($machineProfile.Workloads | Where-Object {
        @('Package manager', 'Developer runtime', 'IDE') -contains $_.Category
    })
    if ($developerWorkloads.Count -gt 0) {
        $developerBytes = & $bytesFor 'devtools'
        $names = ($developerWorkloads | Select-Object -ExpandProperty Name | Select-Object -First 8) -join ', '

        $questions.Add((New-WaQuestion -Id 'devtools' -Provider 'Core' `
            -Prompt 'Should developer tooling caches be analysed?' `
            -Context ("Detected: {0}.{1} Only global, regenerable caches are considered. No project directory, repository, build output, virtual environment or lock file is touched." -f
                $names,
                $(if ($null -ne $developerBytes) { ' Measured so far: ' + (Format-WaBytes $developerBytes) + '.' } else { '' })) `
            -Evidence @($developerWorkloads | ForEach-Object { '{0} ({1})' -f $_.Name, $_.DetectionMethod }) `
            -DefaultOption '2' `
            -Options @(
                (New-WaQuestionOption -Key '1' -Label 'Inspect only' -Effect 'Inspect' -Description 'Report cache sizes without proposing anything.')
                (New-WaQuestionOption -Key '2' -Label 'Analyse and propose cleanup' -Effect 'Analyze' -Description 'Propose clearing global package caches through each tool''s own documented command.')
                (New-WaQuestionOption -Key '3' -Label 'Skip developer tooling' -Effect 'Skip' -Description 'Leave developer caches out of this run.')
            )))
    }

    # -------------------------------------------------------------------- Browsers
    $browsers = @($machineProfile.Workloads | Where-Object { $_.Category -eq 'Browser' })
    if ($browsers.Count -gt 0) {
        $browserBytes = & $bytesFor 'browsers'
        $questions.Add((New-WaQuestion -Id 'browsers' -Provider 'Core' `
            -Prompt 'Should browser caches be included?' `
            -Context ("Detected: {0}.{1} Cache only. Saved passwords, bookmarks, autofill data, cookies, history and open sessions are never touched by this toolkit." -f
                (($browsers | Select-Object -ExpandProperty Name) -join ', '),
                $(if ($null -ne $browserBytes) { ' Measured: ' + (Format-WaBytes $browserBytes) + '.' } else { '' })) `
            -Evidence @($browsers | ForEach-Object { '{0} profile data at {1}' -f $_.Name, $_.InstallPath }) `
            -DefaultOption '2' `
            -Options @(
                (New-WaQuestionOption -Key '1' -Label 'Inspect only' -Effect 'Inspect' -Description 'Report cache sizes only.')
                (New-WaQuestionOption -Key '2' -Label 'Propose cache cleanup' -Effect 'Analyze' -Description 'Propose clearing cache directories. Pages reload from the network once afterwards.')
                (New-WaQuestionOption -Key '3' -Label 'Skip browsers' -Effect 'Skip' -Description 'Leave browsers out of this run.')
            )))
    }

    # ---------------------------------------------------------------- Hibernation
    $hibernation = $machineProfile.Hibernation
    if ($null -ne $hibernation -and $hibernation.Enabled) {
        $isPortable = [bool](Get-WaProperty -Object $machineProfile.Hardware -Name 'IsPortable' -Default $false)
        $sizeText = Format-WaBytes $hibernation.HiberfilBytes

        $context = if ($isPortable) {
            "This is a laptop or tablet, and hiberfil.sys is using $sizeText. Disabling hibernation recovers that space but removes the ability to hibernate, which is what preserves your work when the battery reaches a critical level. It also disables Fast Startup."
        } else {
            "hiberfil.sys is using $sizeText. This is a desktop, so hibernation is less likely to be depended on, but disabling it also disables Fast Startup."
        }

        $questions.Add((New-WaQuestion -Id 'hibernation' -Provider 'Windows.Hibernation' `
            -Prompt 'Should hibernation appear in the maintenance plan at all?' `
            -Context $context `
            -Evidence @(
                ('hiberfil.sys: {0}' -f $sizeText)
                ('Hibernation file type: {0}' -f $hibernation.HiberFileType)
                ('Fast Startup currently effective: {0}' -f $hibernation.FastStartupEffective)
                ('Chassis: {0}' -f (Get-WaProperty -Object $machineProfile.Hardware -Name 'ChassisType' -Default 'Unknown'))
            ) `
            -DefaultOption $(if ($isPortable) { '2' } else { '1' }) `
            -Options @(
                (New-WaQuestionOption -Key '1' -Label 'Include it as a HIGH-risk option' -Effect 'Analyze' -Description 'Offer it in the plan. It still needs its own explicit approval, administrator rights and a restart.')
                (New-WaQuestionOption -Key '2' -Label 'Do not offer it' -Effect 'Skip' -Description 'Leave hibernation alone and out of the plan.')
            )))
    }

    # ---------------------------------------------------------------- Windows.old
    $windowsOld = @($Analysis.Recommendations | Where-Object { $_.QuestionId -eq 'windowsold' })
    if ($windowsOld.Count -gt 0) {
        $questions.Add((New-WaQuestion -Id 'windowsold' -Provider 'Windows.Servicing' `
            -Prompt 'A previous Windows installation is present. Include it?' `
            -Context 'Windows.old holds your previous Windows installation and is what "Go back" uses. Windows removes it automatically after the rollback window. Removing it early permanently ends the ability to roll back the upgrade.' `
            -Evidence @($windowsOld | ForEach-Object { $_.CurrentImpact }) `
            -DefaultOption '2' `
            -Options @(
                (New-WaQuestionOption -Key '1' -Label 'Include as a HIGH-risk option' -Effect 'Analyze' -Description 'Offer it with individual approval required.')
                (New-WaQuestionOption -Key '2' -Label 'Leave it alone' -Effect 'Skip' -Description 'Let Windows remove it on its own schedule.')
            )))
    }

    # -------------------------------------------------------- Deep storage scanning
    $storage = Get-WaStorageAnalysis -Session $Session -Analysis $Analysis
    if ($null -ne $storage.AttributedPercent -and [double]$storage.AttributedPercent -lt 60) {
        $questions.Add((New-WaQuestion -Id 'deepscan' -Provider 'Core' `
            -Prompt 'Most of the used space is not attributed. Run a deep scan?' `
            -Context ("Targeted inspection attributed {0}% of used space ({1} of {2}). A deep scan walks a directory you name, which can mean millions of filesystem operations, so it is never run automatically." -f
                $storage.AttributedPercent, (Format-WaBytes $storage.AttributedBytes), (Format-WaBytes $storage.TotalUsedBytes)) `
            -Evidence @('Deep scan is read-only and reports large files by category. It never proposes deleting anything based on size.') `
            -DefaultOption '2' `
            -Options @(
                (New-WaQuestionOption -Key '1' -Label 'Yes, scan a directory I name' -Effect 'Analyze' -Description 'Re-run with -DeepScanPath pointing at the directory to examine.')
                (New-WaQuestionOption -Key '2' -Label 'No, targeted inspection is enough' -Effect 'Skip' -Description 'Skip the expensive scan.')
            )))
    }

    return $questions.ToArray()
}

function Set-WaQuestionAnswer {
    <#
    .SYNOPSIS
        Records an answer against a question.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Question,
        [Parameter(Mandatory)][string]$OptionKey
    )

    $option = @($Question.Options | Where-Object { $_.Key -eq $OptionKey }) | Select-Object -First 1
    if ($null -eq $option) { throw "Option '$OptionKey' is not valid for question '$($Question.Id)'." }
    $Question.Answer = $option
    return $Question
}

function Select-WaRecommendationByAnswer {
    <#
    .SYNOPSIS
        Filters recommendations according to the answers given.

    .DESCRIPTION
        An unanswered question is treated as its default option, so a non-interactive run
        behaves predictably and conservatively rather than silently including everything.
    #>
    [CmdletBinding()]
    param(
        [object[]]$Recommendation = @(),
        [object[]]$Question = @()
    )

    $effectByQuestion = @{}
    foreach ($item in $Question) {
        $answer = $item.Answer
        if ($null -eq $answer) {
            $answer = @($item.Options | Where-Object { $_.Key -eq $item.DefaultOption }) | Select-Object -First 1
        }
        if ($null -eq $answer) { continue }
        $effectByQuestion[$item.Id] = $answer.Effect
    }

    @($Recommendation | Where-Object {
        # Captured before the switch: inside a switch, $_ is the switch subject, not the
        # pipeline item, so $_.Risk there would read the effect string instead.
        $candidate = $_
        $questionId = [string]$candidate.QuestionId
        if ([string]::IsNullOrEmpty($questionId)) { return $true }
        if (-not $effectByQuestion.ContainsKey($questionId)) { return $true }

        $effect = [string]$effectByQuestion[$questionId]
        if ($effect -eq 'Skip')    { return $false }
        if ($effect -eq 'Inspect') { return ($candidate.Risk -eq 'MANUAL-ONLY') }
        return $true
    })
}
