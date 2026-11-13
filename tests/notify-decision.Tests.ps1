# T10: notify-decision.ps1 pushes one Teams card per waiting decision (SPEC §3.4).
# Office.psm1 decides what is pending; the script runs for real in a sandbox copy where WorkItems.psm1
# is the notify-new stub, which shadows Invoke-RestMethod and records each posted body (no Teams).

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:Stub = Join-Path $PSScriptRoot 'fixtures' 'notify-new' 'WorkItems.stub.psm1'
    $script:Hook = 'https://example.invalid/hook/SECRET-TOKEN-123'
    $script:T0 = [datetime]'2026-11-06T09:00:00'
    # Text that must never reach a card: issue title and description, a diff, the brief.
    $script:Title = 'TITLE-MARKER confidential customer name'
    $script:IssueText = 'ISSUE-BODY-MARKER: password is hunter2'
    $script:Diff = "diff --git a/app.cs b/app.cs`n+DIFF-MARKER var key = 1;"
    Import-Module (Join-Path $script:RepoRoot 'scripts' 'Office.psm1') -Force

    function New-Sandbox {
        $sb = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $scripts = Join-Path $sb 'scripts'
        New-Item -ItemType Directory -Path $scripts -Force | Out-Null
        foreach ($f in 'notify-decision.ps1', 'Office.psm1') { Copy-Item (Join-Path $script:RepoRoot 'scripts' $f) $scripts }
        Copy-Item $script:Stub (Join-Path $scripts 'WorkItems.psm1')
        New-Item -ItemType Directory -Path (Join-Path $sb 'office') -Force | Out-Null
        $sb
    }

    function Add-Item([string]$Office, [int]$Iid) {
        $id = (Register-OfficeWorkItem -OfficeRoot $Office -ProjectPath 'grp/proj' -Iid $Iid -Title $script:Title `
                -WebUrl "https://gitlab.example/grp/proj/-/work_items/$Iid" -Now $script:T0).id
        [IO.File]::WriteAllText((Join-Path $Office 'work' $id 'brief.md'), "# Brief`n$script:IssueText`n")
        $id
    }

    function Add-G2([string]$Office, [string]$Id, [string]$Question = 'grp/proj#1 was edited on GitLab. Change the scope?') {
        New-OfficeDecision -OfficeRoot $Office -Id $Id -Gate 'G2' -Kind 'issue-changed' -Question $Question `
            -Options @('Keep', 'Park') -Context "$script:IssueText`n$script:Diff" -Now $script:T0
    }

    function Invoke-NotifyDecision {
        param([string]$Sandbox, [switch]$Fail, [switch]$NoWebhook)
        $log = Join-Path $Sandbox 'posts.log'
        $bodies = Join-Path $Sandbox 'bodies.log'
        Remove-Item -LiteralPath $log, $bodies -ErrorAction SilentlyContinue
        $env:NOTIFY_STUB_LOG = $log
        $env:NOTIFY_STUB_BODIES = $bodies
        $env:NOTIFY_STUB_FAIL = if ($Fail) { '1' } else { '' }
        $env:NOTIFY_STUB_WEBHOOK = if ($NoWebhook) { '' } else { $script:Hook }
        $prev = [Console]::OutputEncoding
        [Console]::OutputEncoding = [Text.Encoding]::UTF8
        try {
            # Same form as the allowed command: no arguments; the office folder is found next to scripts/.
            $raw = (& pwsh -NoProfile -File (Join-Path $Sandbox 'scripts' 'notify-decision.ps1') 2>&1 | ForEach-Object { "$_" }) -join "`n"
            $code = $LASTEXITCODE
        }
        finally {
            [Console]::OutputEncoding = $prev
            foreach ($v in 'NOTIFY_STUB_LOG', 'NOTIFY_STUB_BODIES', 'NOTIFY_STUB_FAIL', 'NOTIFY_STUB_WEBHOOK') {
                Remove-Item "Env:$v" -ErrorAction SilentlyContinue
            }
        }
        [pscustomobject]@{
            Raw      = $raw
            Json     = $raw | ConvertFrom-Json
            ExitCode = $code
            Posts    = if (Test-Path -LiteralPath $log) { @(Get-Content -LiteralPath $log) } else { @() }
            Bodies   = if (Test-Path -LiteralPath $bodies) { Get-Content -Raw -Encoding utf8 -LiteralPath $bodies } else { '' }
        }
    }

    function Get-Thread([string]$Office, [string]$Id) { Get-Content -Raw -Encoding utf8 (Join-Path $Office 'work' $Id 'thread.md') }
}

