# Office Manager steps that talk to GitLab (read-only): the /huddle-take prep (SPEC §3.8 steps 1, 3)
# and the deterministic part of /huddle-tick (inbox, issue update detection, G2 on late changes).
# Agents are dispatched by the Claude session, not here; these functions only prepare their input.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'WorkItems.psm1')
Import-Module (Join-Path $PSScriptRoot 'Office.psm1')

function Format-IssueTimestamp($Value) {
    # glab output goes through ConvertFrom-Json, which turns ISO timestamps into DateTime.
    if ($Value -is [datetime]) { return $Value.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ') }
    if ($Value -is [DateTimeOffset]) { return $Value.UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ss.fffZ') }
    [string]$Value
}

# One phrase for thread.md: which commit the agent reads, and why it may be behind.
function Format-ReadBase($ReadBase) {
    $at = if ($ReadBase.baseCommit) { "read at $($ReadBase.baseCommit.Substring(0, 7)) ($($ReadBase.baseRef))" } else { 'no base commit to read' }
    if ($ReadBase.error) { "$at; $($ReadBase.error)" } else { $at }
}

function Get-IssueApi([string]$ProjectPath, [int]$Iid) {
    "projects/$([uri]::EscapeDataString($ProjectPath))/issues/$Iid"
}

function Get-GitLabIssue([hashtable]$WorkItemConfig, [string]$ProjectPath, [int]$Iid) {
    (Invoke-GitLabApi -GitLabHost $WorkItemConfig.gitlabHost -Endpoint (Get-IssueApi $ProjectPath $Iid))[0]
}

function Get-GitLabMr([hashtable]$WorkItemConfig, [string]$ProjectPath, [int]$Iid) {
    (Invoke-GitLabApi -GitLabHost $WorkItemConfig.gitlabHost -Endpoint "projects/$([uri]::EscapeDataString($ProjectPath))/merge_requests/$Iid")[0]
}

# Get-GitLabMr through a per-pass cache, so one MR is read once however many work items refer to it.
# A failed read is not cached.
function Get-GitLabMrCached([hashtable]$Cache, [hashtable]$WorkItemConfig, [string]$ProjectPath, [int]$Iid) {
    $key = "$ProjectPath!$Iid"
    if (-not $Cache.ContainsKey($key)) { $Cache[$key] = Get-GitLabMr $WorkItemConfig $ProjectPath $Iid }
    $Cache[$key]
}

# 'group/project!iid', an MR URL, or '!iid' (an MR in -DefaultProject).
function ConvertFrom-MrRef([string]$Ref, [string]$DefaultProject) {
    $r = $Ref.Trim()
    if ($r -match '^https?://[^/]+/(?<p>.+?)/-/merge_requests/(?<iid>\d+)(?:[/?#].*)?$') { $project = $Matches.p; $iid = [int]$Matches.iid }
    elseif ($r -match '^(?<p>[^!\s]+/[^!\s]+)!(?<iid>\d+)$') { $project = $Matches.p; $iid = [int]$Matches.iid }
    elseif ($r -match '^!(?<iid>\d+)$') { $project = $DefaultProject; $iid = [int]$Matches.iid }
    else { throw "Cannot read merge request reference '$Ref'. Use 'group/project!iid', '!iid' or the MR URL." }
    if ($iid -lt 1) { throw "Merge request iid must be positive (got $iid)." }
    [pscustomobject]@{ ProjectPath = $project; Iid = $iid }
}

# Prepares the next agent run for one work item and returns the JSON-ready result that
# huddle-take.ps1 prints (see that script for the fields).
#   -Mode take     /huddle-take: register if needed, then by state
#                    NEW, or BLOCKED before its first brief      -> run-intake
#                    BRIEFED, PLANNED with planNeedsReview,
#                    or BLOCKED by the Builder                    -> run-planner (Builder, plan mode)
#                    PLANNED with a ready plan                    -> g1 (raises G1 or queues it; see g1.result)
#                    PLANNED with a decision pending              -> pending-decision
#   -Mode brief    /huddle-tick: like take, but never plans: BRIEFED -> briefed, anything else -> none
#   -Mode rebrief  run Intake again for BRIEFED, PLANNED, or BLOCKED from one of those
# Errors come back as ok = false; retryable = false when trying again cannot help
# (bad reference, closed issue, wrong state).
function Invoke-HuddleTakePrep {
    param(
        [Parameter(Mandatory)][string]$Ref,
        [Parameter(Mandatory)][string]$OfficeRoot,
        [Parameter(Mandatory)][hashtable]$WorkItemConfig,
        [Parameter(Mandatory)][hashtable]$OfficeConfig,
        [AllowEmptyCollection()][object[]]$SortedItems = @(),
        [ValidateSet('take', 'brief', 'rebrief')][string]$Mode = 'take',
        [string]$Reason,
        [datetime]$Now = (Get-Date)
    )
    $retryable = $false
    try {
        $target = ConvertFrom-OfficeWorkItemRef -Ref $Ref -AssignedReferences @($SortedItems | ForEach-Object Reference)
        $reference = "$($target.ProjectPath)#$($target.Iid)"

        $retryable = $true
        $issueApi = Get-IssueApi $target.ProjectPath $target.Iid
        $issue = Get-GitLabIssue $WorkItemConfig $target.ProjectPath $target.Iid
        $retryable = $false
        if ($issue.state -ne 'opened') { throw "$reference is $($issue.state); only open work items can be taken." }
        $issueUpdatedAt = Format-IssueTimestamp $issue.updated_at

        $radar = $null
        for ($k = 0; $k -lt $SortedItems.Count; $k++) {
            if ($SortedItems[$k].Reference -ieq $reference) {
                $radar = [ordered]@{
                    rank = $k + 1; total = $SortedItems.Count
                    severitySource = $SortedItems[$k].SeveritySource; idleDays = $SortedItems[$k].IdleDays
                }
                break
            }
        }

        if ($Mode -cne 'rebrief') {
            $item = Register-OfficeWorkItem -OfficeRoot $OfficeRoot -ProjectPath $target.ProjectPath -Iid $target.Iid `
                -Title $issue.title -WebUrl $issue.web_url -IssueUpdatedAt $issueUpdatedAt -Now $Now
        }
        else {
            $item = Get-OfficeWorkItem -OfficeRoot $OfficeRoot -Id (Get-OfficeWorkItemId -ProjectPath $target.ProjectPath -Iid $target.Iid)
        }
        $workDir = Join-Path $OfficeRoot 'work' $item.id

        # T21 (SPEC §3.11): a work item that waits for an MR is not briefed, planned or raised to G1.
        $unmet = Get-OfficeUnmetWaits $item
        if ($unmet.Count) {
            $names = ($unmet | ForEach-Object { "$($_['project'])!$($_['iid'])" }) -join ', '
            return [ordered]@{
                ok       = $true
                action   = 'waiting'
                mode     = $Mode
                reason   = $Reason
                id       = $item.id
                state    = $item.state
                project  = $target.ProjectPath
                iid      = $target.Iid
                title    = $issue.title
                webUrl   = $issue.web_url
                waitsFor = @($unmet)
                message  = "$reference waits for $names to be merged. Nothing was started. To start anyway, clear the wait first: scripts/wait-for.ps1 -Ref $reference -Clear"
            }
        }

        # Intake: NEW, or BLOCKED before its first brief (take, brief); a re-brief for BRIEFED / PLANNED,
        # or BLOCKED from NEW / BRIEFED / PLANNED (rebrief).
        $runnable = if ($Mode -ceq 'rebrief') {
            ($item.state -cin 'BRIEFED', 'PLANNED') -or ($item.state -ceq 'BLOCKED' -and $item.resumeTo -cin 'NEW', 'BRIEFED', 'PLANNED')
        }
        else {
            ($item.state -ceq 'NEW') -or ($item.state -ceq 'BLOCKED' -and $item.resumeTo -ceq 'NEW')
        }
        if ($Mode -ceq 'rebrief' -and -not $runnable) {
            throw "$reference is $($item.state); a re-brief needs BRIEFED, PLANNED, or BLOCKED from one of those."
        }
        $plan = $false
        $g1 = $null
        if ($runnable) { $action = 'run-intake' }
        elseif ($Mode -ceq 'brief') { $action = if ($item.state -ceq 'BRIEFED') { 'briefed' } else { 'none' } }
        else {
            $plan = ($item.state -ceq 'BRIEFED') -or
                    ($item.state -ceq 'PLANNED' -and $null -eq $item.pendingDecision -and $item['planNeedsReview']) -or
                    ($item.state -ceq 'BLOCKED' -and $item['blockedBy'] -ceq 'builder' -and $item.resumeTo -cin 'BRIEFED', 'PLANNED')
            if ($plan) { $action = 'run-planner' }
            elseif ($item.state -ceq 'PLANNED' -and $null -ne $item.pendingDecision) { $action = 'pending-decision' }
            elseif ($item.state -ceq 'PLANNED') {
                $action = 'g1'
                $q = Request-OfficeG1 -OfficeRoot $OfficeRoot -Id $item.id -Config $OfficeConfig -Now $Now
                $g1 = [ordered]@{ result = $q.Result; decision = $q.DecisionId; activeBuilds = @($q.ActiveBuilds) }
            }
            else { $action = 'none' }
        }

        $repo = $null
        $replyFile = $null
        $prof = $null
        if ($runnable -or $plan) {
            $agent = if ($plan) { 'builder' } else { 'intake' }
            $retryable = $true
            $r = Initialize-OfficeProjectRepo -Config $OfficeConfig -ProjectPath $target.ProjectPath -GitLabHost $WorkItemConfig.gitlabHost
            $retryable = $false
            $baseBranch = if ($r.Registered) { $r.Project.baseBranch } else { $null }
            # T15b: the agent reads the code at a fetched commit, not the clone's never-updated checkout.
            $rb = Update-OfficeReadBase -RepoPath $r.RepoPath -BaseBranch $baseBranch -NoFetch:$r.Cloned
            $repo = [ordered]@{
                registered       = $r.Registered
                repoPath         = $r.RepoPath
                cloned           = $r.Cloned
                baseBranch       = $baseBranch
                baseRef          = $rb.baseRef
                baseCommit       = $rb.baseCommit
                fetched          = $rb.fetched
                readBaseError    = $rb.error
                profileDraftPath = if ($r.Registered) { $null } else { Join-Path $workDir 'project-profile.json' }
            }
            if ($plan) {
                # T15c: the commit the plan reads; build-step.ps1 compares the worktree's base with it.
                Set-OfficePlanBase -OfficeRoot $OfficeRoot -Id $item.id -Commit $rb.baseCommit -Now $Now
                $pp = Join-Path $workDir 'project-profile.json'
                $prof = [ordered]@{
                    needed = (Read-OfficeProjectProfile -Config $OfficeConfig -ProjectPath $target.ProjectPath -Path $pp).Needed
                    path   = $pp
                    exists = Test-Path -LiteralPath $pp -PathType Leaf
                }
            }
            # Where the Office Manager saves the agent's reply; named from the real clock, not a guess.
            $replyFile = Join-Path $workDir 'replies' "$agent-$($Now.ToString('yyyyMMdd-HHmmss')).md"
            $how = if ($r.Registered) { 'registered repo' } elseif ($r.Cloned) { 'cloned now' } else { 'existing clone' }
            $what = if ($plan) { 'Plan' } elseif ($Mode -ceq 'rebrief') { 'Re-brief' } else { 'Brief' }
            Add-OfficeThreadEntry -OfficeRoot $OfficeRoot -Id $item.id -From 'office-manager' -To $agent -Kind 'assign' `
                -Body "$what requested$(if ($Reason) { " ($Reason)" }). Repo: $($r.RepoPath) ($how), $(Format-ReadBase $rb)." -Now $Now
        }
        $item = Get-OfficeWorkItem -OfficeRoot $OfficeRoot -Id $item.id

        [ordered]@{
            ok             = $true
            action         = $action
            mode           = $Mode
            reason         = $Reason
            id             = $item.id
            workDir        = $workDir
            replyFile      = $replyFile
            state          = $item.state
            project        = $target.ProjectPath
            iid            = $target.Iid
            title          = $issue.title
            webUrl         = $issue.web_url
            issueUpdatedAt = $issueUpdatedAt
            gitlabHost     = $WorkItemConfig.gitlabHost
            issueApi       = $issueApi
            radar          = $radar
            repo           = $repo
            agent          = if ($action -ceq 'run-planner') { 'builder' } elseif ($action -ceq 'run-intake') { 'intake' } else { $null }
            builderMode    = if ($action -ceq 'run-planner') { 'plan' } else { $null }
            planPath       = Join-Path $workDir 'plan.md'
            planNeedsReview = [bool]$item['planNeedsReview']
            profile        = $prof
            pendingDecision = $item.pendingDecision
            g1             = $g1
        }
    }
    catch {
        [ordered]@{ ok = $false; ref = $Ref; error = $_.Exception.Message; retryable = $retryable }
    }
}

# One /huddle-tick pass, without any agent work. Returns:
#   inbox    one row per inbox file: queued (Intake to run), done (nothing to brief), kept (retry later), dropped
#   updates  one row per checked work item: its Get-OfficeUpdateAction result (+ decision id for G2)
#   intake   prep results (action run-intake) for the session to dispatch, at most one per work item
#   errors   messages for anything that failed and will be retried
# Inbox items only ever get a brief (they stop at BRIEFED, SPEC §3.8); nothing here plans or builds.
function Invoke-HuddleTick {
    param(
        [Parameter(Mandatory)][string]$OfficeRoot,
        [Parameter(Mandatory)][hashtable]$WorkItemConfig,
        [Parameter(Mandatory)][hashtable]$OfficeConfig,
        [datetime]$Now = (Get-Date)
    )
    $inbox = [Collections.Generic.List[object]]::new()
    $updates = [Collections.Generic.List[object]]::new()
    $intake = [Collections.Generic.List[object]]::new()
    $errors = [Collections.Generic.List[string]]::new()
    $queued = [Collections.Generic.HashSet[string]]::new()

    $sorted = Get-SortedWorkItems -Config $WorkItemConfig
    if ($null -eq $sorted) { $sorted = @() }
    $common = @{ OfficeRoot = $OfficeRoot; WorkItemConfig = $WorkItemConfig; OfficeConfig = $OfficeConfig; SortedItems = $sorted; Now = $Now }
    $mrCache = @{}

    # 0. Waits (T21, SPEC §3.11): first, so a work item whose MR was just merged is briefed in this pass.
    $unblocked = @()
    try {
        $w = Update-HuddleWaits -OfficeRoot $OfficeRoot -WorkItemConfig $WorkItemConfig -MrCache $mrCache -Now $Now
        $unblocked = @($w.unblocked)
        foreach ($e in @($w.errors)) { $errors.Add($e) }
    }
    catch { $errors.Add("waits: $($_.Exception.Message)") }

    # 1. Inbox: register and queue a brief. The file is removed once the item is registered;
    #    a registered item left in NEW is picked up again by step 2 on a later tick.
    foreach ($f in @(Get-OfficeInboxItems -OfficeRoot $OfficeRoot)) {
        if ($f.Error) {
            $inbox.Add([ordered]@{ file = $f.Name; status = 'kept'; message = "unreadable: $($f.Error)" })
            $errors.Add("inbox $($f.Name): $($f.Error)")
            continue
        }
        $p = Invoke-HuddleTakePrep -Ref $f.Entry.reference -Mode brief -Reason 'inbox' @common
        if (-not $p.ok) {
            $status = if ($p.retryable) { 'kept' } else { 'dropped' }
            if (-not $p.retryable) { Remove-OfficeInboxItem -OfficeRoot $OfficeRoot -Name $f.Name } else { $errors.Add("inbox $($f.Name): $($p.error)") }
            $inbox.Add([ordered]@{ file = $f.Name; reference = $f.Entry.reference; status = $status; message = $p.error })
            continue
        }
        Remove-OfficeInboxItem -OfficeRoot $OfficeRoot -Name $f.Name
        if ($p.action -ceq 'run-intake' -and $queued.Add($p.id)) { $intake.Add($p) }
        $inbox.Add([ordered]@{ file = $f.Name; reference = $f.Entry.reference; id = $p.id; status = $(if ($p.action -ceq 'run-intake') { 'queued' } else { 'done' }); state = $p.state })
    }

    # 2. Work items already in the office.
    $summary = Get-OfficeSummary -OfficeRoot $OfficeRoot
    foreach ($row in @($summary.Items)) {
        if ($queued.Contains($row.Id)) { continue }
        $s = Get-OfficeWorkItem -OfficeRoot $OfficeRoot -Id $row.Id
        $ref = "$($s.project)#$($s.iid)"

        if ($s.state -ceq 'NEW') {
            $p = Invoke-HuddleTakePrep -Ref $ref -Mode brief -Reason 'not briefed yet' @common
            if ($p.ok -and $p.action -ceq 'run-intake' -and $queued.Add($p.id)) { $intake.Add($p) }
            elseif (-not $p.ok) { $errors.Add("${ref}: $($p.error)") }
            continue
        }
        if ($s.state -cin 'PARKED', 'DELIVERED', 'PURGED') { continue }

        try { $issue = Get-GitLabIssue $WorkItemConfig $s.project $s.iid }
        catch { $errors.Add("${ref}: $($_.Exception.Message)"); continue }
        $current = Format-IssueTimestamp $issue.updated_at
        $a = Get-OfficeUpdateAction -State $s.state -ResumeTo $s.resumeTo -RecordedUpdatedAt $s.issueUpdatedAt `
            -CurrentUpdatedAt $current -PendingDecision $s.pendingDecision
        $row2 = [ordered]@{ id = $s.id; reference = $ref; state = $s.state; recorded = $s.issueUpdatedAt; current = $current; action = $a.Action; reason = $a.Reason }

        switch ($a.Action) {
            'record' { $null = Set-OfficeIssueUpdatedAt -OfficeRoot $OfficeRoot -Id $s.id -IssueUpdatedAt $current -Now $Now }
            { $_ -cin 'rebrief', 'rebrief-replan' } {
                $p = Invoke-HuddleTakePrep -Ref $ref -Mode rebrief -Reason $a.Reason @common
                if ($p.ok -and $p.action -cne 'run-intake') { $row2.action = 'defer'; $row2.reason = $p.message }
                elseif ($p.ok -and $queued.Add($p.id)) { $intake.Add($p) }
                elseif (-not $p.ok) { $errors.Add("${ref}: $($p.error)") }
            }
            'raise-g2' {
                $n = New-OfficeDecision -OfficeRoot $OfficeRoot -Id $s.id -Gate 'G2' -Kind 'issue-changed' `
                    -Question "$ref was edited on GitLab while the work item is $($s.state). Change the scope?" `
                    -Options @('Keep the current scope and continue', 'Park the work item until I have read the change') `
                    -Recommendation 'Read the issue change first; park if it affects the plan.' `
                    -Context "Issue updated_at: recorded $($s.issueUpdatedAt), now $current. $($s.webUrl)" -Now $Now
                # The change is now in front of me; do not raise it again on the next tick.
                $null = Set-OfficeIssueUpdatedAt -OfficeRoot $OfficeRoot -Id $s.id -IssueUpdatedAt $current -Now $Now
                $row2.decision = $n
            }
        }
        $updates.Add($row2)
    }

    # 3. Delivered MRs (T20, SPEC §3.11): merged, closed, or a pipeline that changed.
    $delivered = @()
    try {
        $mrs = Update-HuddleDeliveredMrs -OfficeRoot $OfficeRoot -WorkItemConfig $WorkItemConfig -MrCache $mrCache -Now $Now
        $delivered = @($mrs.changes)
        foreach ($e in @($mrs.errors)) { $errors.Add($e) }
    }
    catch { $errors.Add("delivered MRs: $($_.Exception.Message)") }

    # 4. Retention (T17, SPEC §3.7): purge work items DELIVERED for retentionDays or more.
    $purged = @()
    try {
        # Invoke-OfficePurge returns its rows as one array; assigning it first unwraps it to the rows.
        # Piping the call straight into Where-Object filtered the array as a whole: an office with
        # work items but nothing delivered failed here, and a mixed result kept its 'kept' rows.
        $rows = Invoke-OfficePurge -OfficeRoot $OfficeRoot -Config $OfficeConfig -Now $Now
        $purged = @(@($rows) | Where-Object { $_.result -cne 'kept' })
    }
    catch { $errors.Add("purge: $($_.Exception.Message)") }

    [ordered]@{
        ok        = $true
        inbox     = $inbox.ToArray()
        updates   = $updates.ToArray()
        intake    = $intake.ToArray()
        delivered = $delivered
        unblocked = $unblocked
        purged    = $purged
        errors    = $errors.ToArray()
    }
}

# Reads the MR behind every unmet wait (T21) and records what it finds (Set-OfficeWaitStatus).
# Read-only on GitLab. Used by /huddle-tick and the session brief. Returns:
#   unblocked  one row per wait met by this pass: id, reference, mr ('project!iid'),
#              ready (true when the work item has no unmet wait left)
#   errors     one message per MR that could not be read; its wait is left as it was
function Update-HuddleWaits {
    param(
        [Parameter(Mandatory)][string]$OfficeRoot,
        [Parameter(Mandatory)][hashtable]$WorkItemConfig,
        [hashtable]$MrCache = @{},
        [datetime]$Now = (Get-Date)
    )
    $unblocked = [Collections.Generic.List[object]]::new()
    $errors = [Collections.Generic.List[string]]::new()
    foreach ($row in @((Get-OfficeSummary -OfficeRoot $OfficeRoot).Items)) {
        foreach ($w in @($row.WaitsFor | Where-Object { -not $_['metAt'] })) {
            $name = "$($w['project'])!$($w['iid'])"
            try {
                $live = Get-GitLabMrCached $MrCache $WorkItemConfig $w['project'] ([int]$w['iid'])
                $r = Set-OfficeWaitStatus -OfficeRoot $OfficeRoot -Id $row.Id -Project $w['project'] -Iid ([int]$w['iid']) `
                    -MrState ([string]$live['state']) -Now $Now
                if ($r.Met) { $unblocked.Add([ordered]@{ id = $row.Id; reference = $row.Reference; mr = $name; ready = ($r.Remaining -eq 0) }) }
            }
            catch { $errors.Add("$($row.Reference) waits for ${name}: $($_.Exception.Message)") }
        }
    }
    [ordered]@{ unblocked = $unblocked.ToArray(); errors = $errors.ToArray() }
}

