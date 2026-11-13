# Retention pass by hand (T17, SPEC §3.7); /huddle-tick runs the same thing. Purges work items that have
# been DELIVERED for `retentionDays` or more: removes the worktree, deletes the local branch when a copy
# exists on origin (or origin/<baseBranch> already contains it), deletes office/work/<id>/. A worktree
# with uncommitted changes is skipped and the item keeps a warning that /huddle shows. Local only
# (`git ls-remote` / `git fetch` are reads). Outcomes go to office/purge.log. Prints JSON:
#   { ok, dryRun, items: [ { id, reference, deliveredAt, ageDays, result: kept|skipped|would-purge|purged, reason } ] }
#   -DryRun  reports what would happen and changes nothing (no log, no warning).
# On failure: { ok: false, error }. Always exits 0 so the caller reads the JSON.
param(
    [switch]$DryRun,
    [string]$OfficeRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) 'office'),
    [string]$ConfigPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'config' 'office.json')
)
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

try {
    Import-Module (Join-Path $PSScriptRoot 'Office.psm1') -Force
    $items = @(Invoke-OfficePurge -OfficeRoot $OfficeRoot -Config (Get-OfficeConfig -Path $ConfigPath) -DryRun:$DryRun)
    $out = [ordered]@{ ok = $true; dryRun = [bool]$DryRun; items = $items }
}
catch {
    $out = [ordered]@{ ok = $false; error = $_.Exception.Message }
}
$out | ConvertTo-Json -Depth 5
exit 0
