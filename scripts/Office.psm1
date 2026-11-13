Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:RepoRoot = Split-Path -Parent $PSScriptRoot
$script:Utf8NoBom = [Text.UTF8Encoding]::new($false)

# --- State machine (SPEC §3.3) ------------------------------------------------------------------

$script:States = @(
    'NEW', 'BRIEFED', 'PLANNED', 'BUILDING', 'TESTING', 'SEC_REVIEW', 'REVIEW',
    'READY', 'DELIVERED', 'PURGED', 'PARKED', 'BLOCKED'
)
$script:LoopStates = @('BUILDING', 'TESTING', 'SEC_REVIEW', 'REVIEW')
$script:HoldStates = @('PARKED', 'BLOCKED')
# States that can no longer be paused or blocked.
$script:FinalStates = @('DELIVERED', 'PURGED')

function Assert-OfficeState([string]$State) {
    if ($State -cnotin $script:States) {
        throw "Unknown work item state '$State'. Valid states: $($script:States -join ', ')."
    }
}

# Pure check of one transition. Gate transitions need the id of the decision that approved them:
# PLANNED -> BUILDING (G1), reaching READY from anywhere but REVIEW (G2), and BUILDING -> BRIEFED
# (a G2 `base-moved` ruling to re-plan, before any worktree exists), and READY -> BUILDING (a G2
# `rework` ruling: I send the reviewed build back before delivery).
# PARKED / BLOCKED can only go back to the state recorded when they were entered (-ResumeTo).
function Test-OfficeTransition {
    param(
        [Parameter(Mandatory)][string]$From,
        [Parameter(Mandatory)][string]$To,
        [Nullable[int]]$DecisionId,
        [string]$ResumeTo
    )
    Assert-OfficeState $From
    Assert-OfficeState $To
    if ($From -ceq $To) { return $false }
    $hasDecision = $null -ne $DecisionId

    if ($From -cin $script:HoldStates) {
        return ([bool]$ResumeTo) -and ($To -ceq $ResumeTo)
    }
    if ($To -cin $script:HoldStates) {
        return $From -cnotin $script:FinalStates
    }

    if ($From -cin $script:LoopStates -and $To -cin $script:LoopStates) { return $true }
    if ($From -ceq 'BUILDING' -and $To -ceq 'BRIEFED') { return $hasDecision }

    switch ($From) {
        'NEW'       { return $To -ceq 'BRIEFED' }
        'BRIEFED'   { return $To -ceq 'PLANNED' }
        'PLANNED'   { return ($To -ceq 'BUILDING') -and $hasDecision }
        'READY'     { return ($To -ceq 'DELIVERED') -or ($To -ceq 'BUILDING' -and $hasDecision) }
        'DELIVERED' { return $To -ceq 'PURGED' }
    }
    if ($From -cin $script:LoopStates -and $To -ceq 'READY') {
        return ($From -ceq 'REVIEW') -or $hasDecision
    }
    return $false
}

# --- Config -------------------------------------------------------------------------------------

function Get-OfficeConfig {
    param([string]$Path = (Join-Path $script:RepoRoot 'config/office.json'))
    $c = Get-Content -Raw -Encoding utf8 -LiteralPath $Path | ConvertFrom-Json -AsHashtable

    foreach ($key in 'workspaceRoot', 'unknownProject', 'maxAutoRounds', 'maxActiveBuilds', 'retentionDays', 'projects') {
        if (-not $c.ContainsKey($key)) { throw "office config '$Path' is missing required key '$key'." }
    }
    if ($c.unknownProject -cne 'auto-clone') {
        throw "office config: unknownProject must be 'auto-clone' (got '$($c.unknownProject)')."
    }
    foreach ($key in 'maxAutoRounds', 'maxActiveBuilds', 'retentionDays') {
        if ($c[$key] -isnot [long] -and $c[$key] -isnot [int] -or $c[$key] -lt 1) {
            throw "office config: $key must be a positive integer (got '$($c[$key])')."
        }
    }
    foreach ($p in @($c.projects)) {
        foreach ($key in 'match', 'repoPath', 'baseBranch', 'commands') {
            if (-not $p.ContainsKey($key)) { throw "office config: a project entry is missing '$key'." }
        }
    }
    $c
}

# --- Work item storage --------------------------------------------------------------------------

# Folder name for a work item: '<project-slug>-<iid>', e.g. acme/SupportDesk #348 -> acme-supportdesk-348.
function Get-OfficeWorkItemId {
    param(
        [Parameter(Mandatory)][string]$ProjectPath,
        [Parameter(Mandatory)][int]$Iid
    )
    $slug = ($ProjectPath.ToLowerInvariant() -replace '[^a-z0-9._-]+', '-').Trim('-')
    "$slug-$Iid"
}

# --- Project resolution and path naming (SPEC §3.6) ---------------------------------------------
# Pure functions: no file system or git access. Paths are built with [IO.Path]::Combine because
# Join-Path checks that the drive exists. Cloning is Initialize-OfficeProjectRepo, worktrees New-OfficeWorktree.

# GitLab project path segments: letters, digits, '_', '-', '.', not starting with '.'
# (so '.' and '..' segments, which could escape the workspace, are rejected).
function Split-ProjectPath([string]$ProjectPath) {
    $segments = $ProjectPath -split '/'
    if ($segments.Count -lt 2) {
        throw "Project path '$ProjectPath' must be '<namespace>/<project>'."
    }
    foreach ($s in $segments) {
        if ($s -notmatch '^[A-Za-z0-9_][A-Za-z0-9_.-]*$') {
            throw "Project path '$ProjectPath' has an unsafe segment '$s'."
        }
    }
    , $segments
}

function Get-WorkspaceRoot([hashtable]$Config) {
    $root = $Config.workspaceRoot
    if (-not $root -or -not [IO.Path]::IsPathFullyQualified($root)) {
        throw "office config: workspaceRoot must be an absolute path (got '$root')."
    }
    $root
}

# Clone location for a project that is not in the registry: <workspaceRoot>\repos\<namespace>\<project>.
# Nested namespaces become nested folders: tools/portal/portal -> repos\tools\portal\portal.
function Get-OfficeClonePath {
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][string]$ProjectPath
    )
    $parts = @(Get-WorkspaceRoot $Config) + 'repos' + (Split-ProjectPath $ProjectPath)
    [IO.Path]::Combine([string[]]$parts)
}

# Finds the project in the registry: the first projects[].match that $ProjectPath is -like
# (case-insensitive, wildcards allowed; same rule as projectPriority in work-items.json).
# RepoPath is the registered repoPath, or the auto-clone location when the project is unregistered.
function Resolve-OfficeProject {
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][string]$ProjectPath
    )
    $null = Split-ProjectPath $ProjectPath
    foreach ($p in @($Config.projects)) {
        if ($ProjectPath -like $p.match) {
            return [pscustomobject]@{
                ProjectPath = $ProjectPath
                Registered  = $true
                Project     = $p
                RepoPath    = $p.repoPath
            }
        }
    }
    [pscustomobject]@{
        ProjectPath = $ProjectPath
        Registered  = $false
        Project     = $null
        RepoPath    = Get-OfficeClonePath -Config $Config -ProjectPath $ProjectPath
    }
}

# Worktree location: <workspaceRoot>\worktrees\<project-slug>-<iid> (same name as the office folder).
function Get-OfficeWorktreePath {
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][string]$ProjectPath,
        [Parameter(Mandatory)][int]$Iid
    )
    $null = Split-ProjectPath $ProjectPath
    [IO.Path]::Combine((Get-WorkspaceRoot $Config), 'worktrees', (Get-OfficeWorkItemId -ProjectPath $ProjectPath -Iid $Iid))
}

# Branch name: huddle/<iid>-<title-slug>. The slug keeps only ASCII letters and digits (after
# compatibility decomposition, so full-width 'ＡＩ' -> 'ai' and 'é' -> 'e'), joined by '-',
# at most $MaxSlugLength characters. CJK-only titles give an empty slug and the branch is huddle/<iid>.
# The result always satisfies `git check-ref-format --branch`.
function Get-OfficeBranchName {
    param(
        [Parameter(Mandatory)][int]$Iid,
        [AllowEmptyString()][string]$Title = '',
        [int]$MaxSlugLength = 40
    )
    if ($Iid -lt 1) { throw "Iid must be a positive integer (got $Iid)." }
    $decomposed = ([string]$Title).Normalize([Text.NormalizationForm]::FormKD).ToLowerInvariant()
    $slug = ($decomposed -replace '[^a-z0-9]+', '-').Trim('-')
    if ($slug.Length -gt $MaxSlugLength) { $slug = $slug.Substring(0, $MaxSlugLength).TrimEnd('-') }
    if ($slug) { "huddle/$Iid-$slug" } else { "huddle/$Iid" }
}

function Get-WorkItemDir([string]$OfficeRoot, [string]$Id) { Join-Path $OfficeRoot 'work' $Id }

function Get-StatusPath([string]$OfficeRoot, [string]$Id) {
    $path = Join-Path (Get-WorkItemDir $OfficeRoot $Id) 'status.json'
    if (-not (Test-Path -LiteralPath $path)) { throw "Work item '$Id' is not registered in '$OfficeRoot'." }
    $path
}

function Format-Timestamp([datetime]$Now) { $Now.ToString('yyyy-MM-ddTHH:mm:sszzz') }

# Write to a temp file first so a crash never leaves a half-written status.json behind.
function Write-StatusFile([string]$Path, [hashtable]$Status) {
    $tmp = "$Path.tmp"
    [IO.File]::WriteAllText($tmp, ($Status | ConvertTo-Json -Depth 6), $script:Utf8NoBom)
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

function Get-OfficeWorkItem {
    param(
        [Parameter(Mandatory)][string]$OfficeRoot,
        [Parameter(Mandatory)][string]$Id
    )
    $path = Get-StatusPath $OfficeRoot $Id
    # -DateKind String keeps timestamps exactly as written instead of re-formatting them on every save.
    $s = Get-Content -Raw -Encoding utf8 -LiteralPath $path | ConvertFrom-Json -AsHashtable -DateKind String
    $s.history = @($s.history)
    $s
}

# Idempotent: an existing work item is returned as is; nothing is reset or overwritten.
function Register-OfficeWorkItem {
    param(
        [Parameter(Mandatory)][string]$OfficeRoot,
        [Parameter(Mandatory)][string]$ProjectPath,
        [Parameter(Mandatory)][int]$Iid,
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$WebUrl,
        # The issue's updated_at at registration, compared later to detect edits (SPEC §3.8).
        [string]$IssueUpdatedAt,
        [datetime]$Now = (Get-Date)
    )
    $id = Get-OfficeWorkItemId -ProjectPath $ProjectPath -Iid $Iid
    $dir = Get-WorkItemDir $OfficeRoot $id
    $statusPath = Join-Path $dir 'status.json'
    if (Test-Path -LiteralPath $statusPath) { return Get-OfficeWorkItem -OfficeRoot $OfficeRoot -Id $id }

    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $threadPath = Join-Path $dir 'thread.md'
    if (-not (Test-Path -LiteralPath $threadPath)) {
        [IO.File]::WriteAllText($threadPath, "# Thread: $ProjectPath#$Iid`n", $script:Utf8NoBom)
    }
    $ts = Format-Timestamp $Now
    $status = [ordered]@{
        id              = $id
        project         = $ProjectPath
        iid             = $Iid
        title           = $Title
        webUrl          = $WebUrl
        issueUpdatedAt  = if ($IssueUpdatedAt) { $IssueUpdatedAt } else { $null }
        state           = 'NEW'
        resumeTo        = $null
        round           = 0
        pendingDecision = $null
        createdAt       = $ts
        updatedAt       = $ts
        history         = @()
    }
    Write-StatusFile $statusPath $status
    Get-OfficeWorkItem -OfficeRoot $OfficeRoot -Id $id
}

function Set-OfficeWorkItemState {
    param(
        [Parameter(Mandatory)][string]$OfficeRoot,
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$State,
        [Nullable[int]]$DecisionId,
        [datetime]$Now = (Get-Date)
    )
    $path = Get-StatusPath $OfficeRoot $Id
    $s = Get-OfficeWorkItem -OfficeRoot $OfficeRoot -Id $Id
    $from = $s.state
    if (-not (Test-OfficeTransition -From $from -To $State -DecisionId $DecisionId -ResumeTo $s.resumeTo)) {
        $hint = if ($from -cin $script:HoldStates) { " (it can only resume to '$($s.resumeTo)')" }
                elseif ($State -ceq 'READY' -or ($from -cin 'PLANNED', 'READY' -and $State -ceq 'BUILDING')) { ' (a gate decision id is required)' }
                else { '' }
        throw "Illegal transition for '$Id': $from -> $State$hint."
    }

    # A return to BUILDING from inside the loop, or from READY for a rework, is one round (SPEC §3.3);
    # resuming from a hold is not.
    if ($State -ceq 'BUILDING' -and ($from -cin $script:LoopStates -or $from -ceq 'READY')) { $s.round = [int]$s.round + 1 }

    if ($State -cin $script:HoldStates) { $s.resumeTo = $from }
    elseif ($from -cin $script:HoldStates) { $s.resumeTo = $null }

    $ts = Format-Timestamp $Now
    $s.history = @($s.history) + [ordered]@{ from = $from; to = $State; at = $ts; decision = $DecisionId }
    $s.state = $State
    $s.updatedAt = $ts
    Write-StatusFile $path $s
    Get-OfficeWorkItem -OfficeRoot $OfficeRoot -Id $Id
}

function Set-OfficeWorkItemPendingDecision {
    [CmdletBinding(DefaultParameterSetName = 'Set')]
    param(
        [Parameter(Mandatory)][string]$OfficeRoot,
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory, ParameterSetName = 'Set')][int]$DecisionId,
        [Parameter(Mandatory, ParameterSetName = 'Clear')][switch]$Clear,
        [datetime]$Now = (Get-Date)
    )
    $path = Get-StatusPath $OfficeRoot $Id
    $s = Get-OfficeWorkItem -OfficeRoot $OfficeRoot -Id $Id
    $s.pendingDecision = if ($Clear) { $null } else { $DecisionId }
    $s.updatedAt = Format-Timestamp $Now
    Write-StatusFile $path $s
    Get-OfficeWorkItem -OfficeRoot $OfficeRoot -Id $Id
}

# --- thread.md (SPEC §5): append-only ------------------------------------------------------------

function Add-OfficeThreadEntry {
    param(
        [Parameter(Mandatory)][string]$OfficeRoot,
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$From,
        [Parameter(Mandatory)][string]$To,
        [Parameter(Mandatory)][string]$Kind,
        [Parameter(Mandatory)][string]$Body,
        [string]$Refs,
        [datetime]$Now = (Get-Date)
    )
    $null = Get-StatusPath $OfficeRoot $Id
    foreach ($field in @{ From = $From; To = $To; Kind = $Kind; Refs = $Refs }.GetEnumerator()) {
        if ($field.Value -match '[\r\n]') { throw "thread entry field '$($field.Key)' must be a single line." }
    }
    $arrow = [char]0x2192
    $dot = [char]0x00B7
    $entry = "`n### [$($Now.ToString('yyyy-MM-dd HH:mm'))] $From $arrow $To $dot $Kind`n$($Body.TrimEnd())`n"
    if ($Refs) { $entry += "refs: $Refs`n" }
    [IO.File]::AppendAllText((Join-Path (Get-WorkItemDir $OfficeRoot $Id) 'thread.md'), $entry, $script:Utf8NoBom)
}

# --- Summary ------------------------------------------------------------------------------------

function Get-OfficeSummary {
    param([Parameter(Mandatory)][string]$OfficeRoot)
    $workDir = Join-Path $OfficeRoot 'work'
    $items = @()
    if (Test-Path -LiteralPath $workDir) {
        $items = @(Get-ChildItem -LiteralPath $workDir -Directory |
                Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'status.json') } |
                ForEach-Object {
                    $s = Get-OfficeWorkItem -OfficeRoot $OfficeRoot -Id $_.Name
                    [pscustomobject]@{
                        Id              = $s.id
                        Reference       = "$($s.project)#$($s.iid)"
                        Title           = $s.title
                        State           = $s.state
                        PendingDecision = $s.pendingDecision
                        Warning         = $s['purgeWarning']
                        Mr              = $s['mr']
                        WaitsFor        = @(@($s['waitsFor']) | Where-Object { $_ })
                    }
                } |
                Where-Object State -CNE 'PURGED' |
                Sort-Object Id)
    }
    [pscustomobject]@{
        Idle                 = $items.Count -eq 0
        Items                = $items
        PendingDecisionCount = @($items | Where-Object { $null -ne $_.PendingDecision }).Count
    }
}

# The MR column of the office brief (T20): what the last read of the delivered MR found.
# Timestamps are stored in UTC and shown in local time.
function Format-OfficeMrCell($Mr) {
    if ($null -eq $Mr -or $null -eq $Mr['iid']) { return '-' }
    $local = {
        param([string]$Value, [string]$Format)
        if (-not $Value) { return $null }
        [DateTimeOffset]::Parse($Value, [Globalization.CultureInfo]::InvariantCulture).ToLocalTime().ToString($Format)
    }
    $name = "!$($Mr['iid'])"
    $state = $Mr['state']
    if (-not $state) { return "$name (not checked yet)" }
    if ($state -ceq 'merged') {
        $on = & $local $Mr['mergedAt'] 'yyyy-MM-dd'
        return $(if ($on) { "$name merged $on" } else { "$name merged" })
    }
    $text = "$name $state"
    if ($state -ceq 'opened') {
        $text += $(if ($Mr['pipeline']) { ", pipeline $($Mr['pipeline'])" } else { ', no pipeline' })
        $checked = & $local $Mr['checkedAt'] 'MM-dd HH:mm'
        if ($checked) { $text += " (checked $checked)" }
    }
    $text
}

# What needs my attention about a delivered MR, or $null: closed without a merge, or a failed pipeline.
function Get-OfficeMrWarning($Mr) {
    if ($null -eq $Mr -or $null -eq $Mr['iid']) { return $null }
    if ($Mr['state'] -ceq 'closed') { return "MR !$($Mr['iid']) was closed without being merged." }
    if ($Mr['state'] -ceq 'opened' -and $Mr['pipeline'] -ceq 'failed') { return "MR !$($Mr['iid']) pipeline failed." }
    $null
}

# Renders a Get-OfficeSummary result for the SessionStart brief and /huddle.
# Context is markdown for the Claude session; Display is plain text for the terminal.
function Format-OfficeBrief {
    param([Parameter(Mandatory)][psobject]$Summary)
    $context = [System.Collections.Generic.List[string]]::new()
    $display = [System.Collections.Generic.List[string]]::new()
    $context.Add('## Office status')
    $context.Add('')
    if ($Summary.Idle) {
        $context.Add('Office idle: no work items in the office.')
        $display.Add('Office: idle')
    }
    else {
        $n = @($Summary.Items).Count
        $context.Add("Work items in the office: $n. Pending decisions: $($Summary.PendingDecisionCount).")
        $context.Add('')
        $context.Add('| Work item | Title | State | Pending decision | MR |')
        $context.Add('|---|---|---|---|---|')
        $display.Add("Office: $n work item(s), $($Summary.PendingDecisionCount) pending decision(s)")
        # Warnings go after the table: a line between two rows would end the markdown table.
        $warnings = [System.Collections.Generic.List[string]]::new()
        foreach ($i in $Summary.Items) {
            $title = $i.Title -replace '\|', '\|'
            $decision = if ($null -ne $i.PendingDecision) { "office/work/$($i.Id)/decisions/$($i.PendingDecision).md" } else { '-' }
            $mr = $i.PSObject.Properties['Mr'] ? $i.Mr : $null
            $mrCell = Format-OfficeMrCell $mr
            # T21: what the work item waits for, and a reminder once nothing is left to wait for.
            $waits = @($i.PSObject.Properties['WaitsFor'] ? $i.WaitsFor : @())
            $unmet = @($waits | Where-Object { -not $_['metAt'] })
            $state = if ($unmet.Count) { "$($i.State) (waits for $(($unmet | ForEach-Object { Format-OfficeMrRef $_ }) -join ', '))" } else { $i.State }
            $context.Add("| $($i.Reference) | $title | $state | $decision | $mrCell |")
            $pending = if ($null -ne $i.PendingDecision) { "  decision #$($i.PendingDecision) pending" } else { '' }
            $mrText = if ($mrCell -cne '-') { "  $mrCell" } else { '' }
            $display.Add("  $($i.Reference)  $state$pending$mrText")
            $waitWarnings = @($unmet | Where-Object { $_['mrState'] -ceq 'closed' } |
                ForEach-Object { "It waits for $(Format-OfficeMrRef $_), which was closed without being merged." })
            foreach ($w in @($i.Warning, (Get-OfficeMrWarning $mr)) + $waitWarnings | Where-Object { $_ }) {
                $warnings.Add("Warning for $($i.Reference): $w")
                $display.Add("    warning: $w")
            }
            $metWaits = @($waits | Where-Object { $_['metAt'] })
            if ($unmet.Count -eq 0 -and $metWaits.Count -and $i.State -cin 'NEW', 'BRIEFED') {
                $line = "$(($metWaits | ForEach-Object { Format-OfficeMrRef $_ }) -join ', ') merged: $($i.Reference) no longer waits and is ready for /huddle-take."
                $warnings.Add($line)
                $display.Add("    $line")
            }
        }
        foreach ($w in $warnings) {
            $context.Add('')
            $context.Add($w)
        }
    }
    [pscustomobject]@{ Context = $context.ToArray(); Display = $display.ToArray() }
}

# --- Agent outcome (SPEC §3.2): the fenced YAML block that ends every agent reply ----------------
# A deliberately small YAML subset, enough for the contract and nothing more:
#   key: <flow value>            flow value = "double", 'single', plain, [a, b], { k: v, ... }, null / ~
#   key:                         followed by an indented block of '- <flow value>' items
#     sub: <flow value>          or of 'sub: <flow value>' pairs (whose value may again be a '- ' list)
# '#' starts a comment outside quotes. Anything else is a parse error.

class AgentYamlFlowReader {
    [string]$Text
    [int]$Pos = 0
    AgentYamlFlowReader([string]$text) { $this.Text = $text }

    [void] SkipSpace() { while ($this.Pos -lt $this.Text.Length -and $this.Text[$this.Pos] -match '\s') { $this.Pos++ } }
    [bool] AtEnd() { $this.SkipSpace(); return $this.Pos -ge $this.Text.Length }
    [char] Peek() { return $this.Text[$this.Pos] }
    [void] Expect([char]$c) {
        $this.SkipSpace()
        if ($this.Pos -ge $this.Text.Length -or $this.Text[$this.Pos] -ne $c) {
            throw "expected '$c' at column $($this.Pos + 1) in: $($this.Text)"
        }
        $this.Pos++
    }

    [object] ReadValue([bool]$inFlow) {
        $this.SkipSpace()
        if ($this.Pos -ge $this.Text.Length) { return $null }
        $c = $this.Peek()
        if ($c -eq '"') { return $this.ReadDouble() }
        if ($c -eq "'") { return $this.ReadSingle() }
        if ($c -eq '[') { return $this.ReadList() }
        if ($c -eq '{') { return $this.ReadMap() }
        return $this.ReadPlain($inFlow)
    }