Describe 'Get-OfficePendingNotifications' {
    BeforeEach {
        $script:Office = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:Office | Out-Null
    }

    It 'returns nothing when the office has no work items' {
        @(Get-OfficePendingNotifications -OfficeRoot $script:Office).Count | Should -Be 0
    }

    It 'returns nothing for a work item without a decision that is not BLOCKED' {
        $null = Add-Item $script:Office 1
        @(Get-OfficePendingNotifications -OfficeRoot $script:Office).Count | Should -Be 0
    }

    It 'returns the pending decision with its gate and question' {
        $id = Add-Item $script:Office 1
        $null = Add-G2 $script:Office $id
        $n = @(Get-OfficePendingNotifications -OfficeRoot $script:Office)
        $n.Count | Should -Be 1
        $n[0].Id | Should -Be $id
        $n[0].Reference | Should -Be 'grp/proj#1'
        $n[0].Gate | Should -Be 'G2'
        $n[0].Key | Should -Be 'decision-1'
        $n[0].DecisionId | Should -Be 1
        $n[0].Summary | Should -Be 'grp/proj#1 was edited on GitLab. Change the scope?'
    }

    It 'returns a Clarify notification with a fixed summary for a BLOCKED item without a decision' {
        $id = Add-Item $script:Office 2
        $null = Set-OfficeWorkItemState -OfficeRoot $script:Office -Id $id -State 'BLOCKED' -Now $script:T0.AddMinutes(5)
        $n = @(Get-OfficePendingNotifications -OfficeRoot $script:Office)
        $n.Count | Should -Be 1
        $n[0].Gate | Should -Be 'Clarify'
        $n[0].Summary | Should -Be 'Work item is BLOCKED and waiting for your answer.'
        $n[0].Key | Should -Be "blocked-$($script:T0.AddMinutes(5).ToString('yyyy-MM-ddTHH:mm:sszzz'))"
        $n[0].DecisionId | Should -BeNullOrEmpty
    }

    It 'reports only the pending decision when a BLOCKED item also has one' {
        $id = Add-Item $script:Office 3
        $null = Set-OfficeWorkItemState -OfficeRoot $script:Office -Id $id -State 'BLOCKED' -Now $script:T0
        $null = New-OfficeDecision -OfficeRoot $script:Office -Id $id -Gate 'Clarify' -Kind 'question' -Question 'Which export queue?' `
            -Options @('A', 'B') -Now $script:T0
        $n = @(Get-OfficePendingNotifications -OfficeRoot $script:Office)
        $n.Count | Should -Be 1
        $n[0].Key | Should -Be 'decision-1'
        $n[0].Gate | Should -Be 'Clarify'
    }

    It 'does not return a key that was already recorded, sent or failed' -ForEach @(@{ Result = 'sent' }, @{ Result = 'failed' }) {
        $id = Add-Item $script:Office 1
        $null = Add-G2 $script:Office $id
        Add-OfficeNotificationRecord -OfficeRoot $script:Office -Id $id -Key 'decision-1' -Gate 'G2' -Result $Result -ErrorMessage 'x'
        @(Get-OfficePendingNotifications -OfficeRoot $script:Office).Count | Should -Be 0
    }

    It 'returns the next decision after the previous one was resolved' {
        $id = Add-Item $script:Office 1
        $null = Add-G2 $script:Office $id
        Add-OfficeNotificationRecord -OfficeRoot $script:Office -Id $id -Key 'decision-1' -Gate 'G2' -Result sent
        $null = Resolve-OfficeDecision -OfficeRoot $script:Office -Id $id -DecisionId 1 -Choice 1
        @(Get-OfficePendingNotifications -OfficeRoot $script:Office).Count | Should -Be 0
        $null = Add-G2 $script:Office $id
        (@(Get-OfficePendingNotifications -OfficeRoot $script:Office))[0].Key | Should -Be 'decision-2'
    }

    It 'notifies again when a work item becomes BLOCKED a second time' {
        $id = Add-Item $script:Office 1
        $null = Set-OfficeWorkItemState -OfficeRoot $script:Office -Id $id -State 'BLOCKED' -Now $script:T0
        $first = (@(Get-OfficePendingNotifications -OfficeRoot $script:Office))[0].Key
        Add-OfficeNotificationRecord -OfficeRoot $script:Office -Id $id -Key $first -Gate 'Clarify' -Result sent
        $null = Set-OfficeWorkItemState -OfficeRoot $script:Office -Id $id -State 'NEW' -Now $script:T0.AddHours(1)
        $null = Set-OfficeWorkItemState -OfficeRoot $script:Office -Id $id -State 'BLOCKED' -Now $script:T0.AddHours(2)
        $n = @(Get-OfficePendingNotifications -OfficeRoot $script:Office)
        $n.Count | Should -Be 1
        $n[0].Key | Should -Not -Be $first
    }

    It 'collapses the question to one line of at most 160 characters' {
        $id = Add-Item $script:Office 1
        $null = Add-G2 $script:Office $id -Question ("Line one`r`n  line two`t" + ('x' * 300))
        $s = (@(Get-OfficePendingNotifications -OfficeRoot $script:Office))[0].Summary
        $s | Should -Not -Match '[\r\n\t]'
        $s | Should -BeLike 'Line one line two x*'
        $s.Length | Should -Be 160
        $s | Should -BeLike ('*' + [char]0x2026)
    }

    It 'keeps a short question unchanged' {
        $id = Add-Item $script:Office 1
        $null = Add-G2 $script:Office $id -Question ('q' * 160)
        (@(Get-OfficePendingNotifications -OfficeRoot $script:Office))[0].Summary | Should -Be ('q' * 160)
    }
}

