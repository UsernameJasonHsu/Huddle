# T11: New-OfficeWorktree (SPEC §3.6 step 2). Uses throwaway local git repositories only:
# an "origin" repository and a clone of it that stands in for my own repoPath.

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    Import-Module (Join-Path $script:RepoRoot 'scripts' 'Office.psm1') -Force
    foreach ($v in 'GIT_AUTHOR_NAME', 'GIT_COMMITTER_NAME') { Set-Item "Env:$v" 'Huddle Test' }
    foreach ($v in 'GIT_AUTHOR_EMAIL', 'GIT_COMMITTER_EMAIL') { Set-Item "Env:$v" 'huddle-test@example.invalid' }

    function G([string]$Repo) {
        $out = & git -C $Repo @args 2>&1
        if ($LASTEXITCODE -ne 0) { throw "test git $($args -join ' ') failed: $($out -join "`n")" }
        @($out | ForEach-Object { "$_" })
    }

    function Add-Commit([string]$Repo, [string]$File, [string]$Text) {
        Set-Content -LiteralPath (Join-Path $Repo $File) -Value $Text
        $null = G $Repo add -- $File
        $null = G $Repo commit -q -m "change $File"
        @(G $Repo rev-parse HEAD)[0]
    }

    # origin (main) -> clone at repoPath; the clone is left on its own branch with uncommitted work,
    # the way I would leave my own checkout.
    function New-Fixture {
        param([string]$BaseBranch = 'main', [switch]$NoRemote)
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N').Substring(0, 8))
        $origin = Join-Path $root 'origin'
        $repo = Join-Path $root 'mine'
        New-Item -ItemType Directory -Path $origin -Force | Out-Null
        $null = G $origin init -q -b main
        $c1 = Add-Commit $origin 'app.txt' 'v1'
        if ($NoRemote) {
            $repo = $origin
        }
        else {
            $null = & git clone -q $origin $repo 2>&1
        }
        $null = G $repo checkout -q -b my-work
        Set-Content -LiteralPath (Join-Path $repo 'app.txt') -Value 'my uncommitted edit'
        Set-Content -LiteralPath (Join-Path $repo 'scratch.txt') -Value 'untracked'
        $config = @{
            workspaceRoot = (Join-Path $root 'ws')
            projects      = @(@{ match = 'grp/proj'; repoPath = $repo; baseBranch = $BaseBranch; commands = @{ build = $null; test = $null } })
        }
        [pscustomobject]@{ Root = $root; Origin = $origin; Repo = $repo; Config = $config; FirstCommit = $c1 }
    }

    function Get-RepoSnapshot([string]$Repo) {
        [pscustomobject]@{
            Branch = @(G $Repo symbolic-ref --short HEAD)[0]
            Head   = @(G $Repo rev-parse HEAD)[0]
            Status = (G $Repo status --porcelain=v1 --untracked-files=all) -join "`n"
            App    = Get-Content -Raw -LiteralPath (Join-Path $Repo 'app.txt')
        }
    }
}

AfterAll {
    foreach ($v in 'GIT_AUTHOR_NAME', 'GIT_COMMITTER_NAME', 'GIT_AUTHOR_EMAIL', 'GIT_COMMITTER_EMAIL') {
        Remove-Item "Env:$v" -ErrorAction SilentlyContinue
    }
}

