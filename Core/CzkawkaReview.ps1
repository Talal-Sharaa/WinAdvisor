<#
    Core/CzkawkaReview.ps1 - choosing which Czkawka results to delete.

    Czkawka's GUI lets you tick results in bulk: "select all except the oldest" in every
    duplicate group, invert, a path pattern. These are the same rules for the terminal,
    following Krokiet 12.0.2 (krokiet/src/connect_select) so they behave the way Czkawka
    users expect:

      * "Select all except X" clears the selection, then in every group selects each file
        but the one with the extreme value. On a tie the first file in the group is spared.
        Path length compares the folder first, then the file name.
      * "Invert selection in group" flips only groups that already have a selection.
      * "Custom" selects or unselects by wildcard on the full path. Selecting never takes
        the last unselected file of a group (Krokiet's "leave one in group").

    The screen decides only what goes into the action. What runs is still one plan action
    per result type, rebuilt with exactly the selected items and approved individually with
    YES. A group whose every file is selected cannot be confirmed, and execution refuses to
    delete a group member unless another member was left unselected and is unchanged.
#>

$script:WaCzkawkaSelectionRules = [ordered]@{
    ExceptLongestPath        = @{ Label = 'Select all except longest path';        Property = 'PathLength'; SpareMax = $true }
    ExceptShortestPath       = @{ Label = 'Select all except shortest path';       Property = 'PathLength'; SpareMax = $false }
    ExceptBiggestResolution  = @{ Label = 'Select all except biggest resolution';  Property = 'Resolution'; SpareMax = $true }
    ExceptSmallestResolution = @{ Label = 'Select all except smallest resolution'; Property = 'Resolution'; SpareMax = $false }
    ExceptBiggestSize        = @{ Label = 'Select all except biggest size';        Property = 'Size';       SpareMax = $true }
    ExceptSmallestSize       = @{ Label = 'Select all except smallest size';       Property = 'Size';       SpareMax = $false }
    ExceptNewest             = @{ Label = 'Select all except newest';              Property = 'Date';       SpareMax = $true }
    ExceptOldest             = @{ Label = 'Select all except oldest';              Property = 'Date';       SpareMax = $false }
    InvertInGroup            = @{ Label = 'Invert selection in group' }
    Invert                   = @{ Label = 'Invert selection' }
    DeselectAll              = @{ Label = 'Deselect all' }
    SelectAll                = @{ Label = 'Select all' }
    Custom                   = @{ Label = 'Custom select/unselect' }
}

function Test-WaCzkawkaReviewAction {
    <# True for a plan action made of Czkawka deletions, which are chosen on the review screen. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Action)
    $recommendation = $Action.Recommendation
    if ($recommendation.Provider -ne 'External.Czkawka') { return $false }
    $operations = @($recommendation.Operations)
    return ($operations.Count -gt 0 -and @($operations | Where-Object { $_.Kind -ne 'CzkawkaDelete' }).Count -eq 0)
}

function Get-WaCzkawkaSelectionRule {
    <# The rules offered for one result type, in the order Czkawka lists them. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Mode)
    switch ($Mode) {
        'similar-images' { return @($script:WaCzkawkaSelectionRules.Keys) }
        'duplicates'     { return @($script:WaCzkawkaSelectionRules.Keys | Where-Object { $_ -notlike '*Resolution' }) }
        default          { return @('Invert', 'DeselectAll', 'SelectAll', 'Custom') }
    }
}

function Get-WaCzkawkaReviewItem {
    <# One selectable row per operation in the action, numbered in display order. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Action)

    $items = New-Object 'System.Collections.Generic.List[object]'
    $groupNumbers = @{}
    foreach ($operation in @($Action.Recommendation.Operations)) {
        $parameters = $operation.Parameters
        $target = $parameters.Target
        $group = [string](Get-WaProperty $parameters 'Group' '')
        $key = if ($group) { $group } else { 'item:' + $target.Path }
        if (-not $groupNumbers.ContainsKey($key)) { $groupNumbers[$key] = $groupNumbers.Count + 1 }
        $lastWrite = [string](Get-WaProperty $target 'LastWriteUtc' '')
        $width = Get-WaProperty $target 'Width'
        $height = Get-WaProperty $target 'Height'
        $items.Add([pscustomobject]@{
            Number      = $items.Count + 1
            Group       = $key
            GroupNumber = $groupNumbers[$key]
            Grouped     = [bool]$group
            Operation   = $operation
            Path        = [string]$target.Path
            Length      = [long]$target.Length
            ModifiedUtc = $(if ($lastWrite) { [datetime]::Parse($lastWrite, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind) } else { $null })
            Width       = $width
            Height      = $height
            Pixels      = $(if ($null -ne $width -and $null -ne $height) { [long]$width * [long]$height } else { $null })
            Nested      = [Math]::Max(0, @(Get-WaProperty $parameters 'Directories' @()).Count - 1)
            Diagnosis   = [string](Get-WaProperty $parameters 'Diagnosis' '')
            Selected    = $false
        })
    }
    return $items.ToArray()
}

function Get-WaCzkawkaItemGroup {
    <#
        The items split into their groups, in display order; ungrouped items stand alone.
        Returned as one list of arrays: emitting the arrays one by one would unroll a lone
        group into its items.
    #>
    [CmdletBinding()]
    param([object[]]$Item = @())
    $groups = New-Object 'System.Collections.Specialized.OrderedDictionary'
    foreach ($entry in $Item) {
        if (-not $groups.Contains($entry.Group)) { $groups[$entry.Group] = New-Object 'System.Collections.Generic.List[object]' }
        $groups[$entry.Group].Add($entry)
    }
    $result = New-Object 'System.Collections.Generic.List[object]'
    foreach ($members in $groups.Values) { $result.Add($members.ToArray()) }
    Write-Output -NoEnumerate $result
}

function Get-WaCzkawkaItemValue {
    <# The value a "select all except" rule compares. Unknown values compare as zero. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Item, [Parameter(Mandatory)][string]$Property)
    switch ($Property) {
        'PathLength' {
            $directory = [string][IO.Path]::GetDirectoryName($Item.Path)
            $name = [string][IO.Path]::GetFileName($Item.Path)
            return ([long]$directory.Length * 65536 + $name.Length)
        }
        'Size'       { return [long]$Item.Length }
        'Date'       { if ($null -eq $Item.ModifiedUtc) { return [long]0 } return [long]$Item.ModifiedUtc.Ticks }
        'Resolution' { if ($null -eq $Item.Pixels) { return [long]0 } return [long]$Item.Pixels }
    }
    throw "Unknown selection property: $Property"
}

function Set-WaCzkawkaSelection {
    <#
    .SYNOPSIS
        Applies one selection rule to the review items, in place.

    .PARAMETER Pattern
        For Custom: a wildcard matched against the full path, case-insensitively.

    .PARAMETER Unselect
        For Custom: unselect matching items instead of selecting them.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$Item,
        [Parameter(Mandatory)][string]$Rule,
        [string]$Pattern = '',
        [switch]$Unselect
    )

    if (-not $script:WaCzkawkaSelectionRules.Contains($Rule)) { throw "Unknown selection rule: $Rule" }
    $definition = $script:WaCzkawkaSelectionRules[$Rule]

    switch ($Rule) {
        'SelectAll'   { foreach ($entry in $Item) { $entry.Selected = $true } }
        'DeselectAll' { foreach ($entry in $Item) { $entry.Selected = $false } }
        'Invert'      { foreach ($entry in $Item) { $entry.Selected = -not $entry.Selected } }
        'InvertInGroup' {
            foreach ($group in (Get-WaCzkawkaItemGroup -Item $Item)) {
                if (@($group | Where-Object { $_.Selected }).Count -eq 0) { continue }
                foreach ($entry in $group) { $entry.Selected = -not $entry.Selected }
            }
        }
        'Custom' {
            if ([string]::IsNullOrWhiteSpace($Pattern)) { throw 'A custom selection needs a pattern.' }
            foreach ($group in (Get-WaCzkawkaItemGroup -Item $Item)) {
                $matching = @($group | Where-Object { $_.Path -like $Pattern })
                if ($Unselect) {
                    foreach ($entry in $matching) { $entry.Selected = $false }
                    continue
                }
                $toSelect = @($matching | Where-Object { -not $_.Selected })
                $unselected = @($group | Where-Object { -not $_.Selected }).Count
                if ($group[0].Grouped -and $toSelect.Count -gt 0 -and $toSelect.Count -eq $unselected) {
                    $toSelect = @($toSelect | Select-Object -First ($toSelect.Count - 1))
                }
                foreach ($entry in $toSelect) { $entry.Selected = $true }
            }
        }
        default {
            foreach ($group in (Get-WaCzkawkaItemGroup -Item $Item)) {
                $spare = $null
                $extreme = $null
                foreach ($entry in $group) {
                    $value = Get-WaCzkawkaItemValue -Item $entry -Property $definition.Property
                    if ($null -eq $spare -or ($definition.SpareMax -and $value -gt $extreme) -or (-not $definition.SpareMax -and $value -lt $extreme)) {
                        $spare = $entry
                        $extreme = $value
                    }
                }
                foreach ($entry in $group) { $entry.Selected = -not [object]::ReferenceEquals($entry, $spare) }
            }
        }
    }
}