Describe 'Add-OfficeNotificationRecord' {
    BeforeEach {
        $script:Office = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:Office | Out-Null
        $script:Id = Add-Item $script:Office 1
    }

    It 'writes the ledger and a thread entry for a sent notification' {
        Add-OfficeNotificationRecord -OfficeRoot $script:Office -Id $script:Id -Key 'decision-1' -Gate 'G2' -Result sent -Now $script:T0
        $ledger = Get-Content -Raw (Join-Path $script:Office 'work' $script:Id 'notifications.json') | ConvertFrom-Json -AsHashtable -DateKind String
        $ledger['decision-1'].result | Should -Be 'sent'
        $ledger['decision-1'].error | Should -BeNullOrEmpty
        Get-Thread $script:Office $script:Id | Should -Match '(?m)^### \[2026-11-06 09:00\] office-manager → user · notify\r?\nTeams notification sent \(G2, decision-1\)\.'
    }

    It 'records a failure with a one-line error in the thread' {
        Add-OfficeNotificationRecord -OfficeRoot $script:Office -Id $script:Id -Key 'blocked' -Gate 'Clarify' -Result failed `
            -ErrorMessage "boom`nsecond line" -Now $script:T0
        Get-Thread $script:Office $script:Id | Should -Match 'Teams notification failed \(Clarify, blocked\); the decision flow continues\. boom second line'
    }

    It 'keeps earlier keys when adding another' {
        Add-OfficeNotificationRecord -OfficeRoot $script:Office -Id $script:Id -Key 'decision-1' -Gate 'G2' -Result sent
        Add-OfficeNotificationRecord -OfficeRoot $script:Office -Id $script:Id -Key 'decision-2' -Gate 'G1' -Result failed -ErrorMessage 'x'
        $ledger = Get-Content -Raw (Join-Path $script:Office 'work' $script:Id 'notifications.json') | ConvertFrom-Json -AsHashtable
        @($ledger.Keys | Sort-Object) | Should -Be @('decision-1', 'decision-2')
    }
}

