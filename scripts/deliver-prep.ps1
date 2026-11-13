# /huddle-deliver prep (T15, SPEC §3.3 READY -> DELIVERED). Reads from GitLab only: the project's labels
# (with inherited ones) and open MRs from the work item's branch. Saves delivery.json in the work item
# folder (labels and build at this point) and prints JSON for the Builder's mr-draft run:
#   { ok, action, reason, id, state, project, iid, workDir, agent, builderMode, replyFile, title, webUrl,
#     planPath, briefPath, threadPath, reports: { test, security, review }, mrDraftPath, repoPath,
#     baseBranch, worktree: { path, branch, baseCommit, head }, waivers, availableLabels, a1Line,
#     revisionNote, gitlabHost, existingMrs (existing-mr only) }
# action: run-agent | existing-mr (gitlab-mr G2: update that MR, do not open another) | none.
# -Ref is 'group/project#iid', 'project#iid', the issue URL, or the office id. -Note asks the Builder to
# revise the previous draft. Nothing is pushed or posted.
# On failure: { ok: false, ref, error }. Always exits 0 so the caller reads the JSON.
param(
    [Parameter(Mandatory)][string]$Ref,
    [string]$Note,
    [string]$OfficeRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) 'office'),
    [string]$ConfigPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'config' 'office.json')
)
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

try {
    Import-Module (Join-Path $PSScriptRoot 'Huddle.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot 'WorkItems.psm1')
    Import-Module (Join-Path $PSScriptRoot 'Office.psm1')
    $id = $Ref.Trim()
    if (-not (Test-Path -LiteralPath (Join-Path $OfficeRoot 'work' $id 'status.json'))) {
        $known = @(Get-ChildItem -LiteralPath (Join-Path $OfficeRoot 'work') -Directory -ErrorAction SilentlyContinue |
            Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'status.json') } |
            ForEach-Object { $s = Get-OfficeWorkItem -OfficeRoot $OfficeRoot -Id $_.Name; "$($s.project)#$($s.iid)" })
        $r = ConvertFrom-OfficeWorkItemRef -Ref $Ref -AssignedReferences $known
        $id = Get-OfficeWorkItemId -ProjectPath $r.ProjectPath -Iid $r.Iid
    }
    $out = Invoke-HuddleDeliverPrep -OfficeRoot $OfficeRoot -Id $id -WorkItemConfig (Get-WorkItemConfig) `
        -OfficeConfig (Get-OfficeConfig -Path $ConfigPath) -Note $Note
}
catch {
    $out = [ordered]@{ ok = $false; ref = $Ref; error = $_.Exception.Message }
}
$out | ConvertTo-Json -Depth 5
exit 0
