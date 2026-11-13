# Applies the Intake agent's final reply to a work item (/huddle-take, SPEC §3.8 step 6).
# -ReplyFile holds the agent's final message verbatim. Prints JSON:
#   { ok, id, result: done|blocked, reason, from, state, valid, missingSections }
# On failure: { ok: false, error }. Always exits 0 so the caller reads the JSON.
param(
    [Parameter(Mandatory)][string]$Id,
    [Parameter(Mandatory)][string]$ReplyFile,
    # issueUpdatedAt from the huddle-take / huddle-tick prep that dispatched this Intake run.
    [string]$IssueUpdatedAt,
    [string]$OfficeRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) 'office')
)
[Console]::OutputEncoding = [Text.Encoding]::UTF8
# A missing reply file must fail the call, not count as an empty (blocked) reply.
$ErrorActionPreference = 'Stop'

try {
    Import-Module (Join-Path $PSScriptRoot 'Office.psm1') -Force
    $text = Get-Content -Raw -Encoding utf8 -LiteralPath $ReplyFile
    if ($null -eq $text) { $text = '' }
    $r = Complete-OfficeIntake -OfficeRoot $OfficeRoot -Id $Id -ReplyText $text -IssueUpdatedAt $IssueUpdatedAt
    $out = [ordered]@{
        ok              = $true
        id              = $r.Id
        result          = $r.Result
        reason          = $r.Reason
        from            = $r.From
        state           = $r.State
        valid           = $r.Valid
        missingSections = @($r.MissingSections)
    }
}
catch {
    $out = [ordered]@{ ok = $false; error = $_.Exception.Message }
}
$out | ConvertTo-Json -Depth 4
exit 0
