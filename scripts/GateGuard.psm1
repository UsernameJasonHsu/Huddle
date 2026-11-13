# G3 hard gate: classifies a shell command line as deny / ask / none.
#
# The goal is to catch outward writes (git push, GitLab writes, HTTP writes) however they are
# spelled, so the classifier is deliberately conservative: it tokenizes loosely, looks for the
# programs anywhere in the line (including inside quoted sub-commands and script files it runs),
# and prefers a false "ask" over a missed write. Only posting issue notes with my own account is
# denied outright; agents must use scripts/post-issue-note.ps1 (bot identity) instead.
#
# Known limits (see docs/notes/platform-facts.md): commands assembled at run time from variables,
# downloaded code, or programs other than git/glab/HTTP clients are not visible to this gate.
# Script files are read only when the command runs them (T19): as the program itself, or after `&`,
# `.`, `source`, `-File`, or a shell / PowerShell host name. A script that is only a path argument
# (`git add x.ps1`, `Get-Content x.ps1`, `Invoke-Pester -Path x.Tests.ps1`) is not opened, so naming
# large modified scripts in a command no longer runs into the hook timeout.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Rank = @{ none = 0; ask = 1; deny = 2 }

$script:GitValueOptions = @('-C', '-c', '--git-dir', '--work-tree', '--namespace', '--config-env', '--exec-path', '--super-prefix')
$script:GlabValueOptions = @('-R', '--repo', '--hostname', '-g', '--group')

# glab commands/subcommands that only read. Anything else is treated as a write (ask).
$script:GlabReads = @{
    issue   = @('view', 'show', 'list', 'ls')
    mr      = @('view', 'show', 'list', 'ls', 'diff', 'checkout')
    label   = @('list', 'ls')
    repo    = @('clone', 'view', 'list', 'ls')
    auth    = @('status')
    ci      = @('status', 'list', 'ls', 'view', 'get', 'trace')
    release = @('list', 'ls', 'view')
    config  = @('get')
}
$script:GlabAlwaysRead = @('version', 'help', 'completion')

$script:HttpPsPrograms = @('invoke-restmethod', 'irm', 'invoke-webrequest', 'iwr')
$script:ScriptExtensions = @('.ps1', '.psm1', '.sh', '.bash', '.cmd', '.bat')
$script:IssueNotePattern = 'issues/[^/\s"'']+/(notes|discussions)(\b|$)|createNote|createDiscussion'

function New-Decision([string]$Decision, [string]$Reason) {
    [pscustomobject]@{ Decision = $Decision; Reason = $Reason }
}

function Select-Stronger($A, $B) {
    if ($script:Rank[$B.Decision] -gt $script:Rank[$A.Decision]) { $B } else { $A }
}

# Two tokenizations are evaluated and the stronger decision wins:
#  - Quote-aware: "C:\work tree" stays one argument, so option values are parsed correctly.
#  - Loose: quotes are dropped, so quoted sub-commands (bash -c "git push") are scanned too.
function Split-CommandTokens([string]$Command, [switch]$QuoteAware) {
    if ($QuoteAware) {
        $pattern = '(?:[^\s;|&(){}`"'']+|"[^"]*"|''[^'']*'')+|[;|&(){}`]'
        return , @([regex]::Matches($Command, $pattern) | ForEach-Object { $_.Value -replace '["'']', '' })
    }
    $s = $Command -replace '\$\(', ' ( '
    $s = $s -replace '([;|&(){}`\r\n])', ' $1 '
    $s = $s -replace '["'']', ' '
    , @($s -split '\s+' | Where-Object { $_ -ne '' })
}

function Test-Separator([string]$Token) { $Token -match '^[;|&(){}`]+$' }