    [string] ReadDouble() {
        $this.Pos++
        $sb = [Text.StringBuilder]::new()
        while ($this.Pos -lt $this.Text.Length) {
            $c = $this.Text[$this.Pos++]
            if ($c -eq '"') { return $sb.ToString() }
            if ($c -eq '\') {
                if ($this.Pos -ge $this.Text.Length) { break }
                $e = $this.Text[$this.Pos++]
                switch -CaseSensitive ($e) {
                    'n' { [void]$sb.Append("`n") } 't' { [void]$sb.Append("`t") }
                    '"' { [void]$sb.Append('"') } '\' { [void]$sb.Append('\') }
                    default { throw "unsupported escape '\$e' in: $($this.Text)" }
                }
                continue
            }
            [void]$sb.Append($c)
        }
        throw "unterminated double-quoted string in: $($this.Text)"
    }

    [string] ReadSingle() {
        $this.Pos++
        $sb = [Text.StringBuilder]::new()
        while ($this.Pos -lt $this.Text.Length) {
            $c = $this.Text[$this.Pos++]
            if ($c -eq "'") {
                if ($this.Pos -lt $this.Text.Length -and $this.Text[$this.Pos] -eq "'") { [void]$sb.Append("'"); $this.Pos++; continue }
                return $sb.ToString()
            }
            [void]$sb.Append($c)
        }
        throw "unterminated single-quoted string in: $($this.Text)"
    }

    [object] ReadPlain([bool]$inFlow) {
        $start = $this.Pos
        while ($this.Pos -lt $this.Text.Length) {
            $c = $this.Text[$this.Pos]
            if ($inFlow -and ($c -eq ',' -or $c -eq ']' -or $c -eq '}')) { break }
            $this.Pos++
        }
        $s = $this.Text.Substring($start, $this.Pos - $start).Trim()
        if ($s -eq '') { throw "empty value at column $($start + 1) in: $($this.Text)" }
        if ($s -ceq 'null' -or $s -ceq '~') { return $null }
        if ($s -match '^[&*!|>%@`]') { throw "unsupported YAML syntax '$s'" }
        return $s
    }

    [object[]] ReadList() {
        $this.Pos++
        $items = [Collections.Generic.List[object]]::new()
        $this.SkipSpace()
        if ($this.Pos -lt $this.Text.Length -and $this.Peek() -eq ']') { $this.Pos++; return $items.ToArray() }
        while ($true) {
            $items.Add($this.ReadValue($true))
            $this.SkipSpace()
            if ($this.Pos -ge $this.Text.Length) { throw "unterminated list in: $($this.Text)" }
            $c = $this.Text[$this.Pos++]
            if ($c -eq ']') { return $items.ToArray() }
            if ($c -ne ',') { throw "expected ',' or ']' in: $($this.Text)" }
        }
        return $null
    }

    [hashtable] ReadMap() {
        $this.Pos++
        $map = [ordered]@{}
        $this.SkipSpace()
        if ($this.Pos -lt $this.Text.Length -and $this.Peek() -eq '}') { $this.Pos++; return $map }
        while ($true) {
            $this.SkipSpace()
            $m = [regex]::Match($this.Text.Substring($this.Pos), '^([A-Za-z_][A-Za-z0-9_]*)\s*:')
            if (-not $m.Success) { throw "expected 'key:' at column $($this.Pos + 1) in: $($this.Text)" }
            $key = $m.Groups[1].Value
            if ($map.Contains($key)) { throw "duplicate key '$key'" }
            $this.Pos += $m.Length
            $map[$key] = $this.ReadValue($true)
            $this.SkipSpace()
            if ($this.Pos -ge $this.Text.Length) { throw "unterminated mapping in: $($this.Text)" }
            $c = $this.Text[$this.Pos++]
            if ($c -eq '}') { return $map }
            if ($c -ne ',') { throw "expected ',' or '}' in: $($this.Text)" }
        }
        return $null
    }
}

function ConvertFrom-FlowValue([string]$Text) {
    $r = [AgentYamlFlowReader]::new($Text)
    $v = $r.ReadValue($false)
    if (-not $r.AtEnd()) { throw "unexpected text after value in: $Text" }
    if ($null -eq $v) { return $null }
    , $v
}

# Removes a ' #...' comment that is outside quotes.
function Remove-YamlComment([string]$Line) {
    $quote = $null
    for ($i = 0; $i -lt $Line.Length; $i++) {
        $c = $Line[$i]
        if ($quote) {
            if ($c -eq '\' -and $quote -eq '"') { $i++; continue }
            if ($c -eq $quote) { $quote = $null }
            continue
        }
        if ($c -eq '"' -or $c -eq "'") { $quote = $c; continue }
        if ($c -eq '#' -and ($i -eq 0 -or $Line[$i - 1] -match '\s')) { return $Line.Substring(0, $i).TrimEnd() }
    }
    $Line.TrimEnd()
}

# Parses lines (already comment-stripped, blank lines removed) at one indentation level.
function ConvertFrom-YamlBlock([object[]]$Lines) {
    $indent = $Lines[0].Indent
    if ($Lines[0].Text.StartsWith('- ') -or $Lines[0].Text -eq '-') {
        $items = [Collections.Generic.List[object]]::new()
        foreach ($l in $Lines) {
            if ($l.Indent -ne $indent -or -not ($l.Text.StartsWith('- '))) { throw "bad list item: '$($l.Text)'" }
            $items.Add((ConvertFrom-FlowValue $l.Text.Substring(2)))
        }
        return , $items.ToArray()
    }
    $map = [ordered]@{}
    $i = 0
    while ($i -lt $Lines.Count) {
        $l = $Lines[$i]
        if ($l.Indent -ne $indent) { throw "unexpected indentation: '$($l.Text)'" }
        $m = [regex]::Match($l.Text, '^([A-Za-z_][A-Za-z0-9_]*)\s*:(?:\s+(.*))?$')
        if (-not $m.Success) { throw "expected 'key: value', got '$($l.Text)'" }
        $key = $m.Groups[1].Value
        if ($map.Contains($key)) { throw "duplicate key '$key'" }
        $i++
        if ($m.Groups[2].Success -and $m.Groups[2].Value.Trim()) {
            $map[$key] = ConvertFrom-FlowValue $m.Groups[2].Value
            continue
        }
        $child = [Collections.Generic.List[object]]::new()
        while ($i -lt $Lines.Count -and $Lines[$i].Indent -gt $indent) { $child.Add($Lines[$i]); $i++ }
        $map[$key] = if ($child.Count) { ConvertFrom-YamlBlock $child.ToArray() } else { $null }
    }
    $map
}

$script:OutcomeKinds = @('done', 'blocked', 'needs_decision', 'objection')
$script:AgentNames = @('intake', 'builder', 'tester', 'security', 'reviewer')

function ConvertTo-OutcomeObject([Collections.IDictionary]$Map) {
    foreach ($k in $Map.Keys) {
        if ($k -cnotin 'outcome', 'summary', 'next', 'objection_to', 'decision') { throw "unknown key '$k'" }
    }
    $outcome = $Map['outcome']
    if ($outcome -isnot [string] -or $outcome -cnotin $script:OutcomeKinds) {
        throw "outcome must be one of $($script:OutcomeKinds -join ', ') (got '$outcome')"
    }
    $summary = $Map['summary']
    if ($summary -isnot [string] -or -not $summary.Trim()) { throw 'summary must be a non-empty string' }

    $next = @()
    if ($null -ne $Map['next']) {
        $next = @($Map['next'])
        foreach ($n in $next) {
            if ($n -isnot [string] -or $n -cnotin $script:AgentNames) { throw "next: unknown agent '$n'" }
        }
    }

    $objectionTo = $Map['objection_to']
    if ($outcome -ceq 'objection') {
        if ($objectionTo -isnot [string] -or $objectionTo -cnotin $script:AgentNames) {
            throw "objection_to must name an agent when outcome is objection (got '$objectionTo')"
        }
    }

    $decision = $Map['decision']
    if ($outcome -ceq 'needs_decision') {
        if ($decision -isnot [Collections.IDictionary]) { throw 'decision must be a mapping when outcome is needs_decision' }
        foreach ($k in $decision.Keys) {
            if ($k -cnotin 'question', 'options', 'recommendation') { throw "decision: unknown key '$k'" }
        }
        if ($decision['question'] -isnot [string] -or -not $decision['question'].Trim()) { throw 'decision.question must be a non-empty string' }
        $opts = @($decision['options'] | Where-Object { $_ -is [string] -and $_.Trim() })
        if ($opts.Count -lt 2 -or $opts.Count -ne @($decision['options']).Count) {
            throw 'decision.options must list at least two non-empty strings'
        }
        $decision = [pscustomobject]@{
            Question       = $decision['question']
            Options        = [string[]]$opts
            Recommendation = $decision['recommendation']
        }
    }
    else { $decision = $null }

    [pscustomobject]@{
        Valid       = $true
        Error       = $null
        Outcome     = $outcome
        Summary     = $summary.Trim()
        Next        = [string[]]$next
        ObjectionTo = if ($outcome -ceq 'objection') { $objectionTo } else { $null }
        Decision    = $decision
    }
}

# Parses the YAML block that must end an agent's final reply (SPEC §3.2). Never throws on bad agent
# output: a missing or malformed block yields Valid = $false and Outcome = 'blocked'. With
# -OfficeRoot / -Id / -Agent, a malformed reply is also recorded in that work item's thread.md.
function Get-AgentOutcome {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [string]$OfficeRoot,
        [string]$Id,
        [string]$Agent,
        [datetime]$Now = (Get-Date)
    )
    try {
        $fences = [regex]::Matches($Text, '(?ms)^[ \t]*```ya?ml[ \t]*\r?\n(.*?)^[ \t]*```[ \t]*\r?$')
        if ($fences.Count -eq 0) { throw 'no fenced ```yaml block found' }
        $last = $fences[$fences.Count - 1]
        if ($Text.Substring($last.Index + $last.Length).Trim()) {
            throw 'the ```yaml block is not the last thing in the reply'
        }
        $lines = foreach ($raw in ($last.Groups[1].Value -split '\r?\n')) {
            if ($raw -match '\t') { throw 'tabs are not allowed in the YAML block' }
            $t = Remove-YamlComment $raw
            if (-not $t.Trim()) { continue }
            [pscustomobject]@{ Indent = $t.Length - $t.TrimStart().Length; Text = $t.Trim() }
        }
        $lines = @($lines)
        if ($lines.Count -eq 0) { throw 'the ```yaml block is empty' }
        if ($lines[0].Indent -ne 0) { throw 'top-level keys must not be indented' }
        $map = ConvertFrom-YamlBlock $lines
        if ($map -isnot [Collections.IDictionary]) { throw 'the YAML block must be a mapping' }
        ConvertTo-OutcomeObject $map
    }
    catch {
        $err = $_.Exception.Message
        if ($OfficeRoot -and $Id -and $Agent) {
            Add-OfficeThreadEntry -OfficeRoot $OfficeRoot -Id $Id -From $Agent -To 'office-manager' -Kind 'blocked' `
                -Body "Agent reply could not be parsed as an outcome block; treated as blocked.`nParse error: $err" -Now $Now
        }
        [pscustomobject]@{
            Valid = $false; Error = $err; Outcome = 'blocked'
            Summary = "Unparseable agent reply: $err"; Next = [string[]]@(); ObjectionTo = $null; Decision = $null
        }
    }
}

# --- Inbox (SPEC §3.5): newly assigned items written by notify-new.ps1 ---------------------------

# Writes office/inbox/<id>.json, where <id> is the GitLab issue's global id (the same value kept in
# state/seen-work-items.json). Writing the same id again overwrites the file, so a notification that
# is retried on the next poll still leaves exactly one inbox file. Returns the file path.
function Write-OfficeInboxItem {
    param(
        [Parameter(Mandatory)][string]$OfficeRoot,
        [Parameter(Mandatory)][long]$Id,
        [Parameter(Mandatory)][string]$Reference,
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$WebUrl,
        [Nullable[DateTimeOffset]]$IssueUpdatedAt,
        [datetime]$Now = (Get-Date)
    )
    if ($Id -lt 1) { throw "Inbox id must be a positive GitLab issue id (got $Id)." }
    if ($Reference -notmatch '^(?<p>[^#\s]+)#(?<iid>\d+)$') { throw "Inbox reference '$Reference' is not 'group/project#iid'." }
    $project = $Matches.p
    $iid = [int]$Matches.iid
    $null = Split-ProjectPath $project

    $dir = Join-Path $OfficeRoot 'inbox'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $path = Join-Path $dir "$Id.json"
    $entry = [ordered]@{
        id             = $Id
        reference      = $Reference
        project        = $project
        iid            = $iid
        title          = $Title
        webUrl         = $WebUrl
        issueUpdatedAt = if ($null -ne $IssueUpdatedAt) { $IssueUpdatedAt.UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ss.fffZ') } else { $null }
        receivedAt     = Format-Timestamp $Now
    }
    $tmp = "$path.tmp"
    [IO.File]::WriteAllText($tmp, ($entry | ConvertTo-Json), $script:Utf8NoBom)
    Move-Item -LiteralPath $tmp -Destination $path -Force
    $path
}

# --- /huddle-take inputs ------------------------------------------------------------------------

# Accepts 'group/project#123', a GitLab issue or work item URL, or a short 'project#123' that is
# resolved against the references of my assigned items (radar list). Returns ProjectPath and Iid.
function ConvertFrom-OfficeWorkItemRef {
    param(
        [Parameter(Mandatory)][string]$Ref,
        [string[]]$AssignedReferences = @()
    )
    $r = $Ref.Trim()
    if ($r -match '^https?://[^/]+/(?<p>.+?)/-/(?:issues|work_items)/(?<iid>\d+)/?(?:[?#].*)?$') {
        $project = $Matches.p; $iid = [int]$Matches.iid
    }
    elseif ($r -match '^(?<p>[^#\s]+/[^#\s]+)#(?<iid>\d+)$') {
        $project = $Matches.p; $iid = [int]$Matches.iid
    }
    elseif ($r -match '^(?<n>[^#/\s]+)#(?<iid>\d+)$') {
        $name = $Matches.n; $iid = [int]$Matches.iid
        $candidates = @($AssignedReferences | ForEach-Object { $_.Split('#')[0] } |
            Where-Object { ($_ -split '/')[-1] -ieq $name } | Sort-Object -Unique)
        if ($candidates.Count -eq 0) {
            throw "No assigned work item is in a project named '$name'. Use the full path, e.g. 'group/$name#$iid'."
        }
        if ($candidates.Count -gt 1) {
            throw "'$name' is ambiguous: $($candidates -join ', '). Use the full project path."
        }
        $project = $candidates[0]
    }
    else {
        throw "Cannot read work item reference '$Ref'. Use 'group/project#iid', 'project#iid' or the issue URL."
    }
    if ($iid -lt 1) { throw "Work item iid must be positive (got $iid)." }
    $null = Split-ProjectPath $project
    [pscustomobject]@{ ProjectPath = $project; Iid = $iid }
}

# Makes sure the project's repo exists locally (SPEC §3.6 step 3). A registered project must already
# have its repoPath; it is only read, never changed. An unregistered project is cloned once with
# `glab repo clone` (a read from GitLab) into the auto-clone location; an existing clone is reused.
function Initialize-OfficeProjectRepo {
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][string]$ProjectPath,
        [Parameter(Mandatory)][string]$GitLabHost
    )
    $p = Resolve-OfficeProject -Config $Config -ProjectPath $ProjectPath
    $cloned = $false
    if ($p.Registered) {
        if (-not (Test-Path -LiteralPath $p.RepoPath -PathType Container)) {
            throw "Registered repoPath '$($p.RepoPath)' for '$ProjectPath' does not exist. Fix config/office.json."
        }
    }
    elseif (-not (Test-Path -LiteralPath $p.RepoPath)) {
        if ($GitLabHost -notmatch '^[A-Za-z0-9.-]+$') { throw "Invalid GitLab host '$GitLabHost'." }
        New-Item -ItemType Directory -Path (Split-Path -Parent $p.RepoPath) -Force | Out-Null
        # 'group/project' plus GITLAB_HOST (not an https:// URL), so glab clones with the git protocol
        # configured for that host (SSH here); an https URL makes git ask for HTTP credentials.
        $savedHost = $env:GITLAB_HOST
        try {
            $env:GITLAB_HOST = $GitLabHost
            $out = & glab repo clone $ProjectPath $p.RepoPath 2>&1
        }
        finally { $env:GITLAB_HOST = $savedHost }
        if ($LASTEXITCODE -ne 0) {
            throw "glab repo clone failed for '$ProjectPath' (exit $LASTEXITCODE): $($out -join "`n")"
        }
        $cloned = $true
    }
    $p | Add-Member -NotePropertyName Cloned -NotePropertyValue $cloned -PassThru
}

# --- Worktree (SPEC §3.6 step 2) -------------------------------------------------------------------

# Runs git against one repository and returns its output lines; throws with git's message on failure.
function Invoke-OfficeGit {
    param([Parameter(Mandatory)][string]$Repo, [Parameter(Mandatory)][string[]]$Arguments)
    $out = & git -C $Repo @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "git $($Arguments -join ' ') failed (exit $LASTEXITCODE): $($out -join "`n")" }
    @($out | ForEach-Object { "$_" })
}

function Test-OfficeGitRef([string]$Repo, [string]$Ref) {
    & git -C $Repo rev-parse --verify --quiet "$Ref^{commit}" 2>$null | Out-Null
    $LASTEXITCODE -eq 0
}

# The commit a worktree would start from: origin/<base> (after `git fetch origin <base>` with -Fetch), or
# the local <base> when there is no remote-tracking branch. Shared by New-OfficeWorktree and the base
# check in Get-OfficeLoopInput, so both see the same commit.
function Resolve-OfficeBaseCommit {
    param([Parameter(Mandatory)][string]$Repo, [Parameter(Mandatory)][string]$Base, [switch]$Fetch)
    if ($Fetch) { $null = Invoke-OfficeGit $Repo @('fetch', 'origin', $Base) }
    $baseRef = if (Test-OfficeGitRef $Repo "refs/remotes/origin/$Base") { "refs/remotes/origin/$Base" }
    elseif (Test-OfficeGitRef $Repo "refs/heads/$Base") { "refs/heads/$Base" }
    else { throw "Base branch '$Base' was found neither as origin/$Base nor as a local branch in '$Repo'." }
    [pscustomobject]@{ BaseRef = $baseRef; BaseCommit = @(Invoke-OfficeGit $Repo @('rev-parse', "$baseRef^{commit}"))[0] }
}

# Creates (or returns) the work item's worktree: <workspaceRoot>\worktrees\<project-slug>-<iid> on branch
# huddle/<iid>-<slug>, started from origin/<baseBranch> (or the local <baseBranch> when there is no
# remote-tracking branch). Only the registered repoPath's object store and refs gain the new branch and
# the worktree entry; its working directory, index and checked-out branch are never touched, because
# `git worktree add` checks out into the new folder only.
#   -Fetch   first runs `git fetch origin <baseBranch>` (a read from GitLab) so the base is current.
#   -Branch  the branch the work item's build record names, when it has one: a branch renamed with
#            Rename-OfficeBranch no longer has the huddle/<iid>-<slug> name.
# Refuses unregistered projects and a null baseBranch: both need my G1 approval of the project profile.
function New-OfficeWorktree {
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][string]$ProjectPath,
        [Parameter(Mandatory)][int]$Iid,
        [AllowEmptyString()][string]$Title = '',
        [string]$Branch,
        [switch]$Fetch
    )
    $p = Resolve-OfficeProject -Config $Config -ProjectPath $ProjectPath
    if (-not $p.Registered) {
        throw "Project '$ProjectPath' is not in config/office.json. Approve its project-profile.json at G1 first."
    }
    $base = $p.Project.baseBranch
    if (-not $base) {
        throw "baseBranch for '$ProjectPath' is null. Approve the project settings at G1 and set baseBranch in config/office.json first."
    }
    $repo = $p.RepoPath
    if (-not (Test-Path -LiteralPath $repo -PathType Container)) { throw "repoPath '$repo' for '$ProjectPath' does not exist." }
    $null = Invoke-OfficeGit $repo @('rev-parse', '--git-dir')
    $null = Invoke-OfficeGit $repo @('check-ref-format', '--branch', $base)

    $path = Get-OfficeWorktreePath -Config $Config -ProjectPath $ProjectPath -Iid $Iid
    $branch = if ($Branch) { $Branch } else { Get-OfficeBranchName -Iid $Iid -Title $Title }

    # Already created: same repository, same branch. Anything else at that path is an error.
    $existing = @(Invoke-OfficeGit $repo @('worktree', 'list', '--porcelain'))
    $full = [IO.Path]::GetFullPath($path).TrimEnd('\', '/')
    for ($k = 0; $k -lt $existing.Count; $k++) {
        if ($existing[$k] -notmatch '^worktree (.+)$') { continue }
        if ([IO.Path]::GetFullPath($Matches[1]).TrimEnd('\', '/') -ine $full) { continue }
        # Lines of this entry run until the next blank line; 'branch refs/heads/<name>' is absent when detached.
        $head = '(detached HEAD)'
        for ($j = $k + 1; $j -lt $existing.Count -and $existing[$j]; $j++) {
            if ($existing[$j] -match '^branch refs/heads/(.+)$') { $head = $Matches[1] }
        }
        if ($head -ceq $branch) {
            return [pscustomobject]@{ Path = $path; Branch = $branch; RepoPath = $repo; BaseRef = $null; BaseCommit = $null; Created = $false }
        }
        throw "Worktree '$path' exists but is on '$head', not '$branch'."
    }
    if (Test-Path -LiteralPath $path) { throw "'$path' already exists and is not a worktree of '$repo'." }

    $bc = Resolve-OfficeBaseCommit -Repo $repo -Base $base -Fetch:$Fetch
    $baseRef = $bc.BaseRef
    $baseCommit = $bc.BaseCommit

    New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
    if (Test-OfficeGitRef $repo "refs/heads/$branch") {
        # Left over from an earlier attempt (e.g. the folder was removed); reuse it instead of resetting it.
        $null = Invoke-OfficeGit $repo @('worktree', 'add', $path, $branch)
        $baseRef = $null
        $baseCommit = $null
    }
    else {
        # --no-track: the branch must not get origin/<base> as upstream, so nothing can push to it by default.
        $null = Invoke-OfficeGit $repo @('worktree', 'add', '--no-track', '-b', $branch, $path, $baseRef)
    }
    [pscustomobject]@{ Path = $path; Branch = $branch; RepoPath = $repo; BaseRef = $baseRef; BaseCommit = $baseCommit; Created = $true }
}

# The commit Intake and the Builder (plan, analysis-comment) read the code at (T15b). The clone's working
# directory is never updated (its checkout is never touched), so reading files there can show code that is
# far behind the base branch. This fetches the base branch (only remote-tracking refs move) and returns
# origin/<base>, or the local <base> when there is no remote-tracking branch; without a base branch,
# origin/HEAD, else HEAD. Agents read with `git -C <repoPath> show <baseCommit>:<path>`.
# Never throws: a failed fetch or a folder that is not a repository is reported in `error`, and the best
# commit already present is still returned, so the agent can say what it read.
function Update-OfficeReadBase {
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [AllowEmptyString()][string]$BaseBranch,
        [switch]$NoFetch
    )
    $out = [ordered]@{ baseRef = $null; baseCommit = $null; fetched = $false; error = $null }
    try { $null = Invoke-OfficeGit $RepoPath @('rev-parse', '--git-dir') }
    catch { $out.error = "'$RepoPath' is not a git repository: $($_.Exception.Message)"; return $out }
    if ($BaseBranch) {
        try { $null = Invoke-OfficeGit $RepoPath @('check-ref-format', '--branch', $BaseBranch) }
        catch { $out.error = "'$BaseBranch' is not a valid branch name."; return $out }
    }
    if (-not $NoFetch) {
        $fetchArgs = if ($BaseBranch) { @('fetch', '--quiet', 'origin', $BaseBranch) } else { @('fetch', '--quiet', 'origin') }
        try { $null = Invoke-OfficeGit $RepoPath $fetchArgs; $out.fetched = $true }
        catch { $out.error = "fetch failed, so the code read may be behind origin: $($_.Exception.Message)" }
    }
    $candidates = if ($BaseBranch) { @("refs/remotes/origin/$BaseBranch", "refs/heads/$BaseBranch") } else { @('refs/remotes/origin/HEAD', 'HEAD') }
    foreach ($ref in $candidates) {
        if ($ref -ceq 'HEAD' -or (Test-OfficeGitRef $RepoPath $ref)) {
            try {
                $out.baseCommit = @(Invoke-OfficeGit $RepoPath @('rev-parse', '--verify', '--quiet', "$ref^{commit}"))[0]
                $out.baseRef = $ref
                break
            }
            catch { continue }
        }
    }
    if (-not $out.baseRef -and -not $out.error) { $out.error = "No base commit found in '$RepoPath' (tried $($candidates -join ', '))." }
    $out
}

# --- brief.md (SPEC §3.8 step 5, §3.10 V1/V4) ---------------------------------------------------

$script:BriefSections = @('摘要', '排序依據', '發現於', '驗收條件草稿', '範圍', '相關程式碼', '風險標記', '待釐清問題')

# Returns the $Sections that have no '## <name>' heading in the file (all of them when it is missing).
function Get-MissingSections([string]$Path, [string[]]$Sections) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $Sections }
    $headings = @(Get-Content -Encoding utf8 -LiteralPath $Path |
        Where-Object { $_ -match '^##\s+(.+?)\s*$' } | ForEach-Object { ($_ -replace '^##\s+', '').Trim() })
    $Sections | Where-Object { $_ -notin $headings }
}

