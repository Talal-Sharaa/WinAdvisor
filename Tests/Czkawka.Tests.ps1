BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    [void](Import-WaForTest)

    function New-CzkawkaTestContext {
        param([string]$Mode = 'Cleanup')
        $sandbox = New-WaTestSandbox -OldFileCount 1 -NewFileCount 1
        $root = Join-Path $sandbox 'cache'
        [IO.File]::WriteAllText((Join-Path $root 'a.txt'), 'same data')
        [IO.File]::WriteAllText((Join-Path $root 'b.txt'), 'same data')
        [IO.File]::WriteAllText((Join-Path $root 'blank.txt'), '')
        [IO.File]::WriteAllText((Join-Path $root 'broken.png'), 'deliberately invalid image fixture')
        [void](New-Item -ItemType Directory -Path (Join-Path $root 'empty\nested') -Force)
        $session = New-WaTestSession -Mode $Mode
        [void](Set-WaTestMachineProfile $session)
        $session.Config.AllowExternalTools = $true
        $session.Config.CreateRestorePointBeforeHighRisk = $false
        $session.Config.DeepScanPaths = @($root)
        Invoke-WaInternal {
            param($s)
            $s.ProviderState['External.Czkawka'] = @{
                Roots = @($s.Config.DeepScanPaths | ForEach-Object { Get-WaCzkawkaCanonicalPath $_ })
                Modes = @(); Candidates = @(); Groups = @{}; ReservedPaths = @{}; Manifests = @{}; Reports = @()
            }
        } $session
        [pscustomobject]@{ Sandbox = $sandbox; Root = $root; Session = $session }
    }

    function Get-CzkawkaTestEntry {
        param([string]$Path)
        $file = Get-Item -LiteralPath $Path -Force
        $epoch = [datetime]::SpecifyKind([datetime]'1970-01-01', [DateTimeKind]::Utc)
        @{ path = $file.FullName; size = $file.Length; modified_date = [long][Math]::Floor(($file.LastWriteTimeUtc - $epoch).TotalSeconds) }
    }

    # The plan recommendation for one scan type, built from a fixture report the way the
    # provider builds it from a real one.
    function Get-CzkawkaTestRecommendation {
        param($Context, [string]$Mode = 'duplicates')
        $entries = @()
        if ($Mode -in @('duplicates','similar-images')) {
            $entries = @(Get-CzkawkaTestEntry (Join-Path $Context.Root 'a.txt'); Get-CzkawkaTestEntry (Join-Path $Context.Root 'b.txt'))
        }
        $report = Join-Path $Context.Sandbox 'report.json'
        switch ($Mode) {
            'duplicates' { $json = '{"9":[' + (ConvertTo-Json -InputObject $entries -Compress) + ']}' }
            'similar-images' { $json = '[' + (ConvertTo-Json -InputObject $entries -Compress) + ']' }
            'empty-folders' { $json = ConvertTo-Json -InputObject @((Join-Path $Context.Root 'empty')) -Compress }
            'empty-files' { $json = ConvertTo-Json -InputObject @((Get-CzkawkaTestEntry (Join-Path $Context.Root 'blank.txt'))) -Compress }
            'temporary' { $json = ConvertTo-Json -InputObject @((Get-CzkawkaTestEntry (Join-Path $Context.Root 'old-1.tmp'))) -Compress }
            'broken-files' {
                $entry = Get-CzkawkaTestEntry (Join-Path $Context.Root 'broken.png')
                $entry.errors = @{ Image = 'Invalid PNG signature.' }
                $json = ConvertTo-Json -InputObject @($entry) -Depth 5 -Compress
            }
        }
        Set-Content -LiteralPath $report -Value $json -Encoding UTF8
        Invoke-WaInternal {
            param($b)
            $candidates = @(ConvertFrom-WaCzkawkaReport $b.Session $b.Mode $b.Report)
            Register-WaCzkawkaCandidates -Session $b.Session -Candidates $candidates
            New-WaCzkawkaPlanRecommendations -Session $b.Session -Candidates $b.Session.ProviderState['External.Czkawka'].Candidates
        } -Bundle @{ Session = $Context.Session; Mode = $Mode; Report = $report }
    }

    # A plan holding the recommendation, with items chosen the way the review screen does:
    # "select all except oldest" in groups, "select all" otherwise, unless told otherwise.
    function New-CzkawkaTestPlan {
        param($Context, $Recommendation, [string]$Rule = '', [switch]$NoSelection)
        $plan = New-WaTestPlan -Recommendation @($Recommendation)
        $Context.Session.Plan = $plan
        if (-not $NoSelection) {
            $grouped = [bool]$Recommendation.Operations[0].Parameters.Group
            $chosen = if ($Rule) { $Rule } elseif ($grouped) { 'ExceptOldest' } else { 'SelectAll' }
            Invoke-WaInternal {
                param($b)
                $action = $b.Plan.Actions[0]
                $items = @(Get-WaCzkawkaReviewItem -Action $action)
                Set-WaCzkawkaSelection -Item $items -Rule $b.Rule
                [void](Complete-WaCzkawkaSelection -Session $b.Session -Plan $b.Plan -Action $action -Item $items)
            } -Bundle @{ Plan = $plan; Session = $Context.Session; Rule = $chosen }
        }
        return $plan
    }

    function Get-CzkawkaTestTarget {
        param($Plan)
        @($Plan.Actions[0].Recommendation.Operations | ForEach-Object { $_.Parameters.Target.Path })
    }

    function New-CzkawkaTestItem {
        param([string]$Group = '', [string]$Path, [long]$Length = 1, [double]$AgeDays = 0, $Pixels = $null, [int]$GroupNumber = 1)
        [pscustomobject]@{
            Number = 0; Group = $(if ($Group) { $Group } else { 'item:' + $Path }); GroupNumber = $GroupNumber; Grouped = [bool]$Group
            Operation = $null; Path = $Path; Length = $Length; ModifiedUtc = [datetime]::UtcNow.AddDays(-$AgeDays)
            Width = $null; Height = $null; Pixels = $Pixels; Nested = 0; Diagnosis = ''; Selected = $false
        }
    }

    function Set-CzkawkaTestSelection {
        param([object[]]$Item, [string]$Rule, [string]$Pattern = '', [switch]$Unselect)
        Invoke-WaInternal {
            param($b)
            Set-WaCzkawkaSelection -Item $b.Item -Rule $b.Rule -Pattern $b.Pattern -Unselect:$b.Unselect
        } -Bundle @{ Item = $Item; Rule = $Rule; Pattern = $Pattern; Unselect = [bool]$Unselect }
    }
}

