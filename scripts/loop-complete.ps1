# Applies a build-loop agent's final reply (/huddle-build, SPEC §3.3). -ReplyFile holds the reply verbatim.
#   -Agent builder   (BUILDING)   done -> TESTING once the worktree is clean, has new commits and my own
#                                 clone is unchanged; objection -> G2 (Security, Reviewer, or the Tester
#                                 a second time) or back to the Tester to re-check; anything else -> BLOCKED.
#   -Agent tester    (TESTING)    saves test-report.md from the reply; done -> SEC_REVIEW,
#                                 objection -> BUILDING (next round); anything else -> BLOCKED.
#   -Agent security  (SEC_REVIEW) saves security-report.md; done -> REVIEW, objection -> BUILDING;
#                                 an outcome that contradicts the findings -> BLOCKED.
#   -Agent reviewer  (REVIEW)     saves review-report.md; done -> READY, objection (必須修) -> BUILDING.
# A return to BUILDING past maxAutoRounds raises G2 instead of another round.
# Prints { ok, id, agent, result: done | returned | disputed | g2 | blocked, reason, state, round, valid,
#          head, reportPath, problems, findings, decision }. decision is the G2 number when result is g2.
# Nothing is pushed or posted.
# On failure: { ok: false, error }. Always exits 0 so the caller reads the JSON.
param(
    [Parameter(Mandatory)][string]$Id,
    [Parameter(Mandatory)][ValidateSet('builder', 'tester', 'security', 'reviewer')][string]$Agent,
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
    $config = Get-OfficeConfig -Path $ConfigPath
    if ($Agent -ceq 'builder') {
        $r = Complete-OfficeImplement -OfficeRoot $OfficeRoot -Id $Id -ReplyText $text -Config $config
        $out = [ordered]@{
            ok = $true; id = $r.Id; agent = $Agent; result = $r.Result; reason = $r.Reason; state = $r.State
            round = $r.Round; valid = $r.Valid; head = $r.Head; reportPath = $null; problems = @($r.Problems); findings = @()
            decision = $r.Decision
        }
    }
    else {
        $r = Complete-OfficeLoopReview -OfficeRoot $OfficeRoot -Id $Id -Agent $Agent -ReplyText $text -Config $config
        $out = [ordered]@{
            ok = $true; id = $r.Id; agent = $Agent; result = $r.Result; reason = $r.Reason; state = $r.State
            round = $r.Round; valid = $r.Valid; head = $null; reportPath = $r.ReportPath; problems = @($r.Problems)
            findings = @($r.Findings); decision = $r.Decision
        }
    }
}
catch {
    $out = [ordered]@{ ok = $false; error = $_.Exception.Message }
}
$out | ConvertTo-Json -Depth 5
exit 0