Describe 'notify-decision.ps1' {
    BeforeEach {
        $script:Sb = New-Sandbox
        $script:Office = Join-Path $script:Sb 'office'
    }

    It 'prints ok with nothing sent when nothing is waiting' {
        $null = Add-Item $script:Office 1
        $r = Invoke-NotifyDecision $script:Sb
        $r.ExitCode | Should -Be 0
        $r.Json.ok | Should -BeTrue
        @($r.Json.sent).Count | Should -Be 0
        $r.Posts.Count | Should -Be 0
    }

    It 'posts one card per waiting decision to the webhook from the environment' {
        $a = Add-Item $script:Office 1
        $null = Add-G2 $script:Office $a
        $b = Add-Item $script:Office 2
        $null = Set-OfficeWorkItemState -OfficeRoot $script:Office -Id $b -State 'BLOCKED'
        $r = Invoke-NotifyDecision $script:Sb
        $r.Posts | Should -Be @("Post $script:Hook", "Post $script:Hook")
        @($r.Json.sent | ForEach-Object { "$($_.reference) $($_.gate)" }) | Should -Be @('grp/proj#1 G2', 'grp/proj#2 Clarify')
        $r.Bodies | Should -Match 'grp/proj#1 · G2'
        $r.Bodies | Should -Match 'grp/proj#2 · Clarify'
        $r.Bodies | Should -Match 'Change the scope\?'
        Get-Thread $script:Office $a | Should -Match 'Teams notification sent \(G2, decision-1\)'
    }

    It 'sends a card with only the reference, gate and summary' {
        $id = Add-Item $script:Office 1
        $null = Add-G2 $script:Office $id
        $r = Invoke-NotifyDecision $script:Sb
        $card = ($r.Bodies | ConvertFrom-Json).attachments[0].content
        @($card.body | ForEach-Object { $_.text }) | Should -Be @(
            'Huddle: a decision is waiting for you', 'grp/proj#1 · G2', 'grp/proj#1 was edited on GitLab. Change the scope?')
        $card.PSObject.Properties.Name | Should -Not -Contain 'actions'
    }

    It 'never puts the title, issue text, brief, diff or webhook URL in the body' {
        $id = Add-Item $script:Office 1
        $null = Add-G2 $script:Office $id
        $r = Invoke-NotifyDecision $script:Sb
        $r.Bodies | Should -Not -BeNullOrEmpty
        foreach ($marker in 'TITLE-MARKER', 'ISSUE-BODY-MARKER', 'hunter2', 'DIFF-MARKER', 'diff --git', 'SECRET-TOKEN-123', 'example.invalid') {
            $r.Bodies | Should -Not -Match ([regex]::Escape($marker))
        }
    }

    It 'does not send the same decision twice' {
        $id = Add-Item $script:Office 1
        $null = Add-G2 $script:Office $id
        (Invoke-NotifyDecision $script:Sb).Posts.Count | Should -Be 1
        $second = Invoke-NotifyDecision $script:Sb
        $second.Posts.Count | Should -Be 0
        @($second.Json.sent).Count | Should -Be 0
    }

    It 'records a failed post in thread.md, keeps the decision pending and exits 0' {
        $id = Add-Item $script:Office 1
        $null = Add-G2 $script:Office $id
        $r = Invoke-NotifyDecision $script:Sb -Fail
        $r.ExitCode | Should -Be 0
        $r.Json.ok | Should -BeTrue
        @($r.Json.failed).Count | Should -Be 1
        $r.Json.failed[0].error | Should -Match 'stub: webhook unavailable at <webhook>'
        Get-Thread $script:Office $id | Should -Match 'Teams notification failed \(G2, decision-1\); the decision flow continues\.'
        (Get-OfficeWorkItem -OfficeRoot $script:Office -Id $id).pendingDecision | Should -Be 1
        (Invoke-NotifyDecision $script:Sb).Posts.Count | Should -Be 0
    }

    It 'never prints or stores the webhook URL, even in error messages' {
        $id = Add-Item $script:Office 1
        $null = Add-G2 $script:Office $id
        $r = Invoke-NotifyDecision $script:Sb -Fail
        $r.Raw | Should -Not -Match 'SECRET-TOKEN-123'
        $stored = (Get-ChildItem -LiteralPath $script:Office -Recurse -File | ForEach-Object { Get-Content -Raw -LiteralPath $_.FullName }) -join "`n"
        $stored | Should -Not -Match 'SECRET-TOKEN-123'
    }

    It 'records a failure without posting when the webhook variable is not set' {
        $id = Add-Item $script:Office 1
        $null = Add-G2 $script:Office $id
        $r = Invoke-NotifyDecision $script:Sb -NoWebhook
        $r.ExitCode | Should -Be 0
        $r.Posts.Count | Should -Be 0
        $r.Json.failed[0].error | Should -Be 'Environment variable NOTIFY_STUB_WEBHOOK is not set.'
        Get-Thread $script:Office $id | Should -Match 'Teams notification failed \(G2, decision-1\)'
    }

    It 'prints ok false when -OfficeRoot does not exist instead of reporting nothing to send' {
        $missing = Join-Path $script:Sb 'no-such-office'
        $raw = (& pwsh -NoProfile -File (Join-Path $script:Sb 'scripts' 'notify-decision.ps1') -OfficeRoot $missing 2>&1) -join "`n"
        $LASTEXITCODE | Should -Be 0
        $json = $raw | ConvertFrom-Json
        $json.ok | Should -BeFalse
        $json.error | Should -BeLike 'Office folder not found:*'
    }

    It 'prints ok false instead of throwing when the office cannot be read' {
        $id = Add-Item $script:Office 1
        Set-Content -LiteralPath (Join-Path $script:Office 'work' $id 'status.json') -Value '{ broken'
        $r = Invoke-NotifyDecision $script:Sb
        $r.ExitCode | Should -Be 0
        $r.Json.ok | Should -BeFalse
        $r.Json.error | Should -Not -BeNullOrEmpty
    }
}

