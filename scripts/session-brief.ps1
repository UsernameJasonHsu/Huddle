# SessionStart hook: builds the ranked list of open work items assigned to me,
# followed by the Huddle office status (work item states, pending decisions).
# Emits hook JSON on stdout:
#   - hookSpecificOutput.additionalContext: markdown brief injected into the Claude session as context.
#   - systemMessage: plain-text list shown to the user in the terminal at startup.
# Never fails the session.
[Console]::OutputEncoding = [Text.Encoding]::UTF8

$context = [System.Collections.Generic.List[string]]::new()
$display = [System.Collections.Generic.List[string]]::new()

try {
    Import-Module (Join-Path $PSScriptRoot 'WorkItems.psm1') -Force
    $config = Get-WorkItemConfig
    $items = Get-SortedWorkItems -Config $config
    if ($null -eq $items) { $items = @() }

    $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm')
    $context.Add("## Work item brief ($stamp, host: $($config.gitlabHost))")
    $context.Add('')
    $display.Add("Work items ($stamp, $($config.gitlabHost))")

    if ($items.Count -eq 0) {
        $context.Add('No open work items are assigned to me.')
        $display.Add('  No open work items are assigned to me.')
    }
    else {
        # Items that already have an open MR closing them wait for review or merge, not for me to
        # start: they go in a section of their own, after the items that still need work. Each row
        # keeps its number in the ranked order. With no such item (or when the MR lookup is not
        # available) the list is exactly the single table it always was.
        $openMrs = @{}
        $mrErrors = @()
        try {
            $lookup = Get-WorkItemOpenMrs -Config $config -Items $items
            $openMrs = $lookup.Map
            $mrErrors = @($lookup.Errors)
        }
        catch { $mrErrors = @("all items ($($_.Exception.Message))") }

        $rank = 1
        $rows = @(foreach ($w in $items) {
                [pscustomobject]@{ Rank = $rank; Item = $w; Mrs = @($openMrs[$w.Reference] | Where-Object { $_ }) }
                $rank++
            })
        $todo = @($rows | Where-Object { $_.Mrs.Count -eq 0 })
        $inReview = @($rows | Where-Object { $_.Mrs.Count -gt 0 })
        $addDisplay = {
            param($r, [string]$suffix)
            $w = $r.Item
            $due = if ($w.DueDate) { $w.DueDate } else { '-' }
            $display.Add("  $($r.Rank). $($w.Reference)  [$($w.SeveritySource)]  idle $($w.IdleDays)d  due $due$suffix")
            $display.Add("     $($w.Title)")
            $display.Add("     $($w.WebUrl)")
        }

        $context.Add("Open work items assigned to me: $($items.Count). Already ranked by source (Jira before GitLab) -> project priority -> severity -> idle days.")
        $context.Add('')
        if ($inReview.Count) {
            $context.Add("### Not started or still in progress (no open MR): $($todo.Count)")
            $context.Add('')
        }
        if ($todo.Count -or -not $inReview.Count) {
            $context.Add('| # | Reference | Title | Severity (source) | Idle days | Due | URL |')
            $context.Add('|---|---|---|---|---|---|---|')
            foreach ($r in $todo) {
                $w = $r.Item
                $title = $w.Title -replace '\|', '\|'
                $due = if ($w.DueDate) { $w.DueDate } else { '-' }
                $context.Add("| $($r.Rank) | $($w.Reference) | $title | $($w.SeveritySource) | $($w.IdleDays) | $due | $($w.WebUrl) |")
                & $addDisplay $r ''
            }
        }
        else {
            $context.Add('None: every open work item already has an open MR.')
        }
        if ($inReview.Count) {
            $context.Add('')
            $context.Add("### MR already open, waiting for review or merge: $($inReview.Count)")
            $context.Add('')
            $context.Add('`#` is the item''s place in the ranked order above. The MR closes the work item when it is merged.')
            $context.Add('')
            $context.Add('| # | Reference | Title | MR | Severity (source) | Idle days | Due | URL |')
            $context.Add('|---|---|---|---|---|---|---|---|')
            $display.Add("  MR already open, waiting for review or merge ($($inReview.Count)):")
            foreach ($r in $inReview) {
                $w = $r.Item
                $title = $w.Title -replace '\|', '\|'
                $due = if ($w.DueDate) { $w.DueDate } else { '-' }
                $mrText = ($r.Mrs | ForEach-Object { "!$($_.Iid)$(if ($_.Draft) { ' (draft)' })" }) -join ', '
                $context.Add("| $($r.Rank) | $($w.Reference) | $title | $mrText | $($w.SeveritySource) | $($w.IdleDays) | $due | $($w.WebUrl) |")
                & $addDisplay $r "  MR $mrText"
            }
        }
        if ($mrErrors.Count) {
            $context.Add('')
            $context.Add("MR lookup failed for: $($mrErrors -join ', '). These items are listed as having no open MR; that is not confirmed.")
            $display.Add("  MR lookup failed for $($mrErrors.Count) item(s); listed as having no open MR.")
        }
    }
}
catch {
    $context.Clear()
    $display.Clear()
    $msg = "Fetching work items failed: $($_.Exception.Message)"
    $check = 'Check `glab auth status --hostname gitlab.example.com`.'
    $context.Add('## Work item brief unavailable')
    $context.Add('')
    $context.Add($msg)
    $context.Add($check)
    $display.Add('Work item brief unavailable')
    $display.Add("  $msg")
    $display.Add("  $check")
}

# Office status (Huddle) goes after the ranked list, which stays byte-for-byte as before.
# A broken office folder must not hide the work item list, so it is isolated in its own try.
$context.Add('')
$display.Add('')
try {
    Import-Module (Join-Path $PSScriptRoot 'Office.psm1') -Force
    $officeRoot = Join-Path (Split-Path -Parent $PSScriptRoot) 'office'

    # Delivered MRs are read live here (T20), so a merge shows up without waiting for /huddle-tick.
    # A failed read keeps the last recorded status; the brief says so instead of failing.
    $mrNotes = @()
    try {
        Import-Module (Join-Path $PSScriptRoot 'Huddle.psm1') -Force
        $wcfg = Get-WorkItemConfig
        $mrCache = @{}
        # Waits too (T21): a work item whose MR was merged is shown as ready.
        $mrNotes = @((Update-HuddleWaits -OfficeRoot $officeRoot -WorkItemConfig $wcfg -MrCache $mrCache).errors) +
            @((Update-HuddleDeliveredMrs -OfficeRoot $officeRoot -WorkItemConfig $wcfg -MrCache $mrCache).errors)
    }
    catch { $mrNotes = @($_.Exception.Message) }

    $office = Format-OfficeBrief -Summary (Get-OfficeSummary -OfficeRoot $officeRoot)
    $context.AddRange([string[]]$office.Context)
    $display.AddRange([string[]]$office.Display)
    if ($mrNotes.Count) {
        $context.Add('')
        $context.Add("MR status could not be refreshed; the MR column shows the last recorded check. $($mrNotes -join ' | ')")
        $display.Add('  MR status could not be refreshed; showing the last recorded check.')
    }
}
catch {
    $context.Add('## Office status unavailable')
    $context.Add('')
    $context.Add("Reading the office folder failed: $($_.Exception.Message)")
    $display.Add("Office status unavailable: $($_.Exception.Message)")
}

[ordered]@{
    systemMessage      = ($display -join "`n")
    hookSpecificOutput = [ordered]@{
        hookEventName     = 'SessionStart'
        additionalContext = ($context -join "`n")
    }
} | ConvertTo-Json -Depth 4 -Compress