# Returns the required '## ' sections that brief.md lacks (empty when complete).
function Test-OfficeBrief {
    param([Parameter(Mandatory)][string]$Path)
    Get-MissingSections $Path $script:BriefSections
}

# Applies the Intake agent's outcome to the work item (SPEC §3.8 step 6). Intake may only report
# done or blocked; any other or unparseable outcome counts as blocked. 'done' also requires a
# complete brief.md. Every result is recorded in thread.md.
function Complete-OfficeIntake {
    param(
        [Parameter(Mandatory)][string]$OfficeRoot,
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][AllowEmptyString()][string]$ReplyText,
        # The issue's updated_at when Intake was dispatched (from huddle-take / huddle-tick prep).
        [string]$IssueUpdatedAt,
        [datetime]$Now = (Get-Date)
    )
    $item = Get-OfficeWorkItem -OfficeRoot $OfficeRoot -Id $Id
    if ($item.state -cne 'BLOCKED' -and $item.state -cnotin $script:BriefStates) {
        throw "Intake results cannot be applied to '$Id' in state $($item.state)."
    }
    $o = Get-AgentOutcome -Text $ReplyText -OfficeRoot $OfficeRoot -Id $Id -Agent 'intake' -Now $Now
    $briefPath = Join-Path (Get-WorkItemDir $OfficeRoot $Id) 'brief.md'
    $missing = @(Test-OfficeBrief -Path $briefPath)

    $result = 'blocked'
    $reason = $o.Summary
    if ($o.Valid) {
        if ($o.Outcome -ceq 'done' -and $missing.Count -eq 0) { $result = 'done' }
        elseif ($o.Outcome -ceq 'done') { $reason = "brief.md is missing sections: $($missing -join ', ')" }
        elseif ($o.Outcome -cne 'blocked') { $reason = "Intake returned '$($o.Outcome)', which it may not use: $($o.Summary)" }
        Add-OfficeThreadEntry -OfficeRoot $OfficeRoot -Id $Id -From 'intake' -To 'office-manager' -Kind $o.Outcome `
            -Body $o.Summary -Refs 'brief.md' -Now $Now
    }

    # Intake runs before planning (NEW) or as a re-brief (BRIEFED, PLANNED, or BLOCKED from one of those).
    $from = $item.state
    if ($result -ceq 'done') {
        if ($from -ceq 'BLOCKED' -and $item.resumeTo -cin $script:BriefStates) {
            $null = Set-OfficeWorkItemState -OfficeRoot $OfficeRoot -Id $Id -State $item.resumeTo -Now $Now
            $from = $item.resumeTo
        }
        if ($from -ceq 'NEW') { $null = Set-OfficeWorkItemState -OfficeRoot $OfficeRoot -Id $Id -State 'BRIEFED' -Now $Now }
        # A new brief after planning means the plan must be confirmed again (SPEC §3.8); G1 has not passed yet.
        if ($from -ceq 'PLANNED') { $null = Set-StatusField $OfficeRoot $Id 'planNeedsReview' $true $Now }
    }
    elseif ($from -cin $script:BriefStates) {
        $null = Set-OfficeWorkItemState -OfficeRoot $OfficeRoot -Id $Id -State 'BLOCKED' -Now $Now
        $null = Set-StatusField $OfficeRoot $Id 'blockedBy' 'intake' $Now
    }
    # The brief now reflects the issue as of -IssueUpdatedAt, so later ticks compare against it.
    # An unparseable reply did not process the issue, so the old value stays and the change is retried.
    if ($o.Valid -and $IssueUpdatedAt) { $null = Set-StatusField $OfficeRoot $Id 'issueUpdatedAt' $IssueUpdatedAt $Now }

    $after = Get-OfficeWorkItem -OfficeRoot $OfficeRoot -Id $Id
    if ($after.state -cne $item.state) {
        Add-OfficeThreadEntry -OfficeRoot $OfficeRoot -Id $Id -From 'office-manager' -To 'intake' -Kind 'state' `
            -Body "$($item.state) -> $($after.state)$(if ($result -ceq 'blocked') { ": $reason" })" -Now $Now
    }
    [pscustomobject]@{
        Id = $Id; Result = $result; Reason = $reason; From = $item.state; State = $after.state
        Valid = $o.Valid; MissingSections = [string[]]$missing
    }
}

$script:BriefStates = @('NEW', 'BRIEFED', 'PLANNED')

# Sets one top-level status.json field (not 'state'; that only changes through Set-OfficeWorkItemState).
function Set-StatusField([string]$OfficeRoot, [string]$Id, [string]$Name, $Value, [datetime]$Now) {
    if ($Name -cin 'state', 'resumeTo', 'history', 'round', 'pendingDecision', 'id') { throw "Use the dedicated function to change '$Name'." }
    $path = Get-StatusPath $OfficeRoot $Id
    $s = Get-OfficeWorkItem -OfficeRoot $OfficeRoot -Id $Id
    $s[$Name] = $Value
    $s.updatedAt = Format-Timestamp $Now
    Write-StatusFile $path $s
    Get-OfficeWorkItem -OfficeRoot $OfficeRoot -Id $Id
}

# --- Issue update detection (SPEC §3.8 "issue 被修改時") ------------------------------------------

function ConvertTo-Instant([string]$Value) {
    if (-not $Value) { return $null }
    [DateTimeOffset]::Parse($Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal)
}

# Pure: what /huddle-tick does when it sees the issue's current updated_at. Actions:
#   none            unchanged, or a state that is never re-processed (NEW, PARKED, DELIVERED, PURGED)
#   record          no value was recorded yet; store the current one without processing
#   rebrief         BRIEFED, or BLOCKED from NEW / BRIEFED: Intake rewrites the brief
#   rebrief-replan  PLANNED, or BLOCKED from PLANNED: re-brief and mark the plan for review
#   raise-g2        BUILDING and later (BLOCKED from those too): ask me whether to change scope (G2)
#   defer           like raise-g2, but a decision is already pending; ask after it is resolved
# PARKED is left alone and its recorded value is kept, so the change is picked up after resuming.
# Huddle's own comments do not trigger anything because post-issue-note.ps1 records the new
# updated_at with Set-OfficeIssueUpdatedAt right after posting.
function Get-OfficeUpdateAction {
    param(
        [Parameter(Mandatory)][string]$State,
        [string]$ResumeTo,
        [string]$RecordedUpdatedAt,
        [Parameter(Mandatory)][string]$CurrentUpdatedAt,
        [Nullable[int]]$PendingDecision
    )
    Assert-OfficeState $State
    $current = ConvertTo-Instant $CurrentUpdatedAt
    $recorded = ConvertTo-Instant $RecordedUpdatedAt
    $result = { param($a, $why) [pscustomobject]@{ Action = $a; Reason = $why } }

    if ($State -cin 'NEW', 'PARKED', 'DELIVERED', 'PURGED') { return & $result 'none' "state $State is not re-processed" }
    if ($null -eq $recorded) { return & $result 'record' 'no issue updated_at recorded yet' }
    if ($current -le $recorded) { return & $result 'none' 'issue unchanged' }

    $effective = if ($State -ceq 'BLOCKED') { $ResumeTo } else { $State }
    switch ($effective) {
        { $_ -cin 'NEW', 'BRIEFED' } { return & $result 'rebrief' "issue updated while $State" }
        'PLANNED' { return & $result 'rebrief-replan' "issue updated while $State; plan needs review" }
    }
    if ($null -ne $PendingDecision) { return & $result 'defer' "issue updated while $State; decision #$PendingDecision is pending" }
    & $result 'raise-g2' "issue updated while $State"
}

# Records the issue updated_at that Huddle has accounted for (after a re-brief, a G2, or its own comment).
function Set-OfficeIssueUpdatedAt {
    param(
        [Parameter(Mandatory)][string]$OfficeRoot,
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$IssueUpdatedAt,
        [datetime]$Now = (Get-Date)
    )
    $null = ConvertTo-Instant $IssueUpdatedAt
    Set-StatusField $OfficeRoot $Id 'issueUpdatedAt' $IssueUpdatedAt $Now
}

# --- Decisions (SPEC §3.4): office/work/<id>/decisions/<n>.json + <n>.md --------------------------

$script:Gates = @('G1', 'G2', 'Clarify')

# Creates decision <n> (1, 2, ...) for a work item and marks it pending. The .json is the record the
# scripts read; the .md is what /huddle and I read. Only one decision can be pending at a time.
function New-OfficeDecision {
    param(
        [Parameter(Mandatory)][string]$OfficeRoot,
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Gate,
        [Parameter(Mandatory)][string]$Kind,
        [Parameter(Mandatory)][string]$Question,
        [Parameter(Mandatory)][string[]]$Options,
        [string]$Recommendation,
        [string]$Context,
        [datetime]$Now = (Get-Date)
    )
    if ($Gate -cnotin $script:Gates) { throw "Unknown gate '$Gate'. Valid: $($script:Gates -join ', ')." }
    if ($Kind -notmatch '^[a-z][a-z0-9-]*$') { throw "Decision kind must be a lower-case slug (got '$Kind')." }
    if (@($Options).Count -lt 2) { throw 'A decision needs at least two options.' }
    $item = Get-OfficeWorkItem -OfficeRoot $OfficeRoot -Id $Id
    if ($null -ne $item.pendingDecision) { throw "Work item '$Id' already has decision #$($item.pendingDecision) pending." }

    $dir = Join-Path (Get-WorkItemDir $OfficeRoot $Id) 'decisions'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $n = 1 + (@(Get-ChildItem -LiteralPath $dir -Filter '*.json' | ForEach-Object { [int]$_.BaseName }) + 0 | Measure-Object -Maximum).Maximum
    $ts = Format-Timestamp $Now
    $record = [ordered]@{
        id = $n; workItem = $Id; gate = $Gate; kind = $Kind; question = $Question; options = @($Options)
        recommendation = $Recommendation; context = $Context; createdAt = $ts; ruling = $null
    }
    [IO.File]::WriteAllText((Join-Path $dir "$n.json"), ($record | ConvertTo-Json -Depth 4), $script:Utf8NoBom)

    $md = [Text.StringBuilder]::new()
    [void]$md.AppendLine("# Decision $n · $Gate · $($item.project)#$($item.iid)").AppendLine()
    [void]$md.AppendLine("- Created: $ts").AppendLine("- Kind: $Kind").AppendLine()
    [void]$md.AppendLine('## Question').AppendLine($Question).AppendLine().AppendLine('## Options')
    for ($k = 0; $k -lt $Options.Count; $k++) { [void]$md.AppendLine("$($k + 1). $($Options[$k])") }
    if ($Recommendation) { [void]$md.AppendLine().AppendLine('## Recommendation').AppendLine($Recommendation) }
    if ($Context) { [void]$md.AppendLine().AppendLine('## Context').AppendLine($Context) }
    [IO.File]::WriteAllText((Join-Path $dir "$n.md"), $md.ToString(), $script:Utf8NoBom)

    $null = Set-OfficeWorkItemPendingDecision -OfficeRoot $OfficeRoot -Id $Id -DecisionId $n -Now $Now
    Add-OfficeThreadEntry -OfficeRoot $OfficeRoot -Id $Id -From 'office-manager' -To 'user' -Kind 'decision' `
        -Body "$Gate decision #$n ($Kind): $Question" -Refs "decisions/$n.md" -Now $Now
    $n
}

# Records my ruling on a pending decision (append-only in the .md) and clears the pending marker.
# -Choice is the 1-based option number. Returns the chosen option text.
function Resolve-OfficeDecision {
    param(
        [Parameter(Mandatory)][string]$OfficeRoot,
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][int]$DecisionId,
        [Parameter(Mandatory)][int]$Choice,
        [string]$Note,
        [datetime]$Now = (Get-Date)
    )
    $item = Get-OfficeWorkItem -OfficeRoot $OfficeRoot -Id $Id
    if ($item.pendingDecision -ne $DecisionId) { throw "Decision #$DecisionId is not the pending decision of '$Id'." }
    $dir = Join-Path (Get-WorkItemDir $OfficeRoot $Id) 'decisions'
    $jsonPath = Join-Path $dir "$DecisionId.json"
    $d = Get-Content -Raw -Encoding utf8 -LiteralPath $jsonPath | ConvertFrom-Json -AsHashtable -DateKind String
    $options = @($d.options)
    if ($Choice -lt 1 -or $Choice -gt $options.Count) { throw "Choice must be 1..$($options.Count) (got $Choice)." }
    if ($Note -match '[\r\n]') { throw 'The ruling note must be a single line.' }

    $ts = Format-Timestamp $Now
    $chosen = $options[$Choice - 1]
    $d.ruling = [ordered]@{ choice = $Choice; option = $chosen; note = $Note; at = $ts }
    [IO.File]::WriteAllText($jsonPath, ($d | ConvertTo-Json -Depth 4), $script:Utf8NoBom)
    $ruling = "`n## Ruling`n- At: $ts`n- Choice: $Choice. $chosen`n"
    if ($Note) { $ruling += "- Note: $Note`n" }
    [IO.File]::AppendAllText((Join-Path $dir "$DecisionId.md"), $ruling, $script:Utf8NoBom)

    $null = Set-OfficeWorkItemPendingDecision -OfficeRoot $OfficeRoot -Id $Id -Clear -Now $Now
    Add-OfficeThreadEntry -OfficeRoot $OfficeRoot -Id $Id -From 'user' -To 'office-manager' -Kind 'ruling' `
        -Body "Decision #${DecisionId}: $chosen$(if ($Note) { " ($Note)" })" -Refs "decisions/$DecisionId.md" -Now $Now
    $chosen
}

# --- Decision notifications (SPEC §3.4, sent by notify-decision.ps1) -------------------------------
# Each work item keeps office/work/<id>/notifications.json: { "<key>": { result, at, error } }.
# A key is recorded once, whether the post succeeded or failed, so a decision is pushed at most once;
# the decision itself stays on disk and in the SessionStart office status either way.

$script:NotificationSummaryMax = 160
$script:ClarifySummary = 'Work item is BLOCKED and waiting for your answer.'

function Get-NotificationLedgerPath([string]$OfficeRoot, [string]$Id) {
    Join-Path (Get-WorkItemDir $OfficeRoot $Id) 'notifications.json'
}

function Get-NotificationLedger([string]$OfficeRoot, [string]$Id) {
    $path = Get-NotificationLedgerPath $OfficeRoot $Id
    if (-not (Test-Path -LiteralPath $path)) { return @{} }
    $ledger = Get-Content -Raw -Encoding utf8 -LiteralPath $path | ConvertFrom-Json -AsHashtable -DateKind String
    if ($ledger -is [hashtable]) { $ledger } else { @{} }
}

# One line, at most NotificationSummaryMax characters. Only the question goes on the card.
function ConvertTo-NotificationSummary([string]$Text) {
    $line = ($Text -replace '\s+', ' ').Trim()
    if ($line.Length -le $script:NotificationSummaryMax) { return $line }
    $line.Substring(0, $script:NotificationSummaryMax - 1).TrimEnd() + [char]0x2026
}

# Lists the Teams cards that still have to be sent: the pending decision of each work item (G1, G2,
# Clarify), and work items that are BLOCKED without a pending decision (Clarify, e.g. Intake found a
# blocking question). The card carries only the reference, the gate and a one-line summary; the
# work item title, issue text, brief and decision context are never read into it.
function Get-OfficePendingNotifications {
    param([Parameter(Mandatory)][string]$OfficeRoot)
    $workDir = Join-Path $OfficeRoot 'work'
    if (-not (Test-Path -LiteralPath $workDir)) { return }
    foreach ($dir in Get-ChildItem -LiteralPath $workDir -Directory | Sort-Object Name) {
        if (-not (Test-Path -LiteralPath (Join-Path $dir.FullName 'status.json'))) { continue }
        $s = Get-OfficeWorkItem -OfficeRoot $OfficeRoot -Id $dir.Name
        $ledger = Get-NotificationLedger $OfficeRoot $s.id
        $reference = "$($s.project)#$($s.iid)"
        $note = $null
        if ($null -ne $s.pendingDecision) {
            $n = [int]$s.pendingDecision
            $d = Get-Content -Raw -Encoding utf8 -LiteralPath (Join-Path $dir.FullName 'decisions' "$n.json") |
                ConvertFrom-Json -AsHashtable -DateKind String
            $note = @{ Key = "decision-$n"; Gate = $d.gate; Summary = ConvertTo-NotificationSummary $d.question; DecisionId = $n }
        }
        elseif ($s.state -ceq 'BLOCKED') {
            $entered = @($s.history | Where-Object { $_.to -ceq 'BLOCKED' } | Select-Object -Last 1)
            $key = if ($entered.Count) { "blocked-$($entered[0].at)" } else { 'blocked' }
            $note = @{ Key = $key; Gate = 'Clarify'; Summary = $script:ClarifySummary; DecisionId = $null }
        }
        if (-not $note -or $ledger.ContainsKey($note.Key)) { continue }
        [pscustomobject]@{
            Id = $s.id; Reference = $reference; Gate = $note.Gate; Summary = $note.Summary
            Key = $note.Key; DecisionId = $note.DecisionId
        }
    }
}

# Records that a notification was sent or failed (so it is not sent again) and adds a thread entry.
function Add-OfficeNotificationRecord {
    param(
        [Parameter(Mandatory)][string]$OfficeRoot,
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$Gate,
        [Parameter(Mandatory)][ValidateSet('sent', 'failed')][string]$Result,
        [string]$ErrorMessage,
        [datetime]$Now = (Get-Date)
    )
    $ledger = Get-NotificationLedger $OfficeRoot $Id
    $ledger[$Key] = [ordered]@{ result = $Result; at = Format-Timestamp $Now; error = if ($ErrorMessage) { $ErrorMessage } else { $null } }
    $path = Get-NotificationLedgerPath $OfficeRoot $Id
    [IO.File]::WriteAllText("$path.tmp", ($ledger | ConvertTo-Json -Depth 4), $script:Utf8NoBom)
    Move-Item -LiteralPath "$path.tmp" -Destination $path -Force

    $body = if ($Result -ceq 'sent') { "Teams notification sent ($Gate, $Key)." }
    else { "Teams notification failed ($Gate, $Key); the decision flow continues. $(($ErrorMessage -replace '\s+', ' ').Trim())" }
    Add-OfficeThreadEntry -OfficeRoot $OfficeRoot -Id $Id -From 'office-manager' -To 'user' -Kind 'notify' -Body $body -Now $Now
}

# --- Planning and G1 (SPEC §3.3, §3.4, §3.6, §3.10) -----------------------------------------------

# plan.md is Huddle's own format (written by the Builder agent, checked here); analysis-comment.md
# follows the gitlab-issue skill and is not checked section by section, so its rules live in one place.
$script:PlanSections = @('概要', '分析', '選定做法與理由', '考慮過但沒採用', '任務清單', '預計修改的檔案', '驗證與回退')

# States that hold the single build slot (maxActiveBuilds): BUILDING up to READY.
$script:BuildStates = @('BUILDING', 'TESTING', 'SEC_REVIEW', 'REVIEW', 'READY')

# Returns the required '## ' sections that plan.md lacks (empty when complete).
function Test-OfficePlan {
    param([Parameter(Mandatory)][string]$Path)
    Get-MissingSections $Path $script:PlanSections
}

# Ids of work items that hold a build slot: in BUILDING..READY, or PARKED / BLOCKED from one of those
# (a paused build still owns its worktree, so it still counts).
function Get-OfficeActiveBuilds {
    param(
        [Parameter(Mandatory)][string]$OfficeRoot,
        [string]$ExceptId
    )
    $workDir = Join-Path $OfficeRoot 'work'
    if (-not (Test-Path -LiteralPath $workDir)) { return }
    foreach ($dir in Get-ChildItem -LiteralPath $workDir -Directory | Sort-Object Name) {
        if ($dir.Name -ceq $ExceptId) { continue }
        if (-not (Test-Path -LiteralPath (Join-Path $dir.FullName 'status.json'))) { continue }
        $s = Get-OfficeWorkItem -OfficeRoot $OfficeRoot -Id $dir.Name
        $state = if ($s.state -cin $script:HoldStates) { $s.resumeTo } else { $s.state }
        if ($state -cin $script:BuildStates) { $s.id }
    }
}

# Reads and checks office/work/<id>/project-profile.json against the registry (SPEC §3.6 step 3).
# G1 has to approve project settings when the project is unregistered, or registered with a null
# baseBranch. Never throws on a bad draft; returns:
#   Needed  whether this project needs approved settings at all
#   Errors  what is wrong with the draft (empty when it can be saved)
#   Entry   the projects[] entry to save: match, repoPath, baseBranch, commands (evidence is dropped)
#   Index   position of the registered entry to fill in, or $null to append a new entry
# match and repoPath are not taken from the draft: they must equal what the registry already says,
# or, for an unregistered project, its exact path and auto-clone location. baseBranch must exist in
# the repo (origin/<base> or a local branch); only git reads are used.
function Read-OfficeProjectProfile {
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][string]$ProjectPath,
        [Parameter(Mandatory)][string]$Path
    )
    $p = Resolve-OfficeProject -Config $Config -ProjectPath $ProjectPath
    $index = $null
    if ($p.Registered) {
        $all = @($Config.projects)
        for ($k = 0; $k -lt $all.Count; $k++) { if ($ProjectPath -like $all[$k].match) { $index = $k; break } }
    }
    $needed = (-not $p.Registered) -or (-not $p.Project.baseBranch)
    $result = [pscustomobject]@{ Needed = $needed; Errors = [string[]]@(); Entry = $null; Index = $index; Path = $Path }
    if (-not $needed) { return $result }

    $errors = [Collections.Generic.List[string]]::new()
    $draft = $null
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { $errors.Add('project-profile.json is missing') }
    else {
        try { $draft = Get-Content -Raw -Encoding utf8 -LiteralPath $Path | ConvertFrom-Json -AsHashtable }
        catch { $errors.Add("project-profile.json is not valid JSON: $($_.Exception.Message)") }
        if ($null -ne $draft -and $draft -isnot [Collections.IDictionary]) { $errors.Add('project-profile.json must be a JSON object'); $draft = $null }
    }
    if ($null -ne $draft) {
        foreach ($k in $draft.Keys) {
            if ($k -cnotin 'match', 'repoPath', 'baseBranch', 'commands', 'evidence') { $errors.Add("unknown key '$k'") }
        }
        $expectMatch = if ($p.Registered) { $p.Project.match } else { $ProjectPath }
        if ($draft['match'] -cne $expectMatch) { $errors.Add("match must be '$expectMatch' (got '$($draft['match'])')") }
        $draftRepo = [string]$draft['repoPath']
        if (-not $draftRepo -or -not [IO.Path]::IsPathFullyQualified($draftRepo) -or
            [IO.Path]::GetFullPath($draftRepo).TrimEnd('\', '/') -ine [IO.Path]::GetFullPath($p.RepoPath).TrimEnd('\', '/')) {
            $errors.Add("repoPath must be '$($p.RepoPath)' (got '$draftRepo')")
        }

        $base = $draft['baseBranch']
        if ($base -isnot [string] -or -not $base.Trim()) { $errors.Add('baseBranch must be a non-empty string') }
        elseif (-not (Test-Path -LiteralPath $p.RepoPath -PathType Container)) { $errors.Add("repo '$($p.RepoPath)' does not exist, so baseBranch cannot be checked") }
        else {
            & git -C $p.RepoPath check-ref-format --branch $base 2>$null | Out-Null
            if ($LASTEXITCODE -ne 0) { $errors.Add("baseBranch '$base' is not a valid branch name") }
            elseif (-not (Test-OfficeGitRef $p.RepoPath "refs/remotes/origin/$base") -and -not (Test-OfficeGitRef $p.RepoPath "refs/heads/$base")) {
                $errors.Add("baseBranch '$base' exists neither as origin/$base nor as a local branch in '$($p.RepoPath)'")
            }
        }

        $commands = $draft['commands']
        if ($commands -isnot [Collections.IDictionary]) { $errors.Add('commands must be an object with build and test') }
        else {
            foreach ($k in $commands.Keys) { if ($k -cnotin 'build', 'test') { $errors.Add("commands: unknown key '$k'") } }
            foreach ($k in 'build', 'test') {
                $v = $commands[$k]
                if ($null -ne $v -and ($v -isnot [string] -or -not $v.Trim() -or $v -match '[\r\n]')) {
                    $errors.Add("commands.$k must be null or a one-line command")
                }
            }
        }
        if ($errors.Count -eq 0) {
            $result.Entry = [ordered]@{
                match      = $expectMatch
                repoPath   = $p.RepoPath
                baseBranch = $base
                commands   = [ordered]@{ build = $commands['build']; test = $commands['test'] }
            }
        }
    }
    $result.Errors = [string[]]$errors.ToArray()
    $result
}

# Writes an approved project-profile.json into config/office.json (only called on G1 approval).
# Appends a new projects[] entry, or fills baseBranch and commands of the registered one. The new
# file is checked with Get-OfficeConfig before it replaces the old one. Returns $true when written,
# $false when the project needed no settings.
function Save-OfficeProjectProfile {
    param(
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][string]$ProjectPath,
        [Parameter(Mandatory)][string]$ProfilePath
    )
    $config = Get-OfficeConfig -Path $ConfigPath
    $r = Read-OfficeProjectProfile -Config $config -ProjectPath $ProjectPath -Path $ProfilePath
    if (-not $r.Needed) { return $false }
    if ($r.Errors.Count) { throw "project-profile.json cannot be saved: $($r.Errors -join '; ')" }
    $projects = @($config.projects)
    if ($null -eq $r.Index) { $projects += $r.Entry }
    else {
        $projects[$r.Index].baseBranch = $r.Entry.baseBranch
        $projects[$r.Index].commands = $r.Entry.commands
    }
    $config.projects = $projects
    $tmp = "$ConfigPath.tmp"
    [IO.File]::WriteAllText($tmp, (($config | ConvertTo-Json -Depth 6) + "`n"), $script:Utf8NoBom)
    try { $null = Get-OfficeConfig -Path $tmp }
    catch { Remove-Item -LiteralPath $tmp -Force; throw }
    Move-Item -LiteralPath $tmp -Destination $ConfigPath -Force
    $true
}

