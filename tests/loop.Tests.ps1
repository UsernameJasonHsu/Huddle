# T13: build loop BUILDING -> TESTING -> SEC_REVIEW -> REVIEW. Uses throwaway local git repositories
# (an origin and my own clone at repoPath) and an office folder in $TestDrive; no GitLab.

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    Import-Module (Join-Path $script:RepoRoot 'scripts' 'Office.psm1') -Force
    foreach ($v in 'GIT_AUTHOR_NAME', 'GIT_COMMITTER_NAME') { Set-Item "Env:$v" 'Huddle Test' }
    foreach ($v in 'GIT_AUTHOR_EMAIL', 'GIT_COMMITTER_EMAIL') { Set-Item "Env:$v" 'huddle-test@example.invalid' }
    $script:T0 = [datetime]::new(2026, 11, 9, 10, 0, 0)
    $script:Utf8 = [Text.UTF8Encoding]::new($false)
    $script:Id = 'grp-proj-7'

    function G([string]$Repo) {
        $out = & git -C $Repo @args 2>&1
        if ($LASTEXITCODE -ne 0) { throw "test git $($args -join ' ') failed: $($out -join "`n")" }
        @($out | ForEach-Object { "$_" })
    }

    function Reply([string]$Outcome, [string]$Report, [string]$ObjectionTo) {
        $r = "Work finished.`n`n"
        if ($null -ne $Report) { $r += "<!-- huddle:draft:begin -->`n$Report`n<!-- huddle:draft:end -->`n`n" }
        $r += "``````yaml`noutcome: $Outcome`nsummary: ""$Outcome reply""`nnext: []`n"
        if ($ObjectionTo) { $r += "objection_to: $ObjectionTo`n" }
        $r + "```````n"
    }

    $script:TestReport = "# Test report`n`n## 結果`n通過 3`n`n## 執行的指令`n- pester`n`n## 失敗項目`n無`n`n## 覆蓋率與缺口`n都有`n"
    function SecReport([string]$Findings) { "# Security report`n`n## 範圍`nabc..def`n`n## Findings`n`n$Findings`n" }
    function Finding([string]$FId, [string]$Severity) {
        "### $FId：未檢查輸入`n- 嚴重度：$Severity`n- 位置：``src/a.ps1:3```n- 情境：呼叫端可傳入負數`n- 建議修法：加範圍檢查`n"
    }

    # origin -> my clone at repoPath (on its own branch, with uncommitted work); config registers grp/proj
    # with baseBranch main; the work item is approved at G1 and sits in BUILDING.
    function New-Fixture {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N').Substring(0, 8))
        $origin = Join-Path $root 'origin'
        $repo = Join-Path $root 'mine'
        New-Item -ItemType Directory -Path $origin -Force | Out-Null
        $null = G $origin init -q -b main
        Set-Content -LiteralPath (Join-Path $origin 'app.txt') -Value 'v1'
        $null = G $origin add app.txt
        $null = G $origin commit -q -m init
        $null = & git clone -q $origin $repo 2>&1
        $null = G $repo checkout -q -b my-work
        Set-Content -LiteralPath (Join-Path $repo 'app.txt') -Value 'my uncommitted edit'

        $config = @{
            workspaceRoot = (Join-Path $root 'ws'); unknownProject = 'auto-clone'
            maxAutoRounds = 3; maxActiveBuilds = 1; retentionDays = 30
            projects = @(@{ match = 'grp/proj'; repoPath = $repo; baseBranch = 'main'; commands = @{ build = $null; test = 'pwsh -c test' } })
        }
        $configPath = Join-Path $root 'office.json'
        [IO.File]::WriteAllText($configPath, ($config | ConvertTo-Json -Depth 6), $script:Utf8)
        $office = Join-Path $root 'office'
        $null = Register-OfficeWorkItem -OfficeRoot $office -ProjectPath 'grp/proj' -Iid 7 -Title 'Fix average' -WebUrl 'https://example.invalid/grp/proj/-/issues/7' -Now $script:T0
        foreach ($st in 'BRIEFED', 'PLANNED') { $null = Set-OfficeWorkItemState -OfficeRoot $office -Id $script:Id -State $st -Now $script:T0 }
        $null = Set-OfficeWorkItemState -OfficeRoot $office -Id $script:Id -State 'BUILDING' -DecisionId 1 -Now $script:T0
        [pscustomobject]@{ Root = $root; Origin = $origin; Repo = $repo; Office = $office; ConfigPath = $configPath; Config = (Get-OfficeConfig -Path $configPath) }
    }

    function Step($F, [switch]$Resume) { Get-OfficeLoopInput -OfficeRoot $F.Office -Id $script:Id -Config $F.Config -Resume:$Resume -Now $script:T0 }
    function Commit-In([string]$Worktree, [string]$Name = 'fix.txt', [string]$Text = 'fixed') {
        Set-Content -LiteralPath (Join-Path $Worktree $Name) -Value $Text
        $null = G $Worktree add $Name
        $null = G $Worktree commit -q -m "change $Name"
    }
    function Item($F) { Get-OfficeWorkItem -OfficeRoot $F.Office -Id $script:Id }
    function Thread($F) { Get-Content -Raw -Encoding utf8 -LiteralPath (Join-Path $F.Office 'work' $script:Id 'thread.md') }

    # BUILDING -> (Builder commits) -> TESTING; returns the worktree path.
    function To-Testing($F) {
        $in = Step $F
        Commit-In $in.worktree.path
        $r = Complete-OfficeImplement -OfficeRoot $F.Office -Id $script:Id -ReplyText (Reply 'done') -Config $F.Config -Now $script:T0
        if ($r.State -cne 'TESTING') { throw "setup: expected TESTING, got $($r.State): $($r.Reason)" }
        $in.worktree.path
    }
    function To-SecReview($F) {
        $wt = To-Testing $F
        $null = Step $F
        $r = Complete-OfficeLoopReview -OfficeRoot $F.Office -Id $script:Id -Agent tester -ReplyText (Reply 'done' $script:TestReport) -Now $script:T0
        if ($r.State -cne 'SEC_REVIEW') { throw "setup: expected SEC_REVIEW, got $($r.State): $($r.Reason)" }
        $wt
    }

    function RevReport([string]$Items) { "# Review report`n`n## 範圍`nabc..def`n`n## 審查意見`n`n$Items`n" }
    function RevItem([string]$RId, [string]$Verdict, [string]$Axis = '正確性') {
        "### $RId：小數輸入沒有測試`n- 面向：$Axis`n- 判定：$Verdict`n- 位置：``tests/a.Tests.ps1:9```n- 說明：沒有驗到 [double[]]`n- 建議修法：補 1.5, 2 的案例`n"
    }
    function Review($F, [string]$Agent, [string]$Outcome, [string]$Report) {
        $to = if ($Outcome -ceq 'objection') { 'builder' } else { $null }
        Complete-OfficeLoopReview -OfficeRoot $F.Office -Id $script:Id -Agent $Agent -ReplyText (Reply $Outcome $Report $to) -Config $F.Config -Now $script:T0
    }
    function Build($F, [string]$Outcome = 'done', [string]$ObjectionTo, [string]$File) {
        $in = Step $F
        if ($Outcome -ceq 'done') { Commit-In $in.worktree.path $(if ($File) { $File } else { "fix-$([guid]::NewGuid().ToString('N').Substring(0, 6)).txt" }) }
        Complete-OfficeImplement -OfficeRoot $F.Office -Id $script:Id -ReplyText (Reply $Outcome $null $ObjectionTo) -Config $F.Config -Now $script:T0
    }
    function To-Review($F) {
        $wt = To-SecReview $F
        $null = Step $F
        $r = Review $F security done (SecReport '無')
        if ($r.State -cne 'REVIEW') { throw "setup: expected REVIEW, got $($r.State): $($r.Reason)" }
        $null = Step $F
        $wt
    }
    function Decision($F, [int]$N) {
        Get-Content -Raw -Encoding utf8 -LiteralPath (Join-Path $F.Office 'work' $script:Id 'decisions' "$N.json") | ConvertFrom-Json
    }
    function Rule($F, [int]$N, [int]$Choice, [string]$Note) {
        Invoke-OfficeG2Ruling -OfficeRoot $F.Office -Id $script:Id -DecisionId $N -Choice $Choice -Note $Note -Now $script:T0
    }
}