Describe 'Czkawka reviewed deletion' -Tag 'Czkawka', 'Safety' {
    BeforeEach { $script:context = New-CzkawkaTestContext }
    AfterEach { Remove-WaTestSandbox $script:context.Sandbox }

    It 'parses all six report shapes into one HIGH-risk, individually approved action per type' {
        foreach ($mode in @('duplicates','similar-images','empty-folders','empty-files','temporary','broken-files')) {
            $r = Get-CzkawkaTestRecommendation $script:context $mode
            @($r).Count | Should -Be 1
            $r.Id | Should -Be ('external.czkawka.delete.' + $mode)
            $r.Risk | Should -Be 'HIGH'
            $r.IndividualApprovalRequired | Should -BeTrue
            $r.Reversibility | Should -Be 'Irreversible'
            Invoke-WaInternal { param($b) Assert-WaRecommendationPolicy $b.R $b.S.Config.Policy } -Bundle @{ R=$r; S=$script:context.Session } | Should -BeTrue
        }
    }

    It 'makes every member of a duplicate group a candidate, with nothing kept automatically' {
        $r = Get-CzkawkaTestRecommendation $script:context 'duplicates'
        @($r.Operations).Count | Should -Be 2
        @($r.Operations | ForEach-Object { $_.Parameters.Group } | Select-Object -Unique).Count | Should -Be 1
        $script:context.Session.ProviderState['External.Czkawka'].ReservedPaths.Count | Should -Be 0
    }

    It 'deletes the selected items for all six types while keeping the root and the unselected copies' {
        foreach ($mode in @('duplicates','empty-folders','empty-files','temporary','similar-images','broken-files')) {
            if ($mode -eq 'similar-images') { [IO.File]::WriteAllText((Join-Path $script:context.Root 'b.txt'), 'same data') }
            $r = Get-CzkawkaTestRecommendation $script:context $mode
            $plan = New-CzkawkaTestPlan $script:context $r
            $result = Invoke-WaPlan -Session $script:context.Session -Plan $plan
            @($result)[0].Status | Should -Be 'Succeeded' -Because $mode
            foreach ($path in (Get-CzkawkaTestTarget $plan)) { Test-Path -LiteralPath $path | Should -BeFalse -Because $mode }
        }
        Test-Path -LiteralPath (Join-Path $script:context.Root 'a.txt') | Should -BeTrue -Because 'it was the unselected copy in both groups'
        Test-Path -LiteralPath $script:context.Root | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:context.Root 'new-1.tmp') | Should -BeTrue
    }

    It 'narrows the plan action to exactly the selected items and approves that' {
        $r = Get-CzkawkaTestRecommendation $script:context 'duplicates'
        $plan = New-CzkawkaTestPlan $script:context $r
        $action = $plan.Actions[0]
        @($action.Recommendation.Operations).Count | Should -Be 1
        $action.Recommendation.Title | Should -Match 'delete 1 of 2'
        $action.Approval.Scope | Should -Be 'Individual'
        Invoke-WaInternal { param($a) Test-WaApproval -Action $a } $action | Should -BeTrue
        $kept = Invoke-WaInternal { param($p) Get-WaCzkawkaCanonicalPath $p } (Join-Path $script:context.Root 'a.txt')
        $script:context.Session.ProviderState['External.Czkawka'].ReservedPaths.Keys | Should -Contain $kept
    }

    It 'refuses to delete group members when no other member was left unselected' {
        # Approving the unnarrowed action is exactly "select all" without the screen's check.
        $r = Get-CzkawkaTestRecommendation $script:context 'duplicates'
        $plan = New-CzkawkaTestPlan $script:context $r -NoSelection
        [void](Grant-WaApproval -Session $script:context.Session -Plan $plan -ActionId $r.Id -Decision Approved)
        $result = Invoke-WaPlan -Session $script:context.Session -Plan $plan
        @($result)[0].Status | Should -Be 'Skipped'
        @($result)[0].Messages -join ' ' | Should -Match 'left unselected'
        Test-Path -LiteralPath (Join-Path $script:context.Root 'a.txt') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:context.Root 'b.txt') | Should -BeTrue
    }

    It 'refuses to confirm a selection that covers a whole group' {
        $r = Get-CzkawkaTestRecommendation $script:context 'duplicates'
        { New-CzkawkaTestPlan $script:context $r -Rule 'SelectAll' } | Should -Throw '*Every file is selected in group(s) 1*'
        $script:context.Session.Plan.Actions[0].Approval | Should -BeNullOrEmpty
    }

    It 'does not delete without approval' {
        $r = Get-CzkawkaTestRecommendation $script:context
        $plan = New-CzkawkaTestPlan $script:context $r -NoSelection
        Invoke-WaPlan -Session $script:context.Session -Plan $plan | Out-Null
        foreach ($operation in $r.Operations) { Test-Path -LiteralPath $operation.Parameters.Target.Path | Should -BeTrue }
    }

    It 'validates an individually approved deletion inside a default scan folder' {
        $script:context.Session.Config.ProviderConfig['External.Czkawka'].Settings['DefaultScanPaths'] = @($script:context.Root)
        $script:context.Session.Config.DeepScanPaths = @()
        $r = Get-CzkawkaTestRecommendation $script:context
        $plan = New-CzkawkaTestPlan $script:context $r
        $result = Invoke-WaPlan -Session $script:context.Session -Plan $plan
        @($result)[0].Status | Should -Be 'Succeeded'
        Test-Path -LiteralPath (Join-Path $script:context.Root 'a.txt') | Should -BeTrue
        Test-Path -LiteralPath $script:context.Root | Should -BeTrue
    }

    It 'refuses deletion when the default scan folders have changed since review' {
        $script:context.Session.Config.DeepScanPaths = @()
        $script:context.Session.Config.ProviderConfig['External.Czkawka'].Settings['DefaultScanPaths'] = @($script:context.Root)
        $r = Get-CzkawkaTestRecommendation $script:context
        $script:context.Session.Config.ProviderConfig['External.Czkawka'].Settings['DefaultScanPaths'] = @($script:context.Sandbox)
        $plan = New-CzkawkaTestPlan $script:context $r
        $result = Invoke-WaPlan -Session $script:context.Session -Plan $plan
        @($result)[0].Status | Should -Be 'Skipped'
        foreach ($path in (Get-CzkawkaTestTarget $plan)) { Test-Path -LiteralPath $path | Should -BeTrue }
    }

    It 'refuses batch approval even when the configured ceiling is HIGH' {
        $r = Get-CzkawkaTestRecommendation $script:context
        $plan = New-WaTestPlan @($r)
        $script:context.Session.Config.MaximumAutoApprovableRisk = 'HIGH'
        { Grant-WaApproval -Session $script:context.Session -Plan $plan -ActionId $r.Id -Decision Approved -Scope Batch } | Should -Throw '*individual approval*'
    }

    It 'skips a changed target even if its size and timestamp are restored' {
        $r = Get-CzkawkaTestRecommendation $script:context
        $plan = New-CzkawkaTestPlan $script:context $r
        $target = $plan.Actions[0].Recommendation.Operations[0].Parameters.Target
        [IO.File]::WriteAllText($target.Path, 'DIFFERENT')
        (Get-Item -LiteralPath $target.Path).LastWriteTimeUtc = [datetime]$target.LastWriteUtc
        $result = Invoke-WaPlan -Session $script:context.Session -Plan $plan
        @($result)[0].Status | Should -Be 'Skipped'
        Test-Path -LiteralPath $target.Path | Should -BeTrue
    }

    It 'skips deletion if the kept copy disappears' {
        $r = Get-CzkawkaTestRecommendation $script:context
        $plan = New-CzkawkaTestPlan $script:context $r
        [IO.File]::Delete((Join-Path $script:context.Root 'a.txt'))
        $result = Invoke-WaPlan -Session $script:context.Session -Plan $plan
        @($result)[0].Status | Should -Be 'Skipped'
        Test-Path -LiteralPath (Join-Path $script:context.Root 'b.txt') | Should -BeTrue
    }

    It 'skips an empty directory when a hidden file is added before execution' {
        $r = Get-CzkawkaTestRecommendation $script:context 'empty-folders'
        $plan = New-CzkawkaTestPlan $script:context $r
        $path = Join-Path @(Get-CzkawkaTestTarget $plan)[0] 'hidden.txt'
        [IO.File]::WriteAllText($path, 'keep me')
        [IO.File]::SetAttributes($path, [IO.FileAttributes]::Hidden)
        $result = Invoke-WaPlan -Session $script:context.Session -Plan $plan
        @($result)[0].Status | Should -Be 'Skipped'
        Test-Path -LiteralPath $path | Should -BeTrue
    }

    It 'skips a changed empty directory tree rather than deleting new children' {
        $r = Get-CzkawkaTestRecommendation $script:context 'empty-folders'
        $plan = New-CzkawkaTestPlan $script:context $r
        [void](New-Item -ItemType Directory -Path (Join-Path @(Get-CzkawkaTestTarget $plan)[0] 'new-child'))
        $result = Invoke-WaPlan -Session $script:context.Session -Plan $plan
        @($result)[0].Status | Should -Be 'Skipped'
    }

    It 'skips candidates when external tools are disabled after review' {
        $r = Get-CzkawkaTestRecommendation $script:context
        $plan = New-CzkawkaTestPlan $script:context $r
        $script:context.Session.Config.AllowExternalTools = $false
        $result = Invoke-WaPlan -Session $script:context.Session -Plan $plan
        @($result)[0].Status | Should -Be 'Skipped'
    }

    It 'rejects an edited manifest even if a new approval is recorded' {
        $r = Get-CzkawkaTestRecommendation $script:context 'empty-files'
        $r.Operations[0].Parameters.Target.Path = Join-Path $script:context.Root 'new-1.tmp'
        $plan = New-CzkawkaTestPlan $script:context $r
        $result = Invoke-WaPlan -Session $script:context.Session -Plan $plan
        @($result)[0].Status | Should -Be 'Skipped'
        Test-Path -LiteralPath (Join-Path $script:context.Root 'new-1.tmp') | Should -BeTrue
    }

    It 'honours exclusions added after review' {
        $r = Get-CzkawkaTestRecommendation $script:context
        $plan = New-CzkawkaTestPlan $script:context $r
        $script:context.Session.Config.ExcludedPaths = @(Get-CzkawkaTestTarget $plan)
        $result = Invoke-WaPlan -Session $script:context.Session -Plan $plan
        @($result)[0].Status | Should -Be 'Skipped'
    }

    It 'never deletes in a read-only session even with valid individual approval' {
        $r = Get-CzkawkaTestRecommendation $script:context
        $plan = New-CzkawkaTestPlan $script:context $r
        $script:context.Session.ReadOnly = $true
        $result = Invoke-WaPlan -Session $script:context.Session -Plan $plan
        @($result)[0].Status | Should -Be 'Simulated'
        foreach ($path in (Get-CzkawkaTestTarget $plan)) { Test-Path -LiteralPath $path | Should -BeTrue }
    }

    It 'rejects roots as deletion targets and paths outside the selected roots' {
        foreach ($path in @($script:context.Root, $script:context.Sandbox)) {
            { Invoke-WaInternal { param($b) Assert-WaCzkawkaPath $b.S $b.Path } -Bundle @{S=$script:context.Session; Path=$path} } | Should -Throw
        }
    }

    It 'rejects repository contents, including files outside the .git directory' {
        [void](New-Item -ItemType Directory -Path (Join-Path $script:context.Root '.git'))
        { Invoke-WaInternal { param($s) Assert-WaCzkawkaPath $s (Join-Path $s.Config.DeepScanPaths[0] 'a.txt') } $script:context.Session } | Should -Throw '*repository*'
    }

    It 'preserves a selected root nested inside another selected root' {
        $nested = Join-Path $script:context.Root 'empty'
        $script:context.Session.ProviderState['External.Czkawka'].Roots += $nested
        { Invoke-WaInternal { param($b) Assert-WaCzkawkaPath $b.S $b.Path } -Bundle @{ S=$script:context.Session; Path=$nested } } | Should -Throw '*scan root*'
    }

    It 'offers empty children when Czkawka reports the selected root as empty' {
        $selected = Join-Path $script:context.Root 'empty'
        $script:context.Session.Config.DeepScanPaths = @($selected)
        $script:context.Session.ProviderState['External.Czkawka'].Roots = @(Invoke-WaInternal { param($p) Get-WaCzkawkaCanonicalPath $p } $selected)
        $r = Get-CzkawkaTestRecommendation $script:context 'empty-folders'
        $r.Operations[0].Parameters.Target.Path | Should -Match 'nested$'
        $plan = New-CzkawkaTestPlan $script:context $r
        $result = Invoke-WaPlan -Session $script:context.Session -Plan $plan
        @($result)[0].Status | Should -Be 'Succeeded'
        Test-Path -LiteralPath $selected | Should -BeTrue
    }

    It 'rejects linked paths before following them' {
        Mock -ModuleName WinAdvisor Test-WaPathUnlinked { $false }
        { Invoke-WaInternal { param($s) Assert-WaCzkawkaPath $s (Join-Path $s.Config.DeepScanPaths[0] 'a.txt') } $script:context.Session } | Should -Throw '*linked or offline*'
    }

    It 'refuses a CLI version whose report schema has not been verified' {
        Mock -ModuleName WinAdvisor Invoke-WaCatalogProbe { [pscustomobject]@{ Available=$true; ExitCode=0; Output='czkawka 11.0.0' } }
        { Invoke-WaInternal { param($s) Initialize-WaCzkawkaScan $s } $script:context.Session } | Should -Throw '*requires Czkawka CLI 12.0.2*'
    }

    It 'reports a missing executable as unavailable when automatic download is disabled' {
        $script:context.Session.Config.ProviderConfig['External.Czkawka'].Settings['AutoDownload'] = $false
        Mock -ModuleName WinAdvisor Resolve-WaCzkawkaExecutable { $null }
        $availability = Invoke-WaInternal { param($s) & (Get-WaProvider 'External.Czkawka').TestAvailable $s } $script:context.Session
        $availability.Available | Should -BeFalse
        $availability.Reason | Should -Match 'CLI is missing'
    }

    It 'does not reuse candidates or approval manifests after a failed rescan' {
        $r = Get-CzkawkaTestRecommendation $script:context
        $state = $script:context.Session.ProviderState['External.Czkawka']
        $state.Modes = @('duplicates')
        $state.Candidates = @('stale')
        Mock -ModuleName WinAdvisor Invoke-WaNativeProcess { throw 'Scan timeout' }
        $findings = @(Invoke-WaInternal { param($s) Invoke-WaCzkawkaScans $s } $script:context.Session)
        $findings[0].Title | Should -Match 'failed'
        $state.Candidates.Count | Should -Be 0
        $state.Manifests.Count | Should -Be 0
        $plan = New-CzkawkaTestPlan $script:context $r
        $result = Invoke-WaPlan -Session $script:context.Session -Plan $plan
        @($result)[0].Status | Should -Be 'Skipped'
    }

    It 'reports skipped scan folders as a finding' {
        $state = $script:context.Session.ProviderState['External.Czkawka']
        $state.Modes = @()
        $state.SkippedRoots = @('Protected path: C:\')
        $findings = @(Invoke-WaInternal { param($s) Invoke-WaCzkawkaScans $s } $script:context.Session 6>$null)
        $findings.Count | Should -Be 1
        $findings[0].Id | Should -Be 'external.czkawka.skipped-folders'
        $findings[0].Evidence[0].Statement | Should -Be 'Protected path: C:\'
    }

    It 'lets the first scan type claim a path and drops a group left with one member' {
        $a = Get-CzkawkaTestEntry (Join-Path $script:context.Root 'a.txt')
        $b = Get-CzkawkaTestEntry (Join-Path $script:context.Root 'b.txt')
        $blank = Get-CzkawkaTestEntry (Join-Path $script:context.Root 'blank.txt')
        $duplicates = Join-Path $script:context.Sandbox 'dup.json'
        $similar = Join-Path $script:context.Sandbox 'sim.json'
        Set-Content -LiteralPath $duplicates -Value ('{"9":[' + (ConvertTo-Json -InputObject @($a, $b) -Compress) + ']}')
        Set-Content -LiteralPath $similar -Value ('[' + (ConvertTo-Json -InputObject @($a, $blank) -Compress) + ']')
        $state = Invoke-WaInternal {
            param($b)
            $all = @(ConvertFrom-WaCzkawkaReport $b.S 'duplicates' $b.D) + @(ConvertFrom-WaCzkawkaReport $b.S 'similar-images' $b.I)
            Register-WaCzkawkaCandidates -Session $b.S -Candidates $all
            $b.S.ProviderState['External.Czkawka']
        } -Bundle @{ S = $script:context.Session; D = $duplicates; I = $similar }
        @($state.Candidates | Where-Object { $_.Mode -eq 'duplicates' }).Count | Should -Be 2
        @($state.Candidates | Where-Object { $_.Mode -eq 'similar-images' }).Count | Should -Be 0
        $state.Groups.Count | Should -Be 1
    }

    It 'does not interpret malformed JSON as a clean scan' {
        $report = Join-Path $script:context.Sandbox 'bad.json'
        Set-Content -LiteralPath $report -Value '{broken'
        { Invoke-WaInternal { param($b) ConvertFrom-WaCzkawkaReport $b.S 'duplicates' $b.Path } -Bundle @{S=$script:context.Session; Path=$report} } | Should -Throw
    }

    It 'accepts zero matches without manufacturing candidates' {
        $report = Join-Path $script:context.Sandbox 'none.json'
        Set-Content -LiteralPath $report -Value '[]'
        $found = @(Invoke-WaInternal { param($b) ConvertFrom-WaCzkawkaReport $b.S 'similar-images' $b.Path } -Bundle @{S=$script:context.Session; Path=$report})
        $found.Count | Should -Be 0
    }

    It 'does not propose recent temporary files' {
        $report = Join-Path $script:context.Sandbox 'recent.json'
        ConvertTo-Json -InputObject @((Get-CzkawkaTestEntry (Join-Path $script:context.Root 'new-1.tmp'))) | Set-Content -LiteralPath $report
        $found = @(Invoke-WaInternal { param($b) ConvertFrom-WaCzkawkaReport $b.S 'temporary' $b.Path } -Bundle @{S=$script:context.Session; Path=$report})
        $found.Count | Should -Be 0
    }

    It 'shows the broken-file validation error in the review' {
        $r = Get-CzkawkaTestRecommendation $script:context 'broken-files'
        $r.Evidence[0].Statement | Should -Match 'Invalid PNG signature'
        $r.Confidence | Should -Be 'MEDIUM'
        $items = @(Invoke-WaInternal { param($r) Get-WaCzkawkaReviewItem -Action ([pscustomobject]@{ Recommendation = $r }) } $r)
        $items[0].Diagnosis | Should -Match 'Invalid PNG signature'
    }

    It 'skips a broken file that was repaired or changed after review' {
        $r = Get-CzkawkaTestRecommendation $script:context 'broken-files'
        $plan = New-CzkawkaTestPlan $script:context $r
        [IO.File]::WriteAllText(@(Get-CzkawkaTestTarget $plan)[0], 'replacement file')
        $result = Invoke-WaPlan -Session $script:context.Session -Plan $plan
        @($result)[0].Status | Should -Be 'Skipped'
        Test-Path -LiteralPath @(Get-CzkawkaTestTarget $plan)[0] | Should -BeTrue
    }

    It 'rejects a broken-file report entry without a validation error' {
        $report = Join-Path $script:context.Sandbox 'broken-without-error.json'
        ConvertTo-Json -InputObject @((Get-CzkawkaTestEntry (Join-Path $script:context.Root 'broken.png'))) | Set-Content -LiteralPath $report
        $found = @(Invoke-WaInternal { param($b) ConvertFrom-WaCzkawkaReport $b.S 'broken-files' $b.Path } -Bundle @{ S=$script:context.Session; Path=$report })
        $found.Count | Should -Be 0
    }
}