# Sets the build / test command of a registered project after G1 (SPEC §3.6). G1 only writes the
# commands Intake proposed in project-profile.json; a project whose commands were left null, or whose
# command has to change (e.g. tests that must run against a worktree instead of my own clone), is
# changed here, and only when I ask for it. The agents run these commands inside the work item's
# worktree, so a command must work from that folder. -Test / -Build set a command (one line);
# -ClearTest / -ClearBuild set it back to null; a command that is not named stays as it is.
# The new file is checked with Get-OfficeConfig before it replaces the old one.
# Returns { Project, Before = { build, test }, After = { build, test } }.
function Set-OfficeProjectCommands {
    param(
        [Parameter(Mandatory)][string]$ConfigPath,
        # The project's `match` value in config/office.json, exactly (e.g. acme/SupportDesk).
        [Parameter(Mandatory)][string]$Project,
        [string]$Test,
        [string]$Build,
        [switch]$ClearTest,
        [switch]$ClearBuild
    )
    if ($Test -and $ClearTest) { throw 'Give -Test or -ClearTest, not both.' }
    if ($Build -and $ClearBuild) { throw 'Give -Build or -ClearBuild, not both.' }
    if (-not ($Test -or $Build -or $ClearTest -or $ClearBuild)) { throw 'Nothing to change: give -Test, -Build, -ClearTest or -ClearBuild.' }
    foreach ($cmd in $Test, $Build) {
        if ($cmd -match '[\r\n]') { throw 'A command must be a single line.' }
        if ($cmd -and -not $cmd.Trim()) { throw 'A command must not be blank.' }
    }

    $config = Get-OfficeConfig -Path $ConfigPath
    $projects = @($config.projects)
    $index = -1
    for ($k = 0; $k -lt $projects.Count; $k++) { if ([string]$projects[$k].match -ieq $Project) { $index = $k; break } }
    if ($index -lt 0) { throw "Project '$Project' is not registered in '$ConfigPath' (match must be exact). Project settings of a new project are approved at G1." }

    $old = $projects[$index].commands
    $before = [ordered]@{ build = $(if ($old) { $old['build'] }); test = $(if ($old) { $old['test'] }) }
    $after = [ordered]@{ build = $before.build; test = $before.test }
    if ($Test) { $after.test = $Test.Trim() } elseif ($ClearTest) { $after.test = $null }
    if ($Build) { $after.build = $Build.Trim() } elseif ($ClearBuild) { $after.build = $null }

    $projects[$index].commands = [ordered]@{ build = $after.build; test = $after.test }
    $config.projects = $projects
    $tmp = "$ConfigPath.tmp"
    [IO.File]::WriteAllText($tmp, (($config | ConvertTo-Json -Depth 6) + "`n"), $script:Utf8NoBom)
    try { $null = Get-OfficeConfig -Path $tmp }
    catch { Remove-Item -LiteralPath $tmp -Force; throw }
    Move-Item -LiteralPath $tmp -Destination $ConfigPath -Force
    [pscustomobject]@{ Project = [string]$projects[$index].match; Before = $before; After = $after }
}

# Raises the G1 decision for a PLANNED work item (SPEC §3.4), unless the build slot is taken
# (maxActiveBuilds; then the item stays PLANNED in the queue) or a decision is already pending.
# Returns { Result: raised | queued | pending, DecisionId, ActiveBuilds }.
function Request-OfficeG1 {
    param(
        [Parameter(Mandatory)][string]$OfficeRoot,
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][hashtable]$Config,
        [datetime]$Now = (Get-Date)
    )
    $item = Get-OfficeWorkItem -OfficeRoot $OfficeRoot -Id $Id
    if ($item.state -cne 'PLANNED') { throw "G1 is only raised for PLANNED work items ('$Id' is $($item.state))." }
    if ($null -ne $item.pendingDecision) {
        return [pscustomobject]@{ Result = 'pending'; DecisionId = [int]$item.pendingDecision; ActiveBuilds = [string[]]@() }
    }
    if ($item['planNeedsReview']) { throw "The plan of '$Id' needs review (the brief changed); run the Builder again before G1." }
    $dir = Get-WorkItemDir $OfficeRoot $Id
    $missing = @(Test-OfficePlan -Path (Join-Path $dir 'plan.md'))
    if ($missing.Count) { throw "plan.md of '$Id' is missing sections: $($missing -join ', ')." }

    $active = @(Get-OfficeActiveBuilds -OfficeRoot $OfficeRoot -ExceptId $Id)
    if ($active.Count -ge [int]$Config.maxActiveBuilds) {
        Add-OfficeThreadEntry -OfficeRoot $OfficeRoot -Id $Id -From 'office-manager' -To 'user' -Kind 'queued' `
            -Body "Plan is ready, but the build slot is taken ($($active -join ', '); maxActiveBuilds $($Config.maxActiveBuilds)). G1 is asked when /huddle-take is run again after that build is done." -Now $Now
        return [pscustomobject]@{ Result = 'queued'; DecisionId = $null; ActiveBuilds = [string[]]$active }
    }

    $prof = Read-OfficeProjectProfile -Config $Config -ProjectPath $item.project -Path (Join-Path $dir 'project-profile.json')
    if ($prof.Needed -and $prof.Errors.Count) { throw "project-profile.json of '$Id' is not valid: $($prof.Errors -join '; ')." }

    $ref = "$($item.project)#$($item.iid)"
    $context = [Collections.Generic.List[string]]::new()
    $context.Add("Read office/work/$Id/brief.md and office/work/$Id/plan.md.")
    $approve = 'Approve: start building'
    $question = "G1: approve the plan for $ref and start building?"
    if ($prof.Needed) {
        $e = $prof.Entry
        $what = if ($null -eq $prof.Index) { "adds a new project '$($e.match)' to config/office.json" } else { "fills baseBranch and commands of '$($e.match)' in config/office.json" }
        $question += ' This also approves the project settings.'
        $approve = 'Approve: start building and save the project settings'
        $context.Add("Project settings (project-profile.json; approving $what): repoPath $($e.repoPath), baseBranch $($e.baseBranch), build $(if ($e.commands.build) { $e.commands.build } else { 'null' }), test $(if ($e.commands.test) { $e.commands.test } else { 'null' }).")
    }
    $context.Add('Nothing is written to the repo or config before approval. The worktree is created when implementation starts.')
    $n = New-OfficeDecision -OfficeRoot $OfficeRoot -Id $Id -Gate 'G1' -Kind 'g1' -Question $question `
        -Options @($approve, 'Not approved: keep it PLANNED and revise the plan (give the reason as the note)', 'Not approved: park the work item') `
        -Context ($context -join "`n") -Now $Now
    [pscustomobject]@{ Result = 'raised'; DecisionId = $n; ActiveBuilds = [string[]]@() }
}

# Applies the Builder's plan-mode reply (SPEC §3.8 "/huddle-take": BRIEFED -> PLANNED, then G1).
# 'done' needs a valid outcome, a complete plan.md and, when the project needs settings, a valid
# project-profile.json; anything else counts as blocked (BLOCKED with blockedBy = builder).
function Complete-OfficePlan {
    param(
        [Parameter(Mandatory)][string]$OfficeRoot,
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][AllowEmptyString()][string]$ReplyText,
        [Parameter(Mandatory)][hashtable]$Config,
        [datetime]$Now = (Get-Date)
    )
    $item = Get-OfficeWorkItem -OfficeRoot $OfficeRoot -Id $Id
    $ok = ($item.state -ceq 'BRIEFED') -or
          ($item.state -ceq 'PLANNED' -and $null -eq $item.pendingDecision) -or
          ($item.state -ceq 'BLOCKED' -and $item['blockedBy'] -ceq 'builder' -and $item.resumeTo -cin 'BRIEFED', 'PLANNED')
    if (-not $ok) { throw "Builder plan results cannot be applied to '$Id' in state $($item.state)$(if ($null -ne $item.pendingDecision) { " with decision #$($item.pendingDecision) pending" })." }

    $o = Get-AgentOutcome -Text $ReplyText -OfficeRoot $OfficeRoot -Id $Id -Agent 'builder' -Now $Now
    $dir = Get-WorkItemDir $OfficeRoot $Id
    $missing = @(Test-OfficePlan -Path (Join-Path $dir 'plan.md'))
    $prof = Read-OfficeProjectProfile -Config $Config -ProjectPath $item.project -Path (Join-Path $dir 'project-profile.json')

    $result = 'blocked'
    $reason = $o.Summary
    if ($o.Valid) {
        if ($o.Outcome -cne 'done' -and $o.Outcome -cne 'blocked') { $reason = "Builder returned '$($o.Outcome)', which it may not use when planning: $($o.Summary)" }
        elseif ($o.Outcome -ceq 'done' -and $missing.Count) { $reason = "plan.md is missing sections: $($missing -join ', ')" }
        elseif ($o.Outcome -ceq 'done' -and $prof.Needed -and $prof.Errors.Count) { $reason = "project-profile.json: $($prof.Errors -join '; ')" }
        elseif ($o.Outcome -ceq 'done') { $result = 'done' }
        Add-OfficeThreadEntry -OfficeRoot $OfficeRoot -Id $Id -From 'builder' -To 'office-manager' -Kind $o.Outcome `
            -Body $o.Summary -Refs 'plan.md' -Now $Now
    }

    $from = $item.state
    $g1 = $null
    if ($result -ceq 'done') {
        if ($from -ceq 'BLOCKED') {
            $null = Set-OfficeWorkItemState -OfficeRoot $OfficeRoot -Id $Id -State $item.resumeTo -Now $Now
            $from = $item.resumeTo
        }
        if ($from -ceq 'BRIEFED') { $null = Set-OfficeWorkItemState -OfficeRoot $OfficeRoot -Id $Id -State 'PLANNED' -Now $Now }
        $null = Set-StatusField $OfficeRoot $Id 'planNeedsReview' $false $Now
    }
    elseif ($from -cin 'BRIEFED', 'PLANNED') {
        $null = Set-OfficeWorkItemState -OfficeRoot $OfficeRoot -Id $Id -State 'BLOCKED' -Now $Now
        $null = Set-StatusField $OfficeRoot $Id 'blockedBy' 'builder' $Now
    }
    $after = Get-OfficeWorkItem -OfficeRoot $OfficeRoot -Id $Id
    if ($after.state -cne $item.state) {
        Add-OfficeThreadEntry -OfficeRoot $OfficeRoot -Id $Id -From 'office-manager' -To 'builder' -Kind 'state' `
            -Body "$($item.state) -> $($after.state)$(if ($result -ceq 'blocked') { ": $reason" })" -Now $Now
    }
    if ($result -ceq 'done') { $g1 = Request-OfficeG1 -OfficeRoot $OfficeRoot -Id $Id -Config $Config -Now $Now }

    [pscustomobject]@{
        Id = $Id; Result = $result; Reason = $reason; From = $item.state
        State = (Get-OfficeWorkItem -OfficeRoot $OfficeRoot -Id $Id).state
        Valid = $o.Valid; MissingSections = [string[]]$missing; ProfileErrors = [string[]]$prof.Errors; G1 = $g1
    }
}

# Records my G1 ruling (SPEC §3.4) and applies it:
#   1 approve   PLANNED -> BUILDING with this decision id; project settings saved to config/office.json first
#   2 revise    stays PLANNED, planNeedsReview = true, so /huddle-take runs the Builder again
#   3 park      PLANNED -> PARKED
# Approval is refused (the decision stays pending) when the plan was flagged for review after the
# decision was raised, when the build slot is taken, or when the profile draft is not valid.
# Nothing is written for options 2 and 3 except the ruling and the state.
function Invoke-OfficeG1Ruling {
    param(
        [Parameter(Mandatory)][string]$OfficeRoot,
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][int]$DecisionId,
        [Parameter(Mandatory)][int]$Choice,
        [string]$Note,
        [Parameter(Mandatory)][string]$ConfigPath,
        [datetime]$Now = (Get-Date)
    )
    $item = Get-OfficeWorkItem -OfficeRoot $OfficeRoot -Id $Id
    $dir = Get-WorkItemDir $OfficeRoot $Id
    $d = Get-Content -Raw -Encoding utf8 -LiteralPath (Join-Path $dir 'decisions' "$DecisionId.json") | ConvertFrom-Json -AsHashtable -DateKind String
    if ($d.kind -cne 'g1') { throw "Decision #$DecisionId of '$Id' is not a G1 decision (kind '$($d.kind)')." }
    if ($item.pendingDecision -ne $DecisionId) { throw "Decision #$DecisionId is not the pending decision of '$Id'." }
    if ($item.state -cne 'PLANNED') { throw "'$Id' is $($item.state); a G1 ruling needs PLANNED." }

    if ($Choice -eq 1) {
        if ($item['planNeedsReview']) {
            throw "The plan of '$Id' was flagged for review after this G1 was raised (the issue changed). Choose option 2 to have the Builder revise it."
        }
        $config = Get-OfficeConfig -Path $ConfigPath
        $active = @(Get-OfficeActiveBuilds -OfficeRoot $OfficeRoot -ExceptId $Id)
        if ($active.Count -ge [int]$config.maxActiveBuilds) {
            throw "The build slot is taken ($($active -join ', ')); approving '$Id' would exceed maxActiveBuilds $($config.maxActiveBuilds)."
        }
        $prof = Read-OfficeProjectProfile -Config $config -ProjectPath $item.project -Path (Join-Path $dir 'project-profile.json')
        if ($prof.Needed -and $prof.Errors.Count) { throw "project-profile.json of '$Id' is not valid: $($prof.Errors -join '; ')." }
        $saved = Save-OfficeProjectProfile -ConfigPath $ConfigPath -ProjectPath $item.project -ProfilePath $prof.Path
        $option = Resolve-OfficeDecision -OfficeRoot $OfficeRoot -Id $Id -DecisionId $DecisionId -Choice 1 -Note $Note -Now $Now
        $null = Set-OfficeWorkItemState -OfficeRoot $OfficeRoot -Id $Id -State 'BUILDING' -DecisionId $DecisionId -Now $Now
        Add-OfficeThreadEntry -OfficeRoot $OfficeRoot -Id $Id -From 'office-manager' -To 'builder' -Kind 'state' `
            -Body "PLANNED -> BUILDING (G1 #$DecisionId approved).$(if ($saved) { ' Project settings saved to config/office.json.' }) Next: analysis-comment.md." -Now $Now
    }
    else {
        $option = Resolve-OfficeDecision -OfficeRoot $OfficeRoot -Id $Id -DecisionId $DecisionId -Choice $Choice -Note $Note -Now $Now
        if ($Choice -eq 2) { $null = Set-StatusField $OfficeRoot $Id 'planNeedsReview' $true $Now }
        else { $null = Set-OfficeWorkItemState -OfficeRoot $OfficeRoot -Id $Id -State 'PARKED' -Now $Now }
    }
    $s = Get-OfficeWorkItem -OfficeRoot $OfficeRoot -Id $Id
    [pscustomobject]@{ Option = $option; State = $s.state; PlanNeedsReview = [bool]$s['planNeedsReview'] }
}

# Draft markers in the Builder's analysis-comment reply. Each must stand alone on its own line.
$script:DraftBegin = '<!-- huddle:draft:begin -->'
$script:DraftEnd = '<!-- huddle:draft:end -->'

# Returns the text between exactly one pair of draft markers (trimmed of surrounding blank lines),
# or throws when the markers are missing, repeated, or out of order.
function Get-AgentDraft([string]$Text) {
    $lines = $Text -split '\r?\n'
    $begin = @(for ($k = 0; $k -lt $lines.Count; $k++) { if ($lines[$k].Trim() -ceq $script:DraftBegin) { $k } })
    $end = @(for ($k = 0; $k -lt $lines.Count; $k++) { if ($lines[$k].Trim() -ceq $script:DraftEnd) { $k } })
    if ($begin.Count -ne 1 -or $end.Count -ne 1) {
        throw "the reply must contain exactly one '$($script:DraftBegin)' line and one '$($script:DraftEnd)' line (found $($begin.Count) and $($end.Count))"
    }
    if ($end[0] -le $begin[0]) { throw 'the draft end marker comes before the begin marker' }
    $body = if ($end[0] - $begin[0] -gt 1) { ($lines[($begin[0] + 1)..($end[0] - 1)] -join "`n").Trim("`n", "`r", ' ') } else { '' }
    if (-not $body.Trim()) { throw 'the draft between the markers is empty' }
    $body
}

# Applies the Builder's analysis-comment reply (SPEC §3.10 P / D3 / D4). Only after G1 (state in
# BUILDING..READY). The Builder returns the draft as text between the draft markers and this function
# writes it to analysis-comment.md (Claude Code does not let subagents write report files). The draft
# is not posted from here: that is post-issue-note.ps1 (T16) behind G3, or I paste it myself. Never
# changes the state: posting or not does not affect the build.
function Complete-OfficeAnalysisComment {
    param(
        [Parameter(Mandatory)][string]$OfficeRoot,
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][AllowEmptyString()][string]$ReplyText,
        [datetime]$Now = (Get-Date)
    )
    $item = Get-OfficeWorkItem -OfficeRoot $OfficeRoot -Id $Id
    if ($item.state -cnotin $script:BuildStates) { throw "analysis-comment.md is written after G1; '$Id' is $($item.state)." }
    $o = Get-AgentOutcome -Text $ReplyText -OfficeRoot $OfficeRoot -Id $Id -Agent 'builder' -Now $Now
    $path = Join-Path (Get-WorkItemDir $OfficeRoot $Id) 'analysis-comment.md'

    $result = 'blocked'
    $reason = $o.Summary
    if ($o.Valid) {
        if ($o.Outcome -cnotin 'done', 'blocked') { $reason = "Builder returned '$($o.Outcome)', which it may not use for the comment draft: $($o.Summary)" }
        elseif ($o.Outcome -ceq 'done') {
            try {
                $draft = Get-AgentDraft $ReplyText
                [IO.File]::WriteAllText($path, "$draft`n", $script:Utf8NoBom)
                $result = 'done'
            }
            catch { $reason = "no usable draft in the reply: $($_.Exception.Message)" }
        }
        Add-OfficeThreadEntry -OfficeRoot $OfficeRoot -Id $Id -From 'builder' -To 'office-manager' -Kind $o.Outcome `
            -Body $o.Summary -Refs 'analysis-comment.md' -Now $Now
    }
    if ($result -cne 'done') {
        Add-OfficeThreadEntry -OfficeRoot $OfficeRoot -Id $Id -From 'office-manager' -To 'user' -Kind 'note' `
            -Body "analysis-comment.md not ready: $reason. The build is not affected." -Now $Now
    }
    [pscustomobject]@{ Id = $Id; Result = $result; Reason = $reason; State = $item.state; Valid = $o.Valid; Path = $path }
}