Describe 'Get-OfficeLoopInput in BUILDING' {
    It 'creates the worktree, records the build and returns the Builder implement input' {
        $f = New-Fixture
        $in = Step $f
        $in.action | Should -Be 'run-agent'
        $in.agent | Should -Be 'builder'
        $in.mode | Should -Be 'implement'
        $in.worktree.branch | Should -Be 'huddle/7-fix-average'
        Test-Path -LiteralPath (Join-Path $in.worktree.path 'app.txt') | Should -BeTrue
        $in.worktree.baseCommit | Should -Be @(G $f.Origin rev-parse HEAD)[0]
        $in.commands.test | Should -Be 'pwsh -c test'
        $in.feedback | Should -BeNullOrEmpty
        $in.replyFile | Should -BeLike '*replies*builder-20261109-100000.md'
        $b = (Item $f).build
        $b.worktree | Should -Be $in.worktree.path
        $b.repoSnapshot.branch | Should -Be 'my-work'
        Thread $f | Should -Match 'office-manager → builder · assign'
    }

    It 'leaves my own clone untouched' {
        $f = New-Fixture
        $before = (G $f.Repo status --porcelain=v1) -join "`n"
        $null = Step $f
        (G $f.Repo status --porcelain=v1) -join "`n" | Should -Be $before
        @(G $f.Repo symbolic-ref --short HEAD)[0] | Should -Be 'my-work'
    }

    It 'reuses the recorded worktree on the next round' {
        $f = New-Fixture
        $a = Step $f
        $b = Step $f
        $b.worktree.path | Should -Be $a.worktree.path
        $b.worktree.baseCommit | Should -Be $a.worktree.baseCommit
    }

    It 'stops for a pending decision' {
        $f = New-Fixture
        $null = Set-OfficeWorkItemPendingDecision -OfficeRoot $f.Office -Id $script:Id -DecisionId 2
        (Step $f).action | Should -Be 'pending-decision'
    }

    It 'does not run outside the loop states' {
        $f = New-Fixture
        $null = Set-OfficeWorkItemState -OfficeRoot $f.Office -Id $script:Id -State 'PARKED'
        (Step $f).action | Should -Be 'none'
    }
}

Describe 'Complete-OfficeImplement' {
    It 'moves to TESTING when the Builder committed and left everything clean' {
        $f = New-Fixture
        $in = Step $f
        Commit-In $in.worktree.path
        $r = Complete-OfficeImplement -OfficeRoot $f.Office -Id $script:Id -ReplyText (Reply 'done') -Config $f.Config -Now $script:T0
        $r.Result | Should -Be 'done'
        $r.State | Should -Be 'TESTING'
        (Item $f).build.head | Should -Be @(G $in.worktree.path rev-parse HEAD)[0]
        Thread $f | Should -Match 'BUILDING -> TESTING'
    }

    It 'blocks when there is no new commit' {
        $f = New-Fixture
        $null = Step $f
        $r = Complete-OfficeImplement -OfficeRoot $f.Office -Id $script:Id -ReplyText (Reply 'done') -Config $f.Config -Now $script:T0
        $r.State | Should -Be 'BLOCKED'
        $r.Problems -join ';' | Should -Match 'no commit on top of the base'
        (Item $f).blockedBy | Should -Be 'builder'
    }

    It 'blocks when the worktree has uncommitted changes' {
        $f = New-Fixture
        $in = Step $f
        Commit-In $in.worktree.path
        Set-Content -LiteralPath (Join-Path $in.worktree.path 'stray.tmp') -Value 'x'
        $r = Complete-OfficeImplement -OfficeRoot $f.Office -Id $script:Id -ReplyText (Reply 'done') -Config $f.Config -Now $script:T0
        $r.State | Should -Be 'BLOCKED'
        $r.Problems -join ';' | Should -Match 'uncommitted changes.*stray\.tmp'
    }

    It 'blocks when my own clone changed while the Builder ran' {
        $f = New-Fixture
        $in = Step $f
        Commit-In $in.worktree.path
        Set-Content -LiteralPath (Join-Path $f.Repo 'app.txt') -Value 'touched by the builder'
        $r = Complete-OfficeImplement -OfficeRoot $f.Office -Id $script:Id -ReplyText (Reply 'done') -Config $f.Config -Now $script:T0
        $r.State | Should -Be 'BLOCKED'
        $r.Problems -join ';' | Should -Match 'my clone at repoPath has different uncommitted changes'
    }

    It 'lets my own clone advance by my commits while the Builder ran, and notes them (T15d)' {
        $f = New-Fixture
        $in = Step $f
        Commit-In $in.worktree.path
        # My own work in the clone: commit the pending edit, then another commit on top.
        $null = G $f.Repo commit -q -am 'my own commit'
        Set-Content -LiteralPath (Join-Path $f.Repo 'notes.txt') -Value 'mine'
        $null = G $f.Repo add notes.txt
        $null = G $f.Repo commit -q -m 'second of mine'
        $r = Complete-OfficeImplement -OfficeRoot $f.Office -Id $script:Id -ReplyText (Reply 'done') -Config $f.Config -Now $script:T0
        $r.Result | Should -Be 'done'
        $r.State | Should -Be 'TESTING'
        $t = Thread $f
        $t | Should -Match "advanced by 2 commit\(s\) on 'my-work' while the Builder ran, taken as my own work \(the uncommitted changes differ too\)"
        $t | Should -Match 'Huddle Test .* second of mine; .* my own commit'
        $t | Should -Match 'office-manager → user · note'
    }

    It 'blocks when my own clone switched branch while the Builder ran (T15d)' {
        $f = New-Fixture
        $in = Step $f
        Commit-In $in.worktree.path
        $null = G $f.Repo checkout -q -b other-work
        $r = Complete-OfficeImplement -OfficeRoot $f.Office -Id $script:Id -ReplyText (Reply 'done') -Config $f.Config -Now $script:T0
        $r.State | Should -Be 'BLOCKED'
        $r.Problems -join ';' | Should -Match "switched from branch 'my-work' to 'other-work'"
    }

    It 'blocks when my own clone was reset to a commit that does not descend from the snapshot (T15d)' {
        $f = New-Fixture
        $null = G $f.Repo commit -q -am 'before the builder'
        $in = Step $f
        Commit-In $in.worktree.path
        $null = G $f.Repo reset -q --hard HEAD~1
        $r = Complete-OfficeImplement -OfficeRoot $f.Office -Id $script:Id -ReplyText (Reply 'done') -Config $f.Config -Now $script:T0
        $r.State | Should -Be 'BLOCKED'
        $r.Problems -join ';' | Should -Match 'which does not descend from it'
        $r.Problems -join ';' | Should -Match ([regex]::Escape((Item $f).build.repoSnapshot.head))
    }

    It 'blocks when my clone has new uncommitted changes even though HEAD advanced on another branch (T15d)' {
        $f = New-Fixture
        $in = Step $f
        Commit-In $in.worktree.path
        $null = G $f.Repo checkout -q -b other-work
        $null = G $f.Repo commit -q -am 'mine on the other branch'
        $r = Complete-OfficeImplement -OfficeRoot $f.Office -Id $script:Id -ReplyText (Reply 'done') -Config $f.Config -Now $script:T0
        $r.State | Should -Be 'BLOCKED'
        $r.Problems -join ';' | Should -Match 'switched from branch'
        Thread $f | Should -Not -Match 'taken as my own work'
    }

    It 'blocks when the worktree was switched to another branch' {
        $f = New-Fixture
        $in = Step $f
        Commit-In $in.worktree.path
        $null = G $in.worktree.path checkout -q -b elsewhere
        $r = Complete-OfficeImplement -OfficeRoot $f.Office -Id $script:Id -ReplyText (Reply 'done') -Config $f.Config -Now $script:T0
        $r.Problems -join ';' | Should -Match "is on 'elsewhere'"
    }

    It 'blocks an objection when no report sent the work back, and records it to the agent objected to' {
        $f = New-Fixture
        $null = Step $f
        $r = Complete-OfficeImplement -OfficeRoot $f.Office -Id $script:Id -ReplyText (Reply 'objection' $null 'security') -Config $f.Config -Now $script:T0
        $r.State | Should -Be 'BLOCKED'
        $r.Problems -join ';' | Should -Match 'nothing to object to'
        Thread $f | Should -Match 'builder → security · objection'
    }

    It 'blocks an unparseable reply' {
        $f = New-Fixture
        $null = Step $f
        $r = Complete-OfficeImplement -OfficeRoot $f.Office -Id $script:Id -ReplyText 'no yaml here' -Config $f.Config -Now $script:T0
        $r.Valid | Should -BeFalse
        $r.State | Should -Be 'BLOCKED'
    }

    It 'refuses to run before build-step recorded the build' {
        $f = New-Fixture
        { Complete-OfficeImplement -OfficeRoot $f.Office -Id $script:Id -ReplyText (Reply 'done') -Config $f.Config } |
            Should -Throw '*no build record*'
    }

    It 'requires a new commit in a later round' {
        $f = New-Fixture
        $null = To-Testing $f
        $null = Complete-OfficeLoopReview -OfficeRoot $f.Office -Id $script:Id -Agent tester -ReplyText (Reply 'objection' $script:TestReport 'builder') -Now $script:T0
        $null = Step $f
        $r = Complete-OfficeImplement -OfficeRoot $f.Office -Id $script:Id -ReplyText (Reply 'done') -Config $f.Config -Now $script:T0
        $r.Problems -join ';' | Should -Match 'no new commit since the last tested build'
    }
}

