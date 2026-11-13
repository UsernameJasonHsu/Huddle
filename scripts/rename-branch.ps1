# Renames the branch of a work item's worktree (SPEC §3.6), for target repos that require their own
# branch names (e.g. fix/issue-<id>-<slug>): `git branch -m` in the worktree and `build.branch` in
# status.json, so the delivery's push and MR commands use the new name. Allowed between BUILDING and
# READY, before anything was pushed. Local only: nothing is pushed and nothing is read from GitLab.
# Run it only when I ask for the rename, and not while an agent is working on the item. Prints JSON:
#   { ok, id, from, branch, worktree, state }
# -Ref is 'group/project#iid', 'project#iid', the issue URL, or the office id.
# On failure: { ok: false, ref, error }. Always exits 0 so the caller reads the JSON.
param(
    [Parameter(Mandatory)][string]$Ref,
    [Parameter(Mandatory)][string]$Branch,
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
    $res = Rename-OfficeBranch -OfficeRoot $OfficeRoot -Id $id -Branch $Branch -Config $config
    $out = [ordered]@{ ok = $true; id = $res.Id; from = $res.From; branch = $res.Branch; worktree = $res.Worktree; state = $res.State }
}
catch {
    $out = [ordered]@{ ok = $false; ref = $Ref; error = $_.Exception.Message }
}
$out | ConvertTo-Json -Depth 5
exit 0
