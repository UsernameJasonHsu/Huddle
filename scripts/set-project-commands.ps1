# Sets the build / test command of a registered project in config/office.json after G1 (SPEC §3.6).
# The Builder and the Tester run `commands.build` / `commands.test` inside the work item's worktree, so
# the command must work from that folder (and test the worktree's code, not my own clone).
#   -Test "<command>" / -Build "<command>"   set a command (one line)
#   -ClearTest / -ClearBuild                  set it back to null
# A command that is not named stays as it is. Local only: writes config/office.json, nothing else.
# Run it only when I ask, with the exact command I approved. Prints JSON:
#   { ok, project, before: { build, test }, after: { build, test } }
# On failure: { ok: false, project, error }. Always exits 0 so the caller reads the JSON.
param(
    [Parameter(Mandatory)][string]$Project,
    [string]$Test,
    [string]$Build,
    [switch]$ClearTest,
    [switch]$ClearBuild,
    [string]$ConfigPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'config' 'office.json')
)
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

try {
    Import-Module (Join-Path $PSScriptRoot 'Office.psm1') -Force
    $r = Set-OfficeProjectCommands -ConfigPath $ConfigPath -Project $Project -Test $Test -Build $Build `
        -ClearTest:$ClearTest -ClearBuild:$ClearBuild
    $out = [ordered]@{ ok = $true; project = $r.Project; before = $r.Before; after = $r.After }
}
catch {
    $out = [ordered]@{ ok = $false; project = $Project; error = $_.Exception.Message }
}
$out | ConvertTo-Json -Depth 5
exit 0