Describe 'Czkawka selection rules' -Tag 'Czkawka' {

    It 'offers the group rules for duplicates, adds resolution for similar images, and the list rules elsewhere' {
        $duplicates = @(Invoke-WaInternal { Get-WaCzkawkaSelectionRule -Mode 'duplicates' })
        $similar = @(Invoke-WaInternal { Get-WaCzkawkaSelectionRule -Mode 'similar-images' })
        $duplicates.Count | Should -Be 11
        $duplicates | Should -Not -Contain 'ExceptBiggestResolution'
        $similar.Count | Should -Be 13
        $similar | Should -Contain 'ExceptSmallestResolution'
        foreach ($mode in @('empty-folders', 'empty-files', 'temporary', 'broken-files')) {
            @(Invoke-WaInternal { param($m) Get-WaCzkawkaSelectionRule -Mode $m } $mode) | Should -Be @('Invert', 'DeselectAll', 'SelectAll', 'Custom')
        }
    }

    It 'selects all except the oldest in every group, including a lone group' {
        $items = @(
            New-CzkawkaTestItem -Group 'g1' -Path 'C:\x\new.txt' -AgeDays 1
            New-CzkawkaTestItem -Group 'g1' -Path 'C:\x\old.txt' -AgeDays 9
            New-CzkawkaTestItem -Group 'g2' -Path 'C:\y\old.txt' -AgeDays 5 -GroupNumber 2
            New-CzkawkaTestItem -Group 'g2' -Path 'C:\y\new.txt' -AgeDays 2 -GroupNumber 2
        )
        Set-CzkawkaTestSelection -Item $items -Rule 'ExceptOldest'
        @($items | Where-Object { -not $_.Selected } | ForEach-Object { $_.Path }) | Should -Be @('C:\x\old.txt', 'C:\y\old.txt')

        $lone = @($items[0], $items[1])
        Set-CzkawkaTestSelection -Item $lone -Rule 'ExceptNewest'
        @($lone | Where-Object { $_.Selected } | ForEach-Object { $_.Path }) | Should -Be @('C:\x\old.txt')
    }

    It 'spares the first file in the group on a tie, like Czkawka' {
        $items = @(
            New-CzkawkaTestItem -Group 'g' -Path 'C:\a.txt' -Length 10
            New-CzkawkaTestItem -Group 'g' -Path 'C:\b.txt' -Length 10
            New-CzkawkaTestItem -Group 'g' -Path 'C:\c.txt' -Length 10
        )
        Set-CzkawkaTestSelection -Item $items -Rule 'ExceptBiggestSize'
        @($items | ForEach-Object { $_.Selected }) | Should -Be @($false, $true, $true)
        Set-CzkawkaTestSelection -Item $items -Rule 'ExceptSmallestSize'
        @($items | ForEach-Object { $_.Selected }) | Should -Be @($false, $true, $true)
    }

    It 'compares the folder before the file name for path length' {
        $items = @(
            New-CzkawkaTestItem -Group 'g' -Path 'C:\a\long-file-name.txt'
            New-CzkawkaTestItem -Group 'g' -Path 'C:\deeper\b.txt'
        )
        Set-CzkawkaTestSelection -Item $items -Rule 'ExceptLongestPath'
        @($items | Where-Object { -not $_.Selected } | ForEach-Object { $_.Path }) | Should -Be @('C:\deeper\b.txt')
        Set-CzkawkaTestSelection -Item $items -Rule 'ExceptShortestPath'
        @($items | Where-Object { -not $_.Selected } | ForEach-Object { $_.Path }) | Should -Be @('C:\a\long-file-name.txt')
    }

    It 'keeps the biggest or smallest resolution for similar images' {
        $items = @(
            New-CzkawkaTestItem -Group 'g' -Path 'C:\small.png' -Pixels 100
            New-CzkawkaTestItem -Group 'g' -Path 'C:\large.png' -Pixels 4000
        )
        Set-CzkawkaTestSelection -Item $items -Rule 'ExceptBiggestResolution'
        @($items | Where-Object { $_.Selected } | ForEach-Object { $_.Path }) | Should -Be @('C:\small.png')
        Set-CzkawkaTestSelection -Item $items -Rule 'ExceptSmallestResolution'
        @($items | Where-Object { $_.Selected } | ForEach-Object { $_.Path }) | Should -Be @('C:\large.png')
    }

    It 'inverts only the groups that already have a selection' {
        $items = @(
            New-CzkawkaTestItem -Group 'g1' -Path 'C:\1a'
            New-CzkawkaTestItem -Group 'g1' -Path 'C:\1b'
            New-CzkawkaTestItem -Group 'g2' -Path 'C:\2a' -GroupNumber 2
            New-CzkawkaTestItem -Group 'g2' -Path 'C:\2b' -GroupNumber 2
        )
        $items[0].Selected = $true
        Set-CzkawkaTestSelection -Item $items -Rule 'InvertInGroup'
        @($items | ForEach-Object { $_.Selected }) | Should -Be @($false, $true, $false, $false)
        Set-CzkawkaTestSelection -Item $items -Rule 'Invert'
        @($items | ForEach-Object { $_.Selected }) | Should -Be @($true, $false, $true, $true)
    }

    It 'selects by wildcard but never takes the last unselected file in a group' {
        $items = @(
            New-CzkawkaTestItem -Group 'g' -Path 'D:\Downloads\a.jpg'
            New-CzkawkaTestItem -Group 'g' -Path 'D:\Downloads\b.jpg'
            New-CzkawkaTestItem -Path 'D:\Downloads\loose.tmp'
            New-CzkawkaTestItem -Path 'D:\Other\loose.tmp'
        )
        Set-CzkawkaTestSelection -Item $items -Rule 'Custom' -Pattern '*\DOWNLOADS\*'
        @($items | ForEach-Object { $_.Selected }) | Should -Be @($true, $false, $true, $false)
        Set-CzkawkaTestSelection -Item $items -Rule 'Custom' -Pattern '*.tmp' -Unselect
        @($items | ForEach-Object { $_.Selected }) | Should -Be @($true, $false, $false, $false)
    }

    It 'lists every group whose files are all selected' {
        $items = @(
            New-CzkawkaTestItem -Group 'g1' -Path 'C:\1a'
            New-CzkawkaTestItem -Group 'g1' -Path 'C:\1b'
            New-CzkawkaTestItem -Group 'g2' -Path 'C:\2a' -GroupNumber 2
            New-CzkawkaTestItem -Group 'g2' -Path 'C:\2b' -GroupNumber 2
            New-CzkawkaTestItem -Path 'C:\loose'
        )
        Set-CzkawkaTestSelection -Item $items -Rule 'SelectAll'
        $items[3].Selected = $false
        @(Invoke-WaInternal { param($b) Get-WaCzkawkaFullySelectedGroup -Item $b.Item } -Bundle @{ Item = $items }) | Should -Be @(1)
    }

    It 'parses item numbers and ranges, and rejects anything else' {
        @(Invoke-WaInternal { ConvertFrom-WaItemNumberList -Text '3, 7-9 8' -Maximum 10 }) | Should -Be @(3, 7, 8, 9)
        @(Invoke-WaInternal { ConvertFrom-WaItemNumberList -Text '5-4' -Maximum 10 }) | Should -Be @(4, 5)
        { Invoke-WaInternal { ConvertFrom-WaItemNumberList -Text '0' -Maximum 10 } } | Should -Throw '*1 to 10*'
        { Invoke-WaInternal { ConvertFrom-WaItemNumberList -Text '9-11' -Maximum 10 } } | Should -Throw '*1 to 10*'
        { Invoke-WaInternal { ConvertFrom-WaItemNumberList -Text 'all' -Maximum 10 } } | Should -Throw '*Not an item number*'
    }
}