Describe 'New-OfficeWorktree' {
    It 'creates the worktree at the workspace path on a huddle branch from the origin base branch' {
        $f = New-Fixture
        $w = New-OfficeWorktree -Config $f.Config -ProjectPath 'grp/proj' -Iid 5 -Title 'Fix login timeout'
        $w.Created | Should -BeTrue
        $w.Path | Should -Be (Join-Path $f.Config.workspaceRoot 'worktrees' 'grp-proj-5')
        $w.Branch | Should -Be 'huddle/5-fix-login-timeout'
        $w.BaseRef | Should -Be 'refs/remotes/origin/main'
        $w.BaseCommit | Should -Be $f.FirstCommit
        @(G $w.Path symbolic-ref --short HEAD)[0] | Should -Be 'huddle/5-fix-login-timeout'
        @(G $w.Path rev-parse HEAD)[0] | Should -Be $f.FirstCommit
        Get-Content -Raw (Join-Path $w.Path 'app.txt') | Should -Match '^v1'
        (G $w.Path status --porcelain) | Should -BeNullOrEmpty
    }

    It 'leaves repoPath working directory, index and current branch untouched' {
        $f = New-Fixture
        $null = G $f.Repo add -- app.txt   # a staged change too
        $before = Get-RepoSnapshot $f.Repo
        $null = New-OfficeWorktree -Config $f.Config -ProjectPath 'grp/proj' -Iid 5 -Title 'Fix'
        $after = Get-RepoSnapshot $f.Repo
        $after.Branch | Should -Be 'my-work'
        $after.Head | Should -Be $before.Head
        $after.Status | Should -Be $before.Status
        $after.App | Should -Be $before.App
    }

    It 'does not set an upstream on the new branch' {
        $f = New-Fixture
        $w = New-OfficeWorktree -Config $f.Config -ProjectPath 'grp/proj' -Iid 5 -Title 'Fix'
        & git -C $f.Repo config --get "branch.$($w.Branch).merge" 2>$null
        $LASTEXITCODE | Should -Not -Be 0
    }

    It 'refuses a null baseBranch and points to G1, creating nothing' {
        $f = New-Fixture -BaseBranch $null
        { New-OfficeWorktree -Config $f.Config -ProjectPath 'grp/proj' -Iid 5 -Title 'Fix' } |
            Should -Throw '*baseBranch*null*G1*'
        Test-Path (Join-Path $f.Config.workspaceRoot 'worktrees') | Should -BeFalse
        @(G $f.Repo branch --list 'huddle/*') | Should -BeNullOrEmpty
    }

    It 'refuses an unregistered project' {
        $f = New-Fixture
        { New-OfficeWorktree -Config $f.Config -ProjectPath 'other/proj' -Iid 5 } | Should -Throw '*not in config/office.json*G1*'
    }

    It 'refuses a repoPath that does not exist' {
        $f = New-Fixture
        $f.Config.projects[0].repoPath = Join-Path $f.Root 'missing'
        { New-OfficeWorktree -Config $f.Config -ProjectPath 'grp/proj' -Iid 5 } | Should -Throw '*does not exist*'
    }

    It 'refuses a base branch that exists neither on origin nor locally, creating nothing' {
        $f = New-Fixture -BaseBranch 'develop'
        { New-OfficeWorktree -Config $f.Config -ProjectPath 'grp/proj' -Iid 5 -Title 'Fix' } | Should -Throw "*'develop'*"
        Test-Path (Join-Path $f.Config.workspaceRoot 'worktrees' 'grp-proj-5') | Should -BeFalse
        @(G $f.Repo branch --list 'huddle/*') | Should -BeNullOrEmpty
    }

    It 'refuses a baseBranch that is not a valid branch name' {
        $f = New-Fixture -BaseBranch 'main..x'
        { New-OfficeWorktree -Config $f.Config -ProjectPath 'grp/proj' -Iid 5 } | Should -Throw '*check-ref-format*'
    }

    It 'prefers the origin base branch over a stale local one' {
        $f = New-Fixture
        $newer = Add-Commit $f.Origin 'app.txt' 'v2'
        $null = G $f.Repo fetch -q origin
        $w = New-OfficeWorktree -Config $f.Config -ProjectPath 'grp/proj' -Iid 6 -Title 'x'
        $w.BaseCommit | Should -Be $newer
        @(G $f.Repo rev-parse refs/heads/main)[0] | Should -Be $f.FirstCommit
    }

    It 'uses the local base branch when there is no remote-tracking branch' {
        $f = New-Fixture -NoRemote
        $w = New-OfficeWorktree -Config $f.Config -ProjectPath 'grp/proj' -Iid 7 -Title 'x'
        $w.BaseRef | Should -Be 'refs/heads/main'
        $w.BaseCommit | Should -Be $f.FirstCommit
    }

    It 'uses the commit on origin only after -Fetch' {
        $f = New-Fixture
        $newer = Add-Commit $f.Origin 'app.txt' 'v2'
        (New-OfficeWorktree -Config $f.Config -ProjectPath 'grp/proj' -Iid 8 -Title 'a').BaseCommit | Should -Be $f.FirstCommit
        (New-OfficeWorktree -Config $f.Config -ProjectPath 'grp/proj' -Iid 9 -Title 'b' -Fetch).BaseCommit | Should -Be $newer
        (Get-RepoSnapshot $f.Repo).Branch | Should -Be 'my-work'
    }

    It 'returns the existing worktree on a second call without changing it' {
        $f = New-Fixture
        $first = New-OfficeWorktree -Config $f.Config -ProjectPath 'grp/proj' -Iid 5 -Title 'Fix'
        Set-Content -LiteralPath (Join-Path $first.Path 'wip.txt') -Value 'builder work in progress'
        $second = New-OfficeWorktree -Config $f.Config -ProjectPath 'grp/proj' -Iid 5 -Title 'Fix'
        $second.Created | Should -BeFalse
        $second.Path | Should -Be $first.Path
        $second.Branch | Should -Be $first.Branch
        Test-Path (Join-Path $first.Path 'wip.txt') | Should -BeTrue
    }

    It 'refuses when the worktree path holds the work item on another branch' {
        $f = New-Fixture
        $null = New-OfficeWorktree -Config $f.Config -ProjectPath 'grp/proj' -Iid 5 -Title 'Fix'
        { New-OfficeWorktree -Config $f.Config -ProjectPath 'grp/proj' -Iid 5 -Title 'Renamed title' } | Should -Throw '*exists but is on*huddle/5-fix*'
    }

    It 'refuses when the worktree path holds a detached HEAD' {
        $f = New-Fixture
        $w = New-OfficeWorktree -Config $f.Config -ProjectPath 'grp/proj' -Iid 5 -Title 'Fix'
        $null = G $w.Path checkout -q --detach
        { New-OfficeWorktree -Config $f.Config -ProjectPath 'grp/proj' -Iid 5 -Title 'Fix' } | Should -Throw '*detached HEAD*'
    }

    It 'refuses a path that exists but is not a worktree' {
        $f = New-Fixture
        $path = Join-Path $f.Config.workspaceRoot 'worktrees' 'grp-proj-5'
        New-Item -ItemType Directory -Path $path -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $path 'keep.txt') -Value 'not mine to delete'
        { New-OfficeWorktree -Config $f.Config -ProjectPath 'grp/proj' -Iid 5 -Title 'Fix' } | Should -Throw '*not a worktree*'
        Test-Path (Join-Path $path 'keep.txt') | Should -BeTrue
    }

    It 'reuses a branch left from an earlier attempt instead of resetting it' {
        $f = New-Fixture
        $w = New-OfficeWorktree -Config $f.Config -ProjectPath 'grp/proj' -Iid 5 -Title 'Fix'
        $work = Add-Commit $w.Path 'feature.txt' 'done'
        $null = G $f.Repo worktree remove $w.Path
        $again = New-OfficeWorktree -Config $f.Config -ProjectPath 'grp/proj' -Iid 5 -Title 'Fix'
        $again.Created | Should -BeTrue
        $again.BaseRef | Should -BeNullOrEmpty
        @(G $again.Path rev-parse HEAD)[0] | Should -Be $work
    }

    It 'uses huddle/iid alone for a title without ASCII letters or digits' {
        $f = New-Fixture
        (New-OfficeWorktree -Config $f.Config -ProjectPath 'grp/proj' -Iid 12 -Title '確認匯出狀態').Branch | Should -Be 'huddle/12'
    }
}