function Get-WaCzkawkaFullySelectedGroup {
    <# Numbers of the groups in which every file is selected. Those cannot be confirmed. #>
    [CmdletBinding()]
    param([object[]]$Item = @())
    @(foreach ($group in (Get-WaCzkawkaItemGroup -Item $Item)) {
        if ($group[0].Grouped -and @($group | Where-Object { -not $_.Selected }).Count -eq 0) { $group[0].GroupNumber }
    })
}

function ConvertFrom-WaItemNumberList {
    <# Parses "3, 7-12" into item numbers. Throws on anything else or out of range. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text, [Parameter(Mandatory)][int]$Maximum)
    $numbers = New-Object 'System.Collections.Generic.List[int]'
    foreach ($part in @($Text -split '[,\s]+' | Where-Object { $_ })) {
        if ($part -match '^(\d+)-(\d+)$') {
            $from = [int]$Matches[1]; $to = [int]$Matches[2]
            if ($from -gt $to) { $from, $to = $to, $from }
        } elseif ($part -match '^\d+$') {
            $from = [int]$part; $to = $from
        } else {
            throw "Not an item number or range: $part"
        }
        if ($from -lt 1 -or $to -gt $Maximum) { throw "Item numbers run from 1 to ${Maximum}: $part" }
        for ($n = $from; $n -le $to; $n++) { $numbers.Add($n) }
    }
    if ($numbers.Count -eq 0) { throw 'Give item numbers, for example: t 3, 7-12' }
    return @($numbers.ToArray() | Select-Object -Unique)
}