# --- Build loop (T13, T14, SPEC §3.3): BUILDING -> TESTING -> SEC_REVIEW -> REVIEW -> READY --------
#
# The Builder implements in the work item's worktree and commits there; the Tester, Security and the
# Reviewer only read the worktree and return their report as text between the draft markers, which these
# functions save as test-report.md / security-report.md / review-report.md (Claude Code does not let
# subagents write report files). Disagreements (SPEC §3.3 conditions 1-4, Test-OfficeDivergence) become a
# G2 decision; anything else the loop cannot apply on its own (blocked, a reply that breaks the rules)
# moves the work item to BLOCKED with blockedBy / blockedReason.

$script:LoopAgents = @{ BUILDING = 'builder'; TESTING = 'tester'; SEC_REVIEW = 'security'; REVIEW = 'reviewer' }
# Where each reviewing agent sends the work item when it passes, and the report it writes.
$script:LoopNext = @{ tester = 'SEC_REVIEW'; security = 'REVIEW'; reviewer = 'READY' }
$script:LoopReports = @{ tester = 'test-report.md'; security = 'security-report.md'; reviewer = 'review-report.md' }
$script:TestReportSections = @('結果', '執行的指令', '失敗項目', '覆蓋率與缺口')
$script:SecurityReportSections = @('範圍', 'Findings')
$script:ReviewReportSections = @('範圍', '審查意見')
$script:Severities = @('critical', 'high', 'medium', 'low')
# Severities that must be fixed before REVIEW (SPEC §3.3 condition 1 uses the same threshold).
$script:BlockingSeverities = @('critical', 'high', 'medium')
$script:ReviewAxes = @('正確性', '可讀性', '架構', '安全性', '效能')
$script:ReviewVerdicts = @('必須修', '建議')
# How many times the Builder may object to the Tester before it is a disagreement (SPEC §3.3 condition 2:
# both sides insisted for more than one round).
$script:TesterDisputeLimit = 2

# Fingerprint of my own clone: branch, HEAD, and a hash of its uncommitted state (status, the diff of
# tracked files against HEAD, and the content of every untracked file), so an edit to a file that was
# already modified is noticed too. Ignored files are not covered.
function Get-OfficeRepoSnapshot([string]$Repo) {
    $branch = & git -C $Repo symbolic-ref --short -q HEAD 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $branch) { $branch = '(detached)' }
    $parts = @(Invoke-OfficeGit $Repo @('status', '--porcelain=v1', '--untracked-files=all'))
    $parts += @(Invoke-OfficeGit $Repo @('diff', 'HEAD', '--binary', '--no-ext-diff', '--no-color'))
    $untracked = @(Invoke-OfficeGit $Repo @('ls-files', '--others', '--exclude-standard', '-z') | ForEach-Object { $_ -split "`0" } | Where-Object { $_ })
    if ($untracked.Count) { $parts += @(Invoke-OfficeGit $Repo (@('hash-object', '--') + $untracked)) }
    $sha = [Security.Cryptography.SHA256]::HashData($script:Utf8NoBom.GetBytes(($parts -join "`n")))
    [ordered]@{
        branch     = "$branch".Trim()
        head       = @(Invoke-OfficeGit $Repo @('rev-parse', 'HEAD'))[0]
        statusHash = [Convert]::ToHexString($sha).ToLowerInvariant()
    }
}

# Compares two snapshots of my own clone (T15d). The Builder may only write in the worktree, but I keep
# working in the clone while it runs, so only changes the Builder could have made are problems:
#   - the checked-out branch changed;
#   - HEAD moved to a commit that does not descend from the old one (reset, checkout of another commit);
#   - HEAD is the same but the uncommitted changes differ.
# HEAD advancing on the same branch is taken as my own commits and reported as a note (the commits are
# listed so I can audit them); the uncommitted changes may differ then, because committing changes them.
function Compare-OfficeRepoSnapshot {
    param(
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][Collections.IDictionary]$Before,
        [Parameter(Mandatory)][Collections.IDictionary]$After
    )
    $problems = @()
    $notes = @()
    $prefix = 'my clone at repoPath'
    if ($After.branch -cne $Before.branch) {
        $problems += "$prefix switched from branch '$($Before.branch)' to '$($After.branch)'; the Builder may only write in the worktree"
    }
    if ($After.head -cne $Before.head) {
        & git -C $Repo merge-base --is-ancestor $Before.head $After.head 2>$null
        if ($LASTEXITCODE -ne 0) {
            $problems += "$prefix moved from $($Before.head) to $($After.head), which does not descend from it (reset or checkout); the Builder may only write in the worktree"
        }
        elseif (-not $problems.Count) {
            $log = @(Invoke-OfficeGit $Repo @('log', '--format=%h %an %ad %s', '--date=iso-strict', '--no-decorate', "$($Before.head)..$($After.head)"))
            $status = if ($After.statusHash -cne $Before.statusHash) { 'the uncommitted changes differ too' } else { 'the uncommitted changes are unchanged' }
            $notes += "$prefix advanced by $($log.Count) commit(s) on '$($After.branch)' while the Builder ran, taken as my own work ($status): $(($log | Select-Object -First 5) -join '; ')$(if ($log.Count -gt 5) { '; ...' })"
        }
    }
    elseif ($After.statusHash -cne $Before.statusHash) {
        $problems += "$prefix has different uncommitted changes than when the Builder was dispatched (HEAD $($After.head) unchanged); the Builder may only write in the worktree"
    }
    [pscustomobject]@{ Problems = $problems; Notes = $notes }
}

# What changed in the worktree that nobody committed (empty when clean).
function Get-OfficeWorktreeChanges([string]$Worktree) {
    @(Invoke-OfficeGit $Worktree @('status', '--porcelain=v1', '--untracked-files=all') | Where-Object { $_ })
}

function Set-OfficeLoopBlocked {
    param([string]$OfficeRoot, [string]$Id, [string]$Agent, [string]$Reason, [datetime]$Now)
    $from = (Get-OfficeWorkItem -OfficeRoot $OfficeRoot -Id $Id).state
    $null = Set-OfficeWorkItemState -OfficeRoot $OfficeRoot -Id $Id -State 'BLOCKED' -Now $Now
    $null = Set-StatusField $OfficeRoot $Id 'blockedBy' $Agent $Now
    $null = Set-StatusField $OfficeRoot $Id 'blockedReason' $Reason $Now
    Add-OfficeThreadEntry -OfficeRoot $OfficeRoot -Id $Id -From 'office-manager' -To 'user' -Kind 'state' `
        -Body "$from -> BLOCKED: $Reason" -Now $Now
}

function Move-OfficeLoopState {
    param([string]$OfficeRoot, [string]$Id, [string]$To, [string]$Agent, [datetime]$Now)
    $from = (Get-OfficeWorkItem -OfficeRoot $OfficeRoot -Id $Id).state
    $s = Set-OfficeWorkItemState -OfficeRoot $OfficeRoot -Id $Id -State $To -Now $Now
    Add-OfficeThreadEntry -OfficeRoot $OfficeRoot -Id $Id -From 'office-manager' -To $Agent -Kind 'state' `
        -Body "$from -> $To$(if ($To -ceq 'BUILDING') { " (round $($s.round))" })" -Now $Now
}

function Get-OfficeRoundLimit([Collections.IDictionary]$Item, [Collections.IDictionary]$Config) {
    [int]$Config.maxAutoRounds + [int]$(if ($Item['extraRounds']) { $Item['extraRounds'] } else { 0 })
}

# SPEC §3.3: is this agent result a disagreement that needs my G2 ruling? Pure; reads the work item's
# status as it is before the result is applied. Returns { Diverged, Condition (1-4 or 0), Kind, Reason }:
#   1  Builder objects to Security (Security only sends work back for findings of medium or above)
#   2  Builder objects to the Tester again after the Tester insisted (both sides insisted a round)
#   3  Builder objects to a Reviewer must-fix item
#   4  a reviewing agent sends the work back and that round would exceed maxAutoRounds (+ extra rounds
#      I allowed at an earlier G2)
function Test-OfficeDivergence {
    param(
        [Parameter(Mandatory)][Collections.IDictionary]$Item,
        [Parameter(Mandatory)][ValidateSet('builder', 'tester', 'security', 'reviewer')][string]$Agent,
        [Parameter(Mandatory)][string]$Outcome,
        [string]$ObjectionTo,
        [Parameter(Mandatory)][Collections.IDictionary]$Config
    )
    $none = [pscustomobject]@{ Diverged = $false; Condition = 0; Kind = $null; Reason = $null }
    if ($Outcome -cne 'objection') { return $none }
    if ($Agent -ceq 'builder') {
        switch ($ObjectionTo) {
            'security' { return [pscustomobject]@{ Diverged = $true; Condition = 1; Kind = 'divergence-security'; Reason = 'The Builder disagrees with a Security finding of medium or above.' } }
            'reviewer' { return [pscustomobject]@{ Diverged = $true; Condition = 3; Kind = 'divergence-reviewer'; Reason = 'The Builder disagrees with a Reviewer must-fix item.' } }
            'tester' {
                $count = [int]$(if ($Item['testerDisputes']) { $Item['testerDisputes'] } else { 0 }) + 1
                if ($count -ge $script:TesterDisputeLimit) {
                    return [pscustomobject]@{ Diverged = $true; Condition = 2; Kind = 'divergence-tester'; Reason = "The Builder and the Tester each insisted ($count objections by the Builder)." }
                }
            }
        }
        return $none
    }
    $limit = Get-OfficeRoundLimit $Item $Config
    if ([int]$Item.round + 1 -gt $limit) {
        return [pscustomobject]@{ Diverged = $true; Condition = 4; Kind = 'round-limit'; Reason = "Round $([int]$Item.round + 1) would exceed the limit of $limit automatic rounds." }
    }
    $none
}

# Raises the G2 decision for a divergence (the work item stays where it is, with the decision pending).
function Request-OfficeG2 {
    param([string]$OfficeRoot, [string]$Id, [pscustomobject]$Divergence, [string]$Summary, [datetime]$Now)
    $s = Get-OfficeWorkItem -OfficeRoot $OfficeRoot -Id $Id
    $ref = "$($s.project)#$($s.iid)"
    $dir = Get-WorkItemDir $OfficeRoot $Id
    if ($Divergence.Kind -ceq 'round-limit') {
        $question = "G2: $ref has reached round $($s.round) of the build loop, over the automatic limit. Allow another round?"
        $options = @('Allow one more automatic round (the Builder continues)', 'Park the work item')
        $last = if ($s['returnedBy']) { " The last report that sent the work back: $($script:LoopReports[[string]$s['returnedBy']])." } else { '' }
        $context = "$($Divergence.Reason)$last Every round is in thread.md."
    }
    else {
        $other = $Divergence.Kind -replace '^divergence-', ''
        $report = Join-Path $dir $script:LoopReports[$other]
        $next = $script:LoopNext[$other]
        $question = "G2: on $ref the Builder disagrees with the $other. Should the Builder fix it?"
        $options = @(
            "Fix it: the Builder addresses the $other's $($script:LoopReports[$other]) (back to BUILDING)",
            "Accept the Builder's view: record a waiver and continue to $next",
            'Park the work item'
        )
        $context = "$($Divergence.Reason)`nThe $other's side: $report`nThe Builder's side: $Summary`nBoth are in thread.md."
    }
    New-OfficeDecision -OfficeRoot $OfficeRoot -Id $Id -Gate 'G2' -Kind $Divergence.Kind -Question $question `
        -Options $options -Context $context -Now $Now
}

# --- Base moved since the plan (T15c) -------------------------------------------------------------
#
# The plan was written against the base commit recorded in status.json (`planBase`, set when the Builder
# was dispatched in plan mode). The worktree is created from a freshly fetched base, which may be newer.
# Before the first BUILDING step creates it, the two are compared: the files changed between them are
# matched against the paths listed in plan.md「預計修改的檔案」and brief.md「相關程式碼」. No overlap:
# the move is recorded in thread.md and planBase is updated. Overlap: no worktree, G2 `base-moved`.

$script:BaseMoveLogMax = 20

# Records the commit the Builder's plan reads (Huddle.psm1 sets it when the plan is dispatched).
function Set-OfficePlanBase {
    param(
        [Parameter(Mandatory)][string]$OfficeRoot,
        [Parameter(Mandatory)][string]$Id,
        [AllowNull()][AllowEmptyString()][string]$Commit,
        [datetime]$Now = (Get-Date)
    )
    $null = Set-StatusField $OfficeRoot $Id 'planBase' $(if ($Commit) { $Commit } else { $null }) $Now
}

# Repo-relative path patterns in a markdown section: every backtick token that contains a '/' or looks
# like a file name (`name.ext`). `<placeholder>` parts match anything; a trailing '/' matches a folder.
# Bare names without a folder match only at the repo root (the brief sometimes lists `models.py` next to
# a full path; that is not resolved).
function Get-OfficeSectionPaths([string]$Path, [string]$Section) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @() }
    $inSection = $false
    $found = [Collections.Generic.List[string]]::new()
    foreach ($line in Get-Content -Encoding utf8 -LiteralPath $Path) {
        if ($line -match '^##\s+(.+?)\s*$') { $inSection = ($Matches[1] -ceq $Section); continue }
        if (-not $inSection) { continue }
        foreach ($m in [regex]::Matches($line, '`([^`]+)`')) {
            $token = $m.Groups[1].Value.Trim() -replace '\\', '/'
            if (($token -replace '<[^>]*>', '') -match '\s') { continue }
            if ($token -notmatch '/' -and $token -notmatch '^[^/]+\.[A-Za-z0-9]+$') { continue }
            $token = $token -replace '^\./', ''
            if ($token -and -not $found.Contains($token)) { $found.Add($token) }
        }
    }
    @($found)
}

function Get-OfficePlannedPaths([string]$WorkDir) {
    @(
        foreach ($p in Get-OfficeSectionPaths (Join-Path $WorkDir 'plan.md') '預計修改的檔案') { [pscustomobject]@{ Pattern = $p; Source = 'plan' } }
        foreach ($p in Get-OfficeSectionPaths (Join-Path $WorkDir 'brief.md') '相關程式碼') { [pscustomobject]@{ Pattern = $p; Source = 'brief' } }
    )
}

function Test-OfficePathPattern([string]$File, [string]$Pattern) {
    if ($Pattern.EndsWith('/')) { return $File.StartsWith($Pattern, [StringComparison]::Ordinal) }
    if ($Pattern -match '<[^>]*>') {
        $rx = '^' + (($Pattern -split '<[^>]*>' | ForEach-Object { [regex]::Escape($_) }) -join '[^/]*') + '$'
        return $File -cmatch $rx
    }
    $File -ceq $Pattern
}

# Files changed between the plan's base and the new base, and which of them the plan or brief lists.
function Test-OfficeBaseMove {
    param(
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$OldCommit,
        [Parameter(Mandatory)][string]$NewCommit,
        [AllowEmptyCollection()][object[]]$Patterns = @()
    )
    $changed = @(Invoke-OfficeGit $Repo @('diff', '--name-only', $OldCommit, $NewCommit) | Where-Object { $_ })
    $overlaps = @(
        foreach ($file in $changed) {
            foreach ($p in $Patterns) {
                if (Test-OfficePathPattern $file $p.Pattern) { [pscustomobject]@{ Path = $file; Pattern = $p.Pattern; Source = $p.Source }; break }
            }
        }
    )
    $log = @(Invoke-OfficeGit $Repo @('log', '--oneline', '--no-decorate', "--max-count=$($script:BaseMoveLogMax + 1)", "$OldCommit..$NewCommit"))
    $more = $log.Count -gt $script:BaseMoveLogMax
    [pscustomobject]@{
        OldCommit = $OldCommit; NewCommit = $NewCommit; ChangedFiles = $changed; Overlaps = $overlaps
        Commits = @($log | Select-Object -First $script:BaseMoveLogMax); MoreCommits = $more
    }
}

