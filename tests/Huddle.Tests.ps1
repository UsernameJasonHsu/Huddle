# T9: /huddle-tick (inbox, issue update detection, G2 on late changes) and decision files.
# GitLab is mocked inside the Huddle module; everything else runs for real inside $TestDrive.

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    Import-Module (Join-Path $script:RepoRoot 'scripts' 'Office.psm1') -Force
    Import-Module (Join-Path $script:RepoRoot 'scripts' 'Huddle.psm1') -Force
    $script:T0 = [datetime]::new(2026, 11, 6, 9, 0, 0)
    $script:Fx = Join-Path $script:RepoRoot 'tests' 'fixtures' 'agent-outputs'
    $script:FullBrief = "# Brief`n## 摘要`n## 排序依據`n## 發現於`n## 驗收條件草稿`n## 範圍`n## 相關程式碼`n## 風險標記`n## 待釐清問題`n無`n"

    function New-Env {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $repo = Join-Path $root 'repo'
        New-Item -ItemType Directory -Path $repo -Force | Out-Null
        [pscustomobject]@{
            Office = Join-Path $root 'office'
            Wcfg   = @{ gitlabHost = 'gitlab.example' }
            Ocfg   = @{ workspaceRoot = (Join-Path $root 'ws'); projects = @(@{ match = 'a/*'; repoPath = $repo; baseBranch = $null; commands = @{} }) }
        }
    }

    # GitLab issues served by the Invoke-GitLabApi mock, keyed by 'project#iid'.
    $script:Issues = @{}
    function Set-Issue([string]$Ref, [string]$UpdatedAt, [string]$State = 'opened') {
        $p, $i = $Ref.Split('#')
        $script:Issues["projects/$([uri]::EscapeDataString($p))/issues/$i"] = @{
            title = "Issue $Ref"; web_url = "https://gitlab.example/$p/-/issues/$i"; state = $State; updated_at = $UpdatedAt
        }
    }

    function Invoke-Tick($E) { Invoke-HuddleTick -OfficeRoot $E.Office -WorkItemConfig $E.Wcfg -OfficeConfig $E.Ocfg -Now $script:T0 }

    # Plays the session's part for one queued Intake run: write a brief, save a reply, apply it.
    function Complete-Queued($E, $Prep, [string]$Fixture = 'done.md') {
        [IO.File]::WriteAllText((Join-Path $Prep.workDir 'brief.md'), $script:FullBrief, [Text.UTF8Encoding]::new($false))
        $reply = Get-Content -Raw -Encoding utf8 (Join-Path $script:Fx $Fixture)
        Complete-OfficeIntake -OfficeRoot $E.Office -Id $Prep.id -ReplyText $reply -IssueUpdatedAt $Prep.issueUpdatedAt -Now $script:T0
    }
}