function Complete-WaCzkawkaSelection {
    <#
    .SYNOPSIS
        Turns a confirmed selection into the approved plan action.

    .DESCRIPTION
        The unselected files of every group with a selection are reserved first: nothing in
        this session can delete them, and every deletion in their group is checked against
        one of them. The action is then rebuilt with exactly the selected operations and
        approved individually.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)]$Plan,
        [Parameter(Mandatory)]$Action,
        [Parameter(Mandatory)][object[]]$Item
    )

    $full = @(Get-WaCzkawkaFullySelectedGroup -Item $Item)
    if ($full.Count -gt 0) {
        throw ('Every file is selected in group(s) {0}. Leave at least one file in each group unselected.' -f ($full -join ', '))
    }
    $selected = @($Item | Where-Object { $_.Selected })
    if ($selected.Count -eq 0) { throw 'Nothing is selected.' }

    $state = $Session.ProviderState['External.Czkawka']
    foreach ($group in (Get-WaCzkawkaItemGroup -Item $Item)) {
        if (-not $group[0].Grouped -or @($group | Where-Object { $_.Selected }).Count -eq 0) { continue }
        foreach ($entry in $group) {
            if (-not $entry.Selected) { $state.ReservedPaths[$entry.Path] = $true }
        }
    }

    $mode = [string]$selected[0].Operation.Parameters.Mode
    $recommendation = New-WaCzkawkaModeRecommendation -Session $Session -Mode $mode `
        -Operations @($selected | ForEach-Object { $_.Operation }) -CandidateCount $Item.Count
    [void](Set-WaPlanActionRecommendation -Session $Session -Plan $Plan -ActionId $Action.Id -Recommendation $recommendation)
    return (Grant-WaApproval -Session $Session -Plan $Plan -ActionId $Action.Id -Decision 'Approved' -Scope 'Individual' `
        -Note ('{0} of {1} item(s) chosen on the review screen.' -f $selected.Count, $Item.Count))
}

