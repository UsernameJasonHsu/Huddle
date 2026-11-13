# Records my ruling on a pending decision (SPEC §3.4) and applies what that ruling means for the
# decision's kind. -Choice is the 1-based option number. Prints JSON:
#   { ok, id, decision, gate, kind, choice, option, state, builder }
# Kinds with an effect:
#   issue-changed (G2 from /huddle-tick): option 2 parks the work item; option 1 changes nothing.
#   divergence-tester|security|reviewer (G2 from /huddle-build): 1 the Builder fixes it (stays BUILDING),
#       2 accept the Builder's view (waiver recorded; on to where that agent would have passed it), 3 park.
#   round-limit (G2 from /huddle-build): 1 one more automatic round, 2 park.
#   base-moved (G2 from /huddle-build, T15c): 1 re-plan on the new base (BUILDING -> BRIEFED; run
#       /huddle-take again), 2 keep the plan (the worktree starts from the new base), 3 park.
#   g1 (G1 from /huddle-take): option 1 saves the approved project-profile.json to config/office.json
#       (only when the project needs settings) and moves PLANNED -> BUILDING; `builder` is then the
#       input for the Builder's analysis-comment run. Option 2 keeps it PLANNED for a revised plan,
#       option 3 parks it. A refused approval (plan flagged for review, build slot taken, bad profile)
#       leaves the decision pending and returns ok = false.
# On failure: { ok: false, error }. Always exits 0 so the caller reads the JSON.
param(
    [Parameter(Mandatory)][string]$Id,
    [Parameter(Mandatory)][int]$DecisionId,
    [Parameter(Mandatory)][int]$Choice,
    [string]$Note,
    [string]$OfficeRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) 'office'),
    [string]$ConfigPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'config' 'office.json')
)
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

try {
    Import-Module (Join-Path $PSScriptRoot 'Office.psm1') -Force
    $jsonPath = Join-Path $OfficeRoot 'work' $Id 'decisions' "$DecisionId.json"
    $d = Get-Content -Raw -Encoding utf8 -LiteralPath $jsonPath | ConvertFrom-Json -AsHashtable
    $builder = $null
    if ($d.kind -ceq 'g1') {
        $r = Invoke-OfficeG1Ruling -OfficeRoot $OfficeRoot -Id $Id -DecisionId $DecisionId -Choice $Choice -Note $Note -ConfigPath $ConfigPath
        $option = $r.Option
        if ($Choice -eq 1) {
            Import-Module (Join-Path $PSScriptRoot 'WorkItems.psm1') -Force
            Import-Module (Join-Path $PSScriptRoot 'Huddle.psm1') -Force
            $builder = Get-HuddleAnalysisInput -OfficeRoot $OfficeRoot -Id $Id -WorkItemConfig (Get-WorkItemConfig) `
                -OfficeConfig (Get-OfficeConfig -Path $ConfigPath)
        }
    }
    elseif ($d.kind -cmatch '^(divergence-(tester|security|reviewer)|round-limit|base-moved)$') {
        $option = (Invoke-OfficeG2Ruling -OfficeRoot $OfficeRoot -Id $Id -DecisionId $DecisionId -Choice $Choice -Note $Note).Option
    }
    else {
        $option = Resolve-OfficeDecision -OfficeRoot $OfficeRoot -Id $Id -DecisionId $DecisionId -Choice $Choice -Note $Note
        if ($d.kind -ceq 'issue-changed' -and $Choice -eq 2) {
            $null = Set-OfficeWorkItemState -OfficeRoot $OfficeRoot -Id $Id -State 'PARKED'
        }
    }
    $out = [ordered]@{
        ok = $true; id = $Id; decision = $DecisionId; gate = $d.gate; kind = $d.kind
        choice = $Choice; option = $option; state = (Get-OfficeWorkItem -OfficeRoot $OfficeRoot -Id $Id).state
        builder = $builder
    }
}
catch {
    $out = [ordered]@{ ok = $false; error = $_.Exception.Message }
}
$out | ConvertTo-Json -Depth 5
exit 0