function Request-OfficeBaseMovedG2 {
    param([string]$OfficeRoot, [string]$Id, [pscustomobject]$Move, [datetime]$Now)
    $s = Get-OfficeWorkItem -OfficeRoot $OfficeRoot -Id $Id
    $ref = "$($s.project)#$($s.iid)"
    $old7 = $Move.OldCommit.Substring(0, 7)
    $new7 = $Move.NewCommit.Substring(0, 7)
    $question = "G2: the base branch of $ref moved since the plan was written ($old7 -> $new7; $($Move.ChangedFiles.Count) files changed, $($Move.Overlaps.Count) of them listed in the plan or brief). Continue with the current plan?"
    $options = @(
        'Re-plan on the new base: back to BRIEFED, the Builder writes a new plan.md and G1 is asked again',
        'Keep the plan: create the worktree from the new base and let the Builder deal with the differences',
        'Park the work item'
    )
    $ctx = [Text.StringBuilder]::new()
    [void]$ctx.AppendLine("plan.md and brief.md were written against $($Move.OldCommit); the worktree would start from $($Move.NewCommit). No worktree has been created.")
    [void]$ctx.AppendLine('Changed files listed in the plan (預計修改的檔案) or brief (相關程式碼):')
    foreach ($o in $Move.Overlaps) { [void]$ctx.AppendLine("- $($o.Path) ($($o.Source): $($o.Pattern))") }
    [void]$ctx.AppendLine("Commits $old7..$new7$(if ($Move.MoreCommits) { " (first $($script:BaseMoveLogMax))" }):")
    foreach ($c in $Move.Commits) { [void]$ctx.AppendLine("- $c") }
    $n = New-OfficeDecision -OfficeRoot $OfficeRoot -Id $Id -Gate 'G2' -Kind 'base-moved' -Question $question `
        -Options $options -Context $ctx.ToString().TrimEnd() -Now $Now
    $null = Set-StatusField $OfficeRoot $Id 'baseMove' ([ordered]@{
        from = $Move.OldCommit; to = $Move.NewCommit; decision = $n
        changedFiles = $Move.ChangedFiles.Count; overlaps = @($Move.Overlaps | ForEach-Object { $_.Path })
    }) $Now
    $n
}

# Next step of the build loop for one work item. Never dispatches anything itself; returns the input
# for the agent the Office Manager should run, or why nothing should run:
#   action  run-agent         agent = builder (implement) | tester | security | reviewer
#           ready             READY: the loop is done; delivery is T15
#           blocked           BLOCKED by a loop agent; -Resume returns it to resumeTo and continues
#           pending-decision  a decision (G2 from the loop, or another gate) is waiting
#           none              any other state
# In BUILDING the worktree is created on first use (New-OfficeWorktree; -Fetch reads origin first) and
# a snapshot of my own clone (repoPath) is taken, so the Builder's result can be checked against it.
# Every agent gets `waivers`: findings I ruled at G2 need no fix, so they are not raised again.
function Get-OfficeLoopInput {
    param(
        [Parameter(Mandatory)][string]$OfficeRoot,
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][hashtable]$Config,
        [switch]$Resume,
        [switch]$Fetch,
        [datetime]$Now = (Get-Date)
    )
    $s = Get-OfficeWorkItem -OfficeRoot $OfficeRoot -Id $Id
    $workDir = Get-WorkItemDir $OfficeRoot $Id
    $out = [ordered]@{
        ok = $true; action = 'none'; reason = $null; agent = $null; mode = $null; id = $Id; workDir = $workDir
        replyFile = $null; state = $s.state; round = [int]$s.round; maxAutoRounds = (Get-OfficeRoundLimit $s $Config)
        project = $s.project; iid = $s.iid; title = $s.title; webUrl = $s.webUrl; pendingDecision = $s.pendingDecision
    }

    if ($null -ne $s.pendingDecision) {
        $out.action = 'pending-decision'; $out.reason = "Decision #$($s.pendingDecision) is waiting."
        return $out
    }
    if ($s.state -ceq 'BLOCKED' -and $s['blockedBy'] -cin @($script:LoopAgents.Values) -and $s.resumeTo -cin @($script:LoopAgents.Keys)) {
        if (-not $Resume) {
            $out.action = 'blocked'; $out.reason = $s['blockedReason']; $out.agent = $s['blockedBy']
            return $out
        }
        $null = Set-OfficeWorkItemState -OfficeRoot $OfficeRoot -Id $Id -State $s.resumeTo -Now $Now
        $null = Set-StatusField $OfficeRoot $Id 'blockedBy' $null $Now
        $null = Set-StatusField $OfficeRoot $Id 'blockedReason' $null $Now
        Add-OfficeThreadEntry -OfficeRoot $OfficeRoot -Id $Id -From 'user' -To 'office-manager' -Kind 'state' `
            -Body "Resumed: BLOCKED -> $($s.resumeTo)" -Now $Now
        $s = Get-OfficeWorkItem -OfficeRoot $OfficeRoot -Id $Id
        $out.state = $s.state
    }
    if ($s.state -ceq 'READY') {
        $out.action = 'ready'; $out.reason = 'The Reviewer passed (or G2 accepted the result). Delivery (push and MR) is T15.'
        return $out
    }
    if ($s.state -cnotin @($script:LoopAgents.Keys)) {
        $out.reason = "The build loop does not run in state $($s.state)."
        return $out
    }
    if ([int]$s.round -gt (Get-OfficeRoundLimit $s $Config)) {
        # Normally raised when the work came back; this covers a status written before the limit applied.
        $div = [pscustomobject]@{ Diverged = $true; Condition = 4; Kind = 'round-limit'; Reason = "Round $($s.round) exceeds the limit of $(Get-OfficeRoundLimit $s $Config) automatic rounds." }
        $out.pendingDecision = Request-OfficeG2 $OfficeRoot $Id $div '' $Now
        $out.action = 'pending-decision'; $out.reason = $div.Reason
        return $out
    }

    $p = Resolve-OfficeProject -Config $Config -ProjectPath $s.project
    $build = $s['build']
    if ($s.state -ceq 'BUILDING') {
        if (-not $build) {
            # T15c: the base may have moved since the plan read it. Checked once, before the worktree exists.
            $planBase = $s['planBase']
            if ($planBase -and $p.Registered -and $p.Project.baseBranch) {
                $bc = Resolve-OfficeBaseCommit -Repo $p.RepoPath -Base $p.Project.baseBranch -Fetch:$Fetch
                $Fetch = $false
                if ($bc.BaseCommit -cne $planBase) {
                    $move = Test-OfficeBaseMove -Repo $p.RepoPath -OldCommit $planBase -NewCommit $bc.BaseCommit -Patterns (Get-OfficePlannedPaths $workDir)
                    if ($move.Overlaps.Count) {
                        $out.pendingDecision = Request-OfficeBaseMovedG2 $OfficeRoot $Id $move $Now
                        $out.action = 'pending-decision'
                        $out.reason = "The base branch moved since the plan ($($planBase.Substring(0, 7)) -> $($bc.BaseCommit.Substring(0, 7))) and touches $($move.Overlaps.Count) file(s) the plan or brief lists."
                        return $out
                    }
                    Add-OfficeThreadEntry -OfficeRoot $OfficeRoot -Id $Id -From 'office-manager' -To 'builder' -Kind 'note' `
                        -Body "Base moved since the plan: $planBase -> $($bc.BaseCommit) ($($move.ChangedFiles.Count) files changed, none listed in the plan or brief). The worktree starts from the new base." -Now $Now
                    $null = Set-StatusField $OfficeRoot $Id 'planBase' $bc.BaseCommit $Now
                }
            }
            elseif (-not $planBase) {
                Add-OfficeThreadEntry -OfficeRoot $OfficeRoot -Id $Id -From 'office-manager' -To 'builder' -Kind 'note' `
                    -Body 'No plan base recorded (planBase); the base was not compared with the plan.' -Now $Now
            }
        }
        $wt = New-OfficeWorktree -Config $Config -ProjectPath $s.project -Iid $s.iid -Title $s.title -Fetch:$Fetch `
            -Branch $(if ($build) { $build.branch } else { '' })
        if (-not $build) {
            if (-not $wt.Created) { throw "Worktree '$($wt.Path)' already exists but status.json has no build record; check it by hand." }
            $build = [ordered]@{ worktree = $wt.Path; branch = $wt.Branch; baseCommit = $wt.BaseCommit; head = $null; repoSnapshot = $null }
            Add-OfficeThreadEntry -OfficeRoot $OfficeRoot -Id $Id -From 'office-manager' -To 'builder' -Kind 'note' `
                -Body "Worktree created on $($wt.Branch) from $($wt.BaseRef) at $($wt.BaseCommit)." -Refs $wt.Path -Now $Now
        }
        $build.repoSnapshot = Get-OfficeRepoSnapshot $p.RepoPath
        $null = Set-StatusField $OfficeRoot $Id 'build' $build $Now
    }
    elseif (-not $build -or -not $build.head) {
        throw "'$Id' is $($s.state) but has no committed build to check; the Builder has to finish first."
    }

    $agent = $script:LoopAgents[$s.state]
    $out.action = 'run-agent'
    $out.agent = $agent
    $out.mode = if ($agent -ceq 'builder') { 'implement' } else { $null }
    $out.replyFile = Join-Path $workDir 'replies' "$agent-$($Now.ToString('yyyyMMdd-HHmmss')).md"
    $out.planPath = Join-Path $workDir 'plan.md'
    $out.briefPath = Join-Path $workDir 'brief.md'
    $out.threadPath = Join-Path $workDir 'thread.md'
    $out.repoPath = $p.RepoPath
    $out.worktree = [ordered]@{ path = $build.worktree; branch = $build.branch; baseCommit = $build.baseCommit; head = $build.head }
    $out.commands = [ordered]@{ build = $p.Project.commands.build; test = $p.Project.commands.test }
    $out.waivers = @(if ($s['waivers']) { $s['waivers'] })
    if ($agent -ceq 'builder') {
        $from = $s['returnedBy']
        $rework = $s['rework']
        $out.feedback = if ($from) {
            [ordered]@{ from = $from; report = Join-Path $workDir $script:LoopReports[[string]$from]; ruling = $s['fixRuling'] }
        }
        elseif ($rework) {
            # A rework I asked for from READY (Start-OfficeRework): the note of that ruling says what to
            # address; it may name items of any of the three reports, so all of them are listed.
            [ordered]@{
                from = 'user'; report = Join-Path $workDir $script:LoopReports['reviewer']
                reports = @('reviewer', 'security', 'tester' | ForEach-Object { Join-Path $workDir $script:LoopReports[$_] })
                ruling = [ordered]@{ decision = $rework.decision; note = $rework.note }
            }
        }
        else { $null }
    }
    else {
        $out.reportPath = Join-Path $workDir $script:LoopReports[$agent]
        if ($agent -ceq 'tester' -and $s['builderObjection']) {
            $out.dispute = [ordered]@{ count = [int]$s['testerDisputes']; builderObjection = $s['builderObjection'] }
        }
    }
    $body = switch ($agent) {
        'builder' {
            if ($out.feedback -and $out.feedback.from -ceq 'user') { "Rework (round $($s.round)) as ruled at G2 #$($out.feedback.ruling.decision): $($out.feedback.ruling.note)" }
            else { "Implement plan.md (round $($s.round))$(if ($out.feedback) { "; address $(Split-Path -Leaf $out.feedback.report)$(if ($out.feedback.ruling) { " as ruled at G2 #$($out.feedback.ruling.decision)" })" })." }
        }
        'tester' { "Test $($build.branch) at $($build.head)$(if ($out['dispute']) { '; the Builder objects to the last test report, re-check it' })." }
        'security' { "Security review of $($build.baseCommit)..$($build.head)." }
        'reviewer' { "Code review of $($build.baseCommit)..$($build.head)." }
    }
    Add-OfficeThreadEntry -OfficeRoot $OfficeRoot -Id $Id -From 'office-manager' -To $agent -Kind 'assign' -Body $body `
        -Refs $(if ($agent -ceq 'builder') { 'plan.md' } else { Split-Path -Leaf $out.reportPath }) -Now $Now
    $out
}

# Applies the Builder's implement reply (state BUILDING). My own clone (repoPath) must be exactly as it
# was when the Builder was dispatched, whatever the outcome.
#   done       accepted when the worktree is on the recorded branch, clean, and has new commits on top of
#              the base (and of the last tested build) -> TESTING.
#   objection  only against the agent whose report sent the work back (objection_to = returnedBy), only
#              when no G2 already ruled that it must be fixed, and without new commits or changes.
#              Security / Reviewer: G2 right away (SPEC §3.3 conditions 1, 3). Tester: the first time the
#              Tester re-checks (TESTING with the Builder's argument); the second time it is G2 (condition 2).
#   anything else -> BLOCKED.
function Complete-OfficeImplement {
    param(
        [Parameter(Mandatory)][string]$OfficeRoot,
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][AllowEmptyString()][string]$ReplyText,
        [Parameter(Mandatory)][hashtable]$Config,
        [datetime]$Now = (Get-Date)
    )
    $s = Get-OfficeWorkItem -OfficeRoot $OfficeRoot -Id $Id
    if ($s.state -cne 'BUILDING') { throw "Builder implement results need BUILDING; '$Id' is $($s.state)." }
    if ($null -ne $s.pendingDecision) { throw "Decision #$($s.pendingDecision) of '$Id' is pending; the Builder's result cannot be applied now." }
    $build = $s['build']
    if (-not $build -or -not $build.repoSnapshot) { throw "'$Id' has no build record; run build-step.ps1 before dispatching the Builder." }
    $o = Get-AgentOutcome -Text $ReplyText -OfficeRoot $OfficeRoot -Id $Id -Agent 'builder' -Now $Now
    if ($o.Valid) {
        $to = if ($o.Outcome -ceq 'objection') { $o.ObjectionTo } else { 'office-manager' }
        Add-OfficeThreadEntry -OfficeRoot $OfficeRoot -Id $Id -From 'builder' -To $to -Kind $o.Outcome -Body $o.Summary -Now $Now
    }

    $problems = @()
    $head = $null
    if ($o.Valid -and $o.Outcome -cin 'done', 'objection') {
        $p = Resolve-OfficeProject -Config $Config -ProjectPath $s.project
        $cmp = Compare-OfficeRepoSnapshot -Repo $p.RepoPath -Before $build.repoSnapshot -After (Get-OfficeRepoSnapshot $p.RepoPath)
        $problems += $cmp.Problems
        $wt = $build.worktree
        if (-not (Test-Path -LiteralPath $wt -PathType Container)) { $problems += "worktree '$wt' is missing" }
        else {
            $branch = & git -C $wt symbolic-ref --short -q HEAD 2>$null
            if ("$branch".Trim() -cne $build.branch) { $problems += "worktree is on '$("$branch".Trim())', not '$($build.branch)'" }
            $dirty = @(Get-OfficeWorktreeChanges $wt)
            if ($dirty.Count) { $problems += "worktree has uncommitted changes: $(($dirty | Select-Object -First 5) -join '; ')" }
            $head = @(Invoke-OfficeGit $wt @('rev-parse', 'HEAD'))[0]
            if ($o.Outcome -ceq 'done') {
                & git -C $wt merge-base --is-ancestor $build.baseCommit $head 2>$null
                if ($LASTEXITCODE -ne 0) { $problems += "HEAD $head does not contain the base commit $($build.baseCommit)" }
                elseif ($head -ceq $build.baseCommit) { $problems += 'no commit on top of the base commit' }
                elseif ($build.head -and $head -ceq $build.head) { $problems += "no new commit since the last tested build ($($build.head))" }
            }
            else {
                $expected = if ($build.head) { $build.head } else { $build.baseCommit }
                if ($head -cne $expected) { $problems += "an objecting Builder must not commit (HEAD $head, expected $expected)" }
            }
        }
        if ($o.Outcome -ceq 'objection') {
            $from = $s['returnedBy']
            if (-not $from -and $s['rework']) { $problems += "G2 #$($s['rework'].decision) is my own request for this rework; there is no report to object to" }
            elseif (-not $from) { $problems += 'nothing to object to: no report sent this work back' }
            elseif ($o.ObjectionTo -cne $from) { $problems += "objection_to must be $from, whose report sent the work back (got $($o.ObjectionTo))" }
            if ($s['fixRuling']) { $problems += "G2 #$($s['fixRuling'].decision) already ruled that the Builder fixes the $from's report" }
        }
    }

    $decision = $null
    if ($o.Valid -and $o.Outcome -cin 'done', 'objection' -and -not $problems.Count) {
        foreach ($note in $cmp.Notes) {
            Add-OfficeThreadEntry -OfficeRoot $OfficeRoot -Id $Id -From 'office-manager' -To 'user' -Kind 'note' -Body $note -Now $Now
        }
        if ($o.Outcome -ceq 'done') {
            $build.head = $head
            $null = Set-StatusField $OfficeRoot $Id 'build' $build $Now
            foreach ($f in 'returnedBy', 'fixRuling', 'rework') { $null = Set-StatusField $OfficeRoot $Id $f $null $Now }
            Move-OfficeLoopState $OfficeRoot $Id 'TESTING' 'tester' $Now
            $result = 'done'
        }
        else {
            $null = Set-StatusField $OfficeRoot $Id 'builderObjection' $o.Summary $Now
            $div = Test-OfficeDivergence -Item $s -Agent 'builder' -Outcome 'objection' -ObjectionTo $o.ObjectionTo -Config $Config
            if ($div.Diverged) {
                $decision = Request-OfficeG2 $OfficeRoot $Id $div $o.Summary $Now
                $result = 'g2'
            }
            else {
                # Condition 2 needs both sides to insist: the Tester re-checks with the Builder's argument first.
                $null = Set-StatusField $OfficeRoot $Id 'testerDisputes' ([int]$(if ($s['testerDisputes']) { $s['testerDisputes'] } else { 0 }) + 1) $Now
                $null = Set-StatusField $OfficeRoot $Id 'returnedBy' $null $Now
                Move-OfficeLoopState $OfficeRoot $Id 'TESTING' 'tester' $Now
                $result = 'disputed'
            }
        }
        $reason = $o.Summary
    }
    else {
        $reason = if (-not $o.Valid) { $o.Summary }
                  elseif ($problems.Count) { "Builder said $($o.Outcome), but: $($problems -join '; ')" }
                  else { "Builder returned $($o.Outcome): $($o.Summary)" }
        Set-OfficeLoopBlocked $OfficeRoot $Id 'builder' $reason $Now
        $result = 'blocked'
    }
    $after = Get-OfficeWorkItem -OfficeRoot $OfficeRoot -Id $Id
    [pscustomobject]@{
        Id = $Id; Result = $result; Reason = $reason; State = $after.state; Round = [int]$after.round; Valid = $o.Valid
        Head = $head; Problems = [string[]]$problems; Decision = $decision
    }
}

# Parses the items of one '## <Section>' of a report: '### <Prefix>-<n>：<title>' headings, each followed
# by '- <field>：<value>' lines (full- or half-width colon). A section with no item must say 無.
# Returns { Items = @({ Id, Title, Fields }), Errors = @() }.
function Read-OfficeReportItems([string]$Text, [string]$Section, [string]$Prefix, [string[]]$Fields) {
    $items = [Collections.Generic.List[object]]::new()
    $errors = [Collections.Generic.List[string]]::new()
    $m = [regex]::Match($Text, '(?ms)^##[ \t]+' + [regex]::Escape($Section) + '[ \t]*\r?$(.*?)(?=^##[ \t]+[^#]|\z)')
    if (-not $m.Success) { $errors.Add("no ## $Section section"); return [pscustomobject]@{ Items = @(); Errors = @($errors) } }
    $body = $m.Groups[1].Value
    $blocks = [regex]::Matches($body, '(?ms)^###[ \t]+(?<id>[^\s：:]+)[ \t]*[：:]?[ \t]*(?<title>[^\r\n]*)\r?$(?<body>.*?)(?=^###[ \t]|\z)')
    if ($blocks.Count -eq 0) {
        $rest = ($body -split '\r?\n' | Where-Object { $_.Trim() }) -join ' '
        if ($rest.Trim() -cne '無') { $errors.Add("## $Section has no '### $Prefix-<n>' item; write 無 when there is none") }
    }
    $seen = @{}
    foreach ($b in $blocks) {
        $iid = $b.Groups['id'].Value
        if ($iid -cnotmatch "^$Prefix-\d+$") { $errors.Add("heading '$iid' must be $Prefix-<n>"); continue }
        if ($seen.ContainsKey($iid)) { $errors.Add("$iid appears more than once"); continue }
        $seen[$iid] = $true
        $field = @{}
        foreach ($name in $Fields) {
            $fm = [regex]::Match($b.Groups['body'].Value, "(?m)^[ \t]*-[ \t]*$name[ \t]*[：:][ \t]*(?<v>\S[^\r\n]*)")
            if ($fm.Success) { $field[$name] = ($fm.Groups['v'].Value -replace '[`*]', '').Trim() } else { $errors.Add("${iid}: missing '- ${name}：'") }
        }
        $items.Add([pscustomobject]@{ Id = $iid; Title = $b.Groups['title'].Value.Trim(); Fields = $field })
    }
    [pscustomobject]@{ Items = @($items); Errors = @($errors) }
}

# Security findings (SPEC §5): '### F-<n>：<title>' with 嚴重度 / 位置 / 情境 / 建議修法.
# Returns { Findings = @({ Id, Title, Severity, Location }), Errors = @() }.
function Read-OfficeSecurityFindings([string]$Text) {
    $r = Read-OfficeReportItems $Text 'Findings' 'F' @('嚴重度', '位置', '情境', '建議修法')
    $errors = [Collections.Generic.List[string]]::new()
    foreach ($e in $r.Errors) { $errors.Add($e) }
    $findings = foreach ($i in $r.Items) {
        $sev = if ($i.Fields['嚴重度']) { $i.Fields['嚴重度'].ToLowerInvariant() } else { $null }
        if ($sev -and $sev -cnotin $script:Severities) { $errors.Add("$($i.Id): severity '$($i.Fields['嚴重度'])' is not one of $($script:Severities -join ', ')"); $sev = $null }
        [pscustomobject]@{ Id = $i.Id; Title = $i.Title; Severity = $sev; Location = $i.Fields['位置'] }
    }
    [pscustomobject]@{ Findings = @($findings); Errors = @($errors) }
}

# Reviewer items (SPEC §3.2 review-report.md): '### R-<n>：<title>' with 面向 / 判定 / 位置 / 說明 / 建議修法;
# 面向 is one of the five review axes, 判定 is 必須修 or 建議.
# Returns { Items = @({ Id, Title, Axis, Verdict, Location }), Errors = @() }.
function Read-OfficeReviewItems([string]$Text) {
    $r = Read-OfficeReportItems $Text '審查意見' 'R' @('面向', '判定', '位置', '說明', '建議修法')
    $errors = [Collections.Generic.List[string]]::new()
    foreach ($e in $r.Errors) { $errors.Add($e) }
    $items = foreach ($i in $r.Items) {
        $axis = $i.Fields['面向']; $verdict = $i.Fields['判定']
        if ($axis -and $axis -cnotin $script:ReviewAxes) { $errors.Add("$($i.Id): 面向 '$axis' is not one of $($script:ReviewAxes -join '、')"); $axis = $null }
        if ($verdict -and $verdict -cnotin $script:ReviewVerdicts) { $errors.Add("$($i.Id): 判定 '$verdict' must be 必須修 or 建議"); $verdict = $null }
        [pscustomobject]@{ Id = $i.Id; Title = $i.Title; Axis = $axis; Verdict = $verdict; Location = $i.Fields['位置'] }
    }
    [pscustomobject]@{ Items = @($items); Errors = @($errors) }
}

# Shared part of the Tester / Security / Reviewer results: the agent read the worktree only, so HEAD must
# still be the build that was handed to it and nothing may be left uncommitted in the worktree.
function Get-OfficeReadOnlyProblems([Collections.IDictionary]$Build) {
    $problems = @()
    $wt = $Build.worktree
    if (-not (Test-Path -LiteralPath $wt -PathType Container)) { return @("worktree '$wt' is missing") }
    $head = @(Invoke-OfficeGit $wt @('rev-parse', 'HEAD'))[0]
    if ($head -cne $Build.head) { $problems += "worktree HEAD moved from $($Build.head) to $head" }
    $dirty = @(Get-OfficeWorktreeChanges $wt)
    if ($dirty.Count) { $problems += "worktree has uncommitted changes: $(($dirty | Select-Object -First 5) -join '; ')" }
    $problems
}

# Applies a Tester (TESTING), Security (SEC_REVIEW) or Reviewer (REVIEW) reply. The report between the
# draft markers is saved as test-report.md / security-report.md / review-report.md. Outcomes:
#   done                              passed -> SEC_REVIEW / REVIEW / READY
#   objection (objection_to builder)  work to fix -> back to BUILDING (one more round); when that round is
#                                     over the limit, G2 (SPEC §3.3 condition 4) with the item in BUILDING
#   anything else, a missing or malformed report, an outcome that contradicts the findings / must-fix
#   items, or a changed worktree -> BLOCKED.
function Complete-OfficeLoopReview {
    param(
        [Parameter(Mandatory)][string]$OfficeRoot,
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][ValidateSet('tester', 'security', 'reviewer')][string]$Agent,
        [Parameter(Mandatory)][AllowEmptyString()][string]$ReplyText,
        [hashtable]$Config = @{ maxAutoRounds = 3 },
        [datetime]$Now = (Get-Date)
    )
    $state = @{ tester = 'TESTING'; security = 'SEC_REVIEW'; reviewer = 'REVIEW' }[$Agent]
    $next = $script:LoopNext[$Agent]
    $file = $script:LoopReports[$Agent]
    $s = Get-OfficeWorkItem -OfficeRoot $OfficeRoot -Id $Id
    if ($s.state -cne $state) { throw "$Agent results need $state; '$Id' is $($s.state)." }
    if ($null -ne $s.pendingDecision) { throw "Decision #$($s.pendingDecision) of '$Id' is pending; the $Agent's result cannot be applied now." }
    $build = $s['build']
    if (-not $build -or -not $build.head) { throw "'$Id' has no committed build record." }
    $o = Get-AgentOutcome -Text $ReplyText -OfficeRoot $OfficeRoot -Id $Id -Agent $Agent -Now $Now
    $path = Join-Path (Get-WorkItemDir $OfficeRoot $Id) $file

    $problems = @()
    $items = @()
    $saved = $false
    if ($o.Valid) {
        $to = if ($o.Outcome -ceq 'objection') { $o.ObjectionTo } else { 'office-manager' }
        Add-OfficeThreadEntry -OfficeRoot $OfficeRoot -Id $Id -From $Agent -To $to -Kind $o.Outcome -Body $o.Summary -Refs $file -Now $Now
        if ($o.Outcome -cin 'done', 'objection') {
            if ($o.Outcome -ceq 'objection' -and $o.ObjectionTo -cne 'builder') { $problems += "objection_to must be builder (got $($o.ObjectionTo))" }
            try {
                $report = Get-AgentDraft $ReplyText
                [IO.File]::WriteAllText($path, "$report`n", $script:Utf8NoBom)
                $saved = $true
                $sections = @{ tester = $script:TestReportSections; security = $script:SecurityReportSections; reviewer = $script:ReviewReportSections }[$Agent]
                $missing = @(Get-MissingSections $path $sections)
                if ($missing.Count) { $problems += "$file is missing sections: $($missing -join ', ')" }
                if ($Agent -ceq 'security') {
                    $parsed = Read-OfficeSecurityFindings $report
                    $problems += @($parsed.Errors)
                    $items = @($parsed.Findings | ForEach-Object { [ordered]@{ id = $_.Id; severity = $_.Severity; location = $_.Location; title = $_.Title } })
                    $blocking = @($parsed.Findings | Where-Object { $_.Severity -cin $script:BlockingSeverities })
                    if ($o.Outcome -ceq 'done' -and $blocking.Count) { $problems += "outcome is done but $(@($blocking.Id) -join ', ') is medium or above" }
                    if ($o.Outcome -ceq 'objection' -and -not $blocking.Count) { $problems += 'outcome is objection but no finding is medium or above' }
                }
                elseif ($Agent -ceq 'reviewer') {
                    $parsed = Read-OfficeReviewItems $report
                    $problems += @($parsed.Errors)
                    $items = @($parsed.Items | ForEach-Object { [ordered]@{ id = $_.Id; axis = $_.Axis; verdict = $_.Verdict; location = $_.Location; title = $_.Title } })
                    $mustFix = @($parsed.Items | Where-Object { $_.Verdict -ceq '必須修' })
                    if ($o.Outcome -ceq 'done' -and $mustFix.Count) { $problems += "outcome is done but $(@($mustFix.Id) -join ', ') is 必須修" }
                    if ($o.Outcome -ceq 'objection' -and -not $mustFix.Count) { $problems += 'outcome is objection but no item is 必須修' }
                }
            }
            catch { $problems += "no usable report in the reply: $($_.Exception.Message)" }
            $problems += @(Get-OfficeReadOnlyProblems $build)
        }
    }

    $decision = $null
    if ($o.Valid -and $o.Outcome -cin 'done', 'objection' -and -not $problems.Count) {
        if ($o.Outcome -ceq 'done') {
            if ($Agent -ceq 'tester') {
                foreach ($f in 'testerDisputes', 'builderObjection') { $null = Set-StatusField $OfficeRoot $Id $f $null $Now }
            }
            Move-OfficeLoopState $OfficeRoot $Id $next $(if ($next -ceq 'READY') { 'user' } else { $script:LoopAgents[$next] }) $Now
            $result = 'done'
        }
        else {
            $div = Test-OfficeDivergence -Item $s -Agent $Agent -Outcome 'objection' -ObjectionTo 'builder' -Config $Config
            $null = Set-StatusField $OfficeRoot $Id 'returnedBy' $Agent $Now
            Move-OfficeLoopState $OfficeRoot $Id 'BUILDING' 'builder' $Now
            $result = 'returned'
            if ($div.Diverged) {
                $decision = Request-OfficeG2 $OfficeRoot $Id $div $o.Summary $Now
                $result = 'g2'
            }
        }
        $reason = $o.Summary
    }
    else {
        $reason = if (-not $o.Valid) { $o.Summary }
                  elseif ($problems.Count) { "$Agent reply not applied: $($problems -join '; ')" }
                  else { "$Agent returned $($o.Outcome): $($o.Summary)" }
        Set-OfficeLoopBlocked $OfficeRoot $Id $Agent $reason $Now
        $result = 'blocked'
    }
    $after = Get-OfficeWorkItem -OfficeRoot $OfficeRoot -Id $Id
    [pscustomobject]@{
        Id = $Id; Agent = $Agent; Result = $result; Reason = $reason; State = $after.state; Round = [int]$after.round
        Valid = $o.Valid; ReportPath = $(if ($saved) { $path } else { $null }); Problems = [string[]]$problems
        Findings = @($items); Decision = $decision
    }
}