Describe 'Czkawka 12.0.2 executable integration' -Tag 'Czkawka', 'Integration' {
    BeforeAll {
        $script:czkawkaBinary = Join-Path $script:WaTestProjectRoot 'Tools\Czkawka\windows_czkawka_cli.exe'
        if (-not (Test-Path -LiteralPath $script:czkawkaBinary)) {
            $script:czkawkaBinary = Join-Path $script:WaTestProjectRoot 'TestResults\czkawka-research\windows_czkawka_cli.exe'
        }
    }
    BeforeEach {
        if (-not (Test-Path -LiteralPath $script:czkawkaBinary)) { Set-ItResult -Skipped -Because 'Install CLI 12.0.2 with Scripts/Install-Czkawka.ps1 to run real executable tests.'; return }
        $script:context = New-CzkawkaTestContext
        $script:context.Session.Config.ProviderConfig['External.Czkawka'].Settings['ExecutablePath'] = $script:czkawkaBinary
    }
    AfterEach { if ($null -ne $script:context) { Remove-WaTestSandbox $script:context.Sandbox } }

    It 'scans all six types through the provider and executes only the selected fixtures' {
        Add-Type -AssemblyName System.Drawing
        $bitmap = New-Object Drawing.Bitmap 80,80
        try {
            for ($x=0; $x -lt 80; $x++) { for ($y=0; $y -lt 80; $y++) {
                $bitmap.SetPixel($x,$y,[Drawing.Color]::FromArgb((($x*$y*3)%256),(($x*$y*7)%256),(($x*$y*11)%256)))
            } }
            $bitmap.Save((Join-Path $script:context.Root 'image-a.png'))
            $bitmap.SetPixel(40,40,[Drawing.Color]::Black)
            $bitmap.Save((Join-Path $script:context.Root 'image-b.png'))
        } finally { $bitmap.Dispose() }
        $scan = Invoke-WaInternal {
            param($s)
            $provider = Get-WaProvider 'External.Czkawka'
            $availability = & $provider.TestAvailable $s
            if (-not $availability.Available) { throw $availability.Reason }
            $inventory = @(& $provider.GetInventory $s)
            $findings = @(& $provider.GetAnalysis $s $inventory)
            $candidates = @(& $provider.GetCleanupCandidates $s $inventory)
            $recommendations = @(& $provider.GetCleanupPlan $s $candidates)
            @{ Findings=$findings; Candidates=$candidates; Recommendations=$recommendations }
        } $script:context.Session
        @($scan.Findings | Where-Object Title -Like '*failed*').Count | Should -Be 0
        @($scan.Candidates.Mode | Select-Object -Unique).Count | Should -Be 6
        @($scan.Recommendations).Count | Should -Be 6
        foreach ($r in $scan.Recommendations) {
            $plan = New-CzkawkaTestPlan $script:context $r
            $result = Invoke-WaPlan -Session $script:context.Session -Plan $plan
            @($result)[0].Status | Should -Be 'Succeeded' -Because $r.Title
        }
        Test-Path -LiteralPath (Join-Path $script:context.Root 'a.txt') | Should -BeTrue
        @(Get-ChildItem -LiteralPath $script:context.Root -Filter '*.png').Count | Should -Be 1
        Test-Path -LiteralPath (Join-Path $script:context.Root 'new-1.tmp') | Should -BeTrue
    }

    It 'finds duplicate copies across multiple roots containing spaces and honours exclusions' {
        $second = Join-Path $script:context.Sandbox 'second root'
        [void](New-Item -ItemType Directory -Path $second)
        $source = Join-Path $script:context.Root 'b.txt'
        $destination = Join-Path $second 'b.txt'
        [IO.File]::Move($source, $destination)
        $script:context.Session.Config.DeepScanPaths += $second
        $script:context.Session.Config.ProviderConfig['External.Czkawka'].Settings['ScanTypes'] = @('duplicates')
        $script:context.Session.Config.ExcludedPaths = @((Join-Path $script:context.Root 'new-1.tmp'))
        Invoke-WaInternal { param($s) Initialize-WaCzkawkaScan $s; Invoke-WaCzkawkaScans $s } $script:context.Session | Out-Null
        $state = $script:context.Session.ProviderState['External.Czkawka']
        @($state.Candidates).Count | Should -Be 2
        $state.Groups.Count | Should -Be 1
    }
}