# scripts/wait-for.ps1: makes a work item wait for an MR, or clears its waits (T21, SPEC §3.11).
# Registers the work item as NEW when it is not in the office yet. Reads the issue and the MR from
# GitLab; writes nothing there. Returns the JSON-ready result that the script prints.
function Invoke-HuddleWaitFor {
    param(
        [Parameter(Mandatory)][string]$Ref,
        [string]$Mr,
        [string]$Note,
        [switch]$Clear,
        [Parameter(Mandatory)][string]$OfficeRoot,
        [Parameter(Mandatory)][hashtable]$WorkItemConfig,
        [AllowEmptyCollection()][object[]]$SortedItems = @(),
        [datetime]$Now = (Get-Date)
    )
    try {
        if ($Clear -and $Mr) { throw 'Use either -Mr or -Clear, not both.' }
        if (-not $Clear -and -not $Mr) { throw 'Say which merge request to wait for (-Mr), or -Clear.' }
        $target = ConvertFrom-OfficeWorkItemRef -Ref $Ref -AssignedReferences @($SortedItems | ForEach-Object Reference)
        $reference = "$($target.ProjectPath)#$($target.Iid)"
        $id = Get-OfficeWorkItemId -ProjectPath $target.ProjectPath -Iid $target.Iid

        if ($Clear) {
            $n = Clear-OfficeWaits -OfficeRoot $OfficeRoot -Id $id -Now $Now
            return [ordered]@{ ok = $true; action = 'cleared'; id = $id; reference = $reference; cleared = $n }
        }

        $m = ConvertFrom-MrRef $Mr $target.ProjectPath
        $name = "$($m.ProjectPath)!$($m.Iid)"
        $live = Get-GitLabMr $WorkItemConfig $m.ProjectPath $m.Iid
        $state = [string]$live['state']
        if ($state -ceq 'merged') {
            return [ordered]@{ ok = $true; action = 'already-merged'; id = $id; reference = $reference; mr = $name
                message = "$name is already merged; nothing to wait for." }
        }
        if ($state -ceq 'closed') { throw "$name was closed without being merged; a work item cannot wait for it." }

        $registered = Test-Path -LiteralPath (Join-Path $OfficeRoot 'work' $id 'status.json')
        if (-not $registered) {
            $issue = Get-GitLabIssue $WorkItemConfig $target.ProjectPath $target.Iid
            if ($issue.state -ne 'opened') { throw "$reference is $($issue.state); only open work items can wait." }
            $null = Register-OfficeWorkItem -OfficeRoot $OfficeRoot -ProjectPath $target.ProjectPath -Iid $target.Iid `
                -Title $issue.title -WebUrl $issue.web_url -IssueUpdatedAt (Format-IssueTimestamp $issue.updated_at) -Now $Now
        }
        $r = Add-OfficeWait -OfficeRoot $OfficeRoot -Id $id -Project $m.ProjectPath -Iid $m.Iid -Note $Note -Now $Now
        $s = Get-OfficeWorkItem -OfficeRoot $OfficeRoot -Id $id
        [ordered]@{
            ok = $true; action = $(if ($r.Added) { 'waiting' } else { 'already-waiting' })
            id = $id; reference = $reference; state = $s.state; registered = (-not $registered)
            mr = $name; mrState = $state; waitsFor = @(Get-OfficeUnmetWaits $s)
        }
    }
    catch {
        [ordered]@{ ok = $false; ref = $Ref; error = $_.Exception.Message }
    }
}

# Reads the MR of every DELIVERED work item whose MR is not merged or closed yet, and records what
# it finds (Set-OfficeMrStatus). Read-only on GitLab. Used by /huddle-tick and the session brief.
# Returns:
#   changes  one row per MR whose state or pipeline changed: id, reference, mr, from, to, pipeline
#   errors   one message per MR that could not be read; its status.json is left as it was
function Update-HuddleDeliveredMrs {
    param(
        [Parameter(Mandatory)][string]$OfficeRoot,
        [Parameter(Mandatory)][hashtable]$WorkItemConfig,
        [hashtable]$MrCache = @{},
        [datetime]$Now = (Get-Date)
    )
    $changes = [Collections.Generic.List[object]]::new()
    $errors = [Collections.Generic.List[string]]::new()
    foreach ($row in @((Get-OfficeSummary -OfficeRoot $OfficeRoot).Items)) {
        if ($row.State -cne 'DELIVERED') { continue }
        $mr = $row.Mr
        if ($null -eq $mr -or $null -eq $mr['iid']) { continue }
        if ($mr['state'] -cin 'merged', 'closed') { continue }
        $s = Get-OfficeWorkItem -OfficeRoot $OfficeRoot -Id $row.Id
        try {
            $live = Get-GitLabMrCached $MrCache $WorkItemConfig $s.project ([int]$mr['iid'])
            $pipeline = if ($live['head_pipeline']) { [string]$live['head_pipeline']['status'] } else { $null }
            $mergedAt = if ($live['merged_at']) { Format-IssueTimestamp $live['merged_at'] } else { $null }
            $r = Set-OfficeMrStatus -OfficeRoot $OfficeRoot -Id $row.Id -State ([string]$live['state']) `
                -MergedAt $mergedAt -Pipeline $pipeline -Now $Now
            if ($r.Changed) {
                $changes.Add([ordered]@{ id = $row.Id; reference = $row.Reference; mr = $r.Mr; from = $r.From; to = $r.To; pipeline = $r.Pipeline })
            }
        }
        catch { $errors.Add("$($row.Reference) MR !$($mr['iid']): $($_.Exception.Message)") }
    }
    [ordered]@{ changes = $changes.ToArray(); errors = $errors.ToArray() }
}