Describe 'Resuming a work item BLOCKED by a loop agent' {
    It 'reports blocked, and -Resume returns it to BUILDING without counting a round' {
        $f = New-Fixture
        $null = Step $f
        $null = Complete-OfficeImplement -OfficeRoot $f.Office -Id $script:Id -ReplyText (Reply 'blocked') -Config $f.Config -Now $script:T0
        $s = Step $f
        $s.action | Should -Be 'blocked'
        $s.agent | Should -Be 'builder'
        $s.reason | Should -Match 'blocked reply'
        $r = Step $f -Resume
        $r.action | Should -Be 'run-agent'
        $r.state | Should -Be 'BUILDING'
        $r.round | Should -Be 0
        (Item $f).blockedBy | Should -BeNullOrEmpty
    }
}

Describe 'Complete-OfficeLoopReview (tester)' {
    It 'saves test-report.md and moves to SEC_REVIEW on done' {
        $f = New-Fixture
        $null = To-Testing $f
        $in = Step $f
        $in.agent | Should -Be 'tester'
        $in.reportPath | Should -BeLike '*test-report.md'
        $r = Complete-OfficeLoopReview -OfficeRoot $f.Office -Id $script:Id -Agent tester -ReplyText (Reply 'done' $script:TestReport) -Now $script:T0
        $r.Result | Should -Be 'done'
        $r.State | Should -Be 'SEC_REVIEW'
        Get-Content -Raw -LiteralPath $r.ReportPath | Should -Match '## 覆蓋率與缺口'
    }

    It 'returns the work item to BUILDING on an objection, with the report as feedback' {
        $f = New-Fixture
        $null = To-Testing $f
        $r = Complete-OfficeLoopReview -OfficeRoot $f.Office -Id $script:Id -Agent tester -ReplyText (Reply 'objection' $script:TestReport 'builder') -Now $script:T0
        $r.Result | Should -Be 'returned'
        $r.State | Should -Be 'BUILDING'
        $r.Round | Should -Be 1
        $in = Step $f
        $in.feedback.from | Should -Be 'tester'
        $in.feedback.report | Should -BeLike '*test-report.md'
    }

    It 'clears the feedback once the Builder is done' {
        $f = New-Fixture
        $null = To-Testing $f
        $null = Complete-OfficeLoopReview -OfficeRoot $f.Office -Id $script:Id -Agent tester -ReplyText (Reply 'objection' $script:TestReport 'builder') -Now $script:T0
        $in = Step $f
        Commit-In $in.worktree.path 'fix2.txt'
        $null = Complete-OfficeImplement -OfficeRoot $f.Office -Id $script:Id -ReplyText (Reply 'done') -Config $f.Config -Now $script:T0
        (Item $f).returnedBy | Should -BeNullOrEmpty
    }

    It 'blocks a report that lacks a required section' {
        $f = New-Fixture
        $null = To-Testing $f
        $bad = $script:TestReport -replace '## 失敗項目', '## Failures'
        $r = Complete-OfficeLoopReview -OfficeRoot $f.Office -Id $script:Id -Agent tester -ReplyText (Reply 'done' $bad) -Now $script:T0
        $r.State | Should -Be 'BLOCKED'
        $r.Problems -join ';' | Should -Match 'missing sections: 失敗項目'
    }

    It 'blocks a done reply without report markers' {
        $f = New-Fixture
        $null = To-Testing $f
        $r = Complete-OfficeLoopReview -OfficeRoot $f.Office -Id $script:Id -Agent tester -ReplyText (Reply 'done') -Now $script:T0
        $r.State | Should -Be 'BLOCKED'
        $r.Problems -join ';' | Should -Match 'no usable report'
    }

    It 'blocks when the Tester left files in the worktree' {
        $f = New-Fixture
        $wt = To-Testing $f
        Set-Content -LiteralPath (Join-Path $wt 'TestResults.xml') -Value '<x/>'
        $r = Complete-OfficeLoopReview -OfficeRoot $f.Office -Id $script:Id -Agent tester -ReplyText (Reply 'done' $script:TestReport) -Now $script:T0
        $r.State | Should -Be 'BLOCKED'
        $r.Problems -join ';' | Should -Match 'TestResults\.xml'
        (Item $f).blockedBy | Should -Be 'tester'
    }

    It 'blocks when the Tester committed' {
        $f = New-Fixture
        $wt = To-Testing $f
        Commit-In $wt 'tester.txt'
        $r = Complete-OfficeLoopReview -OfficeRoot $f.Office -Id $script:Id -Agent tester -ReplyText (Reply 'done' $script:TestReport) -Now $script:T0
        $r.Problems -join ';' | Should -Match 'HEAD moved'
    }

    It 'blocks an objection aimed at someone other than the Builder' {
        $f = New-Fixture
        $null = To-Testing $f
        $r = Complete-OfficeLoopReview -OfficeRoot $f.Office -Id $script:Id -Agent tester -ReplyText (Reply 'objection' $script:TestReport 'security') -Now $script:T0
        $r.State | Should -Be 'BLOCKED'
        $r.Problems -join ';' | Should -Match 'objection_to must be builder'
    }

    It 'refuses a reply in the wrong state' {
        $f = New-Fixture
        { Complete-OfficeLoopReview -OfficeRoot $f.Office -Id $script:Id -Agent tester -ReplyText (Reply 'done' $script:TestReport) } |
            Should -Throw '*need TESTING*'
    }
}

Describe 'Complete-OfficeLoopReview (security)' {
    It 'moves to REVIEW when there is no finding, and the loop then runs the Reviewer' {
        $f = New-Fixture
        $null = To-SecReview $f
        $r = Complete-OfficeLoopReview -OfficeRoot $f.Office -Id $script:Id -Agent security -ReplyText (Reply 'done' (SecReport '無')) -Now $script:T0
        $r.Result | Should -Be 'done'
        $r.State | Should -Be 'REVIEW'
        $in = Step $f
        $in.agent | Should -Be 'reviewer'
        $in.reportPath | Should -BeLike '*review-report.md'
    }

    It 'allows done with low findings only' {
        $f = New-Fixture
        $null = To-SecReview $f
        $r = Complete-OfficeLoopReview -OfficeRoot $f.Office -Id $script:Id -Agent security -ReplyText (Reply 'done' (SecReport (Finding 'F-1' 'low'))) -Now $script:T0
        $r.State | Should -Be 'REVIEW'
        $r.Findings[0].severity | Should -Be 'low'
    }

    It 'returns to BUILDING on an objection with a high finding' {
        $f = New-Fixture
        $null = To-SecReview $f
        $report = SecReport ((Finding 'F-1' 'high') + "`n" + (Finding 'F-2' 'low'))
        $r = Complete-OfficeLoopReview -OfficeRoot $f.Office -Id $script:Id -Agent security -ReplyText (Reply 'objection' $report 'builder') -Now $script:T0
        $r.Result | Should -Be 'returned'
        $r.State | Should -Be 'BUILDING'
        @($r.Findings).Count | Should -Be 2
        (Step $f).feedback.report | Should -BeLike '*security-report.md'
    }

    It 'blocks done when a finding is medium or above' {
        $f = New-Fixture
        $null = To-SecReview $f
        $r = Complete-OfficeLoopReview -OfficeRoot $f.Office -Id $script:Id -Agent security -ReplyText (Reply 'done' (SecReport (Finding 'F-1' 'medium'))) -Now $script:T0
        $r.State | Should -Be 'BLOCKED'
        $r.Problems -join ';' | Should -Match 'F-1 is medium or above'
    }

    It 'blocks an objection with only low findings' {
        $f = New-Fixture
        $null = To-SecReview $f
        $r = Complete-OfficeLoopReview -OfficeRoot $f.Office -Id $script:Id -Agent security -ReplyText (Reply 'objection' (SecReport (Finding 'F-1' 'low')) 'builder') -Now $script:T0
        $r.State | Should -Be 'BLOCKED'
        $r.Problems -join ';' | Should -Match 'no finding is medium or above'
    }

    It 'blocks a malformed finding' {
        $f = New-Fixture
        $null = To-SecReview $f
        $report = SecReport ((Finding 'F-1' 'severe') -replace '- 建議修法：[^\n]*\n', '')
        $r = Complete-OfficeLoopReview -OfficeRoot $f.Office -Id $script:Id -Agent security -ReplyText (Reply 'objection' $report 'builder') -Now $script:T0
        $r.State | Should -Be 'BLOCKED'
        $r.Problems -join ';' | Should -Match "severity 'severe'"
        $r.Problems -join ';' | Should -Match "missing '- 建議修法："
    }
}

