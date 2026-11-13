# G3 hard gate: classification of shell commands into deny / ask / none,
# plus the hook wrapper contract (JSON in on stdin, JSON out, always exit 0, fail closed).

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    Import-Module (Join-Path $script:RepoRoot 'scripts' 'GateGuard.psm1') -Force
    $script:Hook = Join-Path $script:RepoRoot 'scripts' 'gate-guard.ps1'

    # -Cp950 reproduces the console Claude Code gives the hook on zh-TW Windows: a hidden console whose
    # code page is 950, while stdin carries raw UTF-8 bytes. [Console]::In follows the console code page,
    # so it would misdecode CJK text. The code page is set explicitly so the test does not depend on
    # whatever console the test runner happens to inherit.
    function Invoke-Hook {
        param([string]$StdIn, [switch]$Cp950)
        if ($Cp950) {
            $psi = [System.Diagnostics.ProcessStartInfo]::new('cmd.exe')
            $psi.Arguments = "/d /c chcp 950 >nul && pwsh -NoProfile -File `"$script:Hook`""
            $psi.CreateNoWindow = $true
        }
        else {
            $psi = [System.Diagnostics.ProcessStartInfo]::new('pwsh')
            foreach ($a in '-NoProfile', '-File', $script:Hook) { $psi.ArgumentList.Add($a) }
        }
        $psi.RedirectStandardInput = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.UseShellExecute = $false
        $p =[System.Diagnostics.Process]::Start($psi)
        $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($StdIn)
        $p.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
        $p.StandardInput.Close()
        $out = $p.StandardOutput.ReadToEnd()
        $p.WaitForExit()
        [pscustomobject]@{ ExitCode = $p.ExitCode; Stdout = $out.Trim() }
    }

    function New-HookInput {
        param([string]$Command, [string]$Tool = 'Bash', [string]$Cwd = $script:RepoRoot)
        @{ hook_event_name = 'PreToolUse'; tool_name = $Tool; cwd = $Cwd; tool_input = @{ command = $Command } } |
            ConvertTo-Json -Compress -Depth 5
    }
}

Describe 'Get-GateDecision' {
    Context 'deny: posting issue notes with my own account' {
        It 'denies <_>' -ForEach @(
            'glab issue note 1 --message hi'
            'glab issue note 12 -m hi -R acme/SupportDesk'
            'glab -R acme/SupportDesk issue note 12 -m hi'
            'cd /tmp && glab issue note 1 -m hi'
            'GLAB.EXE issue note 1 -m hi'
            'glab api projects/1/issues/2/notes -f body=hi'
            'glab api -X POST "projects/a%2Fb/issues/2/notes" -f body=hi'
            'glab api --method=POST projects/a%2Fb/issues/2/discussions -f body=hi'
            "glab api graphql -f query='mutation { createNote(input: {noteableId: 1, body: 2}) { note { id } } }'"
        ) {
            (Get-GateDecision -Command $_).Decision | Should -Be 'deny'
        }

        It 'explains that post-issue-note.ps1 is the only way to comment' {
            (Get-GateDecision -Command 'glab issue note 1 -m hi').Reason | Should -Match 'post-issue-note\.ps1'
        }
    }

    Context 'ask: outward writes that need my confirmation' {
        It 'asks for <_>' -ForEach @(
            # git push and ways of spelling it
            'git push'
            'git push origin main'
            'git -C . push origin main'
            'git -C "C:\work tree" push'
            'git --git-dir=.git push'
            'git --git-dir .git --work-tree . push'
            'git -c user.name=x push'
            'git --no-pager push'
            '"C:\Program Files\Git\cmd\git.exe" push'
            'git.exe push'
            'GIT push'
            'git send-pack origin main'
            'git config alias.p push'
            'echo hi; git push'
            'git status && git push'
            'git push --dry-run && git push'
            '(git push)'
            'echo $(git push)'
            'bash -c "git push"'
            'pwsh -NoProfile -Command "git push origin main"'
            'Start-Process git -ArgumentList push'
            # glab write subcommands (anything not on the read allowlist)
            'glab mr create --title x --yes'
            'glab mr update 1 --description x'
            'glab mr merge 1'
            'glab mr note 1 -m hi'
            'glab issue create --title x'
            'glab issue update 1 --label x'
            'glab issue close 1'
            'glab label create foo'
            'glab repo delete a/b'
            'glab something-new'
            # glab api writes
            'glab api projects/1/issues -X POST -f title=x'
            'glab api -XPUT projects/1'
            'glab api --method=PUT projects/1 -f name=x'
            'glab api projects/1/issues -f title=x'
            'glab api projects/1/issues --raw-field title=x'
            'glab api projects/1/issues -F title=@t.txt'
            'glab api projects/1/uploads --form file=@a.png'
            'glab api projects/1/issues --input body.json'
            'glab api graphql -f query=mutation'
            'glab api -X DELETE projects/1/issues/2/notes/3'
            # bot comment script
            'pwsh -NoProfile -File scripts/post-issue-note.ps1 -Issue 1'
            # raw HTTP writes
            'Invoke-RestMethod -Method Post -Uri https://example.test'
            'irm https://example.test -Method:Put'
            'Invoke-WebRequest https://example.test -Body x'
            'curl -X POST https://example.test'
            'curl -XPOST https://example.test'
            'curl --request PATCH https://example.test'
            'curl -d a=b https://example.test'
            'curl --data-binary @f https://example.test'
            'curl -F file=@a https://example.test'
            'curl.exe --json "{}" https://example.test'
            'wget --post-data=a https://example.test'
            # obfuscation that the gate cannot see through
            'iex "git status"'
            'Invoke-Expression $cmd'
            'pwsh -EncodedCommand ZwBpAHQAIABwAHUAcwBoAA=='
            'powershell -enc ZwBpAHQAIABwAHUAcwBoAA=='
        ) {
            (Get-GateDecision -Command $_).Decision | Should -Be 'ask'
        }
    }

    Context 'none: reads and local work pass through' {
        It 'does not gate <_>' -ForEach @(
            'git status'
            'git log --oneline -5'
            'git push --dry-run'
            'git push -n origin main'
            'git commit -m "fix push handling"'
            'git -C ../SupportDesk fetch origin'
            'git worktree add ../wt -b huddle/1-x origin/main'
            'glab issue view 348 -R acme/SupportDesk --comments'
            'glab issue list --assignee=@me'
            'glab mr list --source-branch huddle/1-x'
            'glab label list -R acme/SupportDesk --output json'
            'glab repo clone acme/SupportDesk C:\ws\repos\x'
            'glab auth status --hostname gitlab.example.com'
            'glab --version'
            'glab'
            'git'
            'curl'
            'cd .. && git'
            'glab'
            'glab api projects/1/issues/2/notes'
            'glab api -X GET projects/1/issues/2/notes -f per_page=100'
            'glab api --hostname gitlab.example.com "issues?scope=assigned_to_me&state=opened"'
            'pwsh -NoProfile -File scripts/notify-decision.ps1 -Gate G1'
            'Invoke-RestMethod https://example.test'
            'irm -Method Get https://example.test'
            'curl -f https://example.test'
            'curl -fsSL https://example.test -o out.txt'
            'Invoke-Pester -Path tests -Output Detailed'
            'ls -la'
            ''
        ) {
            (Get-GateDecision -Command $_).Decision | Should -Be 'none'
        }
    }

    Context 'script files are scanned for writes' {
        BeforeAll {
            $script:Tmp = Join-Path ([IO.Path]::GetTempPath()) ("gate-guard-tests-" + [guid]::NewGuid())
            New-Item -ItemType Directory -Path $script:Tmp | Out-Null
            Set-Content -LiteralPath (Join-Path $script:Tmp 'sneaky.ps1') -Value "Write-Host hi`ngit push origin main"
            Set-Content -LiteralPath (Join-Path $script:Tmp 'nested.ps1') -Value '& "$PSScriptRoot/sneaky.ps1"'
            Set-Content -LiteralPath (Join-Path $script:Tmp 'comment.sh') -Value 'glab issue note 1 -m hi'
            Set-Content -LiteralPath (Join-Path $script:Tmp 'harmless.ps1') -Value 'Get-ChildItem'
        }
        AfterAll { Remove-Item -Recurse -Force -LiteralPath $script:Tmp }

        It 'asks when a script it runs contains git push' {
            (Get-GateDecision -Command 'pwsh -File sneaky.ps1' -Cwd $script:Tmp).Decision | Should -Be 'ask'
        }

        It 'follows a script that calls another script' {
            (Get-GateDecision -Command 'pwsh -File ./nested.ps1' -Cwd $script:Tmp).Decision | Should -Be 'ask'
        }

        It 'denies when a script it runs posts an issue note' {
            (Get-GateDecision -Command 'bash comment.sh' -Cwd $script:Tmp).Decision | Should -Be 'deny'
        }

        It 'passes a harmless script' {
            (Get-GateDecision -Command 'pwsh -File harmless.ps1' -Cwd $script:Tmp).Decision | Should -Be 'none'
        }

        It 'reads a script only when the command runs it: <Command> -> <Expected> (T19)' -ForEach @(
            @{ Command = 'git add sneaky.ps1'; Expected = 'none' }
            @{ Command = 'git diff HEAD -- sneaky.ps1 comment.sh'; Expected = 'none' }
            @{ Command = 'Get-Content sneaky.ps1'; Expected = 'none' }
            @{ Command = 'Invoke-Pester -Path sneaky.ps1'; Expected = 'none' }
            @{ Command = './sneaky.ps1'; Expected = 'ask' }
            @{ Command = '. ./sneaky.ps1'; Expected = 'ask' }
            @{ Command = '& ./sneaky.ps1'; Expected = 'ask' }
            @{ Command = 'cd /tmp && ./sneaky.ps1'; Expected = 'ask' }
            @{ Command = 'pwsh -NoProfile -File sneaky.ps1'; Expected = 'ask' }
            @{ Command = 'source comment.sh'; Expected = 'deny' }
            @{ Command = 'sh comment.sh'; Expected = 'deny' }
            @{ Command = 'nohup bash comment.sh'; Expected = 'deny' }
        ) {
            (Get-GateDecision -Command $Command -Cwd $script:Tmp).Decision | Should -Be $Expected
        }

        It 'stays fast when a command only names a large modified script, and still scans it when run (T19)' {
            $big = Join-Path $script:Tmp 'big.ps1'
            # 3000 lines with quotes, apostrophes and a push hidden in a string: the shape that was slow.
            $lines = 1..3000 | ForEach-Object { "Write-Host ""line $_ isn't quoted"" 'x' # git push origin main" }
            Set-Content -LiteralPath $big -Value ($lines -join "`n")
            $sw = [Diagnostics.Stopwatch]::StartNew()
            (Get-GateDecision -Command "git add big.ps1 sneaky.ps1 comment.sh" -Cwd $script:Tmp).Decision | Should -Be 'none'
            $sw.Stop()
            $sw.Elapsed.TotalSeconds | Should -BeLessThan 2
            (Get-GateDecision -Command 'pwsh -File big.ps1' -Cwd $script:Tmp).Decision | Should -Be 'ask'
        }

        It 'trusts unmodified committed scripts under the repo scripts/ folder' {
            # notify-new.ps1 posts to Teams, but it is committed and reviewed.
            (Get-GateDecision -Command 'pwsh -NoProfile -File scripts/notify-new.ps1' -Cwd $script:RepoRoot -RepoRoot $script:RepoRoot).Decision |
                Should -Be 'none'
        }
    }
}