Describe 'notify-decision.ps1 permission surface' {
    It 'has no parameter that could take a webhook URL or card text' {
        $params = (Get-Command (Join-Path $script:RepoRoot 'scripts' 'notify-decision.ps1')).Parameters.Keys |
            Where-Object { $_ -notin [Management.Automation.PSCmdlet]::CommonParameters }
        @($params) | Should -Be @('OfficeRoot')
    }

    It 'reads the webhook only from the configured environment variable' {
        $text = Get-Content -Raw (Join-Path $script:RepoRoot 'scripts' 'notify-decision.ps1')
        $text | Should -Match '\[Environment\]::GetEnvironmentVariable\(\$envVar\)'
        $text | Should -Not -Match 'https?://(?!adaptivecards\.io/schemas)'
    }

    It 'keeps settings.json strict JSON (no trailing commas or comments)' {
        # ConvertFrom-Json accepts trailing commas; a stricter settings parser may reject the whole file,
        # which would drop the G3 hook and deny rules with it.
        $raw = Get-Content -Raw (Join-Path $script:RepoRoot '.claude' 'settings.json')
        { [Text.Json.JsonDocument]::Parse($raw).Dispose() } | Should -Not -Throw
    }

    It 'is allowed in settings.json only as the exact command with no arguments' {
        $settings = Get-Content -Raw (Join-Path $script:RepoRoot '.claude' 'settings.json') | ConvertFrom-Json
        @($settings.permissions.allow) | Should -Be @(
            'Bash(pwsh -NoProfile -File scripts/notify-decision.ps1)',
            'PowerShell(pwsh -NoProfile -File scripts/notify-decision.ps1)')
    }
}