Describe 'Read-OfficeSecurityFindings' {
    It 'reads every finding with half- or full-width colons and backticked severities' {
        $text = SecReport ((Finding 'F-1' '`High`') + "`n### F-2: half width`n- 嚴重度: low`n- 位置: a:1`n- 情境: x`n- 建議修法: y`n")
        $p = Read-OfficeSecurityFindings $text
        $p.Errors | Should -BeNullOrEmpty
        @($p.Findings.Id) | Should -Be @('F-1', 'F-2')
        @($p.Findings.Severity) | Should -Be @('high', 'low')
        $p.Findings[1].Title | Should -Be 'half width'
    }

    It 'accepts 無 and nothing else when there is no finding' {
        (Read-OfficeSecurityFindings (SecReport '無')).Errors | Should -BeNullOrEmpty
        (Read-OfficeSecurityFindings (SecReport 'nothing much')).Errors | Should -Match 'no .### F-<n>. item'
    }

    It 'rejects duplicate ids, bad ids and a missing section' {
        (Read-OfficeSecurityFindings (SecReport ((Finding 'F-1' 'low') + (Finding 'F-1' 'low')))).Errors | Should -Match 'F-1 appears more than once'
        (Read-OfficeSecurityFindings (SecReport (Finding 'X1' 'low'))).Errors | Should -Match "'X1' must be F-<n>"
        (Read-OfficeSecurityFindings "## 範圍`nx").Errors | Should -Be @('no ## Findings section')
    }

    It 'stops the Findings section at the next ## heading' {
        $text = (SecReport (Finding 'F-1' 'low')) + "`n## 附註`n### F-9：not a finding`n"
        @((Read-OfficeSecurityFindings $text).Findings.Id) | Should -Be @('F-1')
    }
}

Describe 'build-step.ps1 and loop-complete.ps1' {
    It 'run one Builder step end to end through the scripts' {
        $f = New-Fixture
        $raw = & pwsh -NoProfile -File (Join-Path $script:RepoRoot 'scripts' 'build-step.ps1') -Ref 'grp/proj#7' -OfficeRoot $f.Office -ConfigPath $f.ConfigPath
        $in = ($raw -join "`n") | ConvertFrom-Json
        $in.ok | Should -BeTrue
        $in.agent | Should -Be 'builder'
        Commit-In $in.worktree.path
        $reply = Join-Path $f.Root 'reply.md'
        [IO.File]::WriteAllText($reply, (Reply 'done'), $script:Utf8)
        $raw = & pwsh -NoProfile -File (Join-Path $script:RepoRoot 'scripts' 'loop-complete.ps1') -Id $script:Id -Agent builder -ReplyFile $reply -OfficeRoot $f.Office -ConfigPath $f.ConfigPath
        $out = ($raw -join "`n") | ConvertFrom-Json
        $out.ok | Should -BeTrue
        $out.state | Should -Be 'TESTING'
    }

    It 'resolves a short ref and the office id' {
        $f = New-Fixture
        foreach ($ref in 'proj#7', $script:Id) {
            $raw = & pwsh -NoProfile -File (Join-Path $script:RepoRoot 'scripts' 'build-step.ps1') -Ref $ref -OfficeRoot $f.Office -ConfigPath $f.ConfigPath
            (($raw -join "`n") | ConvertFrom-Json).id | Should -Be $script:Id
        }
    }

    It 'reports a missing reply file as an error instead of a blocked reply' {
        $f = New-Fixture
        $raw = & pwsh -NoProfile -File (Join-Path $script:RepoRoot 'scripts' 'loop-complete.ps1') -Id $script:Id -Agent tester -ReplyFile (Join-Path $f.Root 'nope.md') -OfficeRoot $f.Office -ConfigPath $f.ConfigPath
        (($raw -join "`n") | ConvertFrom-Json).ok | Should -BeFalse
        (Item $f).state | Should -Be 'BUILDING'
    }
}

Describe 'Loop agent definitions' {
    BeforeAll {
        function Def([string]$Name) { Get-Content -Raw -Encoding utf8 (Join-Path $script:RepoRoot '.claude' 'agents' "$Name.md") }
    }

    It 'Tester runs on Sonnet and Security inherits the session model (SPEC §1 roles)' {
        Def 'tester' | Should -Match '(?m)^model: sonnet\s*$'
        Def 'security' | Should -Match '(?m)^model: inherit\s*$'
    }

    It 'Tester and Security can neither write files nor dispatch agents' {
        foreach ($n in 'tester', 'security') {
            Def $n | Should -Match '(?m)^tools: Read, Grep, Glob, Bash\s*$'
        }
    }

    It 'documents every report section the completion checks' {
        foreach ($s in '結果', '執行的指令', '失敗項目', '覆蓋率與缺口') { Def 'tester' | Should -Match "(?m)^## $s\s*$" }
        foreach ($s in '範圍', 'Findings') { Def 'security' | Should -Match "(?m)^## $s\s*$" }
        foreach ($s in '嚴重度', '位置', '情境', '建議修法') { Def 'security' | Should -Match "(?m)^- ${s}：" }
    }

    It 'Security forbids directly exploitable steps (S4)' {
        Def 'security' | Should -Match '不寫可以直接拿來利用的步驟（團隊規範 S4）'
    }
}

# --- T14: Reviewer, divergence (SPEC §3.3 conditions 1-4) and G2 -------------------------------------

Describe 'Test-OfficeDivergence' {
    BeforeAll {
        $script:Cfg = @{ maxAutoRounds = 3 }
        function Div([hashtable]$Item, [string]$Agent, [string]$Outcome = 'objection', [string]$To) {
            $base = @{ round = 0; testerDisputes = $null; extraRounds = $null }
            foreach ($k in $Item.Keys) { $base[$k] = $Item[$k] }
            Test-OfficeDivergence -Item $base -Agent $Agent -Outcome $Outcome -ObjectionTo $To -Config $script:Cfg
        }
    }

    It 'condition 1: the Builder objects to Security' {
        $d = Div @{} builder objection security
        $d.Diverged | Should -BeTrue
        $d.Condition | Should -Be 1
        $d.Kind | Should -Be 'divergence-security'
    }

    It 'condition 2: only after the Builder objected to the Tester before (both sides insisted)' {
        (Div @{ testerDisputes = $null } builder objection tester).Diverged | Should -BeFalse
        $d = Div @{ testerDisputes = 1 } builder objection tester
        $d.Condition | Should -Be 2
        $d.Kind | Should -Be 'divergence-tester'
    }

    It 'condition 3: the Builder objects to a Reviewer must-fix item' {
        $d = Div @{} builder objection reviewer
        $d.Condition | Should -Be 3
        $d.Kind | Should -Be 'divergence-reviewer'
    }

    It 'condition 4: a round sent back past maxAutoRounds, counting extra rounds allowed at G2' {
        foreach ($a in 'tester', 'security', 'reviewer') {
            (Div @{ round = 2 } $a objection builder).Diverged | Should -BeFalse
            $d = Div @{ round = 3 } $a objection builder
            $d.Condition | Should -Be 4
            $d.Kind | Should -Be 'round-limit'
        }
        (Div @{ round = 3; extraRounds = 1 } tester objection builder).Diverged | Should -BeFalse
        (Div @{ round = 4; extraRounds = 1 } tester objection builder).Condition | Should -Be 4
    }

    It 'is never a disagreement when nobody objects' {
        foreach ($a in 'builder', 'tester', 'security', 'reviewer') {
            foreach ($o in 'done', 'blocked', 'needs_decision') { (Div @{ round = 9; testerDisputes = 5 } $a $o).Diverged | Should -BeFalse }
        }
    }
}

