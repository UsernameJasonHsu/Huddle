# Next step of the Huddle build loop (/huddle-build, SPEC §3.3): BUILDING -> TESTING -> SEC_REVIEW -> REVIEW.
# Local only: reads office/ and config/office.json, and in BUILDING creates the worktree on first use
# (`git fetch origin <baseBranch>` first, a read from GitLab). Dispatches nothing. Prints JSON:
#   { ok, action, reason, agent, mode, id, workDir, replyFile, state, round, maxAutoRounds, pendingDecision,
#     project, iid, title, webUrl, planPath, briefPath, threadPath, repoPath,
#     worktree: { path, branch, baseCommit, head }, commands: { build, test }, waivers: [...],
#     feedback: { from, report, ruling } | null (builder; a rework I asked for from READY has from 'user',
#     the ruling's note and `reports`, all three report paths), reportPath (tester / security / reviewer),
#     dispute: { count, builderObjection } (tester, when the Builder objected to its last report) }
# action: run-agent | ready | blocked | pending-decision | none. maxAutoRounds includes extra rounds
# allowed at G2; a round over the limit raises that G2 here (pendingDecision).
# -Ref is 'group/project#iid', 'project#iid', the issue URL, or the office id (e.g. jason-huddle-sandbox-1).
# -Resume moves an item BLOCKED by a loop agent back to where it was, then continues.
# On failure: { ok: false, ref, error }. Always exits 0 so the caller reads the JSON.
param(
    [Parameter(Mandatory)][string]$Ref,
    [switch]$Resume,
    [string]$OfficeRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) 'office'),
    [string]$ConfigPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'config' 'office.json')
)
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

try {
    Import-Module (Join-Path $PSScriptRoot 'Office.psm1') -Force
    $config = Get-OfficeConfig -Path $ConfigPath
    $id = $Ref.Trim()
    if (-not (Test-Path -LiteralPath (Join-Path $OfficeRoot 'work' $id 'status.json'))) {
        # Short refs ('project#iid') are resolved against the work items already in the office.
        $known = @(Get-ChildItem -LiteralPath (Join-Path $OfficeRoot 'work') -Directory -ErrorAction SilentlyContinue |
            Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'status.json') } |
            ForEach-Object { $s = Get-OfficeWorkItem -OfficeRoot $OfficeRoot -Id $_.Name; "$($s.project)#$($s.iid)" })
        $r = ConvertFrom-OfficeWorkItemRef -Ref $Ref -AssignedReferences $known
        $id = Get-OfficeWorkItemId -ProjectPath $r.ProjectPath -Iid $r.Iid
    }
    $out = Get-OfficeLoopInput -OfficeRoot $OfficeRoot -Id $id -Config $config -Resume:$Resume -Fetch
}
catch {
    $out = [ordered]@{ ok = $false; ref = $Ref; error = $_.Exception.Message }
}
$out | ConvertTo-Json -Depth 5
exit 0