function Get-Segments([string[]]$Tokens) {
    $segments = [System.Collections.Generic.List[object]]::new()
    $current = [System.Collections.Generic.List[string]]::new()
    foreach ($t in $Tokens) {
        if (Test-Separator $t) {
            if ($current.Count) { $segments.Add($current.ToArray()); $current.Clear() }
        }
        else { $current.Add($t) }
    }
    if ($current.Count) { $segments.Add($current.ToArray()) }
    , $segments.ToArray()
}

function Get-ProgramName([string]$Token) {
    $leaf = ($Token -split '[\\/]')[-1].ToLowerInvariant()
    $leaf -replace '\.exe$', ''
}

function Get-GitDecision([string[]]$Rest) {
    $j = 0
    while ($j -lt $Rest.Count -and $Rest[$j].StartsWith('-')) {
        if ($script:GitValueOptions -ccontains $Rest[$j]) { $j += 2 } else { $j += 1 }
    }
    if ($j -ge $Rest.Count) { return New-Decision 'none' '' }
    $sub = $Rest[$j].ToLowerInvariant()
    $after = @($Rest | Select-Object -Skip ($j + 1))

    if ($sub -eq 'push') {
        if ($after -ccontains '--dry-run' -or $after -ccontains '-n') { return New-Decision 'none' '' }
        return New-Decision 'ask' 'git push writes to a remote repository (G3).'
    }
    if ($sub -eq 'send-pack') { return New-Decision 'ask' 'git send-pack writes to a remote repository (G3).' }
    if ($sub -eq 'config' -and @($after | Where-Object { $_ -match '^alias\.' }).Count) {
        return New-Decision 'ask' 'Defining a git alias can hide a push from the gate (G3).'
    }
    New-Decision 'none' ''
}

function Get-GlabApiDecision([string[]]$Rest, [string]$RawCommand) {
    $method = $null
    $hasData = $false
    for ($j = 0; $j -lt $Rest.Count; $j++) {
        $t = $Rest[$j]
        if ($t -ceq '-X' -or $t -ceq '--method') { if ($j + 1 -lt $Rest.Count) { $method = $Rest[$j + 1] }; $j++; continue }
        if ($t -cmatch '^--method=(.+)$' -or $t -cmatch '^-X(.+)$') { $method = $Matches[1]; continue }
        if (@('-f', '--raw-field', '-F', '--field', '--form', '--input') -ccontains $t -or
            $t -cmatch '^--(raw-field|field|form|input)=') { $hasData = $true }
    }
    $effective = if ($method) { $method.ToUpperInvariant() } elseif ($hasData) { 'POST' } else { 'GET' }
    if ($effective -eq 'GET') { return New-Decision 'none' '' }
    if ($effective -eq 'POST' -and $RawCommand -match $script:IssueNotePattern) {
        return New-Decision 'deny' 'Agents must not comment on issues with my account. Use scripts/post-issue-note.ps1 (bot identity, G3).'
    }
    New-Decision 'ask' 'glab api request that writes to GitLab (G3).'
}

function Get-GlabDecision([string[]]$Rest, [string]$RawCommand) {
    $positional = [System.Collections.Generic.List[object]]::new()
    $j = 0
    while ($j -lt $Rest.Count) {
        $t = $Rest[$j]
        if ($t.StartsWith('-')) {
            if ($positional.Count -lt 2 -and $script:GlabValueOptions -ccontains $t) { $j += 2 } else { $j += 1 }
            continue
        }
        $positional.Add(@{ Token = $t.ToLowerInvariant(); Index = $j })
        if ($positional.Count -eq 1 -and $positional[0].Token -eq 'api') { break }
        if ($positional.Count -eq 2) { break }
        $j++
    }
    if ($positional.Count -eq 0) { return New-Decision 'none' '' }
    $cmd = $positional[0].Token
    if ($cmd -eq 'api') {
        return Get-GlabApiDecision -Rest @($Rest | Select-Object -Skip ($positional[0].Index + 1)) -RawCommand $RawCommand
    }
    if ($script:GlabAlwaysRead -contains $cmd) { return New-Decision 'none' '' }
    $sub = if ($positional.Count -ge 2) { $positional[1].Token } else { $null }
    if ($cmd -eq 'issue' -and $sub -eq 'note') {
        return New-Decision 'deny' 'Agents must not comment on issues with my account. Use scripts/post-issue-note.ps1 (bot identity, G3).'
    }
    if ($script:GlabReads.ContainsKey($cmd) -and $sub -and $script:GlabReads[$cmd] -contains $sub) {
        return New-Decision 'none' ''
    }
    New-Decision 'ask' "glab $cmd $sub is not on the read-only allowlist (G3)."
}