# Records my ruling on a G2 raised by the build loop and applies it:
#   divergence-<agent>  1 fix      stays BUILDING; the Builder gets the ruling with its feedback and may not
#                                  object to that report again
#                       2 accept   records a waiver (shown to every later agent) and moves on to where the
#                                  agent would have sent the work had it passed (READY needs this decision id)
#                       3 park     -> PARKED
#   round-limit         1 another  one more automatic round (extraRounds + 1); stays BUILDING
#                       2 park     -> PARKED
function Invoke-OfficeG2Ruling {
    param(
        [Parameter(Mandatory)][string]$OfficeRoot,
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][int]$DecisionId,
        [Parameter(Mandatory)][int]$Choice,
        [string]$Note,
        [datetime]$Now = (Get-Date)
    )
    $s = Get-OfficeWorkItem -OfficeRoot $OfficeRoot -Id $Id
    $dir = Get-WorkItemDir $OfficeRoot $Id
    $d = Get-Content -Raw -Encoding utf8 -LiteralPath (Join-Path $dir 'decisions' "$DecisionId.json") | ConvertFrom-Json -AsHashtable -DateKind String
    if ($d.kind -cnotmatch '^(divergence-(tester|security|reviewer)|round-limit|base-moved)$') { throw "Decision #$DecisionId of '$Id' is not a build-loop G2 (kind '$($d.kind)')." }
    if ($s.pendingDecision -ne $DecisionId) { throw "Decision #$DecisionId is not the pending decision of '$Id'." }
    if ($s.state -cne 'BUILDING') { throw "'$Id' is $($s.state); a build-loop G2 ruling needs BUILDING." }
    if ($d.kind -ceq 'base-moved' -and ($null -eq $s['baseMove'] -or [int]$s['baseMove'].decision -ne $DecisionId)) {
        throw "Decision #$DecisionId of '$Id' has no matching baseMove record in status.json."
    }

    $option = Resolve-OfficeDecision -OfficeRoot $OfficeRoot -Id $Id -DecisionId $DecisionId -Choice $Choice -Note $Note -Now $Now
    $park = ($d.kind -ceq 'round-limit' -and $Choice -eq 2) -or ($d.kind -cne 'round-limit' -and $Choice -eq 3)
    if ($park) {
        $null = Set-OfficeWorkItemState -OfficeRoot $OfficeRoot -Id $Id -State 'PARKED' -Now $Now
    }
    elseif ($d.kind -ceq 'base-moved') {
        $mv = $s['baseMove']
        $null = Set-StatusField $OfficeRoot $Id 'baseMove' $null $Now
        if ($Choice -eq 1) {
            # Re-plan: the next /huddle-take dispatches the Builder in plan mode, which records a new planBase.
            $null = Set-StatusField $OfficeRoot $Id 'planBase' $null $Now
            $null = Set-OfficeWorkItemState -OfficeRoot $OfficeRoot -Id $Id -State 'BRIEFED' -DecisionId $DecisionId -Now $Now
            Add-OfficeThreadEntry -OfficeRoot $OfficeRoot -Id $Id -From 'office-manager' -To 'builder' -Kind 'state' `
                -Body "BUILDING -> BRIEFED (G2 #${DecisionId}: re-plan on $($mv.to); the plan read $($mv.from))$(if ($Note) { " ($Note)" })." -Now $Now
        }
        else {
            $null = Set-StatusField $OfficeRoot $Id 'planBase' $mv.to $Now
            Add-OfficeThreadEntry -OfficeRoot $OfficeRoot -Id $Id -From 'office-manager' -To 'builder' -Kind 'note' `
                -Body "G2 #${DecisionId}: keep the plan; the worktree starts from $($mv.to) although the plan read $($mv.from)$(if ($Note) { " ($Note)" })." -Now $Now
        }
    }
    elseif ($d.kind -ceq 'round-limit') {
        $null = Set-StatusField $OfficeRoot $Id 'extraRounds' ([int]$(if ($s['extraRounds']) { $s['extraRounds'] } else { 0 }) + 1) $Now
        Add-OfficeThreadEntry -OfficeRoot $OfficeRoot -Id $Id -From 'office-manager' -To 'builder' -Kind 'note' `
            -Body "G2 #${DecisionId}: one more automatic round allowed." -Now $Now
    }
    else {
        $other = $d.kind -replace '^divergence-', ''
        if ($Choice -eq 1) {
            $null = Set-StatusField $OfficeRoot $Id 'returnedBy' $other $Now
            $null = Set-StatusField $OfficeRoot $Id 'fixRuling' ([ordered]@{ decision = $DecisionId; note = $Note }) $Now
            foreach ($f in 'testerDisputes', 'builderObjection') { $null = Set-StatusField $OfficeRoot $Id $f $null $Now }
            Add-OfficeThreadEntry -OfficeRoot $OfficeRoot -Id $Id -From 'office-manager' -To 'builder' -Kind 'note' `
                -Body "G2 #${DecisionId}: fix the $other's $($script:LoopReports[$other])$(if ($Note) { " ($Note)" })." -Refs $script:LoopReports[$other] -Now $Now
        }
        else {
            $waiver = [ordered]@{ from = $other; decision = $DecisionId; builderView = $s['builderObjection']; note = $Note; report = $script:LoopReports[$other] }
            $null = Set-StatusField $OfficeRoot $Id 'waivers' (@(if ($s['waivers']) { $s['waivers'] }) + $waiver) $Now
            foreach ($f in 'returnedBy', 'fixRuling', 'testerDisputes', 'builderObjection') { $null = Set-StatusField $OfficeRoot $Id $f $null $Now }
            $to = $script:LoopNext[$other]
            $null = Set-OfficeWorkItemState -OfficeRoot $OfficeRoot -Id $Id -State $to -DecisionId $DecisionId -Now $Now
            Add-OfficeThreadEntry -OfficeRoot $OfficeRoot -Id $Id -From 'office-manager' -To $(if ($to -ceq 'READY') { 'user' } else { $script:LoopAgents[$to] }) -Kind 'state' `
                -Body "BUILDING -> $to (G2 #$DecisionId accepted the Builder's view; waiver recorded)." -Now $Now
        }
    }
    $after = Get-OfficeWorkItem -OfficeRoot $OfficeRoot -Id $Id
    [pscustomobject]@{ Option = $option; State = $after.state }
}

# --- Rework from READY (SPEC §3.3) ----------------------------------------------------------------
#
# READY means every reviewing agent passed, but their reports may still hold things I want done before
# delivery (Reviewer 建議, Security low findings). Only I can ask for that: this records a G2 decision of
# kind `rework` together with my ruling (the request is the ruling, so nothing is left pending and no
# card is pushed), and moves READY -> BUILDING with that decision id. The Builder gets the ruling's note
# as its feedback and may not object; the Tester, Security and the Reviewer then check the new build as
# in any other round. The round counts; when it would be over the automatic limit, the extra round is
# allowed with it (I asked for this one).
function Start-OfficeRework {
    param(
        [Parameter(Mandatory)][string]$OfficeRoot,
        [Parameter(Mandatory)][string]$Id,
        # What the Builder has to address, on one line (e.g. 'R-1, R-4 of review-report.md; F-1 of security-report.md').
        [Parameter(Mandatory)][string]$Note,
        [Parameter(Mandatory)][hashtable]$Config,
        [datetime]$Now = (Get-Date)
    )
    $s = Get-OfficeWorkItem -OfficeRoot $OfficeRoot -Id $Id
    if ($s.state -cne 'READY') { throw "A rework starts from READY; '$Id' is $($s.state)." }
    if ($null -ne $s.pendingDecision) { throw "Decision #$($s.pendingDecision) of '$Id' is pending; rule on it first." }
    $Note = "$Note".Trim()
    if (-not $Note) { throw 'A rework needs a note that says what the Builder has to address.' }
    if ($Note -match '[\r\n]') { throw 'The rework note must be a single line.' }
    $build = $s['build']
    if (-not $build -or -not $build.head) { throw "'$Id' is READY but has no committed build record." }

    $ref = "$($s.project)#$($s.iid)"
    $n = New-OfficeDecision -OfficeRoot $OfficeRoot -Id $Id -Gate 'G2' -Kind 'rework' `
        -Question "G2: send $ref back from READY to the Builder before delivery?" `
        -Options @(
            'Rework: the Builder addresses what the note lists (back to BUILDING; the Tester, Security and the Reviewer check the new build)',
            'Keep it READY'
        ) `
        -Context "Raised and ruled in one step at my request (rework.ps1). Reviewed build: $($build.head) on $($build.branch). Reports: test-report.md, security-report.md, review-report.md." `
        -Now $Now
    $null = Resolve-OfficeDecision -OfficeRoot $OfficeRoot -Id $Id -DecisionId $n -Choice 1 -Note $Note -Now $Now

    foreach ($f in 'returnedBy', 'fixRuling', 'testerDisputes', 'builderObjection') { $null = Set-StatusField $OfficeRoot $Id $f $null $Now }
    $null = Set-StatusField $OfficeRoot $Id 'rework' ([ordered]@{ decision = $n; note = $Note; fromHead = $build.head }) $Now
    $after = Set-OfficeWorkItemState -OfficeRoot $OfficeRoot -Id $Id -State 'BUILDING' -DecisionId $n -Now $Now
    $over = [int]$after.round - (Get-OfficeRoundLimit $after $Config)
    if ($over -gt 0) {
        $null = Set-StatusField $OfficeRoot $Id 'extraRounds' ([int]$(if ($after['extraRounds']) { $after['extraRounds'] } else { 0 }) + $over) $Now
    }
    Add-OfficeThreadEntry -OfficeRoot $OfficeRoot -Id $Id -From 'office-manager' -To 'builder' -Kind 'state' `
        -Body "READY -> BUILDING (round $($after.round); G2 #$n rework): $Note" -Refs "decisions/$n.md" -Now $Now
    $after = Get-OfficeWorkItem -OfficeRoot $OfficeRoot -Id $Id
    [pscustomobject]@{ Id = $Id; Decision = $n; State = $after.state; Round = [int]$after.round; Note = $Note }
}

# --- Branch rename (SPEC §3.6) --------------------------------------------------------------------
#
# The worktree branch starts as huddle/<iid>-<slug>. A target repo may require its own branch names
# (e.g. fix/issue-<id>-<slug>), and the push and MR commands of the delivery use the name in the build
# record, so the rename has to happen here: the local branch is renamed in the worktree
# (`git branch -m`, nothing is pushed) and `build.branch` follows. Allowed between BUILDING and READY,
# while no agent is running on the work item and before anything was pushed. Local git only; whether
# origin has the new name is judged from the remote-tracking refs as last fetched.
function Rename-OfficeBranch {
    param(
        [Parameter(Mandatory)][string]$OfficeRoot,
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Branch,
        [Parameter(Mandatory)][hashtable]$Config,
        [datetime]$Now = (Get-Date)
    )
    $s = Get-OfficeWorkItem -OfficeRoot $OfficeRoot -Id $Id
    if ($s.state -cnotin $script:BuildStates) { throw "The branch can be renamed between BUILDING and READY; '$Id' is $($s.state)." }
    if ($null -ne $s.pendingDecision) { throw "Decision #$($s.pendingDecision) of '$Id' is pending; rule on it first." }
    $build = $s['build']
    if (-not $build -or -not $build.branch) { throw "'$Id' has no worktree yet; there is no branch to rename." }
    $old = [string]$build.branch
    $Branch = "$Branch".Trim()
    if ($Branch -ceq $old) { throw "The branch of '$Id' is already '$old'." }

    $p = Resolve-OfficeProject -Config $Config -ProjectPath $s.project
    $repo = $p.RepoPath
    & git -C $repo check-ref-format --branch $Branch 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "'$Branch' is not a valid branch name." }
    if ($Branch -ceq $p.Project.baseBranch) { throw "'$Branch' is the base branch of '$($s.project)'." }
    if (Test-OfficeGitRef $repo "refs/heads/$Branch") { throw "Branch '$Branch' already exists in '$repo'." }
    if (Test-OfficeGitRef $repo "refs/remotes/origin/$Branch") { throw "origin already has a branch '$Branch' (as last fetched)." }
    if (Test-OfficeGitRef $repo "refs/remotes/origin/$old") { throw "'$old' was already pushed to origin; renaming it locally would leave the pushed branch behind." }

    $wt = $build.worktree
    if (-not (Test-Path -LiteralPath $wt -PathType Container)) { throw "worktree '$wt' is missing." }
    $current = & git -C $wt symbolic-ref --short -q HEAD 2>$null
    if ("$current".Trim() -cne $old) { throw "worktree '$wt' is on '$("$current".Trim())', not '$old'." }

    $null = Invoke-OfficeGit $wt @('branch', '-m', $old, $Branch)
    $build.branch = $Branch
    $null = Set-StatusField $OfficeRoot $Id 'build' $build $Now
    Add-OfficeThreadEntry -OfficeRoot $OfficeRoot -Id $Id -From 'user' -To 'office-manager' -Kind 'note' `
        -Body "Branch renamed: $old -> $Branch (local only; nothing pushed)." -Refs $wt -Now $Now
    [pscustomobject]@{ Id = $Id; From = $old; Branch = $Branch; Worktree = $wt; State = $s.state }
}

# --- Delivery (T15, SPEC §3.3 READY -[G3]-> DELIVERED, §3.10) -------------------------------------
#
# The Builder writes the MR draft (gitlab-mr template) and returns it between the draft markers; these
# functions check and save it, and print the exact push and MR (`glab api --method POST`) commands. Those two commands
# are run by the Office Manager as they are, so the harness asks me before each (G3); nothing here
# pushes or writes to GitLab. The MR is opened with my account (gitlab-mr G3) and its description
# starts with the A1 line. Labels must already exist (L1, L2): Huddle never creates one.

$script:A1Line = '> 🤖 本內容由 AI 撰寫，經開發者確認'

# Saved by Get-OfficeDeliveryInput so the draft is checked against the labels GitLab had at that time.
function Get-DeliveryContextPath([string]$OfficeRoot, [string]$Id) { Join-Path (Get-WorkItemDir $OfficeRoot $Id) 'delivery.json' }

# Input for the Builder's mr-draft run (state READY). -Labels are the project's existing label names
# (including inherited ones) and -OpenMrs the open MRs whose source branch is the work item's branch,
# both read from GitLab by the caller. An open MR already there means gitlab-mr G2 (update, do not
# open another): action existing-mr, nothing is dispatched.
#   action  run-agent | existing-mr | none
function Get-OfficeDeliveryInput {
    param(
        [Parameter(Mandatory)][string]$OfficeRoot,
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][hashtable]$Config,
        [AllowEmptyCollection()][string[]]$Labels = @(),
        [AllowEmptyCollection()][object[]]$OpenMrs = @(),
        [string]$Note,
        # Saved in delivery.json: the MR command names the host instead of letting glab infer it.
        [string]$GitLabHost,
        [datetime]$Now = (Get-Date)
    )
    $s = Get-OfficeWorkItem -OfficeRoot $OfficeRoot -Id $Id
    $workDir = Get-WorkItemDir $OfficeRoot $Id
    $out = [ordered]@{ ok = $true; action = 'none'; reason = $null; id = $Id; state = $s.state; project = $s.project; iid = $s.iid; workDir = $workDir }
    if ($s.state -cne 'READY') {
        $out.reason = "Delivery starts from READY; '$Id' is $($s.state)."
        return $out
    }
    $build = $s['build']
    if (-not $build -or -not $build.head) { throw "'$Id' is READY but has no committed build record." }
    $mrs = @($OpenMrs | Where-Object { $_ })
    if ($mrs.Count) {
        $out.action = 'existing-mr'
        $out.reason = "Branch $($build.branch) already has an open MR: $(@($mrs | ForEach-Object { "!$($_.iid) $($_.web_url)" }) -join ', '). Update it instead of opening another (gitlab-mr G2)."
        $out.existingMrs = @($mrs | ForEach-Object { [ordered]@{ iid = $_.iid; url = $_.web_url } })
        return $out
    }
    $p = Resolve-OfficeProject -Config $Config -ProjectPath $s.project
    if (-not $GitLabHost) { throw "Get-OfficeDeliveryInput needs -GitLabHost to prepare '$Id' for delivery." }
    $context = [ordered]@{ labels = @($Labels); branch = $build.branch; head = $build.head; gitlabHost = $GitLabHost; at = (Format-Timestamp $Now) }
    [IO.File]::WriteAllText((Get-DeliveryContextPath $OfficeRoot $Id), ($context | ConvertTo-Json -Depth 4), $script:Utf8NoBom)

    $out.action = 'run-agent'
    $out.agent = 'builder'
    $out.builderMode = 'mr-draft'
    $out.replyFile = Join-Path $workDir 'replies' "builder-$($Now.ToString('yyyyMMdd-HHmmss')).md"
    $out.title = $s.title
    $out.webUrl = $s.webUrl
    $out.planPath = Join-Path $workDir 'plan.md'
    $out.briefPath = Join-Path $workDir 'brief.md'
    $out.threadPath = Join-Path $workDir 'thread.md'
    $out.reports = [ordered]@{
        test = Join-Path $workDir 'test-report.md'; security = Join-Path $workDir 'security-report.md'; review = Join-Path $workDir 'review-report.md'
    }
    $out.mrDraftPath = Join-Path $workDir 'mr-draft.md'
    $out.repoPath = $p.RepoPath
    $out.baseBranch = $p.Project.baseBranch
    $out.worktree = [ordered]@{ path = $build.worktree; branch = $build.branch; baseCommit = $build.baseCommit; head = $build.head }
    $out.waivers = @(if ($s['waivers']) { $s['waivers'] })
    $out.availableLabels = @($Labels)
    $out.a1Line = $script:A1Line
    $out.revisionNote = if ($Note) { $Note } else { $null }
    Add-OfficeThreadEntry -OfficeRoot $OfficeRoot -Id $Id -From 'office-manager' -To 'builder' -Kind 'assign' `
        -Body "MR draft requested for $($build.branch)$(if ($Note) { " (revise: $Note)" })." -Refs 'mr-draft.md' -Now $Now
    $out
}

