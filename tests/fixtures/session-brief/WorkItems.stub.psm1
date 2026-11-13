# Stand-in for scripts/WorkItems.psm1 used by tests/session-brief.Tests.ps1.
# The real module talks to GitLab; this one returns fixed data chosen by $env:BRIEF_STUB_MODE.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-WorkItemConfig {
    @{ gitlabHost = 'gitlab.example'; projectPriority = @('acme/SupportDesk') }
}

function Get-SortedWorkItems {
    param([hashtable]$Config)
    switch ($env:BRIEF_STUB_MODE) {
        'fail'  { throw 'glab api issues failed (exit 1): stub failure' }
        'empty' { return @() }
        default {
            @(
                [pscustomobject]@{
                    Reference = 'acme/SupportDesk#348'; Title = 'Check staging export | schedule'
                    SeveritySource = 'priority::high (fallback)'; IdleDays = 37; DueDate = $null
                    WebUrl = 'https://gitlab.example/acme/SupportDesk/-/work_items/348'
                }
                [pscustomobject]@{
                    Reference = 'tools/portal/portal#407'; Title = 'Search index'
                    SeveritySource = 'priority::medium (fallback)'; IdleDays = 7; DueDate = '2026-12-01'
                    WebUrl = 'https://gitlab.example/tools/portal/portal/-/work_items/407'
                }
            )
        }
    }
}

# Open MRs that close a work item. $env:BRIEF_STUB_OPENMR:
#   '348'   acme/SupportDesk#348 has open MR !573
#   'all'   both items have an open MR (portal#407's is a draft)
#   'error' the lookup fails for portal#407
#   unset   no item has an open MR
function Get-WorkItemOpenMrs {
    param([hashtable]$Config, [object[]]$Items = @())
    $map = @{}
    $errors = @()
    $mr573 = [pscustomobject]@{ Iid = 573; WebUrl = 'https://gitlab.example/acme/SupportDesk/-/merge_requests/573'; Draft = $false }
    $mr514 = [pscustomobject]@{ Iid = 514; WebUrl = 'https://gitlab.example/tools/portal/portal/-/merge_requests/514'; Draft = $true }
    switch ($env:BRIEF_STUB_OPENMR) {
        '348'   { $map['acme/SupportDesk#348'] = @($mr573) }
        'all'   { $map['acme/SupportDesk#348'] = @($mr573); $map['tools/portal/portal#407'] = @($mr514) }
        'error' { $errors = @('tools/portal/portal#407') }
    }
    [pscustomobject]@{ Map = $map; Errors = $errors }
}

# The only GitLab read the brief makes besides the list: a delivered work item's MR (T20).
# $env:BRIEF_STUB_MR = 'merged' serves a merged MR; anything else fails like an unreachable GitLab.
function Invoke-GitLabApi {
    param([string]$GitLabHost, [string]$Endpoint)
    if ($env:BRIEF_STUB_MR -ceq 'merged') {
        return , @(@{ iid = 9; state = 'merged'; merged_at = '2026-11-06T04:00:00.000Z'; head_pipeline = @{ status = 'success' } })
    }
    throw "glab api $Endpoint failed (exit 1): stub failure"
}

Export-ModuleMember -Function Get-WorkItemConfig, Get-SortedWorkItems, Invoke-GitLabApi, Get-WorkItemOpenMrs