function Get-HttpDecision([string]$Program, [string[]]$Rest) {
    $write = $false
    if ($script:HttpPsPrograms -contains $Program) {
        # PowerShell parameters are case-insensitive and accept -Name:Value.
        for ($j = 0; $j -lt $Rest.Count; $j++) {
            $t = $Rest[$j]
            if ($t -match '^-Method:(.+)$') { if ($Matches[1] -notmatch '^(Get|Head|Options)$') { $write = $true }; continue }
            if ($t -match '^-Method$' -and $j + 1 -lt $Rest.Count) {
                if ($Rest[$j + 1] -notmatch '^(Get|Head|Options)$') { $write = $true }
                $j++; continue
            }
            if ($t -match '^-(Body|InFile|Form)(:|$)') { $write = $true }
        }
    }
    elseif ($Program -eq 'curl') {
        for ($j = 0; $j -lt $Rest.Count; $j++) {
            $t = $Rest[$j]
            if ($t -ceq '-X' -or $t -ceq '--request') {
                if ($j + 1 -lt $Rest.Count -and $Rest[$j + 1] -notmatch '^(GET|HEAD|OPTIONS)$') { $write = $true }
                $j++; continue
            }
            if ($t -cmatch '^-X(.+)$' -or $t -cmatch '^--request=(.+)$') { if ($Matches[1] -notmatch '^(GET|HEAD|OPTIONS)$') { $write = $true }; continue }
            if (@('-d', '-F', '-T', '--json', '--form', '--upload-file') -ccontains $t -or $t -cmatch '^--(data|form|json|upload-file)') { $write = $true }
        }
    }
    elseif ($Program -eq 'wget') {
        if (@($Rest | Where-Object { $_ -cmatch '^--(post-data|post-file|body-data|body-file|method)' }).Count) { $write = $true }
    }
    if ($write) { New-Decision 'ask' "$Program request that sends data or uses a write method (G3)." } else { New-Decision 'none' '' }
}

function Test-TrustedScript([string]$Path, [string]$RepoRoot) {
    if (-not $RepoRoot) { return $false }
    $scriptsDir = [IO.Path]::GetFullPath((Join-Path $RepoRoot 'scripts')) + [IO.Path]::DirectorySeparatorChar
    $full = [IO.Path]::GetFullPath($Path)
    if (-not $full.StartsWith($scriptsDir, [StringComparison]::OrdinalIgnoreCase)) { return $false }
    # Trusted only while identical to the committed version: tracked and without local changes.
    & git -C $RepoRoot ls-files --error-unmatch -- $full 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { return $false }
    & git -C $RepoRoot diff --quiet HEAD -- $full 2>$null
    $LASTEXITCODE -eq 0
}

# Words after which the next token is a script being run (lower-case; program names without .exe).
$script:ScriptRunners = @('&', '.', 'source', '-file', 'pwsh', 'powershell', 'bash', 'sh', 'zsh', 'cmd', 'exec', 'start', 'nohup')