function Show-WaCzkawkaReviewPage {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Mode, [Parameter(Mandatory)][object[]]$Item, [int]$Page = 1, [int]$PageSize = 25)

    $pageCount = [Math]::Max(1, [int][Math]::Ceiling($Item.Count / $PageSize))
    $slice = @($Item | Select-Object -Skip (($Page - 1) * $PageSize) -First $PageSize)
    $grouped = Test-WaCzkawkaGroupMode $Mode
    $groupSizes = @{}
    foreach ($entry in $Item) { $groupSizes[$entry.Group] = 1 + [int]$groupSizes[$entry.Group] }

    Write-Host ''
    $lastGroup = $null
    foreach ($entry in $slice) {
        if ($grouped -and $entry.Group -ne $lastGroup) {
            $header = if ($Mode -eq 'duplicates') {
                'Group {0}   {1} identical files of {2}' -f $entry.GroupNumber, $groupSizes[$entry.Group], (Format-WaBytes $entry.Length)
            } else {
                'Group {0}   {1} similar images' -f $entry.GroupNumber, $groupSizes[$entry.Group]
            }
            Write-Host ('    {0}' -f $header) -ForegroundColor Cyan
            $lastGroup = $entry.Group
        }
        $indent = if ($grouped) { '      ' } else { '    ' }
        Write-Host ('{0}[{1,4}] ' -f $indent, $entry.Number) -NoNewline -ForegroundColor DarkGray
        if ($entry.Selected) { Write-Host '[x] ' -NoNewline -ForegroundColor Red } else { Write-Host '[ ] ' -NoNewline -ForegroundColor DarkGray }
        if ($Mode -ne 'empty-folders') {
            $modified = if ($null -ne $entry.ModifiedUtc) { $entry.ModifiedUtc.ToLocalTime().ToString('yyyy-MM-dd HH:mm') } else { '' }
            $columns = '{0,10}  {1,-16}  ' -f (Format-WaBytes $entry.Length), $modified
            if ($Mode -eq 'similar-images') {
                $columns += '{0,-11}  ' -f $(if ($null -ne $entry.Pixels) { '{0}x{1}' -f $entry.Width, $entry.Height } else { '' })
            }
            Write-Host $columns -NoNewline -ForegroundColor DarkGray
        }
        $path = $entry.Path
        if ($entry.Nested -gt 0) { $path += ' (+{0} empty folder(s) inside)' -f $entry.Nested }
        Write-Host $path -ForegroundColor $(if ($entry.Selected) { 'White' } else { 'Gray' })
        if ($entry.Diagnosis) {
            $diagnosis = if ($entry.Diagnosis.Length -gt 110) { $entry.Diagnosis.Substring(0, 107) + '...' } else { $entry.Diagnosis }
            Write-Host ('{0}           {1}' -f $indent, $diagnosis) -ForegroundColor DarkGray
        }
    }

    $selected = @($Item | Where-Object { $_.Selected })
    $bytes = [long](($selected | ForEach-Object { $_.Length }) | Measure-Object -Sum).Sum
    Write-Host ''
    Write-Host ('  Selected {0} of {1} ({2}).   Page {3} of {4}.' -f $selected.Count, $Item.Count, (Format-WaBytes $bytes), $Page, $pageCount) -ForegroundColor White
    $full = @(Get-WaCzkawkaFullySelectedGroup -Item $Item)
    if ($full.Count -gt 0) {
        $list = (@($full | Select-Object -First 10) -join ', ') + $(if ($full.Count -gt 10) { ', ...' } else { '' })
        Write-Host ('  Every file is selected in group(s) {0}. Unselect at least one in each before finishing.' -f $list) -ForegroundColor Yellow
    }
}

