Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:RepoRoot = Split-Path -Parent $PSScriptRoot

function Get-WorkItemConfig {
    param([string]$Path = (Join-Path $script:RepoRoot 'config/work-items.json'))
    Get-Content -Raw -Encoding utf8 -LiteralPath $Path | ConvertFrom-Json -AsHashtable
}

function Invoke-GitLabApi {
    param(
        [Parameter(Mandatory)][string]$GitLabHost,
        [Parameter(Mandatory)][string]$Endpoint
    )
    [Console]::OutputEncoding = [Text.Encoding]::UTF8
    $out = & glab api --hostname $GitLabHost $Endpoint 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "glab api $Endpoint failed (exit $LASTEXITCODE): $($out -join "`n")"
    }
    $json = ($out | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }) -join "`n"
    # ConvertFrom-Json may return a JSON array as a single object; piping flattens it.
    $parsed = $json | ConvertFrom-Json -AsHashtable
    , @($parsed | ForEach-Object { $_ })
}

# Open issues / work items assigned to the authenticated glab user, across all projects.
function Get-AssignedWorkItems {
    param([Parameter(Mandatory)][hashtable]$Config)
    $all = [System.Collections.Generic.List[object]]::new()
    $page = 1
    while ($true) {
        $batch = Invoke-GitLabApi -GitLabHost $Config.gitlabHost `
            -Endpoint "issues?scope=assigned_to_me&state=opened&per_page=100&page=$page"
        foreach ($i in $batch) { $all.Add($i) }
        if ($batch.Count -lt 100) { break }
        $page++
    }
    $all.ToArray()
}

function Get-ProjectRank {
    param([hashtable]$Config, [string]$ProjectPath)
    $list = @($Config.projectPriority)
    for ($k = 0; $k -lt $list.Count; $k++) {
        if ($ProjectPath -like $list[$k]) { return $k }
    }
    $list.Count
}

# Severity resolution order:
#   1. scoped label severity::<level>
#   2. built-in GitLab severity field (ignored when UNKNOWN)
#   3. scoped label priority::<level>  (only when priorityLabelFallback is true)
function Get-SeverityInfo {
    param([hashtable]$Config, [hashtable]$Item)
    $map = $Config.severityRank
    $unset = $map.Count

    foreach ($l in @($Item.labels)) {
        if ($l -match '^severity::(.+)$' -and $map.ContainsKey($Matches[1].ToLower())) {
            return @{ Rank = $map[$Matches[1].ToLower()]; Source = $l }
        }
    }
    $field = "$($Item.severity)".ToLower()
    if ($field -and $map.ContainsKey($field)) {
        return @{ Rank = $map[$field]; Source = "severity field: $field" }
    }
    if ($Config.priorityLabelFallback) {
        foreach ($l in @($Item.labels)) {
            if ($l -match '^priority::(.+)$' -and $map.ContainsKey($Matches[1].ToLower())) {
                return @{ Rank = $map[$Matches[1].ToLower()]; Source = "$l (fallback)" }
            }
        }
    }
    @{ Rank = $unset; Source = 'unset' }
}

# Where a work item came from: 'jira' when it carries the label named in `jiraLabel` (set by the Jira
# triage that opens the GitLab issue), otherwise 'gitlab'. Without `jiraLabel` every item ranks alike.
function Get-SourceInfo {
    param([hashtable]$Config, [hashtable]$Item)
    $label = if ($Config.ContainsKey('jiraLabel')) { "$($Config['jiraLabel'])" } else { '' }
    if (-not $label) { return @{ Source = 'gitlab'; Rank = 0 } }
    if (@($Item.labels) -contains $label) { return @{ Source = 'jira'; Rank = 0 } }
    @{ Source = 'gitlab'; Rank = 1 }
}

# Sort order: source (Jira before GitLab) -> project priority -> severity -> least recently updated first.
function Get-SortedWorkItems {
    param([Parameter(Mandatory)][hashtable]$Config)
    $now = [DateTimeOffset]::UtcNow
    $rows = foreach ($i in @(Get-AssignedWorkItems -Config $Config)) {
        $ref = $i.references.full
        $project = $ref.Split('#')[0]
        $sev = Get-SeverityInfo -Config $Config -Item $i
        $src = Get-SourceInfo -Config $Config -Item $i
        $updated = [DateTimeOffset]::Parse($i.updated_at)
        [pscustomobject]@{
            Id             = $i.id
            Reference      = $ref
            Project        = $project
            Title          = $i.title
            Type           = $i.issue_type
            Labels         = @($i.labels)
            WebUrl         = $i.web_url
            DueDate        = $i.due_date
            Source         = $src.Source
            SourceRank     = $src.Rank
            ProjectRank   = Get-ProjectRank -Config $Config -ProjectPath $project
            SeverityRank   = $sev.Rank
            SeveritySource = $sev.Source
            UpdatedAt      = $updated
            IdleDays       = [int][Math]::Floor(($now - $updated).TotalDays)
        }
    }
    , @($rows | Sort-Object SourceRank, ProjectRank, SeverityRank, UpdatedAt)
}

# Keeps the open MRs out of an issue's `closed_by` answer (MRs that close the issue when merged).
function Select-OpenClosingMrs {
    param([AllowNull()][object[]]$MergeRequests)
    @(foreach ($m in @($MergeRequests)) {
            if ($null -eq $m -or $m['state'] -cne 'opened') { continue }
            [pscustomobject]@{ Iid = [int]$m['iid']; WebUrl = [string]$m['web_url']; Draft = [bool]$m['draft'] }
        })
}

# The open MRs in one `closed_by` response body. Always an array: the answer for an issue that no MR
# closes is `[]`, which parses to nothing, and `$null.Count` throws in strict mode.
function ConvertFrom-ClosedByJson {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Json)
    $parsed = $Json | ConvertFrom-Json -AsHashtable
    , @(Select-OpenClosingMrs -MergeRequests @($parsed | ForEach-Object { $_ }))
}

# Which of these work items already have an open MR that closes them (the work is waiting for review
# or merge, not for me to start). One read per item (`issues/:iid/closed_by`), run in parallel because
# this is on the session start path. Read-only. Returns:
#   Map     reference -> open MRs (Iid, WebUrl, Draft); only items that have at least one
#   Errors  references whose MR could not be read; they are treated as having no MR
function Get-WorkItemOpenMrs {
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [AllowEmptyCollection()][object[]]$Items = @()
    )
    $map = @{}
    $errors = [System.Collections.Generic.List[string]]::new()
    if (@($Items).Count -eq 0) { return [pscustomobject]@{ Map = $map; Errors = @() } }
    [Console]::OutputEncoding = [Text.Encoding]::UTF8
    $gitlabHost = $Config.gitlabHost
    $rows = @($Items | ForEach-Object Reference) | ForEach-Object -ThrottleLimit 6 -Parallel {
        $ref = $_
        $project, $iid = $ref.Split('#')
        $out = & glab api --hostname $using:gitlabHost "projects/$([uri]::EscapeDataString($project))/issues/$iid/closed_by" 2>&1
        [pscustomobject]@{
            Reference = $ref
            Ok        = ($LASTEXITCODE -eq 0)
            Json      = (($out | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }) -join "`n")
        }
    }
    foreach ($r in $rows) {
        if (-not $r.Ok) { $errors.Add($r.Reference); continue }
        try {
            $open = ConvertFrom-ClosedByJson -Json $r.Json
            if ($open.Count) { $map[$r.Reference] = $open }
        }
        catch { $errors.Add($r.Reference) }
    }
    [pscustomobject]@{ Map = $map; Errors = $errors.ToArray() }
}

Export-ModuleMember -Function Get-WorkItemConfig, Invoke-GitLabApi, Get-AssignedWorkItems, Get-SortedWorkItems,
    Get-WorkItemOpenMrs, Select-OpenClosingMrs, ConvertFrom-ClosedByJson