Describe 'gate-guard.ps1 hook wrapper' {
    It 'emits a PreToolUse deny decision and exits 0' {
        $r = Invoke-Hook (New-HookInput 'glab issue note 1 -m hi')
        $r.ExitCode | Should -Be 0
        $j = $r.Stdout | ConvertFrom-Json
        $j.hookSpecificOutput.hookEventName | Should -Be 'PreToolUse'
        $j.hookSpecificOutput.permissionDecision | Should -Be 'deny'
        $j.hookSpecificOutput.permissionDecisionReason | Should -Not -BeNullOrEmpty
    }

    It 'emits an ask decision for git push' {
        $r = Invoke-Hook (New-HookInput 'git push')
        ($r.Stdout | ConvertFrom-Json).hookSpecificOutput.permissionDecision | Should -Be 'ask'
    }

    It 'handles the PowerShell tool the same way' {
        $r = Invoke-Hook (New-HookInput -Tool 'PowerShell' 'git -C . push')
        ($r.Stdout | ConvertFrom-Json).hookSpecificOutput.permissionDecision | Should -Be 'ask'
    }

    It 'prints nothing for an ungated command' {
        $r = Invoke-Hook (New-HookInput 'git status')
        $r.ExitCode | Should -Be 0
        $r.Stdout | Should -BeNullOrEmpty
    }

    It 'prints nothing for tools it does not gate' {
        $json = @{ tool_name = 'Read'; tool_input = @{ file_path = 'x' } } | ConvertTo-Json -Compress
        (Invoke-Hook $json).Stdout | Should -BeNullOrEmpty
    }

    It 'fails closed on malformed input' {
        $r = Invoke-Hook 'this is not json'
        $r.ExitCode | Should -Be 0
        ($r.Stdout | ConvertFrom-Json).hookSpecificOutput.permissionDecision | Should -Be 'deny'
    }

    Context 'non-ASCII commands under a cp950 console (regression: stdin decoding broke the JSON)' {
        BeforeAll {
            # Built from code points so this file's own encoding cannot affect the test.
            # The trailing U+2713 matters: its last UTF-8 byte (0x93) is a Big5 lead byte, so a cp950 decoder
            # swallows the JSON escape backslash that follows it and the payload no longer parses.
            $script:Cjk = -join ([char[]](0x6E2C, 0x8A66, 0x2713))
        }

        It 'still denies a gated command that contains CJK text' {
            $r = Invoke-Hook (New-HookInput "glab issue note 1 -m `"$script:Cjk`"") -Cp950
            $j = $r.Stdout | ConvertFrom-Json
            $j.hookSpecificOutput.permissionDecision | Should -Be 'deny'
            $j.hookSpecificOutput.permissionDecisionReason | Should -Not -Match 'failing closed'
        }

        It 'prints nothing for an ungated command that contains CJK text' {
            $r = Invoke-Hook (New-HookInput "echo `"$script:Cjk`"") -Cp950
            $r.ExitCode | Should -Be 0
            $r.Stdout | Should -BeNullOrEmpty
        }
    }

    It 'fails closed when a shell tool call has no command' {
        $json = @{ tool_name = 'Bash'; tool_input = @{} } | ConvertTo-Json -Compress
        ($( Invoke-Hook $json ).Stdout | ConvertFrom-Json).hookSpecificOutput.permissionDecision | Should -Be 'deny'
    }
}