# Tokens in an "executed" position: the first token of a segment, or the token after a runner word.
# `&` and `.` are segment separators in Split-CommandTokens, so `& ./x.ps1` puts x.ps1 first anyway.
function Get-ExecutedScriptCandidates([object[]]$Segments) {
    $found = [System.Collections.Generic.List[string]]::new()
    foreach ($segment in $Segments) {
        for ($i = 0; $i -lt $segment.Count; $i++) {
            $run = ($i -eq 0) -or ($script:ScriptRunners -contains (Get-ProgramName $segment[$i - 1]))
            if ($run -and -not $found.Contains($segment[$i])) { $found.Add($segment[$i]) }
        }
    }
    , $found.ToArray()
}

function Get-ScriptFileDecision([string[]]$Tokens, [string]$Cwd, [string]$RepoRoot, [int]$Depth) {
    $result = New-Decision 'none' ''
    if ($Depth -ge 4) { return $result }
    foreach ($t in $Tokens) {
        $candidate = $t -replace '^\$PSScriptRoot[\\/]', ''
        $ext = [IO.Path]::GetExtension($candidate).ToLowerInvariant()
        if ($script:ScriptExtensions -notcontains $ext) { continue }
        $path = if ([IO.Path]::IsPathRooted($candidate)) { $candidate } elseif ($Cwd) { Join-Path $Cwd $candidate } else { $null }
        if (-not $path -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        if ((Get-Item -LiteralPath $path).Length -gt 1MB) {
            $result = Select-Stronger $result (New-Decision 'ask' "Script $candidate is too large to inspect (G3).")
            continue
        }
        if (Test-TrustedScript -Path $path -RepoRoot $RepoRoot) { continue }
        $content = Get-Content -Raw -LiteralPath $path
        $inner = Get-GateDecision -Command $content -Cwd (Split-Path -Parent $path) -RepoRoot $RepoRoot -Depth ($Depth + 1)
        if ($inner.Decision -ne 'none') {
            $inner = New-Decision $inner.Decision "Script $candidate contains a gated command: $($inner.Reason)"
        }
        $result = Select-Stronger $result $inner
    }
    $result
}

function Get-GateDecision {
    param(
        [AllowEmptyString()][string]$Command,
        [string]$Cwd,
        [string]$RepoRoot,
        [int]$Depth = 0
    )
    $result = New-Decision 'none' ''
    if (-not $Command) { return $result }

    $tokens = Split-CommandTokens $Command
    $quoted = Split-CommandTokens $Command -QuoteAware
    $segments = @((Get-Segments $quoted) + (Get-Segments $tokens))
    foreach ($segment in $segments) {
        for ($i = 0; $i -lt $segment.Count; $i++) {
            $program = Get-ProgramName $segment[$i]
            # Assigned in two steps: an `else { @() }` branch emits nothing and would leave $rest null.
            $rest = @()
            if ($i + 1 -lt $segment.Count) { $rest = @($segment[($i + 1)..($segment.Count - 1)]) }
            $d = switch ($program) {
                'git' { Get-GitDecision $rest }
                'glab' { Get-GlabDecision $rest $Command }
                { $_ -in 'iex', 'invoke-expression' } { New-Decision 'ask' 'Invoke-Expression hides the real command from the gate (G3).' }
                { $_ -in $script:HttpPsPrograms -or $_ -in 'curl', 'wget' } { Get-HttpDecision $program $rest }
                { $_ -like '*post-issue-note.ps1' } { New-Decision 'ask' 'post-issue-note.ps1 comments on GitLab as the bot (G3).' }
                { $_ -in '-encodedcommand', '-enc', '-ec' } { New-Decision 'ask' 'Encoded commands hide the real command from the gate (G3).' }
                default { $null }
            }
            if ($d) { $result = Select-Stronger $result $d }
        }
    }
    if ($result.Decision -ne 'deny') {
        $candidates = Get-ExecutedScriptCandidates $segments
        $result = Select-Stronger $result (Get-ScriptFileDecision -Tokens $candidates -Cwd $Cwd -RepoRoot $RepoRoot -Depth $Depth)
    }
    $result
}

Export-ModuleMember -Function Get-GateDecision
