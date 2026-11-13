# Applies the Builder agent's final reply to a work item. -ReplyFile holds the reply verbatim.
#   -Mode plan              (/huddle-take, SPEC §3.8): checks plan.md (+ project-profile.json when the
#                           project needs settings), BRIEFED -> PLANNED, then raises G1 or queues it.
#                           Prints { ok, id, mode, result: done|blocked, reason, from, state, valid,
#                                    missingSections, profileErrors, g1: { result, decision, activeBuilds } | null }
#   -Mode analysis-comment  (after G1, SPEC §3.10): checks analysis-comment.md; never changes the state.
#                           Prints { ok, id, mode, result, reason, state, valid, path }
#   -Mode mr-draft          (READY, T15): checks the MR draft (front matter, labels from delivery.json,
#                           A1 line, Closes #iid), saves mr-draft.md and mr-body.md; never changes the state.
#                           Prints { ok, id, mode, result, reason, state, valid, problems, title, labels,
#                                    draftPath, bodyPath, commands: { push, mrCreate } | null }.
#                           The commands are for the Office Manager to run as they are (each asks G3).
# Nothing is posted anywhere. On failure: { ok: false, error }. Always exits 0 so the caller reads the JSON.
param(
    [Parameter(Mandatory)][string]$Id,
    [Parameter(Mandatory)][ValidateSet('plan', 'analysis-comment', 'mr-draft')][string]$Mode,
    [Parameter(Mandatory)][string]$ReplyFile,
    [string]$OfficeRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) 'office'),
    [string]$ConfigPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'config' 'office.json')
)
[Console]::OutputEncoding = [Text.Encoding]::UTF8
# A missing reply file must fail the call, not count as an empty (blocked) reply.
$ErrorActionPreference = 'Stop'

try {
    Import-Module (Join-Path $PSScriptRoot 'Office.psm1') -Force
    $text = Get-Content -Raw -Encoding utf8 -LiteralPath $ReplyFile
    if ($null -eq $text) { $text = '' }
    if ($Mode -ceq 'plan') {
        $r = Complete-OfficePlan -OfficeRoot $OfficeRoot -Id $Id -ReplyText $text -Config (Get-OfficeConfig -Path $ConfigPath)
        $out = [ordered]@{
            ok              = $true
            id              = $r.Id
            mode            = $Mode
            result          = $r.Result
            reason          = $r.Reason
            from            = $r.From
            state           = $r.State
            valid           = $r.Valid
            missingSections = @($r.MissingSections)
            profileErrors   = @($r.ProfileErrors)
            g1              = if ($r.G1) { [ordered]@{ result = $r.G1.Result; decision = $r.G1.DecisionId; activeBuilds = @($r.G1.ActiveBuilds) } } else { $null }
        }
    }
    elseif ($Mode -ceq 'mr-draft') {
        $r = Complete-OfficeMrDraft -OfficeRoot $OfficeRoot -Id $Id -ReplyText $text -Config (Get-OfficeConfig -Path $ConfigPath)
        $out = [ordered]@{
            ok = $true; id = $r.Id; mode = $Mode; result = $r.Result; reason = $r.Reason; state = $r.State; valid = $r.Valid
            problems = @($r.Problems); title = $r.Title; labels = @($r.Labels); draftPath = $r.DraftPath; bodyPath = $r.BodyPath
            commands = $r.Commands
        }
    }
    else {
        $r = Complete-OfficeAnalysisComment -OfficeRoot $OfficeRoot -Id $Id -ReplyText $text
        $out = [ordered]@{
            ok = $true; id = $r.Id; mode = $Mode; result = $r.Result; reason = $r.Reason
            state = $r.State; valid = $r.Valid; path = $r.Path
        }
    }
}
catch {
    $out = [ordered]@{ ok = $false; error = $_.Exception.Message }
}
$out | ConvertTo-Json -Depth 5
exit 0
