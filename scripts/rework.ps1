# Sends a READY work item back to the Builder before delivery (SPEC §3.3): records a G2 decision of kind
# `rework` together with my ruling and moves READY -> BUILDING. The note says what the Builder has to
# address (items of review-report.md / security-report.md / test-report.md); continue with /huddle-build.
# Local only: writes office/ state, nothing in the target repo and nothing to GitLab or Teams.
# Run it only when I ask for a rework. Prints JSON:
#   { ok, id, decision, state, round, note }
# -Ref is 'group/project#iid', 'project#iid', the issue URL, or the office id.
# On failure: { ok: false, ref, error }. Always exits 0 so the caller reads the JSON.
param(
    [Parameter(Mandatory)][string]$Ref,
    [Parameter(Mandatory)][string]$Note,
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
    $res = Start-OfficeRework -OfficeRoot $OfficeRoot -Id $id -Note $Note -Config $config
    $out = [ordered]@{ ok = $true; id = $res.Id; decision = $res.Decision; state = $res.State; round = $res.Round; note = $res.Note }
}
catch {
    $out = [ordered]@{ ok = $false; ref = $Ref; error = $_.Exception.Message }
}
$out | ConvertTo-Json -Depth 5
exit 0