function Show-WaCzkawkaSelectionMenu {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$Rule)

    $labels = @(for ($i = 0; $i -lt $Rule.Count; $i++) { '[{0,2}] {1}' -f ($i + 1), $script:WaCzkawkaSelectionRules[$Rule[$i]].Label })
    Write-Host ''
    if ((Get-WaConsoleWidth) -ge 96) {
        for ($i = 0; $i -lt $labels.Count; $i += 2) {
            $right = if ($i + 1 -lt $labels.Count) { $labels[$i + 1] } else { '' }
            Write-Host ('    {0}{1}' -f $labels[$i].PadRight(46), $right) -ForegroundColor Gray
        }
    } else {
        foreach ($label in $labels) { Write-Host ('    {0}' -f $label) -ForegroundColor Gray }
    }
    Write-Host '    t 3, 7-12  toggle items    n / p  next or previous page    l  show this page again' -ForegroundColor DarkGray
    Write-Host '    d  done                    x  delete nothing of this type' -ForegroundColor DarkGray
}

function Read-WaCzkawkaCustomSelection {
    <# Asks for a custom select/unselect. Returns $null when the user backs out. #>
    [CmdletBinding()]
    param()
    Write-Host ''
    Write-Host '  Custom select/unselect matches a wildcard against the full path, ignoring case:' -ForegroundColor Gray
    Write-Host '  * is any text and ? is one character, for example  *\Downloads\*  or  *.tmp' -ForegroundColor DarkGray
    Write-Host '  Selecting never takes the last unselected file in a group.' -ForegroundColor DarkGray
    $direction = (Read-Host '  [S] select matching or [U] unselect matching (Enter to go back)').Trim().ToUpperInvariant()
    if ($direction -notin @('S', 'U')) { return $null }
    $pattern = (Read-Host '  Pattern').Trim()
    if (-not $pattern) { return $null }
    return [pscustomobject]@{ Pattern = $pattern; Unselect = ($direction -eq 'U') }
}