Describe 'Complete-OfficeLoopReview (reviewer)' {
    It 'moves to READY when nothing must be fixed, and the loop is then done' {
        $f = New-Fixture
        $null = To-Review $f
        $r = Review $f reviewer done (RevReport ((RevItem 'R-1' '建議') + "`n" + (RevItem 'R-2' '建議' '可讀性')))
        $r.Result | Should -Be 'done'
        $r.State | Should -Be 'READY'
        @($r.Findings).Count | Should -Be 2
        (Step $f).action | Should -Be 'ready'
        Get-Content -Raw -LiteralPath $r.ReportPath | Should -Match '## 審查意見'
    }

    It 'accepts 無 when there is no comment' {
        $f = New-Fixture
        $null = To-Review $f
        (Review $f reviewer done (RevReport '無')).State | Should -Be 'READY'
    }

    It 'returns to BUILDING on a must-fix item, with the review report as feedback' {
        $f = New-Fixture
        $null = To-Review $f
        $r = Review $f reviewer objection (RevReport (RevItem 'R-1' '必須修'))
        $r.Result | Should -Be 'returned'
        $r.State | Should -Be 'BUILDING'
        $r.Round | Should -Be 1
        (Step $f).feedback.report | Should -BeLike '*review-report.md'
    }

    It 'blocks done with a must-fix item, and objection without one' {
        $f = New-Fixture
        $null = To-Review $f
        $r = Review $f reviewer done (RevReport (RevItem 'R-1' '必須修'))
        $r.State | Should -Be 'BLOCKED'
        $r.Problems -join ';' | Should -Match 'R-1 is 必須修'
        $g = New-Fixture
        $null = To-Review $g
        (Review $g reviewer objection (RevReport (RevItem 'R-1' '建議'))).Problems -join ';' | Should -Match 'no item is 必須修'
    }

    It 'blocks an unknown axis or verdict' {
        $f = New-Fixture
        $null = To-Review $f
        $r = Review $f reviewer objection (RevReport (RevItem 'R-1' '一定要修' '風格'))
        $r.State | Should -Be 'BLOCKED'
        $r.Problems -join ';' | Should -Match "面向 '風格'"
        $r.Problems -join ';' | Should -Match "判定 '一定要修'"
    }
}

Describe 'Read-OfficeReviewItems' {
    It 'reads every item with its axis and verdict' {
        $p = Read-OfficeReviewItems (RevReport ((RevItem 'R-1' '必須修') + (RevItem 'R-2' '建議' '效能')))
        $p.Errors | Should -BeNullOrEmpty
        @($p.Items.Verdict) | Should -Be @('必須修', '建議')
        @($p.Items.Axis) | Should -Be @('正確性', '效能')
    }

    It 'reports a missing field and a missing section' {
        (Read-OfficeReviewItems (RevReport ((RevItem 'R-1' '建議') -replace '- 說明：[^\n]*\n', ''))).Errors | Should -Match "R-1: missing '- 說明："
        (Read-OfficeReviewItems "## 範圍`nx").Errors | Should -Be @('no ## 審查意見 section')
    }
}

Describe 'Builder objections' {
    It 'condition 1: an objection to Security raises G2 and keeps the item in BUILDING' {
        $f = New-Fixture
        $null = To-SecReview $f
        $null = Review $f security objection (SecReport (Finding 'F-1' 'high'))
        $r = Build $f objection security
        $r.Result | Should -Be 'g2'
        $r.State | Should -Be 'BUILDING'
        $d = Decision $f $r.Decision
        $d.gate | Should -Be 'G2'
        $d.kind | Should -Be 'divergence-security'
        $d.options.Count | Should -Be 3
        $d.context | Should -Match 'security-report.md'
        $d.context | Should -Match 'objection reply'
        (Item $f).pendingDecision | Should -Be $r.Decision
        (Step $f).action | Should -Be 'pending-decision'
        @(Get-OfficePendingNotifications -OfficeRoot $f.Office).Gate | Should -Be 'G2'
    }

    It 'condition 3: an objection to a Reviewer must-fix item raises G2' {
        $f = New-Fixture
        $null = To-Review $f
        $null = Review $f reviewer objection (RevReport (RevItem 'R-1' '必須修'))
        $r = Build $f objection reviewer
        $r.Result | Should -Be 'g2'
        (Decision $f $r.Decision).kind | Should -Be 'divergence-reviewer'
    }

    It 'condition 2: the Tester re-checks after the first objection; the second objection raises G2' {
        $f = New-Fixture
        $null = To-Testing $f
        $null = Step $f
        $null = Review $f tester objection $script:TestReport
        $r = Build $f objection tester
        $r.Result | Should -Be 'disputed'
        $r.State | Should -Be 'TESTING'
        $in = Step $f
        $in.dispute.count | Should -Be 1
        $in.dispute.builderObjection | Should -Be 'objection reply'
        $null = Review $f tester objection $script:TestReport
        $r = Build $f objection tester
        $r.Result | Should -Be 'g2'
        (Decision $f $r.Decision).kind | Should -Be 'divergence-tester'
    }

    It 'resets the dispute when the Tester accepts the Builder''s argument' {
        $f = New-Fixture
        $null = To-Testing $f
        $null = Step $f
        $null = Review $f tester objection $script:TestReport
        $null = Build $f objection tester
        $null = Step $f
        (Review $f tester done $script:TestReport).State | Should -Be 'SEC_REVIEW'
        (Item $f).testerDisputes | Should -BeNullOrEmpty
        (Item $f).builderObjection | Should -BeNullOrEmpty
    }

    It 'blocks an objection that comes with a new commit' {
        $f = New-Fixture
        $null = To-SecReview $f
        $null = Review $f security objection (SecReport (Finding 'F-1' 'high'))
        $in = Step $f
        Commit-In $in.worktree.path 'partial.txt'
        $r = Complete-OfficeImplement -OfficeRoot $f.Office -Id $script:Id -ReplyText (Reply 'objection' $null 'security') -Config $f.Config -Now $script:T0
        $r.State | Should -Be 'BLOCKED'
        $r.Problems -join ';' | Should -Match 'an objecting Builder must not commit'
    }

    It 'blocks an objection aimed at an agent other than the one that sent the work back' {
        $f = New-Fixture
        $null = To-SecReview $f
        $null = Review $f security objection (SecReport (Finding 'F-1' 'high'))
        $r = Build $f objection reviewer
        $r.State | Should -Be 'BLOCKED'
        $r.Problems -join ';' | Should -Match 'objection_to must be security'
    }

    It 'refuses results while a decision is pending' {
        $f = New-Fixture
        $null = To-SecReview $f
        $null = Review $f security objection (SecReport (Finding 'F-1' 'high'))
        $null = Build $f objection security
        { Complete-OfficeImplement -OfficeRoot $f.Office -Id $script:Id -ReplyText (Reply 'done') -Config $f.Config } | Should -Throw '*is pending*'
    }
}

Describe 'Invoke-OfficeG2Ruling' {
    BeforeAll {
        # Security sent the work back (F-1 high) and the Builder objected: a G2 is pending.
        function New-SecurityG2 {
            $f = New-Fixture
            $null = To-SecReview $f
            $null = Review $f security objection (SecReport (Finding 'F-1' 'high'))
            $r = Build $f objection security
            [pscustomobject]@{ F = $f; N = $r.Decision }
        }
    }

    It 'fix: the Builder gets the ruling with its feedback and may not object again' {
        $g = New-SecurityG2
        $r = Rule $g.F $g.N 1 'add the range check'
        $r.State | Should -Be 'BUILDING'
        $in = Step $g.F
        $in.feedback.from | Should -Be 'security'
        $in.feedback.ruling.decision | Should -Be $g.N
        $in.feedback.ruling.note | Should -Be 'add the range check'
        $x = Complete-OfficeImplement -OfficeRoot $g.F.Office -Id $script:Id -ReplyText (Reply 'objection' $null 'security') -Config $g.F.Config -Now $script:T0
        $x.State | Should -Be 'BLOCKED'
        $x.Problems -join ';' | Should -Match "G2 #$($g.N) already ruled"
    }

    It 'fix: the ruling is cleared once the Builder is done' {
        $g = New-SecurityG2
        $null = Rule $g.F $g.N 1
        $null = Build $g.F
        (Item $g.F).fixRuling | Should -BeNullOrEmpty
        (Item $g.F).state | Should -Be 'TESTING'
    }

    It 'accept: records a waiver, moves on to REVIEW and shows the waiver to later agents' {
        $g = New-SecurityG2
        $r = Rule $g.F $g.N 2 'internal tool only'
        $r.State | Should -Be 'REVIEW'
        $w = @((Item $g.F).waivers)
        $w.Count | Should -Be 1
        $w[0].from | Should -Be 'security'
        $w[0].decision | Should -Be $g.N
        $w[0].builderView | Should -Be 'objection reply'
        $in = Step $g.F
        $in.agent | Should -Be 'reviewer'
        $in.waivers[0].note | Should -Be 'internal tool only'
    }

    It 'accept on a Reviewer disagreement reaches READY with the decision id' {
        $f = New-Fixture
        $null = To-Review $f
        $null = Review $f reviewer objection (RevReport (RevItem 'R-1' '必須修'))
        $n = (Build $f objection reviewer).Decision
        (Rule $f $n 2).State | Should -Be 'READY'
        @((Item $f).history)[-1].decision | Should -Be $n
    }

    It 'accept on a Tester disagreement continues to SEC_REVIEW' {
        $f = New-Fixture
        $null = To-Testing $f
        $null = Step $f
        $null = Review $f tester objection $script:TestReport
        $null = Build $f objection tester
        $null = Step $f
        $null = Review $f tester objection $script:TestReport
        $n = (Build $f objection tester).Decision
        (Rule $f $n 2).State | Should -Be 'SEC_REVIEW'
    }

    It 'park: moves the work item to PARKED' {
        $g = New-SecurityG2
        (Rule $g.F $g.N 3).State | Should -Be 'PARKED'
    }

    It 'refuses a decision that is not pending, or not a build-loop G2' {
        $g = New-SecurityG2
        { Rule $g.F 99 1 } | Should -Throw
        $null = Rule $g.F $g.N 3
        { Rule $g.F $g.N 1 } | Should -Throw '*not the pending decision*'
    }
}