# Splits mr-draft.md: a front matter block ('---' / 'title: …' / 'labels: a, b' / '---') and the body.
function ConvertFrom-OfficeMrDraft([string]$Text) {
    $m = [regex]::Match($Text, '(?s)\A---[ \t]*\r?\n(?<fm>.*?)\r?\n---[ \t]*(\r?\n|\z)(?<body>.*)\z')
    if (-not $m.Success) { throw "the draft must start with a front matter block: '---', 'title: …', 'labels: …', '---'" }
    $title = $null; $labels = $null
    foreach ($line in ($m.Groups['fm'].Value -split '\r?\n')) {
        if (-not $line.Trim()) { continue }
        if ($line -match '^title:[ \t]*(?<v>.*)$') { $title = $Matches.v.Trim() }
        elseif ($line -match '^labels:[ \t]*(?<v>.*)$') { $labels = @($Matches.v -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
        else { throw "unknown front matter line '$line' (only title and labels)" }
    }
    if ($null -eq $title) { throw "the front matter has no 'title:' line" }
    if ($null -eq $labels) { throw "the front matter has no 'labels:' line (leave it empty for no labels)" }
    [pscustomobject]@{ Title = $title; Labels = [string[]]@($labels); Body = $m.Groups['body'].Value.Trim("`r", "`n") }
}

# Bash single-quoted word (the Office Manager runs the commands with the Bash tool).
function ConvertTo-BashWord([string]$Value) { "'" + ($Value -replace "'", "'\''") + "'" }

# Applies the Builder's mr-draft reply (state READY; never changes the state). Checks: the reply is done
# and has one draft; the front matter has a one-line title and only labels from delivery.json; the
# body's first line is exactly the A1 line and it closes the issue (`Closes #<iid>`). Saves mr-draft.md
# (as returned) and mr-body.md (the body, for --description). Returns the push and MR commands.
function Complete-OfficeMrDraft {
    param(
        [Parameter(Mandatory)][string]$OfficeRoot,
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][AllowEmptyString()][string]$ReplyText,
        [Parameter(Mandatory)][hashtable]$Config,
        [datetime]$Now = (Get-Date)
    )
    $s = Get-OfficeWorkItem -OfficeRoot $OfficeRoot -Id $Id
    if ($s.state -cne 'READY') { throw "The MR draft is written in READY; '$Id' is $($s.state)." }
    $ctxPath = Get-DeliveryContextPath $OfficeRoot $Id
    if (-not (Test-Path -LiteralPath $ctxPath)) { throw "'$Id' has no delivery.json; run deliver-prep.ps1 first." }
    $ctx = Get-Content -Raw -Encoding utf8 -LiteralPath $ctxPath | ConvertFrom-Json -AsHashtable -DateKind String
    $build = $s['build']
    $dir = Get-WorkItemDir $OfficeRoot $Id
    $o = Get-AgentOutcome -Text $ReplyText -OfficeRoot $OfficeRoot -Id $Id -Agent 'builder' -Now $Now
    if ($o.Valid) {
        Add-OfficeThreadEntry -OfficeRoot $OfficeRoot -Id $Id -From 'builder' -To 'office-manager' -Kind $o.Outcome -Body $o.Summary -Refs 'mr-draft.md' -Now $Now
    }

    $problems = @()
    if (-not $ctx['gitlabHost']) { $problems += 'delivery.json has no gitlabHost; run deliver-prep.ps1 again' }
    $draft = $null
    if ($o.Valid -and $o.Outcome -ceq 'done') {
        try {
            $text = Get-AgentDraft $ReplyText
            $draft = ConvertFrom-OfficeMrDraft $text
            if (-not $draft.Title -or $draft.Title.Length -gt 255) { $problems += 'title must be 1 to 255 characters' }
            if ($draft.Title -match '[\r\n]') { $problems += 'title must be one line' }
            $known = @($ctx.labels)
            foreach ($l in $draft.Labels) {
                if ($l -cnotin $known) { $problems += "label '$l' does not exist in $($s.project); Huddle never creates labels (L1, L2)" }
            }
            $first = @($draft.Body -split '\r?\n' | Where-Object { $_.Trim() } | Select-Object -First 1)
            if (-not $first.Count -or $first[0].Trim() -cne $script:A1Line) { $problems += "the description must start with the line '$($script:A1Line)' (A1)" }
            if ($draft.Body -cnotmatch "(?m)^Closes #$($s.iid)\b") { $problems += "the description must close the issue with a line 'Closes #$($s.iid)'" }
            if ($ctx.head -cne $build.head) { $problems += "the build changed since deliver-prep ($($ctx.head) -> $($build.head)); run it again" }
            if (-not $problems.Count) {
                [IO.File]::WriteAllText((Join-Path $dir 'mr-draft.md'), "$text`n", $script:Utf8NoBom)
                [IO.File]::WriteAllText((Join-Path $dir 'mr-body.md'), "$($draft.Body)`n", $script:Utf8NoBom)
            }
        }
        catch { $problems += "no usable MR draft in the reply: $($_.Exception.Message)" }
    }

    $result = 'blocked'
    $commands = $null
    if ($o.Valid -and $o.Outcome -ceq 'done' -and -not $problems.Count) {
        $result = 'done'
        $p = Resolve-OfficeProject -Config $Config -ProjectPath $s.project
        $wt = $build.worktree -replace '\\', '/'
        $body = (Join-Path $dir 'mr-body.md') -replace '\\', '/'
        # The MR is opened with `glab api`, not `glab mr create`: mr create resolves the source project from
        # the git remote of the directory it runs in (my own clone), adds a remote there and fetches into
        # it. The API call names the host and the project, uses no :placeholders and runs no git.
        # -f sends every value as a plain string; `--method POST` first so settings.json can ask on it.
        $endpoint = "projects/$([uri]::EscapeDataString($s.project))/merge_requests"
        $mr = "glab api --method POST --hostname $(ConvertTo-BashWord $ctx.gitlabHost) $(ConvertTo-BashWord $endpoint)" +
            " -f $(ConvertTo-BashWord "source_branch=$($build.branch)") -f $(ConvertTo-BashWord "target_branch=$($p.Project.baseBranch)")" +
            " -f $(ConvertTo-BashWord "title=$($draft.Title)") -f `"description=`$(cat $(ConvertTo-BashWord $body))`""
        if ($draft.Labels.Count) { $mr += " -f $(ConvertTo-BashWord "labels=$($draft.Labels -join ',')")" }
        $commands = [ordered]@{
            # No -u: setting an upstream would write to my clone's git config.
            push = "git -C $(ConvertTo-BashWord $wt) push origin $(ConvertTo-BashWord $build.branch)"
            mrCreate = $mr
        }
        $reason = $o.Summary
    }
    else {
        $reason = if (-not $o.Valid) { $o.Summary } elseif ($problems.Count) { "MR draft not accepted: $($problems -join '; ')" } else { "Builder returned $($o.Outcome): $($o.Summary)" }
        Add-OfficeThreadEntry -OfficeRoot $OfficeRoot -Id $Id -From 'office-manager' -To 'user' -Kind 'note' -Body "mr-draft.md not ready: $reason" -Now $Now
    }
    [pscustomobject]@{
        Id = $Id; Result = $result; Reason = $reason; State = $s.state; Valid = $o.Valid; Problems = [string[]]$problems
        Title = if ($draft) { $draft.Title } else { $null }; Labels = if ($draft) { $draft.Labels } else { [string[]]@() }
        DraftPath = Join-Path $dir 'mr-draft.md'; BodyPath = Join-Path $dir 'mr-body.md'; Commands = $commands
    }
}

# Records the opened MR (read back from GitLab by the caller) and moves READY -> DELIVERED, which frees
# the build slot. -Mr is the one open MR from the work item's branch; -IssueUpdatedAt is the issue's
# updated_at read after the MR was opened ('Closes #n' touches the issue), stored so /huddle-tick does
# not take Huddle's own MR for an edit of the issue (SPEC §3.8).
function Complete-OfficeDelivery {
    param(
        [Parameter(Mandatory)][string]$OfficeRoot,
        [Parameter(Mandatory)][string]$Id,
        [AllowEmptyCollection()][object[]]$OpenMrs = @(),
        [string]$IssueUpdatedAt,
        [datetime]$Now = (Get-Date)
    )
    $s = Get-OfficeWorkItem -OfficeRoot $OfficeRoot -Id $Id
    if ($s.state -cne 'READY') { throw "Delivery completes from READY; '$Id' is $($s.state)." }
    $build = $s['build']
    $mrs = @($OpenMrs | Where-Object { $_ -and $_.source_branch -ceq $build.branch })
    if ($mrs.Count -ne 1) { throw "Expected exactly one open MR from $($build.branch), found $($mrs.Count). Nothing was recorded." }
    $mr = $mrs[0]
    if ($mr.sha -and $mr.sha -cne $build.head) { throw "MR !$($mr.iid) is at $($mr.sha), not the reviewed build $($build.head). Nothing was recorded." }
    $null = Set-StatusField $OfficeRoot $Id 'mr' ([ordered]@{ iid = $mr.iid; url = $mr.web_url; sha = $mr.sha; at = (Format-Timestamp $Now) }) $Now
    if ($IssueUpdatedAt) { $null = Set-OfficeIssueUpdatedAt -OfficeRoot $OfficeRoot -Id $Id -IssueUpdatedAt $IssueUpdatedAt -Now $Now }
    $null = Set-OfficeWorkItemState -OfficeRoot $OfficeRoot -Id $Id -State 'DELIVERED' -Now $Now
    Add-OfficeThreadEntry -OfficeRoot $OfficeRoot -Id $Id -From 'office-manager' -To 'user' -Kind 'state' `
        -Body "READY -> DELIVERED: MR !$($mr.iid) opened." -Refs $mr.web_url -Now $Now
    $after = Get-OfficeWorkItem -OfficeRoot $OfficeRoot -Id $Id
    [pscustomobject]@{ Id = $Id; State = $after.state; MrIid = $mr.iid; MrUrl = $mr.web_url }
}

# --- After delivery (T20, SPEC §3.11): what became of the MR -----------------------------------------

# Records one read of a delivered work item's MR in status.json (`mr.state`, `mr.mergedAt`,
# `mr.pipeline`, `mr.checkedAt`) and notes a change in thread.md. The work item stays DELIVERED.
# The MR was open when it was delivered, so a first read that finds it open with a pipeline that
# did not fail is not a change. Returns what changed, for /huddle-tick's report.
function Set-OfficeMrStatus {
    param(
        [Parameter(Mandatory)][string]$OfficeRoot,
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][ValidateSet('opened', 'merged', 'closed', 'locked')][string]$State,
        [string]$MergedAt,
        [string]$Pipeline,
        [datetime]$Now = (Get-Date)
    )
    $s = Get-OfficeWorkItem -OfficeRoot $OfficeRoot -Id $Id
    if ($s.state -cne 'DELIVERED') { throw "MR status is tracked for DELIVERED work items; '$Id' is $($s.state)." }
    $old = $s['mr']
    if ($null -eq $old -or $null -eq $old['iid']) { throw "Work item '$Id' has no recorded MR." }

    $fromState = if ($old['state']) { [string]$old['state'] } else { 'opened' }
    $fromPipeline = if ($old['pipeline']) { [string]$old['pipeline'] } else { $null }
    $toPipeline = if ($Pipeline) { $Pipeline } else { $null }
    $stateChanged = $fromState -cne $State
    $pipelineChanged = $State -ceq 'opened' -and $fromPipeline -cne $toPipeline -and
        ($null -ne $fromPipeline -or $toPipeline -ceq 'failed')

    $new = [ordered]@{}
    foreach ($k in $old.Keys) { $new[$k] = $old[$k] }
    $new.state = $State
    $new.mergedAt = if ($MergedAt) { $MergedAt } else { $null }
    $new.pipeline = $toPipeline
    $new.checkedAt = Format-Timestamp $Now
    $null = Set-StatusField $OfficeRoot $Id 'mr' $new $Now

    if ($stateChanged -or $pipelineChanged) {
        $body = if ($stateChanged) { "MR !$($old['iid']) $fromState -> $State." }
        else { "MR !$($old['iid']) pipeline $(if ($fromPipeline) { $fromPipeline } else { 'none' }) -> $(if ($toPipeline) { $toPipeline } else { 'none' })." }
        Add-OfficeThreadEntry -OfficeRoot $OfficeRoot -Id $Id -From 'office-manager' -To 'user' -Kind 'state' `
            -Body $body -Refs $old['url'] -Now $Now
    }
    [pscustomobject]@{
        Id = $Id; Mr = $old['iid']; Changed = ($stateChanged -or $pipelineChanged)
        From = $fromState; To = $State; PipelineFrom = $fromPipeline; Pipeline = $toPipeline
    }
}

# --- Waiting for another MR (T21, SPEC §3.11) ---------------------------------------------------------
#
# status.json `waitsFor`: [{ kind: 'mr-merged', project, iid, note, addedAt, metAt, mrState }].
# A wait is unmet while `metAt` is null. While a work item has an unmet wait, /huddle-tick does not
# brief it and /huddle-take does not start it; nothing else looks at waits.

function Format-OfficeMrRef($Wait) { "$($Wait['project'])!$($Wait['iid'])" }

function Get-OfficeUnmetWaits {
    param([Parameter(Mandatory)][Collections.IDictionary]$Item)
    , @(@($Item['waitsFor']) | Where-Object { $_ -and -not $_['metAt'] })
}

function Add-OfficeWait {
    param(
        [Parameter(Mandatory)][string]$OfficeRoot,
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Project,
        [Parameter(Mandatory)][int]$Iid,
        [string]$Note,
        [datetime]$Now = (Get-Date)
    )
    if ($Note -match '[\r\n]') { throw 'The note must be a single line.' }
    $s = Get-OfficeWorkItem -OfficeRoot $OfficeRoot -Id $Id
    if ($s.state -cnotin $script:BriefStates) {
        throw "A work item can wait for an MR only before it is built (NEW, BRIEFED, PLANNED); '$Id' is $($s.state)."
    }
    $waits = @(@($s['waitsFor']) | Where-Object { $_ })
    $same = @($waits | Where-Object { -not $_['metAt'] -and $_['project'] -ceq $Project -and [int]$_['iid'] -eq $Iid })
    if ($same.Count) { return [pscustomobject]@{ Id = $Id; Added = $false; Wait = $same[0] } }
    $wait = [ordered]@{
        kind = 'mr-merged'; project = $Project; iid = $Iid; note = $(if ($Note) { $Note } else { $null })
        addedAt = (Format-Timestamp $Now); metAt = $null; mrState = $null
    }
    $null = Set-StatusField $OfficeRoot $Id 'waitsFor' @($waits + $wait) $Now
    Add-OfficeThreadEntry -OfficeRoot $OfficeRoot -Id $Id -From 'user' -To 'office-manager' -Kind 'wait' `
        -Body "Waits for $(Format-OfficeMrRef $wait) to be merged.$(if ($Note) { " $Note" })" -Now $Now
    [pscustomobject]@{ Id = $Id; Added = $true; Wait = $wait }
}

# Drops every unmet wait; waits that were met stay as history. Returns how many were dropped.
function Clear-OfficeWaits {
    param(
        [Parameter(Mandatory)][string]$OfficeRoot,
        [Parameter(Mandatory)][string]$Id,
        [datetime]$Now = (Get-Date)
    )
    $s = Get-OfficeWorkItem -OfficeRoot $OfficeRoot -Id $Id
    $unmet = Get-OfficeUnmetWaits $s
    if ($unmet.Count -eq 0) { return 0 }
    $kept = @(@($s['waitsFor']) | Where-Object { $_ -and $_['metAt'] })
    $null = Set-StatusField $OfficeRoot $Id 'waitsFor' $kept $Now
    Add-OfficeThreadEntry -OfficeRoot $OfficeRoot -Id $Id -From 'user' -To 'office-manager' -Kind 'wait' `
        -Body "No longer waits for $(($unmet | ForEach-Object { Format-OfficeMrRef $_ }) -join ', ')." -Now $Now
    $unmet.Count
}

# Records one read of an MR that a work item waits for. 'merged' meets the wait; any other state is
# kept as `mrState` (a closed MR is shown as a warning). Returns whether the wait was met by this read.
function Set-OfficeWaitStatus {
    param(
        [Parameter(Mandatory)][string]$OfficeRoot,
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Project,
        [Parameter(Mandatory)][int]$Iid,
        [Parameter(Mandatory)][string]$MrState,
        [datetime]$Now = (Get-Date)
    )
    $s = Get-OfficeWorkItem -OfficeRoot $OfficeRoot -Id $Id
    $waits = @(@($s['waitsFor']) | Where-Object { $_ })
    $met = $false
    $changed = $false
    foreach ($w in $waits) {
        if ($w['metAt'] -or $w['project'] -cne $Project -or [int]$w['iid'] -ne $Iid) { continue }
        if ($w['mrState'] -cne $MrState) { $w['mrState'] = $MrState; $changed = $true }
        if ($MrState -ceq 'merged') { $w['metAt'] = Format-Timestamp $Now; $met = $true }
    }
    if (-not $changed) { return [pscustomobject]@{ Id = $Id; Met = $false; Remaining = (Get-OfficeUnmetWaits $s).Count } }
    $after = Set-StatusField $OfficeRoot $Id 'waitsFor' $waits $Now
    if ($met) {
        Add-OfficeThreadEntry -OfficeRoot $OfficeRoot -Id $Id -From 'office-manager' -To 'user' -Kind 'wait' `
            -Body "$Project!$Iid was merged; the work item no longer waits for it." -Now $Now
    }
    elseif ($MrState -ceq 'closed') {
        Add-OfficeThreadEntry -OfficeRoot $OfficeRoot -Id $Id -From 'office-manager' -To 'user' -Kind 'wait' `
            -Body "$Project!$Iid was closed without being merged; the work item still waits for it." -Now $Now
    }
    [pscustomobject]@{ Id = $Id; Met = $met; Remaining = (Get-OfficeUnmetWaits $after).Count }
}

# --- Retention (T17, SPEC §3.7: DELIVERED -(retentionDays)-> PURGED) ---------------------------------
#
# Run by /huddle-tick. A work item DELIVERED for at least `retentionDays` is purged: its worktree is
# removed, its local branch deleted when a copy exists elsewhere (the same branch on origin, or its tip
# already contained in origin/<baseBranch>), and office/work/<id>/ deleted. A worktree with uncommitted
# changes stops the purge for that item (nothing is touched; the item keeps a `purgeWarning` that
# /huddle shows). Everything is local except `git ls-remote` / `git fetch` (reads). Each outcome is
# appended to office/purge.log.

function Get-OfficeDeliveredAt([Collections.IDictionary]$Item) {
    $entry = @($Item.history | Where-Object { $_.to -ceq 'DELIVERED' } | Select-Object -Last 1)
    if ($entry.Count) { [DateTimeOffset]::Parse($entry[0].at, [Globalization.CultureInfo]::InvariantCulture) } else { $null }
}

function Add-OfficePurgeLog([string]$OfficeRoot, [string]$Line, [datetime]$Now) {
    [IO.File]::AppendAllText((Join-Path $OfficeRoot 'purge.log'), "[$(Format-Timestamp $Now)] $Line`n", $script:Utf8NoBom)
}

# True when deleting the local branch loses nothing: origin has the branch, or origin/<base> contains it.
function Test-OfficeBranchCopied([string]$Repo, [string]$Branch, [string]$BaseBranch) {
    $remote = @(& git -C $Repo ls-remote --heads origin $Branch 2>$null)
    if ($LASTEXITCODE -eq 0 -and @($remote | Where-Object { $_ -match "refs/heads/$([regex]::Escape($Branch))$" }).Count) { return $true }
    if (-not $BaseBranch) { return $false }
    & git -C $Repo fetch --quiet origin $BaseBranch 2>$null | Out-Null
    if (-not (Test-OfficeGitRef $Repo "refs/remotes/origin/$BaseBranch")) { return $false }
    & git -C $Repo merge-base --is-ancestor "refs/heads/$Branch" "refs/remotes/origin/$BaseBranch" 2>$null
    $LASTEXITCODE -eq 0
}

function Invoke-OfficePurge {
    param(
        [Parameter(Mandatory)][string]$OfficeRoot,
        [Parameter(Mandatory)][hashtable]$Config,
        [switch]$DryRun,
        [datetime]$Now = (Get-Date)
    )
    # Get-OfficeConfig guarantees retentionDays; a hand-built config (tests) falls back to the SPEC default.
    $days = if ($null -ne $Config['retentionDays']) { [int]$Config['retentionDays'] } else { 30 }
    $rows = @()
    $workDir = Join-Path $OfficeRoot 'work'
    if (-not (Test-Path -LiteralPath $workDir)) { return $rows }
    foreach ($dir in Get-ChildItem -LiteralPath $workDir -Directory | Sort-Object Name) {
        if (-not (Test-Path -LiteralPath (Join-Path $dir.FullName 'status.json'))) { continue }
        $s = Get-OfficeWorkItem -OfficeRoot $OfficeRoot -Id $dir.Name
        if ($s.state -cne 'DELIVERED') { continue }
        $deliveredAt = Get-OfficeDeliveredAt $s
        if ($null -eq $deliveredAt) { continue }
        $age = [int][math]::Floor(([DateTimeOffset]$Now - $deliveredAt).TotalDays)
        $row = [ordered]@{ id = $s.id; reference = "$($s.project)#$($s.iid)"; deliveredAt = $deliveredAt.ToString('yyyy-MM-ddTHH:mm:sszzz'); ageDays = $age; result = $null; reason = $null }
        if ($age -lt $days) { $row.result = 'kept'; $row.reason = "delivered $age day(s) ago; retention is $days"; $rows += $row; continue }

        $build = $s['build']
        $wt = if ($build) { $build.worktree } else { $null }
        $hasWorktree = $wt -and (Test-Path -LiteralPath $wt -PathType Container)
        if ($hasWorktree) {
            $dirty = @(Get-OfficeWorktreeChanges $wt)
            if ($dirty.Count) {
                $row.result = 'skipped'
                $row.reason = "worktree has uncommitted changes: $(($dirty | Select-Object -First 5) -join '; ')"
                if (-not $DryRun) {
                    $null = Set-StatusField $OfficeRoot $s.id 'purgeWarning' "Purge skipped: $($row.reason)" $Now
                    Add-OfficePurgeLog $OfficeRoot "$($row.reference) ($($s.id)) skipped: $($row.reason)" $Now
                }
                $rows += $row
                continue
            }
        }
        if ($DryRun) { $row.result = 'would-purge'; $row.reason = "delivered $age day(s) ago"; $rows += $row; continue }

        $p = Resolve-OfficeProject -Config $Config -ProjectPath $s.project
        $repo = $p.RepoPath
        $actions = @()
        if ($build -and $repo -and (Test-Path -LiteralPath $repo -PathType Container)) {
            if ($hasWorktree) { $null = Invoke-OfficeGit $repo @('worktree', 'remove', $wt); $actions += 'worktree removed' }
            else { $null = Invoke-OfficeGit $repo @('worktree', 'prune'); $actions += 'worktree already gone (pruned)' }
            if ($build.branch -and (Test-OfficeGitRef $repo "refs/heads/$($build.branch)")) {
                if (Test-OfficeBranchCopied $repo $build.branch $p.Project.baseBranch) {
                    $null = Invoke-OfficeGit $repo @('branch', '-D', $build.branch); $actions += "branch $($build.branch) deleted"
                }
                else { $actions += "branch $($build.branch) kept (no copy on origin)" }
            }
        }
        $null = Set-OfficeWorkItemState -OfficeRoot $OfficeRoot -Id $s.id -State 'PURGED' -Now $Now
        Remove-Item -LiteralPath $dir.FullName -Recurse -Force
        $actions += 'office/work folder deleted'
        $row.result = 'purged'; $row.reason = $actions -join '; '
        Add-OfficePurgeLog $OfficeRoot "$($row.reference) ($($s.id)) purged after $age day(s): $($row.reason)" $Now
        $rows += $row
    }
    , $rows
}

# --- Inbox reading (written by notify-new.ps1) -----------------------------------------------------

function Get-OfficeInboxItems {
    param([Parameter(Mandatory)][string]$OfficeRoot)
    $dir = Join-Path $OfficeRoot 'inbox'
    if (-not (Test-Path -LiteralPath $dir)) { return }
    foreach ($f in Get-ChildItem -LiteralPath $dir -Filter '*.json' -File | Sort-Object Name) {
        $entry = $null
        $err = $null
        try { $entry = Get-Content -Raw -Encoding utf8 -LiteralPath $f.FullName | ConvertFrom-Json -AsHashtable -DateKind String }
        catch { $err = $_.Exception.Message }
        if (-not $err -and ($entry -isnot [hashtable] -or -not $entry.reference)) { $err = 'missing reference' }
        [pscustomobject]@{ File = $f.FullName; Name = $f.Name; Entry = $entry; Error = $err }
    }
}

function Remove-OfficeInboxItem {
    param(
        [Parameter(Mandatory)][string]$OfficeRoot,
        [Parameter(Mandatory)][string]$Name
    )
    if ($Name -notmatch '^\d+\.json$') { throw "Not an inbox file name: '$Name'." }
    Remove-Item -LiteralPath (Join-Path $OfficeRoot 'inbox' $Name) -Force
}

Export-ModuleMember -Function Get-OfficeConfig, Get-OfficeWorkItemId, Test-OfficeTransition,
    Register-OfficeWorkItem, Get-OfficeWorkItem, Set-OfficeWorkItemState, Set-OfficeWorkItemPendingDecision,
    Add-OfficeThreadEntry, Get-OfficeSummary, Format-OfficeBrief,
    Resolve-OfficeProject, Get-OfficeClonePath, Get-OfficeWorktreePath, Get-OfficeBranchName,
    Get-AgentOutcome, ConvertFrom-OfficeWorkItemRef, Initialize-OfficeProjectRepo, Test-OfficeBrief,
    Complete-OfficeIntake, Write-OfficeInboxItem, Get-OfficeUpdateAction, Set-OfficeIssueUpdatedAt,
    New-OfficeDecision, Resolve-OfficeDecision, Get-OfficeInboxItems, Remove-OfficeInboxItem,
    Get-OfficePendingNotifications, Add-OfficeNotificationRecord, New-OfficeWorktree, Update-OfficeReadBase,
    Test-OfficePlan, Get-OfficeActiveBuilds, Read-OfficeProjectProfile, Save-OfficeProjectProfile, Set-OfficeProjectCommands,
    Request-OfficeG1, Complete-OfficePlan, Invoke-OfficeG1Ruling, Complete-OfficeAnalysisComment,
    Get-OfficeLoopInput, Complete-OfficeImplement, Complete-OfficeLoopReview, Read-OfficeSecurityFindings,
    Read-OfficeReviewItems, Test-OfficeDivergence, Invoke-OfficeG2Ruling, Start-OfficeRework, Rename-OfficeBranch,
    Resolve-OfficeBaseCommit, Get-OfficePlannedPaths, Test-OfficeBaseMove, Set-OfficePlanBase, Compare-OfficeRepoSnapshot,
    Get-OfficeDeliveryInput, Complete-OfficeMrDraft, Complete-OfficeDelivery, Invoke-OfficePurge,
    Set-OfficeMrStatus, Get-OfficeUnmetWaits, Add-OfficeWait, Clear-OfficeWaits, Set-OfficeWaitStatus