Describe 'Get-OfficeUpdateAction (SPEC §3.8 table)' {
    It '<State> (resume <ResumeTo>) -> <Expected>' -ForEach @(
        @{ State = 'BRIEFED'; ResumeTo = $null; Expected = 'rebrief' }
        @{ State = 'BLOCKED'; ResumeTo = 'NEW'; Expected = 'rebrief' }
        @{ State = 'BLOCKED'; ResumeTo = 'BRIEFED'; Expected = 'rebrief' }
        @{ State = 'PLANNED'; ResumeTo = $null; Expected = 'rebrief-replan' }
        @{ State = 'BLOCKED'; ResumeTo = 'PLANNED'; Expected = 'rebrief-replan' }
        @{ State = 'BUILDING'; ResumeTo = $null; Expected = 'raise-g2' }
        @{ State = 'TESTING'; ResumeTo = $null; Expected = 'raise-g2' }
        @{ State = 'SEC_REVIEW'; ResumeTo = $null; Expected = 'raise-g2' }
        @{ State = 'REVIEW'; ResumeTo = $null; Expected = 'raise-g2' }
        @{ State = 'READY'; ResumeTo = $null; Expected = 'raise-g2' }
        @{ State = 'BLOCKED'; ResumeTo = 'BUILDING'; Expected = 'raise-g2' }
        @{ State = 'DELIVERED'; ResumeTo = $null; Expected = 'none' }
        @{ State = 'PURGED'; ResumeTo = $null; Expected = 'none' }
        @{ State = 'PARKED'; ResumeTo = 'BUILDING'; Expected = 'none' }
        @{ State = 'NEW'; ResumeTo = $null; Expected = 'none' }
    ) {
        (Get-OfficeUpdateAction -State $State -ResumeTo $ResumeTo -RecordedUpdatedAt '2026-11-01T00:00:00.000Z' `
            -CurrentUpdatedAt '2026-11-02T00:00:00.000Z').Action | Should -Be $Expected
    }

    It 'does nothing when the issue is unchanged, whatever the text format' {
        (Get-OfficeUpdateAction -State 'BUILDING' -RecordedUpdatedAt '2026-11-01T08:00:00.000Z' `
            -CurrentUpdatedAt '2026-11-01T16:00:00+08:00').Action | Should -Be 'none'
    }

    It 'treats an older current value as unchanged' {
        (Get-OfficeUpdateAction -State 'BRIEFED' -RecordedUpdatedAt '2026-11-02T00:00:00Z' -CurrentUpdatedAt '2026-11-01T00:00:00Z').Action |
            Should -Be 'none'
    }

    It 'records instead of processing when nothing was recorded yet' {
        (Get-OfficeUpdateAction -State 'BUILDING' -CurrentUpdatedAt '2026-11-02T00:00:00Z').Action | Should -Be 'record'
    }

    It 'defers a G2 while another decision is pending' {
        (Get-OfficeUpdateAction -State 'BUILDING' -RecordedUpdatedAt '2026-11-01T00:00:00Z' `
            -CurrentUpdatedAt '2026-11-02T00:00:00Z' -PendingDecision 3).Action | Should -Be 'defer'
    }
}

Describe 'Decisions' {
    BeforeEach {
        $script:E = New-Env
        $script:Id = (Register-OfficeWorkItem -OfficeRoot $script:E.Office -ProjectPath 'a/b' -Iid 1 -Title 't' -WebUrl 'u' -Now $script:T0).id
    }

    It 'creates numbered decisions, marks them pending, and records the ruling append-only' {
        $n = New-OfficeDecision -OfficeRoot $script:E.Office -Id $script:Id -Gate 'G2' -Kind 'issue-changed' `
            -Question 'Change scope?' -Options 'Keep', 'Park' -Recommendation 'Park' -Context 'ctx' -Now $script:T0
        $n | Should -Be 1
        (Get-OfficeWorkItem -OfficeRoot $script:E.Office -Id $script:Id).pendingDecision | Should -Be 1
        $md = Join-Path $script:E.Office 'work' $script:Id 'decisions' '1.md'
        $before = Get-Content -Raw -Encoding utf8 $md
        $before | Should -BeLike '*Decision 1 · G2 · a/b#1*'
        $before | Should -BeLike "*1. Keep*2. Park*"

        Resolve-OfficeDecision -OfficeRoot $script:E.Office -Id $script:Id -DecisionId 1 -Choice 2 -Note 'later' -Now $script:T0 |
            Should -Be 'Park'
        $after = Get-Content -Raw -Encoding utf8 $md
        $after.StartsWith($before) | Should -BeTrue
        $after | Should -BeLike '*## Ruling*Choice: 2. Park*Note: later*'
        (Get-OfficeWorkItem -OfficeRoot $script:E.Office -Id $script:Id).pendingDecision | Should -BeNullOrEmpty
        (Get-Content -Raw (Join-Path $script:E.Office 'work' $script:Id 'decisions' '1.json') | ConvertFrom-Json).ruling.choice | Should -Be 2

        New-OfficeDecision -OfficeRoot $script:E.Office -Id $script:Id -Gate 'G1' -Kind 'plan' -Question 'q' -Options 'a', 'b' |
            Should -Be 2
    }

    It 'refuses a second pending decision' {
        $null = New-OfficeDecision -OfficeRoot $script:E.Office -Id $script:Id -Gate 'G2' -Kind 'x' -Question 'q' -Options 'a', 'b'
        { New-OfficeDecision -OfficeRoot $script:E.Office -Id $script:Id -Gate 'G2' -Kind 'x' -Question 'q' -Options 'a', 'b' } |
            Should -Throw '*already has decision #1 pending*'
    }

    It 'rejects bad input: <Name>' -ForEach @(
        @{ Name = 'unknown gate'; Gate = 'G9'; Kind = 'x'; Options = @('a', 'b') }
        @{ Name = 'one option'; Gate = 'G2'; Kind = 'x'; Options = @('a') }
        @{ Name = 'bad kind'; Gate = 'G2'; Kind = 'Bad Kind'; Options = @('a', 'b') }
    ) {
        { New-OfficeDecision -OfficeRoot $script:E.Office -Id $script:Id -Gate $Gate -Kind $Kind -Question 'q' -Options $Options } |
            Should -Throw
    }

    It 'rejects a ruling for a decision that is not pending, or an out-of-range choice' {
        $null = New-OfficeDecision -OfficeRoot $script:E.Office -Id $script:Id -Gate 'G2' -Kind 'x' -Question 'q' -Options 'a', 'b'
        { Resolve-OfficeDecision -OfficeRoot $script:E.Office -Id $script:Id -DecisionId 2 -Choice 1 } | Should -Throw '*not the pending*'
        { Resolve-OfficeDecision -OfficeRoot $script:E.Office -Id $script:Id -DecisionId 1 -Choice 3 } | Should -Throw '*1..2*'
    }
}

Describe 'Invoke-HuddleTick' {
    BeforeEach {
        $script:E = New-Env
        $script:Issues = @{}
        $script:Assigned = @()
        Mock -ModuleName Huddle Get-SortedWorkItems { , @($script:Assigned) }
        Mock -ModuleName Huddle Invoke-GitLabApi {
            if (-not $script:Issues.ContainsKey($Endpoint)) { throw "glab api $Endpoint failed (exit 1): 404 Not Found" }
            , @($script:Issues[$Endpoint])
        }
    }

    It 'turns an inbox file into a registered work item with one queued Intake run, and removes the file' {
        Set-Issue 'a/b#5' '2026-11-05T00:00:00.000Z'
        $null = Write-OfficeInboxItem -OfficeRoot $script:E.Office -Id 9005 -Reference 'a/b#5' -Title 't' -WebUrl 'u'
        $r = Invoke-Tick $script:E
        @($r.intake).Count | Should -Be 1
        $r.intake[0].id | Should -Be 'a-b-5'
        $r.intake[0].action | Should -Be 'run-intake'
        $r.intake[0].issueUpdatedAt | Should -Be '2026-11-05T00:00:00.000Z'
        $r.intake[0].replyFile | Should -BeLike '*a-b-5*replies*intake-20261106-090000.md'
        $r.inbox[0].status | Should -Be 'queued'
        @(Get-ChildItem (Join-Path $script:E.Office 'inbox')).Count | Should -Be 0
        (Get-OfficeWorkItem -OfficeRoot $script:E.Office -Id 'a-b-5').state | Should -Be 'NEW'
    }

    It 'stops inbox items at BRIEFED: no plan.md and no worktree (Success Criteria #12)' {
        Set-Issue 'a/b#5' '2026-11-05T00:00:00.000Z'
        $null = Write-OfficeInboxItem -OfficeRoot $script:E.Office -Id 9005 -Reference 'a/b#5' -Title 't' -WebUrl 'u'
        $r = Invoke-Tick $script:E
        (Complete-Queued $script:E $r.intake[0]).State | Should -Be 'BRIEFED'
        $again = Invoke-Tick $script:E
        @($again.intake).Count | Should -Be 0
        (Get-OfficeWorkItem -OfficeRoot $script:E.Office -Id 'a-b-5').state | Should -Be 'BRIEFED'
        Test-Path (Join-Path $script:E.Office 'work' 'a-b-5' 'plan.md') | Should -BeFalse
        Test-Path (Join-Path $script:E.Ocfg.workspaceRoot 'worktrees') | Should -BeFalse
    }

    It 'runs the retention pass and reports an empty purged list when nothing is due (T17)' {
        $r = Invoke-Tick $script:E
        $r.Keys | Should -Contain 'purged'
        @($r.purged).Count | Should -Be 0
        @($r.errors).Count | Should -Be 0
    }

    It 'runs the retention pass without an error when the office has work items but nothing delivered' {
        Set-Issue 'a/b#5' '2026-11-05T00:00:00.000Z'
        $null = Register-OfficeWorkItem -OfficeRoot $script:E.Office -ProjectPath 'a/b' -Iid 5 -Title 't' -WebUrl 'u' -Now $script:T0
        $r = Invoke-Tick $script:E
        @($r.purged).Count | Should -Be 0
        @($r.errors).Count | Should -Be 0
    }

    It 'does not process the same item twice across two ticks' {
        Set-Issue 'a/b#5' '2026-11-05T00:00:00.000Z'
        Set-Issue 'a/b#6' '2026-11-05T00:00:00.000Z'
        $null = Write-OfficeInboxItem -OfficeRoot $script:E.Office -Id 9005 -Reference 'a/b#5' -Title 't' -WebUrl 'u'
        $null = Write-OfficeInboxItem -OfficeRoot $script:E.Office -Id 9006 -Reference 'a/b#6' -Title 't' -WebUrl 'u'
        $first = Invoke-Tick $script:E
        @($first.intake.id) | Should -Be @('a-b-5', 'a-b-6')
        foreach ($p in $first.intake) { $null = Complete-Queued $script:E $p }
        $second = Invoke-Tick $script:E
        @($second.intake).Count | Should -Be 0
        @($second.updates | Where-Object action -NE 'none').Count | Should -Be 0
        @($second.inbox).Count | Should -Be 0
    }

    It 'prepares an inbox item only once per tick (one assign entry, one issue read)' {
        Set-Issue 'a/b#5' '2026-11-05T00:00:00.000Z'
        $null = Write-OfficeInboxItem -OfficeRoot $script:E.Office -Id 9005 -Reference 'a/b#5' -Title 't' -WebUrl 'u'
        $null = Invoke-Tick $script:E
        $thread = Get-Content -Raw -Encoding utf8 (Join-Path $script:E.Office 'work' 'a-b-5' 'thread.md')
        ([regex]::Matches($thread, 'office-manager → intake · assign')).Count | Should -Be 1
        Should -Invoke -ModuleName Huddle Invoke-GitLabApi -Times 1 -Exactly
    }

    It 'queues a NEW item again on the next tick if its Intake never finished' {
        Set-Issue 'a/b#5' '2026-11-05T00:00:00.000Z'
        $null = Write-OfficeInboxItem -OfficeRoot $script:E.Office -Id 9005 -Reference 'a/b#5' -Title 't' -WebUrl 'u'
        $null = Invoke-Tick $script:E
        @((Invoke-Tick $script:E).intake.id) | Should -Be @('a-b-5')
    }

    It 'keeps an inbox file when GitLab cannot be read, and drops it for a closed issue' {
        $null = Write-OfficeInboxItem -OfficeRoot $script:E.Office -Id 9007 -Reference 'a/b#7' -Title 't' -WebUrl 'u'
        Set-Issue 'a/b#8' '2026-11-05T00:00:00.000Z' -State 'closed'
        $null = Write-OfficeInboxItem -OfficeRoot $script:E.Office -Id 9008 -Reference 'a/b#8' -Title 't' -WebUrl 'u'
        $r = Invoke-Tick $script:E
        ($r.inbox | Where-Object file -EQ '9007.json').status | Should -Be 'kept'
        ($r.inbox | Where-Object file -EQ '9008.json').status | Should -Be 'dropped'
        (Get-ChildItem (Join-Path $script:E.Office 'inbox')).Name | Should -Be @('9007.json')
        @($r.errors).Count | Should -Be 1
        @($r.intake).Count | Should -Be 0
    }

    Context 'issue edited while BRIEFED (Success Criteria #14)' {
        It 're-briefs, stays BRIEFED, and records the new updated_at so the next tick is quiet' {
            Set-Issue 'a/b#5' '2026-11-05T00:00:00.000Z'
            $null = Write-OfficeInboxItem -OfficeRoot $script:E.Office -Id 9005 -Reference 'a/b#5' -Title 't' -WebUrl 'u'
            $null = Complete-Queued $script:E (Invoke-Tick $script:E).intake[0]

            Set-Issue 'a/b#5' '2026-11-06T01:00:00.000Z'
            $r = Invoke-Tick $script:E
            $r.updates[0].action | Should -Be 'rebrief'
            $r.intake[0].mode | Should -Be 'rebrief'
            $r.intake[0].issueUpdatedAt | Should -Be '2026-11-06T01:00:00.000Z'

            (Complete-Queued $script:E $r.intake[0]).State | Should -Be 'BRIEFED'
            (Get-OfficeWorkItem -OfficeRoot $script:E.Office -Id 'a-b-5').issueUpdatedAt | Should -Be '2026-11-06T01:00:00.000Z'
            @((Invoke-Tick $script:E).intake).Count | Should -Be 0
        }

        It 'retries the re-brief when the Intake reply was unparseable' {
            Set-Issue 'a/b#5' '2026-11-05T00:00:00.000Z'
            $null = Write-OfficeInboxItem -OfficeRoot $script:E.Office -Id 9005 -Reference 'a/b#5' -Title 't' -WebUrl 'u'
            $null = Complete-Queued $script:E (Invoke-Tick $script:E).intake[0]
            Set-Issue 'a/b#5' '2026-11-06T01:00:00.000Z'
            $null = Complete-Queued $script:E (Invoke-Tick $script:E).intake[0] 'malformed-no-block.md'
            # BLOCKED now, recorded value unchanged -> the change is still pending.
            (Invoke-Tick $script:E).intake[0].mode | Should -Be 'rebrief'
        }
    }

    It 're-briefs a PLANNED item and flags the plan for review' {
        Set-Issue 'a/b#5' '2026-11-05T00:00:00.000Z'
        $null = Write-OfficeInboxItem -OfficeRoot $script:E.Office -Id 9005 -Reference 'a/b#5' -Title 't' -WebUrl 'u'
        $null = Complete-Queued $script:E (Invoke-Tick $script:E).intake[0]
        $null = Set-OfficeWorkItemState -OfficeRoot $script:E.Office -Id 'a-b-5' -State 'PLANNED' -Now $script:T0
        Set-Issue 'a/b#5' '2026-11-06T01:00:00.000Z'
        $r = Invoke-Tick $script:E
        $r.updates[0].action | Should -Be 'rebrief-replan'
        (Complete-Queued $script:E $r.intake[0]).State | Should -Be 'PLANNED'
        (Get-OfficeWorkItem -OfficeRoot $script:E.Office -Id 'a-b-5').planNeedsReview | Should -BeTrue
    }

    Context 'issue edited while BUILDING (Success Criteria #14)' {
        BeforeEach {
            Set-Issue 'a/b#5' '2026-11-05T00:00:00.000Z'
            $null = Register-OfficeWorkItem -OfficeRoot $script:E.Office -ProjectPath 'a/b' -Iid 5 -Title 't' -WebUrl 'u' `
                -IssueUpdatedAt '2026-11-05T00:00:00.000Z' -Now $script:T0
            foreach ($s in 'BRIEFED', 'PLANNED') { $null = Set-OfficeWorkItemState -OfficeRoot $script:E.Office -Id 'a-b-5' -State $s -Now $script:T0 }
            $null = Set-OfficeWorkItemState -OfficeRoot $script:E.Office -Id 'a-b-5' -State 'BUILDING' -DecisionId 1 -Now $script:T0
        }

        It 'raises one G2 decision, does not re-brief, and stays BUILDING' {
            Set-Issue 'a/b#5' '2026-11-06T01:00:00.000Z'
            $r = Invoke-Tick $script:E
            $r.updates[0].action | Should -Be 'raise-g2'
            $r.updates[0].decision | Should -Be 1
            @($r.intake).Count | Should -Be 0
            $s = Get-OfficeWorkItem -OfficeRoot $script:E.Office -Id 'a-b-5'
            $s.state | Should -Be 'BUILDING'
            $s.pendingDecision | Should -Be 1
            $d = Get-Content -Raw (Join-Path $script:E.Office 'work' 'a-b-5' 'decisions' '1.json') | ConvertFrom-Json
            $d.gate | Should -Be 'G2'
            $d.kind | Should -Be 'issue-changed'
            # Second tick: same updated_at, nothing new.
            $again = Invoke-Tick $script:E
            $again.updates[0].action | Should -Be 'none'
            @(Get-ChildItem (Join-Path $script:E.Office 'work' 'a-b-5' 'decisions') -Filter '*.json').Count | Should -Be 1
        }

        It 'defers a second change while the first G2 is still pending' {
            Set-Issue 'a/b#5' '2026-11-06T01:00:00.000Z'
            $null = Invoke-Tick $script:E
            Set-Issue 'a/b#5' '2026-11-06T02:00:00.000Z'
            (Invoke-Tick $script:E).updates[0].action | Should -Be 'defer'
            $null = Resolve-OfficeDecision -OfficeRoot $script:E.Office -Id 'a-b-5' -DecisionId 1 -Choice 1
            $r = Invoke-Tick $script:E
            $r.updates[0].action | Should -Be 'raise-g2'
            $r.updates[0].decision | Should -Be 2
        }
    }

    It "ignores updated_at changes that Huddle recorded itself (its own comments)" {
        Set-Issue 'a/b#5' '2026-11-05T00:00:00.000Z'
        $null = Write-OfficeInboxItem -OfficeRoot $script:E.Office -Id 9005 -Reference 'a/b#5' -Title 't' -WebUrl 'u'
        $null = Complete-Queued $script:E (Invoke-Tick $script:E).intake[0]
        # What post-issue-note.ps1 will do after posting (T16): record the updated_at its comment caused.
        Set-Issue 'a/b#5' '2026-11-06T03:00:00.000Z'
        $null = Set-OfficeIssueUpdatedAt -OfficeRoot $script:E.Office -Id 'a-b-5' -IssueUpdatedAt '2026-11-06T03:00:00.000Z'
        $r = Invoke-Tick $script:E
        $r.updates[0].action | Should -Be 'none'
        @($r.intake).Count | Should -Be 0
    }

    It 'leaves PARKED items alone, including their recorded updated_at' {
        Set-Issue 'a/b#5' '2026-11-05T00:00:00.000Z'
        $null = Write-OfficeInboxItem -OfficeRoot $script:E.Office -Id 9005 -Reference 'a/b#5' -Title 't' -WebUrl 'u'
        $null = Complete-Queued $script:E (Invoke-Tick $script:E).intake[0]
        $null = Set-OfficeWorkItemState -OfficeRoot $script:E.Office -Id 'a-b-5' -State 'PARKED' -Now $script:T0
        Set-Issue 'a/b#5' '2026-11-06T01:00:00.000Z'
        $r = Invoke-Tick $script:E
        @($r.updates).Count | Should -Be 0
        (Get-OfficeWorkItem -OfficeRoot $script:E.Office -Id 'a-b-5').issueUpdatedAt | Should -Be '2026-11-05T00:00:00.000Z'
        $null = Set-OfficeWorkItemState -OfficeRoot $script:E.Office -Id 'a-b-5' -State 'BRIEFED' -Now $script:T0
        (Invoke-Tick $script:E).updates[0].action | Should -Be 'rebrief'
    }

    It 'records updated_at for items registered before it was tracked, without processing' {
        Set-Issue 'a/b#5' '2026-11-05T00:00:00.000Z'
        $null = Register-OfficeWorkItem -OfficeRoot $script:E.Office -ProjectPath 'a/b' -Iid 5 -Title 't' -WebUrl 'u' -Now $script:T0
        $null = Set-OfficeWorkItemState -OfficeRoot $script:E.Office -Id 'a-b-5' -State 'BRIEFED' -Now $script:T0
        $r = Invoke-Tick $script:E
        $r.updates[0].action | Should -Be 'record'
        @($r.intake).Count | Should -Be 0
        (Get-OfficeWorkItem -OfficeRoot $script:E.Office -Id 'a-b-5').issueUpdatedAt | Should -Be '2026-11-05T00:00:00.000Z'
    }

    It 'only reads from GitLab' {
        Set-Issue 'a/b#5' '2026-11-05T00:00:00.000Z'
        $null = Write-OfficeInboxItem -OfficeRoot $script:E.Office -Id 9005 -Reference 'a/b#5' -Title 't' -WebUrl 'u'
        $null = Invoke-Tick $script:E
        Should -Invoke -ModuleName Huddle Invoke-GitLabApi -ParameterFilter { $Endpoint -notmatch '^projects/[^/]+/issues/\d+$' } -Times 0 -Exactly
    }
}

Describe 'Delivered MRs (T20, SPEC §3.11)' {
    BeforeAll {
        # A work item that went through the loop and was delivered with MR !9 (or with no MR recorded).
        function New-Delivered($E, [int]$Iid = 5, [switch]$NoMr) {
            $id = (Register-OfficeWorkItem -OfficeRoot $E.Office -ProjectPath 'a/b' -Iid $Iid -Title 't' -WebUrl 'u' -Now $script:T0).id
            foreach ($s in 'BRIEFED', 'PLANNED') { $null = Set-OfficeWorkItemState -OfficeRoot $E.Office -Id $id -State $s -Now $script:T0 }
            $null = Set-OfficeWorkItemState -OfficeRoot $E.Office -Id $id -State 'BUILDING' -DecisionId 1 -Now $script:T0
            foreach ($s in 'TESTING', 'SEC_REVIEW', 'REVIEW', 'READY', 'DELIVERED') { $null = Set-OfficeWorkItemState -OfficeRoot $E.Office -Id $id -State $s -Now $script:T0 }
            if (-not $NoMr) {
                $status = Get-OfficeWorkItem -OfficeRoot $E.Office -Id $id
                $status.mr = [ordered]@{ iid = 9; url = 'https://gitlab.example/a/b/-/merge_requests/9'; sha = 'abc'; at = '2026-11-05T10:00:00+08:00' }
                [IO.File]::WriteAllText((Join-Path $E.Office 'work' $id 'status.json'), ($status | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
            }
            $id
        }
        function Set-Mr([string]$State, [string]$Pipeline, [string]$MergedAt) {
            $script:Issues['projects/a%2Fb/merge_requests/9'] = @{
                iid = 9; state = $State; merged_at = $(if ($MergedAt) { $MergedAt } else { $null })
                head_pipeline = $(if ($Pipeline) { @{ id = 1; status = $Pipeline } } else { $null })
            }
        }
        function Get-Mr($E, [string]$Id) { (Get-OfficeWorkItem -OfficeRoot $E.Office -Id $Id).mr }
        function Get-Thread($E, [string]$Id) {
            $p = Join-Path $E.Office 'work' $Id 'thread.md'
            if (Test-Path $p) { Get-Content -Raw -Encoding utf8 $p } else { '' }
        }
        function Get-Brief($E) { (Format-OfficeBrief -Summary (Get-OfficeSummary -OfficeRoot $E.Office)) }
    }

    BeforeEach {
        $script:E = New-Env
        $script:Issues = @{}
        Mock -ModuleName Huddle Get-SortedWorkItems { , @() }
        Mock -ModuleName Huddle Invoke-GitLabApi {
            if (-not $script:Issues.ContainsKey($Endpoint)) { throw "glab api $Endpoint failed (exit 1): 404 Not Found" }
            , @($script:Issues[$Endpoint])
        }
    }

    It 'records a merge, notes it in thread.md, reports it, and shows it in the brief' {
        $id = New-Delivered $script:E
        Set-Mr 'merged' 'success' '2026-11-06T04:00:00.000Z'
        $r = Invoke-Tick $script:E
        @($r.errors).Count | Should -Be 0
        @($r.delivered).Count | Should -Be 1
        $r.delivered[0].reference | Should -Be 'a/b#5'
        $r.delivered[0].mr | Should -Be 9
        $r.delivered[0].from | Should -Be 'opened'
        $r.delivered[0].to | Should -Be 'merged'

        $mr = Get-Mr $script:E $id
        $mr.state | Should -Be 'merged'
        $mr.mergedAt | Should -Be '2026-11-06T04:00:00.000Z'
        $mr.checkedAt | Should -Not -BeNullOrEmpty
        $mr.url | Should -Be 'https://gitlab.example/a/b/-/merge_requests/9'
        (Get-OfficeWorkItem -OfficeRoot $script:E.Office -Id $id).state | Should -Be 'DELIVERED'
        Get-Thread $script:E $id | Should -Match 'MR !9 opened -> merged\.'
        ((Get-Brief $script:E).Context -join "`n") | Should -Match '\| DELIVERED \| - \| !9 merged 2026-11-0\d \|'
    }

    It 'stops reading an MR once it is merged' {
        $null = New-Delivered $script:E
        Set-Mr 'merged' 'success' '2026-11-06T04:00:00.000Z'
        $null = Invoke-Tick $script:E
        $again = Invoke-Tick $script:E
        @($again.delivered).Count | Should -Be 0
        Should -Invoke -ModuleName Huddle Invoke-GitLabApi -ParameterFilter { $Endpoint -match 'merge_requests' } -Times 1 -Exactly
    }

    It 'treats a first read of an open MR with a passing pipeline as no change' {
        $id = New-Delivered $script:E
        Set-Mr 'opened' 'success'
        $r = Invoke-Tick $script:E
        @($r.delivered).Count | Should -Be 0
        (Get-Mr $script:E $id).state | Should -Be 'opened'
        (Get-Mr $script:E $id).pipeline | Should -Be 'success'
        Get-Thread $script:E $id | Should -Not -Match 'MR !9'
        $brief = Get-Brief $script:E
        ($brief.Context -join "`n") | Should -Match '!9 opened, pipeline success \(checked \d\d-\d\d \d\d:\d\d\)'
        ($brief.Context -join "`n") | Should -Not -Match 'Warning for'
    }

    It 'reports a pipeline that turns red and warns in the brief' {
        $id = New-Delivered $script:E
        Set-Mr 'opened' 'success'
        $null = Invoke-Tick $script:E
        Set-Mr 'opened' 'failed'
        $r = Invoke-Tick $script:E
        @($r.delivered).Count | Should -Be 1
        $r.delivered[0].pipeline | Should -Be 'failed'
        Get-Thread $script:E $id | Should -Match 'MR !9 pipeline success -> failed\.'
        $brief = Get-Brief $script:E
        ($brief.Context -join "`n") | Should -Match 'Warning for a/b#5: MR !9 pipeline failed\.'
        ($brief.Display -join "`n") | Should -Match 'warning: MR !9 pipeline failed\.'
    }

    It 'warns when the MR was closed without a merge, and stops reading it' {
        $null = New-Delivered $script:E
        Set-Mr 'closed' 'success'
        $r = Invoke-Tick $script:E
        $r.delivered[0].to | Should -Be 'closed'
        ((Get-Brief $script:E).Context -join "`n") | Should -Match 'Warning for a/b#5: MR !9 was closed without being merged\.'
        $null = Invoke-Tick $script:E
        Should -Invoke -ModuleName Huddle Invoke-GitLabApi -ParameterFilter { $Endpoint -match 'merge_requests' } -Times 1 -Exactly
    }

    It 'leaves status.json alone when GitLab cannot be read, and still returns ok' {
        $id = New-Delivered $script:E
        $before = Get-Content -Raw (Join-Path $script:E.Office 'work' $id 'status.json')
        $r = Invoke-Tick $script:E
        $r.ok | Should -BeTrue
        @($r.delivered).Count | Should -Be 0
        @($r.errors).Count | Should -Be 1
        $r.errors[0] | Should -Match 'a/b#5 MR !9: .*404'
        Get-Content -Raw (Join-Path $script:E.Office 'work' $id 'status.json') | Should -Be $before
        ((Get-Brief $script:E).Context -join "`n") | Should -Match '!9 \(not checked yet\)'
    }

    It 'skips a DELIVERED work item that has no recorded MR' {
        $null = New-Delivered $script:E -NoMr
        $r = Invoke-Tick $script:E
        @($r.errors).Count | Should -Be 0
        @($r.delivered).Count | Should -Be 0
        Should -Invoke -ModuleName Huddle Invoke-GitLabApi -Times 0 -Exactly
        ((Get-Brief $script:E).Context -join "`n") | Should -Match '\| DELIVERED \| - \| - \|'
    }

    It 'only reads from GitLab' {
        $null = New-Delivered $script:E
        Set-Mr 'opened' 'running'
        $null = Invoke-Tick $script:E
        Should -Invoke -ModuleName Huddle Invoke-GitLabApi -ParameterFilter { $Endpoint -notmatch '^projects/[^/]+/merge_requests/\d+$' } -Times 0 -Exactly
    }

    It 'refuses to record MR status for a work item that is not DELIVERED' {
        $id = (Register-OfficeWorkItem -OfficeRoot $script:E.Office -ProjectPath 'a/b' -Iid 6 -Title 't' -WebUrl 'u').id
        { Set-OfficeMrStatus -OfficeRoot $script:E.Office -Id $id -State 'merged' } | Should -Throw '*DELIVERED*'
    }
}

Describe 'Waiting for an MR (T21, SPEC §3.11)' {
    BeforeAll {
        function Set-Mr([string]$Ref, [string]$State) {
            $p, $i = $Ref.Split('!')
            $script:Issues["projects/$([uri]::EscapeDataString($p))/merge_requests/$i"] = @{ iid = [int]$i; state = $State; merged_at = $null; head_pipeline = $null }
        }
        function Wait-For($E, [string]$Ref, [string]$Mr, [switch]$Clear, [string]$Note) {
            Invoke-HuddleWaitFor -Ref $Ref -Mr $Mr -Note $Note -Clear:$Clear -OfficeRoot $E.Office -WorkItemConfig $E.Wcfg -Now $script:T0
        }
        function Take($E, [string]$Ref) {
            Invoke-HuddleTakePrep -Ref $Ref -OfficeRoot $E.Office -WorkItemConfig $E.Wcfg -OfficeConfig $E.Ocfg -Mode take -Now $script:T0
        }
        function Get-Thread($E, [string]$Id) { Get-Content -Raw -Encoding utf8 (Join-Path $E.Office 'work' $Id 'thread.md') }
        function Get-BriefText($E) { (Format-OfficeBrief -Summary (Get-OfficeSummary -OfficeRoot $E.Office)).Context -join "`n" }
    }

    BeforeEach {
        $script:E = New-Env
        $script:Issues = @{}
        Mock -ModuleName Huddle Get-SortedWorkItems { , @() }
        Mock -ModuleName Huddle Invoke-GitLabApi {
            if (-not $script:Issues.ContainsKey($Endpoint)) { throw "glab api $Endpoint failed (exit 1): 404 Not Found" }
            , @($script:Issues[$Endpoint])
        }
        Set-Issue 'a/b#5' '2026-11-05T00:00:00.000Z'
        Set-Mr 'a/b!9' 'opened'
    }

    It 'registers the work item as NEW, records the wait, and shows it in the brief' {
        $r = Wait-For $script:E 'a/b#5' 'a/b!9' -Note 'changes the same file'
        $r.ok | Should -BeTrue
        $r.action | Should -Be 'waiting'
        $r.registered | Should -BeTrue
        $s = Get-OfficeWorkItem -OfficeRoot $script:E.Office -Id 'a-b-5'
        $s.state | Should -Be 'NEW'
        @($s.waitsFor).Count | Should -Be 1
        $s.waitsFor[0].kind | Should -Be 'mr-merged'
        $s.waitsFor[0].project | Should -Be 'a/b'
        $s.waitsFor[0].iid | Should -Be 9
        $s.waitsFor[0].note | Should -Be 'changes the same file'
        $s.waitsFor[0].metAt | Should -BeNullOrEmpty
        Get-BriefText $script:E | Should -Match ([regex]::Escape('| NEW (waits for a/b!9) | - | - |'))
        Get-Thread $script:E 'a-b-5' | Should -Match 'Waits for a/b!9 to be merged\. changes the same file'
    }

    It 'reads "!9" as an MR in the work item''s own project, and does not record the same wait twice' {
        (Wait-For $script:E 'a/b#5' '!9').action | Should -Be 'waiting'
        (Wait-For $script:E 'a/b#5' 'https://gitlab.example/a/b/-/merge_requests/9').action | Should -Be 'already-waiting'
        @((Get-OfficeWorkItem -OfficeRoot $script:E.Office -Id 'a-b-5').waitsFor).Count | Should -Be 1
    }

    It 'does not brief the work item on a tick while the MR is open, not even from the inbox' {
        $null = Wait-For $script:E 'a/b#5' 'a/b!9'
        $null = Write-OfficeInboxItem -OfficeRoot $script:E.Office -Id 9005 -Reference 'a/b#5' -Title 't' -WebUrl 'u'
        $r = Invoke-Tick $script:E
        @($r.intake).Count | Should -Be 0
        @($r.unblocked).Count | Should -Be 0
        @($r.errors).Count | Should -Be 0
        $r.inbox[0].status | Should -Be 'done'
        (Get-OfficeWorkItem -OfficeRoot $script:E.Office -Id 'a-b-5').state | Should -Be 'NEW'
        Get-Thread $script:E 'a-b-5' | Should -Not -Match 'assign'
    }

    It 'refuses /huddle-take while the MR is open and says how to start anyway' {
        $null = Wait-For $script:E 'a/b#5' 'a/b!9'
        $r = Take $script:E 'a/b#5'
        $r.ok | Should -BeTrue
        $r.action | Should -Be 'waiting'
        $r.message | Should -Match 'a/b#5 waits for a/b!9 to be merged\. Nothing was started\.'
        $r.message | Should -Match 'wait-for\.ps1 -Ref a/b#5 -Clear'
        (Get-OfficeWorkItem -OfficeRoot $script:E.Office -Id 'a-b-5').state | Should -Be 'NEW'
        Get-Thread $script:E 'a-b-5' | Should -Not -Match 'assign'
    }

    It 'reports the merge on the next tick, briefs the work item in the same pass, and shows it as ready' {
        $null = Wait-For $script:E 'a/b#5' 'a/b!9'
        Set-Mr 'a/b!9' 'merged'
        $r = Invoke-Tick $script:E
        @($r.unblocked).Count | Should -Be 1
        $r.unblocked[0].reference | Should -Be 'a/b#5'
        $r.unblocked[0].mr | Should -Be 'a/b!9'
        $r.unblocked[0].ready | Should -BeTrue
        @($r.intake.id) | Should -Be @('a-b-5')
        (Get-OfficeWorkItem -OfficeRoot $script:E.Office -Id 'a-b-5').waitsFor[0].metAt | Should -Not -BeNullOrEmpty
        Get-Thread $script:E 'a-b-5' | Should -Match 'a/b!9 was merged; the work item no longer waits for it\.'
        $brief = Get-BriefText $script:E
        $brief | Should -Match 'a/b!9 merged: a/b#5 no longer waits and is ready for /huddle-take\.'
        $brief | Should -Not -Match 'waits for a/b!9\)'
        # A met wait is not read or reported again.
        $again = Invoke-Tick $script:E
        @($again.unblocked).Count | Should -Be 0
        Should -Invoke -ModuleName Huddle Invoke-GitLabApi -ParameterFilter { $Endpoint -match 'merge_requests' } -Times 2 -Exactly
    }

    It 'starts the work item after the wait is cleared' {
        $null = Wait-For $script:E 'a/b#5' 'a/b!9'
        $c = Wait-For $script:E 'a/b#5' -Clear
        $c.action | Should -Be 'cleared'
        $c.cleared | Should -Be 1
        (Take $script:E 'a/b#5').action | Should -Be 'run-intake'
        Get-BriefText $script:E | Should -Not -Match 'waits for'
        (Wait-For $script:E 'a/b#5' -Clear).cleared | Should -Be 0
    }

    It 'reads an MR once per tick when two work items wait for it' {
        Set-Issue 'a/b#6' '2026-11-05T00:00:00.000Z'
        $null = Wait-For $script:E 'a/b#5' 'a/b!9'
        $null = Wait-For $script:E 'a/b#6' 'a/b!9'
        Set-Mr 'a/b!9' 'merged'
        $r = Invoke-Tick $script:E
        @($r.unblocked.reference) | Should -Be @('a/b#5', 'a/b#6')
        # Two reads when the waits were recorded, one for the tick.
        Should -Invoke -ModuleName Huddle Invoke-GitLabApi -ParameterFilter { $Endpoint -match 'merge_requests' } -Times 3 -Exactly
    }

    It 'keeps waiting and warns when the MR is closed without a merge' {
        $null = Wait-For $script:E 'a/b#5' 'a/b!9'
        Set-Mr 'a/b!9' 'closed'
        $r = Invoke-Tick $script:E
        @($r.unblocked).Count | Should -Be 0
        @($r.intake).Count | Should -Be 0
        $brief = Get-BriefText $script:E
        $brief | Should -Match 'Warning for a/b#5: It waits for a/b!9, which was closed without being merged\.'
        $brief | Should -Match 'waits for a/b!9\)'
    }

    It 'leaves the wait alone when the MR cannot be read' {
        $null = Wait-For $script:E 'a/b#5' 'a/b!9'
        $script:Issues.Remove('projects/a%2Fb/merge_requests/9')
        $before = Get-Content -Raw (Join-Path $script:E.Office 'work' 'a-b-5' 'status.json')
        $r = Invoke-Tick $script:E
        $r.ok | Should -BeTrue
        @($r.errors).Count | Should -Be 1
        $r.errors[0] | Should -Match 'a/b#5 waits for a/b!9: .*404'
        Get-Content -Raw (Join-Path $script:E.Office 'work' 'a-b-5' 'status.json') | Should -Be $before
    }

    It 'does not record a wait for an MR that is already merged, closed, or missing' {
        Set-Mr 'a/b!9' 'merged'
        $r = Wait-For $script:E 'a/b#5' 'a/b!9'
        $r.action | Should -Be 'already-merged'
        Test-Path (Join-Path $script:E.Office 'work' 'a-b-5') | Should -BeFalse
        Set-Mr 'a/b!9' 'closed'
        (Wait-For $script:E 'a/b#5' 'a/b!9').error | Should -Match 'closed without being merged'
        (Wait-For $script:E 'a/b#5' 'a/b!404').ok | Should -BeFalse
        (Wait-For $script:E 'a/b#5' 'not-a-ref').error | Should -Match 'Cannot read merge request reference'
        Test-Path (Join-Path $script:E.Office 'work' 'a-b-5') | Should -BeFalse
    }

    It 'refuses a wait for a work item that is already being built' {
        $null = Register-OfficeWorkItem -OfficeRoot $script:E.Office -ProjectPath 'a/b' -Iid 5 -Title 't' -WebUrl 'u'
        foreach ($s in 'BRIEFED', 'PLANNED') { $null = Set-OfficeWorkItemState -OfficeRoot $script:E.Office -Id 'a-b-5' -State $s }
        $null = Set-OfficeWorkItemState -OfficeRoot $script:E.Office -Id 'a-b-5' -State 'BUILDING' -DecisionId 1
        $r = Wait-For $script:E 'a/b#5' 'a/b!9'
        $r.ok | Should -BeFalse
        $r.error | Should -Match 'only before it is built'
    }

    It 'only reads from GitLab' {
        $null = Wait-For $script:E 'a/b#5' 'a/b!9'
        $null = Invoke-Tick $script:E
        Should -Invoke -ModuleName Huddle Invoke-GitLabApi -ParameterFilter { $Endpoint -notmatch '^projects/[^/]+/(issues|merge_requests)/\d+$' } -Times 0 -Exactly
    }
}

Describe 'Complete-OfficeIntake refuses states Intake does not own' {
    It 'throws for a BUILDING item' {
        $e = New-Env
        $null = Register-OfficeWorkItem -OfficeRoot $e.Office -ProjectPath 'a/b' -Iid 5 -Title 't' -WebUrl 'u'
        foreach ($s in 'BRIEFED', 'PLANNED') { $null = Set-OfficeWorkItemState -OfficeRoot $e.Office -Id 'a-b-5' -State $s }
        $null = Set-OfficeWorkItemState -OfficeRoot $e.Office -Id 'a-b-5' -State 'BUILDING' -DecisionId 1
        { Complete-OfficeIntake -OfficeRoot $e.Office -Id 'a-b-5' -ReplyText 'x' } | Should -Throw '*cannot be applied*'
    }
}