Describe 'Round limit (condition 4)' {
    BeforeAll {
        # Builder done, Tester objects: one round each time.
        function Spin($F) {
            $null = Build $F
            $null = Step $F
            Review $F tester objection $script:TestReport
        }
    }

    It 'raises G2 when a round would pass maxAutoRounds; allowing one more round continues the loop' {
        $f = New-Fixture
        for ($k = 1; $k -le 3; $k++) { (Spin $f).Result | Should -Be 'returned' }
        $r = Spin $f
        $r.Result | Should -Be 'g2'
        $r.State | Should -Be 'BUILDING'
        $r.Round | Should -Be 4
        $d = Decision $f $r.Decision
        $d.kind | Should -Be 'round-limit'
        $d.options.Count | Should -Be 2
        (Step $f).action | Should -Be 'pending-decision'

        $null = Rule $f $r.Decision 1
        (Item $f).extraRounds | Should -Be 1
        $in = Step $f
        $in.action | Should -Be 'run-agent'
        $in.maxAutoRounds | Should -Be 4
        (Spin $f).Result | Should -Be 'g2'
    }

    It 'park ends the loop' {
        $f = New-Fixture
        for ($k = 1; $k -le 4; $k++) { $r = Spin $f }
        (Rule $f $r.Decision 2).State | Should -Be 'PARKED'
    }

    It 'build-step raises the G2 itself for a round already past the limit' {
        $f = New-Fixture
        $cfg = $f.Config.Clone(); $cfg.maxAutoRounds = 0
        $null = To-Testing $f
        $null = Step $f
        $null = Review $f tester objection $script:TestReport
        $in = Get-OfficeLoopInput -OfficeRoot $f.Office -Id $script:Id -Config $cfg -Now $script:T0
        $in.action | Should -Be 'pending-decision'
        (Decision $f $in.pendingDecision).kind | Should -Be 'round-limit'
    }
}

Describe 'resolve-decision.ps1 with a build-loop G2' {
    It 'applies the ruling and prints the new state' {
        $f = New-Fixture
        $null = To-SecReview $f
        $null = Review $f security objection (SecReport (Finding 'F-1' 'high'))
        $n = (Build $f objection security).Decision
        $raw = & pwsh -NoProfile -File (Join-Path $script:RepoRoot 'scripts' 'resolve-decision.ps1') -Id $script:Id -DecisionId $n -Choice 2 -Note 'accepted' -OfficeRoot $f.Office -ConfigPath $f.ConfigPath
        $out = ($raw -join "`n") | ConvertFrom-Json
        $out.ok | Should -BeTrue
        $out.kind | Should -Be 'divergence-security'
        $out.state | Should -Be 'REVIEW'
        $out.option | Should -Match "Accept the Builder's view"
    }
}

