# One /huddle-tick pass without agent work (SPEC §3.5, §3.8): reads office/inbox, registers new
# items, checks every office work item's issue updated_at, raises G2 for changes after BUILDING,
# lists the Intake runs the session must dispatch, checks the MRs that work items wait for (T21) and
# the MRs of DELIVERED work items (T20), and runs the retention pass. Reads from GitLab only. Prints JSON:
#   { ok, inbox: [...], updates: [...], intake: [<huddle-take.ps1 result>...], delivered: [...],
#     unblocked: [...], purged: [...], errors: [...] }
# On failure: { ok: false, error }. Always exits 0 so the caller reads the JSON.
param(
    [string]$OfficeRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) 'office')
)
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

try {
    Import-Module (Join-Path $PSScriptRoot 'Huddle.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot 'WorkItems.psm1')
    Import-Module (Join-Path $PSScriptRoot 'Office.psm1')
    $out = Invoke-HuddleTick -OfficeRoot $OfficeRoot -WorkItemConfig (Get-WorkItemConfig) -OfficeConfig (Get-OfficeConfig)
}
catch {
    $out = [ordered]@{ ok = $false; error = $_.Exception.Message }
}
$out | ConvertTo-Json -Depth 6
exit 0