# T15b: Intake and the Builder (plan, analysis-comment) read the code at a fetched base commit, because
# the clone's working directory is never updated. The fetch only moves remote-tracking refs.
Describe 'Update-OfficeReadBase' {
    It 'fetches the base branch and returns origin/<base> at the new commit, leaving my checkout alone' {
        $f = New-Fixture
        $new = Add-Commit $f.Origin 'app.txt' 'v2'
        $before = Get-RepoSnapshot $f.Repo
        $r = Update-OfficeReadBase -RepoPath $f.Repo -BaseBranch 'main'
        $r.baseRef | Should -Be 'refs/remotes/origin/main'
        $r.baseCommit | Should -Be $new
        $r.fetched | Should -BeTrue
        $r.error | Should -BeNullOrEmpty
        $after = Get-RepoSnapshot $f.Repo
        $after.Branch | Should -Be $before.Branch
        $after.Head | Should -Be $before.Head
        $after.Status | Should -Be $before.Status
        $after.App | Should -Be $before.App
    }

    It 'does not fetch with -NoFetch (a clone made just now is already current)' {
        $f = New-Fixture
        $null = Add-Commit $f.Origin 'app.txt' 'v2'
        $r = Update-OfficeReadBase -RepoPath $f.Repo -BaseBranch 'main' -NoFetch
        $r.fetched | Should -BeFalse
        $r.baseCommit | Should -Be $f.FirstCommit
    }

    It 'without a base branch, fetches origin and uses origin/HEAD' {
        $f = New-Fixture
        $new = Add-Commit $f.Origin 'app.txt' 'v2'
        $r = Update-OfficeReadBase -RepoPath $f.Repo -BaseBranch $null
        $r.baseRef | Should -Be 'refs/remotes/origin/HEAD'
        $r.baseCommit | Should -Be $new
    }

    It 'reports a failed fetch and falls back to the commit it already has' {
        $f = New-Fixture
        $null = G $f.Repo remote set-url origin (Join-Path $f.Root 'gone')
        $r = Update-OfficeReadBase -RepoPath $f.Repo -BaseBranch 'main'
        $r.fetched | Should -BeFalse
        $r.error | Should -Match 'fetch failed'
        $r.baseRef | Should -Be 'refs/remotes/origin/main'
        $r.baseCommit | Should -Be $f.FirstCommit
    }

    It 'uses the local base branch when there is no remote' {
        $f = New-Fixture -NoRemote
        $r = Update-OfficeReadBase -RepoPath $f.Repo -BaseBranch 'main'
        $r.baseRef | Should -Be 'refs/heads/main'
        $r.baseCommit | Should -Be $f.FirstCommit
        $r.error | Should -Match 'fetch failed'
    }

    It 'does not throw for a folder that is not a git repository' {
        $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $dir | Out-Null
        $r = Update-OfficeReadBase -RepoPath $dir -BaseBranch 'main'
        $r.baseRef | Should -BeNullOrEmpty
        $r.baseCommit | Should -BeNullOrEmpty
        $r.error | Should -Match 'not a git repository'
    }

    It 'refuses a base branch name that is not a valid ref' {
        $f = New-Fixture
        $r = Update-OfficeReadBase -RepoPath $f.Repo -BaseBranch 'bad..name'
        $r.baseRef | Should -BeNullOrEmpty
        $r.error | Should -Match 'not a valid branch name'
    }
}
