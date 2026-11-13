# PreToolUse hook for the Bash and PowerShell tools (G3 hard gate).
# Reads the hook JSON on stdin and prints a permission decision on stdout.
#
# Always exits 0: Claude Code treats a non-zero exit other than 2 as a hook error and lets the
# tool call run, so every failure here is turned into an explicit deny instead (fail closed).
[Console]::OutputEncoding = [Text.Encoding]::UTF8

function Write-Decision([string]$Decision, [string]$Reason) {
    [ordered]@{
        hookSpecificOutput = [ordered]@{
            hookEventName            = 'PreToolUse'
            permissionDecision       = $Decision
            permissionDecisionReason = "[gate-guard] $Reason"
        }
    } | ConvertTo-Json -Depth 4 -Compress
}

try {
    $ErrorActionPreference = 'Stop'
    # Claude Code sends UTF-8. Without an attached console, [Console]::In decodes with the ANSI code page
    # (cp950 here), which corrupts CJK text and breaks the JSON, so decode the raw bytes explicitly.
    $reader = [IO.StreamReader]::new([Console]::OpenStandardInput(), [Text.UTF8Encoding]::new($false))
    try { $raw = $reader.ReadToEnd() } finally { $reader.Dispose() }
    $hookInput = $raw | ConvertFrom-Json -AsHashtable

    if ($hookInput.tool_name -notin @('Bash', 'PowerShell')) { exit 0 }

    $toolInput = $hookInput.tool_input
    $command = if ($toolInput -is [hashtable] -and $toolInput.ContainsKey('command')) { $toolInput.command } else { $null }
    if ($command -isnot [string]) {
        Write-Decision 'deny' 'Shell tool call without a command string; refusing to guess (fail closed).'
        exit 0
    }

    Import-Module (Join-Path $PSScriptRoot 'GateGuard.psm1') -Force
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $d = Get-GateDecision -Command $command -Cwd $hookInput.cwd -RepoRoot $repoRoot
    if ($d.Decision -ne 'none') { Write-Decision $d.Decision $d.Reason }
    exit 0
}
catch {
    Write-Decision 'deny' "gate-guard failed and is failing closed: $($_.Exception.Message)"
    exit 0
}
