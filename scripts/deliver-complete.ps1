# /huddle-deliver, after the push and the MR request (`glab api --method POST`) I approved (G3). Reads from GitLab only: the open
# MR from the work item's branch and the issue's updated_at. Records the MR in status.json, stores the
# new updated_at (so /huddle-tick does not treat Huddle's own MR as an edit) and moves READY -> DELIVERED.
# Prints { ok, id, state, mrIid, mrUrl }. On failure (no MR, several MRs, an MR not at the reviewed
# commit): { ok: false, error } and nothing is recorded. Always exits 0 so the caller reads the JSON.
param(
    [Parameter(Mandatory)][string]$Id,
    [string]$OfficeRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) 'office')
)
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

try {
    Import-Module (Join-Path $PSScriptRoot 'Huddle.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot 'WorkItems.psm1')
    $r = Invoke-HuddleDeliverComplete -OfficeRoot $OfficeRoot -Id $Id -WorkItemConfig (Get-WorkItemConfig)
    $out = [ordered]@{ ok = $true; id = $r.Id; state = $r.State; mrIid = $r.MrIid; mrUrl = $r.MrUrl }
}
catch {
    $out = [ordered]@{ ok = $false; error = $_.Exception.Message }
}
$out | ConvertTo-Json -Depth 5
exit 0
