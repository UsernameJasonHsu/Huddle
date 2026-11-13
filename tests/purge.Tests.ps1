# T17: retention (SPEC §3.7). DELIVERED work items older than retentionDays are purged: worktree removed,
# local branch deleted only when a copy exists, office/work/<id>/ deleted; a dirty worktree is skipped.
# Throwaway local git repositories (origin + my clone) and an office folder in $TestDrive; no GitLab.

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    Import-Module (Join-Path $script:RepoRoot 'scripts' 'Office.psm1') -Force
    foreach ($v in 'GIT_AUTHOR_NAME', 'GIT_COMMITTER_NAME') { Set-Item "Env:$v" 'Huddle Test' }
    foreach ($v in 'GIT_AUTHOR_EMAIL', 'GIT_COMMITTER_EMAIL') { Set-Item "Env:$v" 'huddle-test@example.invalid' }
    $script:Utf8 = [Text.UTF8Encoding]::new($false)
    $script:Id = 'grp-proj-7'
    $script:Delivered = [datetime]::new(2026, 10, 1, 10, 0, 0)   # delivered on 1 Oct
    $script:Now = [datetime]::new(2026, 11, 10, 10, 0, 0)        # 40 days later

    function G([string]$Repo) {
        $out = & git -C $Repo @args 2>&1
        if ($LASTEXITCODE -ne 0) { throw "test git $($args -join ' ') failed: $($out -join "`n")" }
        @($out | ForEach-Object { "$_" })
    }

    # origin -> my clone; the work item went through the whole loop and was DELIVERED at $Delivered,
    # with a worktree on huddle/7-fix-average holding one commit.
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
        $config = @{
            workspaceRoot = (Join-Path $root 'ws'); unknownProject = 'auto-clone'
            maxAutoRounds = 3; maxActiveBuilds = 1; retentionDays = 30
            projects = @(@{ match = 'grp/proj'; repoPath = $repo; baseBranch = 'main'; commands = @{ build = $null; test = $null } })
        }
        $office = Join-Path $root 'office'
        $null = Register-OfficeWorkItem -OfficeRoot $office -ProjectPath 'grp/proj' -Iid 7 -Title 'Fix average' -WebUrl 'https://example.invalid/grp/proj/-/issues/7' -Now $script:Delivered
        foreach ($st in 'BRIEFED', 'PLANNED') { $null = Set-OfficeWorkItemState -OfficeRoot $office -Id $script:Id -State $st -Now $script:Delivered }
        $null = Set-OfficeWorkItemState -OfficeRoot $office -Id $script:Id -State 'BUILDING' -DecisionId 1 -Now $script:Delivered
        $wt = New-OfficeWorktree -Config $config -ProjectPath 'grp/proj' -Iid 7 -Title 'Fix average'
        Set-Content -LiteralPath (Join-Path $wt.Path 'fix.txt') -Value 'fixed'
        $null = G $wt.Path add fix.txt
        $null = G $wt.Path commit -q -m 'fix'
        $head = @(G $wt.Path rev-parse HEAD)[0]
        $status = Get-OfficeWorkItem -OfficeRoot $office -Id $script:Id
        $status.build = [ordered]@{ worktree = $wt.Path; branch = $wt.Branch; baseCommit = $wt.BaseCommit; head = $head; repoSnapshot = $null }
        [IO.File]::WriteAllText((Join-Path $office 'work' $script:Id 'status.json'), ($status | ConvertTo-Json -Depth 10), $script:Utf8)
        foreach ($st in 'TESTING', 'SEC_REVIEW', 'REVIEW', 'READY', 'DELIVERED') { $null = Set-OfficeWorkItemState -OfficeRoot $office -Id $script:Id -State $st -Now $script:Delivered }
        [pscustomobject]@{ Root = $root; Origin = $origin; Repo = $repo; Office = $office; Config = $config; Worktree = $wt.Path; Branch = $wt.Branch; Head = $head }
    }

    function Purge($F, [switch]$DryRun, [datetime]$At = $script:Now) { @(Invoke-OfficePurge -OfficeRoot $F.Office -Config $F.Config -DryRun:$DryRun -Now $At) }
    function WorkDir($F) { Join-Path $F.Office 'work' $script:Id }
    function PurgeLog($F) { $p = Join-Path $F.Office 'purge.log'; if (Test-Path $p) { Get-Content -Raw -Encoding utf8 $p } else { '' } }
    function Push-Branch($F) { $null = G $F.Worktree push -q origin $F.Branch }
}

AfterAll {
    foreach ($v in 'GIT_AUTHOR_NAME', 'GIT_COMMITTER_NAME', 'GIT_AUTHOR_EMAIL', 'GIT_COMMITTER_EMAIL') { Remove-Item "Env:$v" -ErrorAction SilentlyContinue }
}

Describe 'Invoke-OfficePurge' {
    It 'keeps a work item delivered less than retentionDays ago' {
        $f = New-Fixture
        $r = Purge $f -At ([datetime]::new(2026, 10, 20, 10, 0, 0))
        $r.Count | Should -Be 1
        $r[0].result | Should -Be 'kept'
        $r[0].ageDays | Should -Be 19
        Test-Path (WorkDir $f) | Should -BeTrue
        Test-Path $f.Worktree | Should -BeTrue
        PurgeLog $f | Should -Be ''
    }

    It 'purges after retentionDays: worktree removed, branch deleted when origin has it, folder deleted, log written' {
        $f = New-Fixture
        Push-Branch $f
        $r = Purge $f
        $r[0].result | Should -Be 'purged'
        $r[0].ageDays | Should -Be 40
        $r[0].reason | Should -Match 'worktree removed; branch huddle/7-fix-average deleted; office/work folder deleted'
        Test-Path $f.Worktree | Should -BeFalse
        Test-Path (WorkDir $f) | Should -BeFalse
        (G $f.Repo branch --list $f.Branch) -join '' | Should -Be ''
        (G $f.Repo worktree list --porcelain) -join "`n" | Should -Not -Match 'grp-proj-7'
        PurgeLog $f | Should -Match 'grp/proj#7 \(grp-proj-7\) purged after 40 day\(s\)'
        (Get-OfficeSummary -OfficeRoot $f.Office).Idle | Should -BeTrue
    }

    It 'keeps the local branch when no copy exists anywhere, but still removes the worktree and folder' {
        $f = New-Fixture
        $r = Purge $f
        $r[0].result | Should -Be 'purged'
        $r[0].reason | Should -Match 'branch huddle/7-fix-average kept \(no copy on origin\)'
        (G $f.Repo branch --list $f.Branch) -join '' | Should -Match 'huddle/7-fix-average'
        @(G $f.Repo rev-parse $f.Branch)[0] | Should -Be $f.Head
        Test-Path $f.Worktree | Should -BeFalse
        Test-Path (WorkDir $f) | Should -BeFalse
    }

    It 'deletes the local branch when origin/main already contains it (merged, source branch removed)' {
        $f = New-Fixture
        # The MR was merged and its source branch removed: origin/main contains the commit, origin has no branch.
        Push-Branch $f
        $null = G $f.Origin merge -q --ff-only $f.Branch
        $null = G $f.Origin branch -D $f.Branch
        @(G $f.Repo ls-remote --heads origin $f.Branch).Count | Should -Be 0
        $r = Purge $f
        $r[0].reason | Should -Match 'branch huddle/7-fix-average deleted'
        (G $f.Repo branch --list $f.Branch) -join '' | Should -Be ''
    }

    It 'skips a work item whose worktree has uncommitted changes, warns in /huddle, and touches nothing' {
        $f = New-Fixture
        Set-Content -LiteralPath (Join-Path $f.Worktree 'wip.txt') -Value 'not committed'
        $r = Purge $f
        $r[0].result | Should -Be 'skipped'
        $r[0].reason | Should -Match 'uncommitted changes: \?\? wip\.txt'
        Test-Path $f.Worktree | Should -BeTrue
        Test-Path (WorkDir $f) | Should -BeTrue
        $s = Get-OfficeWorkItem -OfficeRoot $f.Office -Id $script:Id
        $s.state | Should -Be 'DELIVERED'
        $s.purgeWarning | Should -Match 'Purge skipped: worktree has uncommitted changes'
        PurgeLog $f | Should -Match 'skipped: worktree has uncommitted changes'
        $brief = Format-OfficeBrief -Summary (Get-OfficeSummary -OfficeRoot $f.Office)
        ($brief.Display -join "`n") | Should -Match 'warning: Purge skipped'
        ($brief.Context -join "`n") | Should -Match 'Warning for grp/proj#7: Purge skipped'
    }

    It 'purges once the uncommitted changes are gone' {
        $f = New-Fixture
        Set-Content -LiteralPath (Join-Path $f.Worktree 'wip.txt') -Value 'not committed'
        $null = Purge $f
        Remove-Item (Join-Path $f.Worktree 'wip.txt')
        (Purge $f)[0].result | Should -Be 'purged'
        Test-Path (WorkDir $f) | Should -BeFalse
    }

    It '-DryRun reports would-purge / skipped and changes nothing' {
        $f = New-Fixture
        $r = Purge $f -DryRun
        $r[0].result | Should -Be 'would-purge'
        Test-Path $f.Worktree | Should -BeTrue
        Test-Path (WorkDir $f) | Should -BeTrue
        PurgeLog $f | Should -Be ''
        Set-Content -LiteralPath (Join-Path $f.Worktree 'wip.txt') -Value 'x'
        (Purge $f -DryRun)[0].result | Should -Be 'skipped'
        (Get-OfficeWorkItem -OfficeRoot $f.Office -Id $script:Id)['purgeWarning'] | Should -BeNullOrEmpty
        PurgeLog $f | Should -Be ''
    }

    It 'purges a work item whose worktree folder was already removed by hand' {
        $f = New-Fixture
        Remove-Item -Recurse -Force $f.Worktree
        $r = Purge $f
        $r[0].result | Should -Be 'purged'
        $r[0].reason | Should -Match 'worktree already gone \(pruned\)'
        (G $f.Repo worktree list --porcelain) -join "`n" | Should -Not -Match 'grp-proj-7'
        Test-Path (WorkDir $f) | Should -BeFalse
    }

    It 'ignores work items in other states' {
        $f = New-Fixture
        $path = Join-Path (WorkDir $f) 'status.json'
        $s = Get-Content -Raw -Encoding utf8 $path | ConvertFrom-Json -AsHashtable
        $s.state = 'READY'
        [IO.File]::WriteAllText($path, ($s | ConvertTo-Json -Depth 10), $script:Utf8)
        (Purge $f).Count | Should -Be 0
        Test-Path $f.Worktree | Should -BeTrue
    }

    It 'leaves my own clone checkout untouched' {
        $f = New-Fixture
        Push-Branch $f
        Set-Content -LiteralPath (Join-Path $f.Repo 'app.txt') -Value 'my uncommitted edit'
        $null = Purge $f
        @(G $f.Repo symbolic-ref --short HEAD)[0] | Should -Be 'my-work'
        (Get-Content -Raw (Join-Path $f.Repo 'app.txt')).Trim() | Should -Be 'my uncommitted edit'
    }

    It 'office-purge.ps1 prints the rows and honours -DryRun' {
        $f = New-Fixture
        $cfg = Join-Path $f.Root 'office.json'
        [IO.File]::WriteAllText($cfg, ($f.Config | ConvertTo-Json -Depth 6), $script:Utf8)
        $raw = & pwsh -NoProfile -File (Join-Path $script:RepoRoot 'scripts' 'office-purge.ps1') -DryRun -OfficeRoot $f.Office -ConfigPath $cfg
        $out = ($raw -join "`n") | ConvertFrom-Json
        $out.ok | Should -BeTrue
        $out.dryRun | Should -BeTrue
        @($out.items).Count | Should -Be 1
        Test-Path (WorkDir $f) | Should -BeTrue
    }
}