Describe 'Base moved since the plan (T15c)' {
    BeforeAll {
        # plan.md lists app.txt and a migration placeholder; brief.md lists the lib/ folder and a bare root file.
        $script:PlanText = "# Plan`n## 概要`n## 分析`n程式碼基準：abc1234（refs/remotes/origin/main）`n## 選定做法與理由`n## 考慮過但沒採用`n無`n## 任務清單`n" +
            "## 預計修改的檔案`n- ``app.txt``：改 ``Get-Average`` 的 ``[int[]]```n- ``migrations/<新 revision>_root_cause.py``：新增`n- ``src/a.ps1``、``src/b.ps1``：兩個`n- 不碰 ``package.json```n## 驗證與回退`n"
        $script:BriefText = "# Brief`n## 摘要`n## 排序依據`n## 發現於`n## 驗收條件草稿`n## 範圍`n## 相關程式碼`n程式碼基準：abc1234`n- ``lib/``：共用`n- ``README.md``：說明`n- ``models.py``：裸檔名`n## 風險標記`n## 待釐清問題`n"
        function Write-Docs($F) {
            $dir = Join-Path $F.Office 'work' $script:Id
            [IO.File]::WriteAllText((Join-Path $dir 'plan.md'), $script:PlanText, $script:Utf8)
            [IO.File]::WriteAllText((Join-Path $dir 'brief.md'), $script:BriefText, $script:Utf8)
        }
        # The plan read origin's current HEAD; then origin moves by one commit touching $File.
        function New-MovedFixture([string]$File, [switch]$NoMove) {
            $f = New-Fixture
            Write-Docs $f
            $script:PlanCommit = @(G $f.Origin rev-parse HEAD)[0]
            Set-OfficePlanBase -OfficeRoot $f.Office -Id $script:Id -Commit $script:PlanCommit -Now $script:T0
            if (-not $NoMove) {
                $full = Join-Path $f.Origin $File
                New-Item -ItemType Directory -Path (Split-Path -Parent $full) -Force | Out-Null
                Set-Content -LiteralPath $full -Value 'moved'
                $null = G $f.Origin add -- $File
                $null = G $f.Origin commit -q -m "origin: $File"
            }
            $script:NewCommit = @(G $f.Origin rev-parse HEAD)[0]
            $f
        }
        function WorktreePath($F) { Get-OfficeWorktreePath -Config $F.Config -ProjectPath 'grp/proj' -Iid 7 }
        # build-step.ps1 passes -Fetch, so the clone's origin/main is current when the base is compared.
        function Step($F) { Get-OfficeLoopInput -OfficeRoot $F.Office -Id $script:Id -Config $F.Config -Fetch -Now $script:T0 }
    }

    It 'fetches before comparing: a stale origin/main in my clone does not hide the move' {
        $f = New-MovedFixture 'app.txt'
        @(G $f.Repo rev-parse origin/main)[0] | Should -Be $script:PlanCommit
        (Step $f).action | Should -Be 'pending-decision'
        @(G $f.Repo rev-parse origin/main)[0] | Should -Be $script:NewCommit
    }

    It 'reads repo-relative paths out of the plan and brief sections only' {
        $f = New-Fixture
        Write-Docs $f
        $paths = Get-OfficePlannedPaths (Join-Path $f.Office 'work' $script:Id)
        @($paths | Where-Object Source -ceq 'plan' | ForEach-Object Pattern) | Should -Be @('app.txt', 'migrations/<新 revision>_root_cause.py', 'src/a.ps1', 'src/b.ps1', 'package.json')
        @($paths | Where-Object Source -ceq 'brief' | ForEach-Object Pattern) | Should -Be @('lib/', 'README.md', 'models.py')
        @($paths | ForEach-Object Pattern) | Should -Not -Contain 'Get-Average'
        @($paths | ForEach-Object Pattern) | Should -Not -Contain '[int[]]'
    }

    It 'same base: creates the worktree and records no move' {
        $f = New-MovedFixture -NoMove
        $in = Step $f
        $in.action | Should -Be 'run-agent'
        $in.worktree.baseCommit | Should -Be $script:PlanCommit
        Thread $f | Should -Not -Match 'Base moved'
        (Item $f).planBase | Should -Be $script:PlanCommit
    }

    It 'moved without touching listed files: records the move, updates planBase, worktree starts from the new base' {
        $f = New-MovedFixture 'docs/other.txt'
        $in = Step $f
        $in.action | Should -Be 'run-agent'
        $in.worktree.baseCommit | Should -Be $script:NewCommit
        (Item $f).planBase | Should -Be $script:NewCommit
        (Item $f).pendingDecision | Should -BeNullOrEmpty
        Thread $f | Should -Match ([regex]::Escape("Base moved since the plan: $script:PlanCommit -> $script:NewCommit (1 files changed, none listed"))
        @(Get-ChildItem (Join-Path $f.Office 'work' $script:Id 'decisions') -Filter '*.json' -ErrorAction SilentlyContinue).Count | Should -Be 0
    }

    It 'moved onto <Name>: raises G2 base-moved and creates no worktree' -ForEach @(
        @{ Name = 'a planned file'; File = 'app.txt'; Pattern = 'app.txt'; Source = 'plan' }
        @{ Name = 'a placeholder pattern'; File = 'migrations/0042_root_cause.py'; Pattern = 'migrations/<新 revision>_root_cause.py'; Source = 'plan' }
        @{ Name = 'a folder the brief lists'; File = 'lib/util/x.txt'; Pattern = 'lib/'; Source = 'brief' }
        @{ Name = 'a file the plan says it will not touch'; File = 'package.json'; Pattern = 'package.json'; Source = 'plan' }
    ) {
        $f = New-MovedFixture $File
        $in = Step $f
        $in.action | Should -Be 'pending-decision'
        $in.pendingDecision | Should -Be 1
        $in.reason | Should -Match 'moved since the plan'
        Test-Path -LiteralPath (WorktreePath $f) | Should -BeFalse
        $s = Item $f
        $s.state | Should -Be 'BUILDING'
        $s['build'] | Should -BeNullOrEmpty
        $s.planBase | Should -Be $script:PlanCommit
        $s.baseMove.from | Should -Be $script:PlanCommit
        $s.baseMove.to | Should -Be $script:NewCommit
        $s.baseMove.decision | Should -Be 1
        @($s.baseMove.overlaps) | Should -Be @($File)
        $d = Decision $f 1
        $d.gate | Should -Be 'G2'
        $d.kind | Should -Be 'base-moved'
        $d.options.Count | Should -Be 3
        $d.question | Should -Match '1 files changed, 1 of them listed'
        $d.context | Should -Match ([regex]::Escape("- $File ($Source`: $Pattern)"))
        $d.context | Should -Match 'origin: '
        $d.context | Should -Match ([regex]::Escape($script:NewCommit))
        Get-Content -Raw -Encoding utf8 (Join-Path $f.Office 'work' $script:Id 'decisions' '1.md') | Should -Match 'Kind: base-moved'
    }

    It 'a bare file name in the brief matches only at the repo root' {
        $f = New-MovedFixture 'deep/models.py'
        (Step $f).action | Should -Be 'run-agent'
    }

    It 'shows up as a pending G2 notification' {
        $f = New-MovedFixture 'app.txt'
        $null = Step $f
        $n = @(Get-OfficePendingNotifications -OfficeRoot $f.Office)
        $n.Count | Should -Be 1
        $n[0].Gate | Should -Be 'G2'
        $n[0].Summary | Should -Match 'moved since the plan'
    }

    It 'does not compare when no plan base was recorded, and says so' {
        $f = New-MovedFixture 'app.txt'
        Set-OfficePlanBase -OfficeRoot $f.Office -Id $script:Id -Commit $null -Now $script:T0
        $in = Step $f
        $in.action | Should -Be 'run-agent'
        $in.worktree.baseCommit | Should -Be $script:NewCommit
        Thread $f | Should -Match 'No plan base recorded'
    }

    It 'checks only once: the second step reuses the worktree' {
        $f = New-MovedFixture 'docs/other.txt'
        $null = Step $f
        $b = Step $f
        $b.action | Should -Be 'run-agent'
        ([regex]::Matches((Thread $f), 'Base moved since the plan')).Count | Should -Be 1
    }

    It 'option 1 (re-plan): BUILDING -> BRIEFED with the decision id, planBase cleared, still no worktree' {
        $f = New-MovedFixture 'app.txt'
        $null = Step $f
        $r = Rule $f 1 1 'take the new migration into account'
        $r.State | Should -Be 'BRIEFED'
        $s = Item $f
        $s.pendingDecision | Should -BeNullOrEmpty
        $s['planBase'] | Should -BeNullOrEmpty
        $s['baseMove'] | Should -BeNullOrEmpty
        @($s.history)[-1].decision | Should -Be 1
        Test-Path -LiteralPath (WorktreePath $f) | Should -BeFalse
        Thread $f | Should -Match 'BUILDING -> BRIEFED \(G2 #1: re-plan on'
        Thread $f | Should -Match 'take the new migration into account'
        (Step $f).action | Should -Be 'none'
    }

    It 'option 2 (keep the plan): planBase moves to the new base and the next step creates the worktree without a second G2' {
        $f = New-MovedFixture 'app.txt'
        $null = Step $f
        $r = Rule $f 1 2
        $r.State | Should -Be 'BUILDING'
        (Item $f).planBase | Should -Be $script:NewCommit
        (Item $f)['baseMove'] | Should -BeNullOrEmpty
        $in = Step $f
        $in.action | Should -Be 'run-agent'
        $in.worktree.baseCommit | Should -Be $script:NewCommit
        (Item $f).pendingDecision | Should -BeNullOrEmpty
        Thread $f | Should -Match 'G2 #1: keep the plan'
    }

    It 'option 3 parks the work item' {
        $f = New-MovedFixture 'app.txt'
        $null = Step $f
        (Rule $f 1 3).State | Should -Be 'PARKED'
        Test-Path -LiteralPath (WorktreePath $f) | Should -BeFalse
    }

    It 'refuses a base-moved ruling whose baseMove record is gone' {
        $f = New-MovedFixture 'app.txt'
        $null = Step $f
        $null = Set-OfficePlanBase -OfficeRoot $f.Office -Id $script:Id -Commit $script:PlanCommit -Now $script:T0
        $path = Join-Path $f.Office 'work' $script:Id 'status.json'
        $s = Get-Content -Raw -Encoding utf8 $path | ConvertFrom-Json -AsHashtable
        $s.Remove('baseMove')
        [IO.File]::WriteAllText($path, ($s | ConvertTo-Json -Depth 10), $script:Utf8)
        { Rule $f 1 2 } | Should -Throw '*no matching baseMove record*'
        (Item $f).pendingDecision | Should -Be 1
    }

    It 'resolve-decision.ps1 applies a base-moved ruling' {
        $f = New-MovedFixture 'app.txt'
        $null = Step $f
        $raw = & pwsh -NoProfile -File (Join-Path $script:RepoRoot 'scripts' 'resolve-decision.ps1') -Id $script:Id -DecisionId 1 -Choice 1 -OfficeRoot $f.Office -ConfigPath $f.ConfigPath
        $out = ($raw -join "`n") | ConvertFrom-Json
        $out.ok | Should -BeTrue
        $out.kind | Should -Be 'base-moved'
        $out.state | Should -Be 'BRIEFED'
    }

    It 'leaves my own clone untouched either way' {
        $f = New-MovedFixture 'app.txt'
        $before = (G $f.Repo status --porcelain=v1) -join "`n"
        $null = Step $f
        (G $f.Repo status --porcelain=v1) -join "`n" | Should -Be $before
        @(G $f.Repo symbolic-ref --short HEAD)[0] | Should -Be 'my-work'
        (Get-Content -Raw -LiteralPath (Join-Path $f.Repo 'app.txt')).Trim() | Should -Be 'my uncommitted edit'
    }
}