# Input for the Builder agent in analysis-comment mode (after G1 approval, SPEC §3.10): no GitLab
# call, everything comes from status.json, the configs and the clock. Adds a thread entry.
function Get-HuddleAnalysisInput {
    param(
        [Parameter(Mandatory)][string]$OfficeRoot,
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][hashtable]$WorkItemConfig,
        [Parameter(Mandatory)][hashtable]$OfficeConfig,
        [datetime]$Now = (Get-Date)
    )
    $s = Get-OfficeWorkItem -OfficeRoot $OfficeRoot -Id $Id
    $p = Resolve-OfficeProject -Config $OfficeConfig -ProjectPath $s.project
    $workDir = Join-Path $OfficeRoot 'work' $Id
    $baseBranch = if ($p.Registered) { $p.Project.baseBranch } else { $null }
    $rb = Update-OfficeReadBase -RepoPath $p.RepoPath -BaseBranch $baseBranch
    Add-OfficeThreadEntry -OfficeRoot $OfficeRoot -Id $Id -From 'office-manager' -To 'builder' -Kind 'assign' `
        -Body "Analysis comment requested (G1 approved), $(Format-ReadBase $rb)." -Refs 'analysis-comment.md' -Now $Now
    [ordered]@{
        ok                  = $true
        agent               = 'builder'
        builderMode         = 'analysis-comment'
        id                  = $Id
        workDir             = $workDir
        replyFile           = Join-Path $workDir 'replies' "builder-$($Now.ToString('yyyyMMdd-HHmmss')).md"
        state               = $s.state
        project             = $s.project
        iid                 = $s.iid
        title               = $s.title
        webUrl              = $s.webUrl
        gitlabHost          = $WorkItemConfig.gitlabHost
        issueApi            = Get-IssueApi $s.project $s.iid
        planPath            = Join-Path $workDir 'plan.md'
        analysisCommentPath = Join-Path $workDir 'analysis-comment.md'
        repo                = [ordered]@{
            registered = $p.Registered; repoPath = $p.RepoPath; baseBranch = $baseBranch
            baseRef = $rb.baseRef; baseCommit = $rb.baseCommit; fetched = $rb.fetched; readBaseError = $rb.error
        }
    }
}

# --- Delivery (T15): GitLab reads around the MR; the push and the MR request are not here ----------

function Get-ProjectApi([string]$ProjectPath) { "projects/$([uri]::EscapeDataString($ProjectPath))" }

# Invoke-GitLabApi returns its array wrapped (, @(...)); assigning it first unwraps it to the items.
function Get-GitLabOpenMrs([hashtable]$WorkItemConfig, [string]$ProjectPath, [string]$Branch) {
    $mrs = Invoke-GitLabApi -GitLabHost $WorkItemConfig.gitlabHost -Endpoint "$(Get-ProjectApi $ProjectPath)/merge_requests?state=opened&source_branch=$([uri]::EscapeDataString($Branch))&per_page=100"
    , @($mrs)
}

# /huddle-deliver prep: reads the project's labels (with inherited ones) and any open MR from the
# work item's branch, then returns Get-OfficeDeliveryInput's result for the Builder's mr-draft run.
function Invoke-HuddleDeliverPrep {
    param(
        [Parameter(Mandatory)][string]$OfficeRoot,
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][hashtable]$WorkItemConfig,
        [Parameter(Mandatory)][hashtable]$OfficeConfig,
        [string]$Note,
        [datetime]$Now = (Get-Date)
    )
    $s = Get-OfficeWorkItem -OfficeRoot $OfficeRoot -Id $Id
    if ($s.state -cne 'READY') {
        return Get-OfficeDeliveryInput -OfficeRoot $OfficeRoot -Id $Id -Config $OfficeConfig -Now $Now
    }
    $raw = Invoke-GitLabApi -GitLabHost $WorkItemConfig.gitlabHost -Endpoint "$(Get-ProjectApi $s.project)/labels?include_ancestor_groups=true&per_page=100"
    $labels = [string[]]@(foreach ($l in @($raw)) { [string]$l.name })
    $mrs = Get-GitLabOpenMrs $WorkItemConfig $s.project $s.build.branch
    $out = Get-OfficeDeliveryInput -OfficeRoot $OfficeRoot -Id $Id -Config $OfficeConfig -Labels $labels -OpenMrs $mrs -Note $Note -GitLabHost $WorkItemConfig.gitlabHost -Now $Now
    $out.gitlabHost = $WorkItemConfig.gitlabHost
    $out
}

# /huddle-deliver after the MR request: reads the open MR from the branch and the issue's new
# updated_at, then records the delivery (READY -> DELIVERED).
function Invoke-HuddleDeliverComplete {
    param(
        [Parameter(Mandatory)][string]$OfficeRoot,
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][hashtable]$WorkItemConfig,
        [datetime]$Now = (Get-Date)
    )
    $s = Get-OfficeWorkItem -OfficeRoot $OfficeRoot -Id $Id
    if ($s.state -cne 'READY') { throw "Delivery completes from READY; '$Id' is $($s.state)." }
    $mrs = Get-GitLabOpenMrs $WorkItemConfig $s.project $s.build.branch
    $issue = Get-GitLabIssue $WorkItemConfig $s.project $s.iid
    Complete-OfficeDelivery -OfficeRoot $OfficeRoot -Id $Id -OpenMrs $mrs -IssueUpdatedAt (Format-IssueTimestamp $issue.updated_at) -Now $Now
}

Export-ModuleMember -Function Invoke-HuddleTakePrep, Invoke-HuddleTick, Get-HuddleAnalysisInput,
    Invoke-HuddleDeliverPrep, Invoke-HuddleDeliverComplete, Update-HuddleDeliveredMrs,
    Update-HuddleWaits, Invoke-HuddleWaitFor
