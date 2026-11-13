# Prepares a work item for the Intake agent (/huddle-take, SPEC §3.8 steps 1 and 3).
# Reads from GitLab only: the assigned-item list (radar rank), the issue itself, and, for an
# unregistered project, `glab repo clone`. Registers the work item in office/ and prints JSON:
#   { ok, action, mode, reason, id, workDir, replyFile (null unless an agent runs), state, project, iid,
#     title, webUrl, issueUpdatedAt, gitlabHost, issueApi,
#     radar: { rank, total, severitySource, idleDays } | null,
#     repo: { registered, repoPath, cloned, baseBranch, profileDraftPath } | null,
#     agent: intake | builder | null, builderMode: plan | null, planPath, planNeedsReview,
#     profile: { needed, path, exists } | null (run-planner only), pendingDecision,
#     g1: { result: raised | queued | pending, decision, activeBuilds } | null }
# action: 'run-intake' (NEW, or BLOCKED waiting to be briefed), 'run-planner' (BRIEFED, a plan to
# revise, or BLOCKED by the Builder), 'g1' (PLANNED with a ready plan: G1 was just raised, or the
# item is queued behind another build), 'pending-decision', 'none' (any other state), or 'waiting'
# (the work item waits for a merge request, T21: nothing was started; { waitsFor, message } say why).
# On failure: { ok: false, ref, error, retryable }.
# Always exits 0 so the caller reads the JSON.
param(
    [Parameter(Mandatory)][string]$Ref,
    [string]$OfficeRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) 'office')
)
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

try {
    Import-Module (Join-Path $PSScriptRoot 'Huddle.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot 'WorkItems.psm1')
    Import-Module (Join-Path $PSScriptRoot 'Office.psm1')
    $wcfg = Get-WorkItemConfig
    # Get-SortedWorkItems already returns one array (comma-wrapped); @() here would nest it.
    $sorted = Get-SortedWorkItems -Config $wcfg
    if ($null -eq $sorted) { $sorted = @() }
    $out = Invoke-HuddleTakePrep -Ref $Ref -OfficeRoot $OfficeRoot -WorkItemConfig $wcfg -OfficeConfig (Get-OfficeConfig) `
        -SortedItems $sorted -Mode take
}
catch {
    $out = [ordered]@{ ok = $false; ref = $Ref; error = $_.Exception.Message; retryable = $true }
}
$out | ConvertTo-Json -Depth 5
exit 0