Describe 'Rework from READY (Start-OfficeRework)' {
    BeforeAll {
        function To-Ready($F) {
            $wt = To-Review $F
            $r = Review $F reviewer done (RevReport (RevItem 'R-1' '建議'))
            if ($r.State -cne 'READY') { throw "setup: expected READY, got $($r.State): $($r.Reason)" }
            $wt
        }
        function Rework($F, [string]$Note = 'R-1 of review-report.md') {
            Start-OfficeRework -OfficeRoot $F.Office -Id $script:Id -Note $Note -Config $F.Config -Now $script:T0
        }
    }

    It 'records a ruled G2 rework decision and moves READY -> BUILDING as one more round' {
        $f = New-Fixture
        $null = To-Ready $f
        $r = Rework $f
        $r.State | Should -Be 'BUILDING'
        $r.Round | Should -Be 1
        $s = Item $f
        $s.pendingDecision | Should -BeNullOrEmpty
        $s.history[-1].from | Should -Be 'READY'
        $s.history[-1].decision | Should -Be $r.Decision
        $d = Decision $f $r.Decision
        $d.gate | Should -Be 'G2'
        $d.kind | Should -Be 'rework'
        $d.ruling.choice | Should -Be 1
        $d.ruling.note | Should -Be 'R-1 of review-report.md'
        Thread $f | Should -Match 'READY -> BUILDING \(round 1; G2 #\d+ rework\): R-1 of review-report\.md'
    }

    It 'gives the Builder the ruling as feedback, with all three reports' {
        $f = New-Fixture
        $null = To-Ready $f
        $r = Rework $f 'R-1; F-1 of security-report.md'
        $in = Step $f
        $in.agent | Should -Be 'builder'
        $in.feedback.from | Should -Be 'user'
        $in.feedback.report | Should -BeLike '*review-report.md'
        @($in.feedback.reports).Count | Should -Be 3
        $in.feedback.ruling.decision | Should -Be $r.Decision
        $in.feedback.ruling.note | Should -Be 'R-1; F-1 of security-report.md'
        Thread $f | Should -Match 'Rework \(round 1\) as ruled at G2'
    }

    It 'runs the loop again to READY once the Builder commits, and clears the rework record' {
        $f = New-Fixture
        $null = To-Ready $f
        $null = Rework $f
        (Build $f).State | Should -Be 'TESTING'
        (Item $f)['rework'] | Should -BeNullOrEmpty
        $null = Step $f
        (Review $f tester done $script:TestReport).State | Should -Be 'SEC_REVIEW'
        $null = Step $f
        (Review $f security done (SecReport '無')).State | Should -Be 'REVIEW'
        $null = Step $f
        (Review $f reviewer done (RevReport '無')).State | Should -Be 'READY'
    }

    It 'needs a new commit: a Builder that says done without one is BLOCKED' {
        $f = New-Fixture
        $null = To-Ready $f
        $null = Rework $f
        $null = Step $f
        $r = Complete-OfficeImplement -OfficeRoot $f.Office -Id $script:Id -ReplyText (Reply 'done') -Config $f.Config -Now $script:T0
        $r.Result | Should -Be 'blocked'
        $r.Reason | Should -Match 'no new commit since the last tested build'
    }

    It 'does not let the Builder object to a rework' {
        $f = New-Fixture
        $null = To-Ready $f
        $null = Rework $f
        $r = Build $f objection reviewer
        $r.Result | Should -Be 'blocked'
        $r.Reason | Should -Match 'my own request for this rework'
    }

    It 'allows the extra round when the rework would be over the automatic limit' {
        $f = New-Fixture
        $f.Config.maxAutoRounds = 0
        $null = To-Ready $f
        $null = Rework $f
        (Item $f)['extraRounds'] | Should -Be 1
        (Step $f).action | Should -Be 'run-agent'
    }

    It 'refuses outside READY, with a pending decision, or without a one-line note' {
        $f = New-Fixture
        { Rework $f } | Should -Throw '*starts from READY*'
        $null = To-Ready $f
        { Rework $f '   ' } | Should -Throw '*needs a note*'
        { Rework $f "a`nb" } | Should -Throw '*single line*'
        $null = New-OfficeDecision -OfficeRoot $f.Office -Id $script:Id -Gate 'G2' -Kind 'issue-changed' -Question 'q?' -Options 'a', 'b' -Now $script:T0
        { Rework $f } | Should -Throw '*is pending*'
        (Item $f).state | Should -Be 'READY'
    }

    It 'rework.ps1 prints the result as JSON, and an error as ok = false' {
        $f = New-Fixture
        $script = Join-Path $script:RepoRoot 'scripts' 'rework.ps1'
        $bad = & pwsh -NoProfile -File $script -Ref $script:Id -Note 'R-1' -OfficeRoot $f.Office -ConfigPath $f.ConfigPath | ConvertFrom-Json
        $bad.ok | Should -BeFalse
        $bad.error | Should -Match 'starts from READY'
        $null = To-Ready $f
        $ok = & pwsh -NoProfile -File $script -Ref 'grp/proj#7' -Note 'R-1' -OfficeRoot $f.Office -ConfigPath $f.ConfigPath | ConvertFrom-Json
        $ok.ok | Should -BeTrue
        $ok.state | Should -Be 'BUILDING'
        $ok.round | Should -Be 1
    }
}

Describe 'Rename-OfficeBranch' {
    BeforeAll {
        function Rename($F, [string]$Branch) {
            Rename-OfficeBranch -OfficeRoot $F.Office -Id $script:Id -Branch $Branch -Config $F.Config -Now $script:T0
        }
    }

    It 'renames the worktree branch and the build record, without touching my clone or origin' {
        $f = New-Fixture
        $wt = To-Testing $f
        $head = @(G $wt rev-parse HEAD)[0]
        $r = Rename $f 'fix/issue-7-average'
        $r.From | Should -Be 'huddle/7-fix-average'
        $r.Branch | Should -Be 'fix/issue-7-average'
        @(G $wt symbolic-ref --short HEAD)[0] | Should -Be 'fix/issue-7-average'
        @(G $wt rev-parse HEAD)[0] | Should -Be $head
        (Item $f).build.branch | Should -Be 'fix/issue-7-average'
        @(G $f.Repo branch --list 'huddle/*').Count | Should -Be 0
        @(G $f.Repo symbolic-ref --short HEAD)[0] | Should -Be 'my-work'
        @(G $f.Origin branch --list 'fix/*').Count | Should -Be 0
        Thread $f | Should -Match 'Branch renamed: huddle/7-fix-average -> fix/issue-7-average'
    }

    It 'lets the loop go on with the renamed branch, including another Builder round' {
        $f = New-Fixture
        $null = To-Testing $f
        $null = Rename $f 'fix/issue-7-average'
        $in = Step $f
        $in.agent | Should -Be 'tester'
        $in.worktree.branch | Should -Be 'fix/issue-7-average'
        (Review $f tester objection $script:TestReport).State | Should -Be 'BUILDING'
        $b = Step $f
        $b.agent | Should -Be 'builder'
        $b.worktree.branch | Should -Be 'fix/issue-7-average'
        Commit-In $b.worktree.path 'again.txt'
        (Complete-OfficeImplement -OfficeRoot $f.Office -Id $script:Id -ReplyText (Reply 'done') -Config $f.Config -Now $script:T0).State | Should -Be 'TESTING'
    }

    It 'refuses an invalid, existing or base branch name and leaves everything as it was' {
        $f = New-Fixture
        $wt = To-Testing $f
        { Rename $f 'bad..name' } | Should -Throw '*not a valid branch name*'
        { Rename $f 'main' } | Should -Throw '*base branch*'
        { Rename $f 'my-work' } | Should -Throw '*already exists*'
        { Rename $f 'huddle/7-fix-average' } | Should -Throw '*is already*'
        $null = G $f.Origin branch fix/taken
        $null = G $f.Repo fetch -q origin
        { Rename $f 'fix/taken' } | Should -Throw '*origin already has*'
        @(G $wt symbolic-ref --short HEAD)[0] | Should -Be 'huddle/7-fix-average'
        (Item $f).build.branch | Should -Be 'huddle/7-fix-average'
    }

    It 'refuses before the worktree exists, after delivery states, and once the branch was pushed' {
        $f = New-Fixture
        { Rename $f 'fix/issue-7-average' } | Should -Throw '*no worktree yet*'
        $wt = To-Testing $f
        $null = G $wt push -q origin huddle/7-fix-average
        $null = G $f.Repo fetch -q origin
        { Rename $f 'fix/issue-7-average' } | Should -Throw '*already pushed*'
        $null = Set-OfficeWorkItemState -OfficeRoot $f.Office -Id $script:Id -State 'PARKED' -Now $script:T0
        { Rename $f 'fix/issue-7-average' } | Should -Throw '*between BUILDING and READY*'
    }

    It 'rename-branch.ps1 prints the result as JSON, and an error as ok = false' {
        $f = New-Fixture
        $null = To-Testing $f
        $script = Join-Path $script:RepoRoot 'scripts' 'rename-branch.ps1'
        $bad = & pwsh -NoProfile -File $script -Ref $script:Id -Branch 'main' -OfficeRoot $f.Office -ConfigPath $f.ConfigPath | ConvertFrom-Json
        $bad.ok | Should -BeFalse
        $ok = & pwsh -NoProfile -File $script -Ref 'grp/proj#7' -Branch 'fix/issue-7-average' -OfficeRoot $f.Office -ConfigPath $f.ConfigPath | ConvertFrom-Json
        $ok.ok | Should -BeTrue
        $ok.from | Should -Be 'huddle/7-fix-average'
        $ok.branch | Should -Be 'fix/issue-7-average'
    }
}

Describe 'Reviewer agent definition' {
    BeforeAll { $script:Rev = Get-Content -Raw -Encoding utf8 (Join-Path $script:RepoRoot '.claude' 'agents' 'reviewer.md') }

    It 'inherits the session model and can neither write files nor dispatch agents' {
        $script:Rev | Should -Match '(?m)^model: inherit\s*$'
        $script:Rev | Should -Match '(?m)^tools: Read, Grep, Glob, Bash\s*$'
    }

    It 'documents every section, field, axis and verdict the completion checks' {
        foreach ($x in '範圍', '審查意見') { $script:Rev | Should -Match "(?m)^## $x\s*$" }
        foreach ($x in '面向', '判定', '位置', '說明', '建議修法') { $script:Rev | Should -Match "(?m)^- ${x}：" }
        foreach ($x in '正確性', '可讀性', '架構', '安全性', '效能', '必須修', '建議') { $script:Rev | Should -Match "``$x``" }
    }
}