function Invoke-WaCzkawkaSelection {
    <#
    .SYNOPSIS
        The review screen for one Czkawka result type. Returns $true when a selection was approved.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)]$Plan, [Parameter(Mandatory)]$Action)

    $recommendation = $Action.Recommendation
    $mode = [string]@($recommendation.Operations)[0].Parameters.Mode
    $items = @(Get-WaCzkawkaReviewItem -Action $Action)
    $rules = @(Get-WaCzkawkaSelectionRule -Mode $mode)
    $pageSize = 25
    $pageCount = [Math]::Max(1, [int][Math]::Ceiling($items.Count / $pageSize))
    $page = 1

    Write-WaHeading ('Choose what to delete: ' + $recommendation.Title)
    Write-Host ('  {0}' -f $recommendation.Description) -ForegroundColor Gray
    foreach ($warning in @($recommendation.Warnings)) { Write-Host ('  ! {0}' -f $warning) -ForegroundColor Yellow }
    Write-Host '  Nothing is selected yet. Selected items are deleted permanently, not moved to the Recycle Bin.' -ForegroundColor Red

    $done = $false
    $redraw = $true
    while (-not $done) {
        if ($redraw) {
            Show-WaCzkawkaReviewPage -Mode $mode -Item $items -Page $page -PageSize $pageSize
            Show-WaCzkawkaSelectionMenu -Rule $rules
        }
        $redraw = $true
        $answer = (Read-Host '  Choose').Trim()

        if ($answer -match '^\d+$') {
            $number = [int]$answer
            if ($number -lt 1 -or $number -gt $rules.Count) {
                Write-Host '  Not a listed option. To toggle items, type t followed by their numbers.' -ForegroundColor Yellow
                $redraw = $false
                continue
            }
            $rule = $rules[$number - 1]
            $before = @($items | ForEach-Object { $_.Selected })
            if ($rule -eq 'Custom') {
                $custom = Read-WaCzkawkaCustomSelection
                if ($null -eq $custom) { continue }
                Set-WaCzkawkaSelection -Item $items -Rule 'Custom' -Pattern $custom.Pattern -Unselect:$custom.Unselect
            } else {
                Set-WaCzkawkaSelection -Item $items -Rule $rule
            }
            $changed = 0
            for ($i = 0; $i -lt $items.Count; $i++) { if ($items[$i].Selected -ne $before[$i]) { $changed++ } }
            Write-Host ('  {0}: {1} item(s) changed.' -f $script:WaCzkawkaSelectionRules[$rule].Label, $changed) -ForegroundColor Cyan
            continue
        }

        switch -Regex ($answer) {
            '^[tT]\s*(.*)$' {
                try {
                    $numbers = @(ConvertFrom-WaItemNumberList -Text $Matches[1] -Maximum $items.Count)
                    foreach ($n in $numbers) { $items[$n - 1].Selected = -not $items[$n - 1].Selected }
                    Write-Host ('  Toggled {0} item(s).' -f $numbers.Count) -ForegroundColor Cyan
                } catch {
                    Write-Host ('  {0}' -f $_.Exception.Message) -ForegroundColor Yellow
                    $redraw = $false
                }
            }
            '^[nN]$' { if ($page -lt $pageCount) { $page++ } else { Write-Host '  This is the last page.' -ForegroundColor DarkGray; $redraw = $false } }
            '^[pP]$' { if ($page -gt 1) { $page-- } else { Write-Host '  This is the first page.' -ForegroundColor DarkGray; $redraw = $false } }
            '^[lL]$' { }
            '^[dD]$' {
                $full = @(Get-WaCzkawkaFullySelectedGroup -Item $items)
                if ($full.Count -gt 0) {
                    Write-Host ('  Every file is selected in group(s) {0}. Leave at least one file in each group unselected, then finish.' -f ($full -join ', ')) -ForegroundColor Yellow
                    $redraw = $false
                } else {
                    $done = $true
                }
            }
            '^[xX]$' {
                [void](Grant-WaApproval -Session $Session -Plan $Plan -ActionId $Action.Id -Decision 'Declined' -Note 'Left without a selection on the review screen.')
                Write-Host '  Nothing of this type will be deleted.' -ForegroundColor DarkGray
                return $false
            }
            default {
                Write-Host '  Not a listed option.' -ForegroundColor Yellow
                $redraw = $false
            }
        }
    }

    $selected = @($items | Where-Object { $_.Selected })
    if ($selected.Count -eq 0) {
        [void](Grant-WaApproval -Session $Session -Plan $Plan -ActionId $Action.Id -Decision 'Declined' -Note 'Nothing was selected on the review screen.')
        Write-Host '  Nothing selected. Nothing of this type will be deleted.' -ForegroundColor DarkGray
        return $false
    }

    $bytes = [long](($selected | ForEach-Object { $_.Length }) | Measure-Object -Sum).Sum
    Write-Host ''
    Write-Host ('  Selected for permanent deletion: {0} item(s), {1}.' -f $selected.Count, (Format-WaBytes $bytes)) -ForegroundColor White
    foreach ($entry in @($selected | Select-Object -First 15)) { Write-Host ('    - {0}' -f $entry.Path) -ForegroundColor Gray }
    if ($selected.Count -gt 15) { Write-Host ('    ... and {0} more, as shown on the pages above.' -f ($selected.Count - 15)) -ForegroundColor DarkGray }
    if (Test-WaCzkawkaGroupMode $mode) {
        Write-Host '  The unselected files in each group are kept, and every deletion is checked against one of them first.' -ForegroundColor DarkGray
    }
    Write-Host '  This is a HIGH-risk change. Type the word YES in full to delete these items. Anything else declines.' -ForegroundColor Red
    $confirmation = (Read-Host '  Approve?').Trim()
    if ($confirmation -cne 'YES') {
        [void](Grant-WaApproval -Session $Session -Plan $Plan -ActionId $Action.Id -Decision 'Declined' -Note 'Selection not confirmed.')
        Write-Host '  Declined. Nothing of this type will be deleted.' -ForegroundColor DarkGray
        return $false
    }

    try {
        [void](Complete-WaCzkawkaSelection -Session $Session -Plan $Plan -Action $Action -Item $items)
        Write-Host ('  Approved: {0} item(s).' -f $selected.Count) -ForegroundColor Green
        return $true
    } catch {
        Write-Host ('  Could not approve: {0}' -f $_.Exception.Message) -ForegroundColor Yellow
        return $false
    }
}
