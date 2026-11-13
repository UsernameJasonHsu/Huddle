# T12: Builder plan results, G1 (raise, queue, approve, revise, park), project settings saved on approval,
# and the analysis comment draft. Uses throwaway local git repositories and a config file in $TestDrive;
# GitLab is mocked inside the Huddle module.

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    Import-Module (Join-Path $script:RepoRoot 'scripts' 'Office.psm1') -Force
    Import-Module (Join-Path $script:RepoRoot 'scripts' 'Huddle.psm1') -Force
    foreach ($v in 'GIT_AUTHOR_NAME', 'GIT_COMMITTER_NAME') { Set-Item "Env:$v" 'Huddle Test' }
    foreach ($v in 'GIT_AUTHOR_EMAIL', 'GIT_COMMITTER_EMAIL') { Set-Item "Env:$v" 'huddle-test@example.invalid' }
    $script:T0 = [datetime]::new(2026, 11, 6, 16, 0, 0)
    $script:Utf8 = [Text.UTF8Encoding]::new($false)
    $script:FullPlan = "# Plan`n## 概要`n## 分析`n## 選定做法與理由`n## 考慮過但沒採用`n無`n## 任務清單`n## 預計修改的檔案`n## 驗證與回退`n"
    $script:Done = "Plan written.`n`n``````yaml`noutcome: done`nsummary: ""plan ready""`nnext: []`n```````n"
    $script:Blocked = "Cannot plan.`n`n``````yaml`noutcome: blocked`nsummary: ""need the SMTP owner""`nnext: []`n```````n"

    function G([string]$Repo) {
        $out = & git -C $Repo @args 2>&1
        if ($LASTEXITCODE -ne 0) { throw "test git $($args -join ' ') failed: $($out -join "`n")" }
        @($out | ForEach-Object { "$_" })
    }

    # origin (main + develop) -> clone at repoPath, standing in for my own checkout (on its own branch,
    # with uncommitted work). The config file registers grp/proj with baseBranch null.
    function New-Fixture {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N').Substring(0, 8))
        $origin = Join-Path $root 'origin'
        $repo = Join-Path $root 'mine'
        New-Item -ItemType Directory -Path $origin -Force | Out-Null
        $null = G $origin init -q -b main
        Set-Content -LiteralPath (Join-Path $origin 'app.txt') -Value 'v1'
        $null = G $origin add app.txt
        $null = G $origin commit -q -m init
        $null = G $origin branch develop
        $null = & git clone -q $origin $repo 2>&1
        $null = G $repo checkout -q -b my-work
        Set-Content -LiteralPath (Join-Path $repo 'app.txt') -Value 'my uncommitted edit'

        $configPath = Join-Path $root 'office.json'
        $config = [ordered]@{
            workspaceRoot = (Join-Path $root 'ws'); unknownProject = 'auto-clone'
            maxAutoRounds = 3; maxActiveBuilds = 1; retentionDays = 30
            projects = @([ordered]@{ match = 'grp/proj'; repoPath = $repo; baseBranch = $null; commands = [ordered]@{ build = $null; test = $null } })
        }
        [IO.File]::WriteAllText($configPath, ($config | ConvertTo-Json -Depth 6), $script:Utf8)
        [pscustomobject]@{
            Root = $root; Origin = $origin; Repo = $repo; ConfigPath = $configPath
            Office = Join-Path $root 'office'
        }
    }

    function Get-Config($F) { Get-OfficeConfig -Path $F.ConfigPath }

    function Get-RepoSnapshot([string]$Repo) {
        [pscustomobject]@{
            Branch    = @(G $Repo symbolic-ref --short HEAD)[0]
            Head      = @(G $Repo rev-parse HEAD)[0]
            Status    = (G $Repo status --porcelain=v1 --untracked-files=all) -join "`n"
            Branches  = (G $Repo for-each-ref --format='%(refname)' refs/heads) -join "`n"
            Worktrees = @(G $Repo worktree list --porcelain | Where-Object { $_ -like 'worktree *' }).Count
        }
    }

    # A work item in BRIEFED (or another state reached through the real state machine).
    function New-Item-InState($F, [int]$Iid, [string]$State = 'BRIEFED', [string]$Project = 'grp/proj') {
        $s = Register-OfficeWorkItem -OfficeRoot $F.Office -ProjectPath $Project -Iid $Iid -Title "Item $Iid" `
            -WebUrl "https://gitlab.example/$Project/-/issues/$Iid" -Now $script:T0
        $path = @('BRIEFED', 'PLANNED', 'BUILDING', 'TESTING', 'SEC_REVIEW', 'REVIEW', 'READY')
        foreach ($to in $path) {
            $now = (Get-OfficeWorkItem -OfficeRoot $F.Office -Id $s.id).state
            if ($now -ceq $State) { break }
            $dec = if ($now -ceq 'PLANNED' -or $to -ceq 'READY') { 99 } else { $null }
            $null = Set-OfficeWorkItemState -OfficeRoot $F.Office -Id $s.id -State $to -DecisionId $dec -Now $script:T0
        }
        $s.id
    }

    function Write-WorkFile($F, [string]$Id, [string]$Name, [string]$Text) {
        [IO.File]::WriteAllText((Join-Path $F.Office 'work' $Id $Name), $Text, $script:Utf8)
    }

    function Write-Profile($F, [string]$Id, [hashtable]$Override = @{}) {
        $p = [ordered]@{
            match = 'grp/proj'; repoPath = $F.Repo; baseBranch = 'develop'
            commands = [ordered]@{ build = 'dotnet build'; test = 'dotnet test' }
            evidence = [ordered]@{ baseBranch = 'origin/HEAD'; build = 'README:3'; test = 'README:4' }
        }
        foreach ($k in $Override.Keys) { $p[$k] = $Override[$k] }
        Write-WorkFile $F $Id 'project-profile.json' ($p | ConvertTo-Json -Depth 4)
    }

    function Complete-Plan($F, [string]$Id, [string]$Reply = $script:Done) {
        Complete-OfficePlan -OfficeRoot $F.Office -Id $Id -ReplyText $Reply -Config (Get-Config $F) -Now $script:T0
    }

    # BRIEFED -> PLANNED with G1 raised; returns the decision id.
    function New-PlannedWithG1($F, [int]$Iid = 348) {
        $id = New-Item-InState $F $Iid
        Write-WorkFile $F $id 'plan.md' $script:FullPlan
        Write-Profile $F $id
        $r = Complete-Plan $F $id
        $r.G1.Result | Should -Be 'raised'
        [pscustomobject]@{ Id = $id; Decision = $r.G1.DecisionId }
    }
}

AfterAll {
    foreach ($v in 'GIT_AUTHOR_NAME', 'GIT_COMMITTER_NAME', 'GIT_AUTHOR_EMAIL', 'GIT_COMMITTER_EMAIL') {
        Remove-Item "Env:$v" -ErrorAction SilentlyContinue
    }
}

Describe 'Test-OfficePlan' {
    It 'lists every section for a missing file and none for a complete plan' {
        $dir = Join-Path $TestDrive 'plan-check'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        @(Test-OfficePlan -Path (Join-Path $dir 'nope.md')).Count | Should -Be 7
        [IO.File]::WriteAllText((Join-Path $dir 'plan.md'), $script:FullPlan, $script:Utf8)
        @(Test-OfficePlan -Path (Join-Path $dir 'plan.md')).Count | Should -Be 0
        [IO.File]::WriteAllText((Join-Path $dir 'p2.md'), ($script:FullPlan -replace '## 考慮過但沒採用', '## 其他'), $script:Utf8)
        Test-OfficePlan -Path (Join-Path $dir 'p2.md') | Should -Be '考慮過但沒採用'
    }
}

Describe 'Get-OfficeActiveBuilds' {
    It 'counts BUILDING..READY and paused builds, not plans or paused plans' {
        $F = New-Fixture
        $b = New-Item-InState $F 1 'BUILDING'
        $r = New-Item-InState $F 2 'READY'
        $pb = New-Item-InState $F 3 'TESTING'
        $null = Set-OfficeWorkItemState -OfficeRoot $F.Office -Id $pb -State 'PARKED' -Now $script:T0
        $null = New-Item-InState $F 4 'PLANNED'
        $pp = New-Item-InState $F 5 'PLANNED'
        $null = Set-OfficeWorkItemState -OfficeRoot $F.Office -Id $pp -State 'BLOCKED' -Now $script:T0
        @(Get-OfficeActiveBuilds -OfficeRoot $F.Office) | Should -Be @($b, $r, $pb)
        @(Get-OfficeActiveBuilds -OfficeRoot $F.Office -ExceptId $b) | Should -Be @($r, $pb)
    }
}

Describe 'Read-OfficeProjectProfile' {
    BeforeAll {
        $script:F = New-Fixture
        $script:ProfId = New-Item-InState $script:F 7
        $script:PPath = Join-Path $script:F.Office 'work' $script:ProfId 'project-profile.json'
    }

    It 'is not needed for a registered project that has a baseBranch' {
        $c = Get-Config $script:F
        $c.projects[0].baseBranch = 'main'
        (Read-OfficeProjectProfile -Config $c -ProjectPath 'grp/proj' -Path $script:PPath).Needed | Should -BeFalse
    }

    It 'accepts a valid draft for a registered project with a null baseBranch and drops evidence' {
        Write-Profile $script:F $script:ProfId
        $r = Read-OfficeProjectProfile -Config (Get-Config $script:F) -ProjectPath 'grp/proj' -Path $script:PPath
        $r.Needed | Should -BeTrue
        $r.Errors | Should -BeNullOrEmpty
        $r.Index | Should -Be 0
        $r.Entry.baseBranch | Should -Be 'develop'
        $r.Entry.commands.test | Should -Be 'dotnet test'
        $r.Entry.Contains('evidence') | Should -BeFalse
    }

    It 'rejects <Name>' -ForEach @(
        @{ Name = 'a different match'; Override = @{ match = 'grp/*' }; Expect = 'match must be' }
        @{ Name = 'a different repoPath'; Override = @{ repoPath = 'C:\elsewhere' }; Expect = 'repoPath must be' }
        @{ Name = 'an unknown key'; Override = @{ extra = 1 }; Expect = "unknown key 'extra'" }
        @{ Name = 'a branch that does not exist'; Override = @{ baseBranch = 'release' }; Expect = 'exists neither' }
        @{ Name = 'an invalid branch name'; Override = @{ baseBranch = 'a..b' }; Expect = 'not a valid branch name' }
        @{ Name = 'an empty baseBranch'; Override = @{ baseBranch = '' }; Expect = 'non-empty string' }
        @{ Name = 'a multi-line command'; Override = @{ commands = @{ build = "a`nb"; test = $null } }; Expect = 'commands.build' }
        @{ Name = 'an unknown command'; Override = @{ commands = @{ build = $null; test = $null; deploy = 'x' } }; Expect = "commands: unknown key 'deploy'" }
    ) {
        Write-Profile $script:F $script:ProfId $Override
        $r = Read-OfficeProjectProfile -Config (Get-Config $script:F) -ProjectPath 'grp/proj' -Path $script:PPath
        ($r.Errors -join '; ') | Should -BeLike "*$Expect*"
        $r.Entry | Should -BeNullOrEmpty
    }

    It 'reports a missing or unreadable draft' {
        Remove-Item -LiteralPath $script:PPath -ErrorAction SilentlyContinue
        (Read-OfficeProjectProfile -Config (Get-Config $script:F) -ProjectPath 'grp/proj' -Path $script:PPath).Errors | Should -Be 'project-profile.json is missing'
        Write-WorkFile $script:F $script:ProfId 'project-profile.json' '{ not json'
        (Read-OfficeProjectProfile -Config (Get-Config $script:F) -ProjectPath 'grp/proj' -Path $script:PPath).Errors[0] | Should -BeLike 'project-profile.json is not valid JSON*'
    }

    It 'for an unregistered project, requires its exact path and the auto-clone location' {
        $c = Get-Config $script:F
        $clone = Get-OfficeClonePath -Config $c -ProjectPath 'other/thing'
        $null = & git clone -q $script:F.Origin $clone 2>&1
        Write-Profile $script:F $script:ProfId @{ match = 'other/thing'; repoPath = $clone; baseBranch = 'main' }
        $r = Read-OfficeProjectProfile -Config $c -ProjectPath 'other/thing' -Path $script:PPath
        $r.Errors | Should -BeNullOrEmpty
        $r.Index | Should -BeNullOrEmpty
        Write-Profile $script:F $script:ProfId @{ match = 'other/thing'; repoPath = $script:F.Repo; baseBranch = 'main' }
        (Read-OfficeProjectProfile -Config $c -ProjectPath 'other/thing' -Path $script:PPath).Errors[0] | Should -BeLike 'repoPath must be*'
    }
}

Describe 'Save-OfficeProjectProfile' {
    It 'fills baseBranch and commands of the registered entry and keeps the file loadable' {
        $F = New-Fixture
        $id = New-Item-InState $F 8
        Write-Profile $F $id
        Save-OfficeProjectProfile -ConfigPath $F.ConfigPath -ProjectPath 'grp/proj' -ProfilePath (Join-Path $F.Office 'work' $id 'project-profile.json') | Should -BeTrue
        $c = Get-Config $F
        @($c.projects).Count | Should -Be 1
        $c.projects[0].baseBranch | Should -Be 'develop'
        $c.projects[0].commands.build | Should -Be 'dotnet build'
        $c.maxActiveBuilds | Should -Be 1
        Test-Path "$($F.ConfigPath).tmp" | Should -BeFalse
    }

    It 'appends an entry for an unregistered project' {
        $F = New-Fixture
        $id = New-Item-InState $F 9 'BRIEFED' 'other/thing'
        $clone = Get-OfficeClonePath -Config (Get-Config $F) -ProjectPath 'other/thing'
        $null = & git clone -q $F.Origin $clone 2>&1
        Write-Profile $F $id @{ match = 'other/thing'; repoPath = $clone; baseBranch = 'main'; commands = @{ build = $null; test = $null } }
        Save-OfficeProjectProfile -ConfigPath $F.ConfigPath -ProjectPath 'other/thing' -ProfilePath (Join-Path $F.Office 'work' $id 'project-profile.json') | Should -BeTrue
        $c = Get-Config $F
        @($c.projects).Count | Should -Be 2
        $c.projects[1].match | Should -Be 'other/thing'
        $c.projects[1].repoPath | Should -Be $clone
        $c.projects[0].baseBranch | Should -BeNullOrEmpty
    }

    It 'throws on a bad draft and leaves the config file byte for byte unchanged' {
        $F = New-Fixture
        $id = New-Item-InState $F 10
        Write-Profile $F $id @{ baseBranch = 'release' }
        $before = [IO.File]::ReadAllBytes($F.ConfigPath)
        { Save-OfficeProjectProfile -ConfigPath $F.ConfigPath -ProjectPath 'grp/proj' -ProfilePath (Join-Path $F.Office 'work' $id 'project-profile.json') } |
            Should -Throw '*cannot be saved*'
        [IO.File]::ReadAllBytes($F.ConfigPath) | Should -Be $before
    }
}

Describe 'Set-OfficeProjectCommands' {
    BeforeAll {
        $script:TestCmd = '(cd frontend && npx vitest run); docker compose run --rm -v "$(pwd -W)/backend:/app" backend python -m pytest tests/ -q'
    }

    It 'sets the test command of a registered project and leaves the rest of the config as it was' {
        $F = New-Fixture
        $r = Set-OfficeProjectCommands -ConfigPath $F.ConfigPath -Project 'grp/proj' -Test $script:TestCmd
        $r.Project | Should -Be 'grp/proj'
        $r.Before.test | Should -BeNullOrEmpty
        $r.After.test | Should -Be $script:TestCmd
        $c = Get-Config $F
        $c.projects[0].commands.test | Should -Be $script:TestCmd
        $c.projects[0].commands.build | Should -BeNullOrEmpty
        $c.projects[0].repoPath | Should -Be $F.Repo
        $c.projects[0].baseBranch | Should -BeNullOrEmpty
        $c.maxAutoRounds | Should -Be 3
        Test-Path "$($F.ConfigPath).tmp" | Should -BeFalse
    }

    It 'changes only the command that is named, and can clear one' {
        $F = New-Fixture
        $null = Set-OfficeProjectCommands -ConfigPath $F.ConfigPath -Project 'grp/proj' -Test 'npm test' -Build 'npm run build'
        $r = Set-OfficeProjectCommands -ConfigPath $F.ConfigPath -Project 'GRP/Proj' -ClearBuild
        $r.Before.build | Should -Be 'npm run build'
        $r.After.build | Should -BeNullOrEmpty
        $r.After.test | Should -Be 'npm test'
        (Get-Config $F).projects[0].commands.test | Should -Be 'npm test'
    }

    It 'is what the build loop then hands to the agents' {
        $F = New-Fixture
        $null = Set-OfficeProjectCommands -ConfigPath $F.ConfigPath -Project 'grp/proj' -Test 'npm test'
        (Resolve-OfficeProject -Config (Get-Config $F) -ProjectPath 'grp/proj').Project.commands.test | Should -Be 'npm test'
    }

    It 'refuses an unregistered project, an empty change, a multi-line command and contradicting switches' {
        $F = New-Fixture
        $before = [IO.File]::ReadAllBytes($F.ConfigPath)
        { Set-OfficeProjectCommands -ConfigPath $F.ConfigPath -Project 'other/thing' -Test 'x' } | Should -Throw '*not registered*'
        { Set-OfficeProjectCommands -ConfigPath $F.ConfigPath -Project 'grp/*' -Test 'x' } | Should -Throw '*not registered*'
        { Set-OfficeProjectCommands -ConfigPath $F.ConfigPath -Project 'grp/proj' } | Should -Throw '*Nothing to change*'
        { Set-OfficeProjectCommands -ConfigPath $F.ConfigPath -Project 'grp/proj' -Test "a`nb" } | Should -Throw '*single line*'
        { Set-OfficeProjectCommands -ConfigPath $F.ConfigPath -Project 'grp/proj' -Test 'x' -ClearTest } | Should -Throw '*not both*'
        [IO.File]::ReadAllBytes($F.ConfigPath) | Should -Be $before
    }

    It 'set-project-commands.ps1 prints the change as JSON, and an error as ok = false' {
        $F = New-Fixture
        $script = Join-Path $script:RepoRoot 'scripts' 'set-project-commands.ps1'
        $ok = & pwsh -NoProfile -File $script -Project 'grp/proj' -Test $script:TestCmd -ConfigPath $F.ConfigPath | ConvertFrom-Json
        $ok.ok | Should -BeTrue
        $ok.before.test | Should -BeNullOrEmpty
        $ok.after.test | Should -Be $script:TestCmd
        (Get-Config $F).projects[0].commands.test | Should -Be $script:TestCmd
        $bad = & pwsh -NoProfile -File $script -Project 'no/such' -Test 'x' -ConfigPath $F.ConfigPath | ConvertFrom-Json
        $bad.ok | Should -BeFalse
        $bad.error | Should -Match 'not registered'
    }
}

Describe 'Complete-OfficePlan' {
    It 'moves BRIEFED -> PLANNED and raises one G1 decision, writing nothing to the repo or config (Success Criteria #2, #9)' {
        $F = New-Fixture
        $repoBefore = Get-RepoSnapshot $F.Repo
        $configBefore = [IO.File]::ReadAllBytes($F.ConfigPath)
        $id = New-Item-InState $F 348
        Write-WorkFile $F $id 'plan.md' $script:FullPlan
        Write-Profile $F $id
        $r = Complete-Plan $F $id
        $r.Result | Should -Be 'done'
        $r.State | Should -Be 'PLANNED'
        $r.G1.Result | Should -Be 'raised'
        $s = Get-OfficeWorkItem -OfficeRoot $F.Office -Id $id
        $s.pendingDecision | Should -Be $r.G1.DecisionId
        $s.planNeedsReview | Should -BeFalse
        $d = Get-Content -Raw (Join-Path $F.Office 'work' $id 'decisions' "$($r.G1.DecisionId).json") | ConvertFrom-Json
        $d.gate | Should -Be 'G1'
        $d.kind | Should -Be 'g1'
        @($d.options).Count | Should -Be 3
        $d.question | Should -BeLike '*grp/proj#348*project settings*'
        $d.question | Should -Not -BeLike '*Item 348*' -Because 'the question goes on the Teams card, which must not carry the title'
        $d.context | Should -BeLike '*baseBranch develop*'
        (Get-RepoSnapshot $F.Repo).Worktrees | Should -Be $repoBefore.Worktrees
        (Get-RepoSnapshot $F.Repo).Branches | Should -Be $repoBefore.Branches
        [IO.File]::ReadAllBytes($F.ConfigPath) | Should -Be $configBefore
        Test-Path (Get-OfficeWorktreePath -Config (Get-Config $F) -ProjectPath 'grp/proj' -Iid 348) | Should -BeFalse
    }

    It 'shows up as a pending G1 notification' {
        $F = New-Fixture
        $p = New-PlannedWithG1 $F
        $n = @(Get-OfficePendingNotifications -OfficeRoot $F.Office)
        $n.Count | Should -Be 1
        $n[0].Gate | Should -Be 'G1'
        $n[0].DecisionId | Should -Be $p.Decision
    }

    It 'queues the plan without a decision while another work item holds the build slot (maxActiveBuilds)' {
        $F = New-Fixture
        $busy = New-Item-InState $F 1 'BUILDING'
        $id = New-Item-InState $F 2
        Write-WorkFile $F $id 'plan.md' $script:FullPlan
        Write-Profile $F $id
        $r = Complete-Plan $F $id
        $r.State | Should -Be 'PLANNED'
        $r.G1.Result | Should -Be 'queued'
        $r.G1.ActiveBuilds | Should -Be @($busy)
        (Get-OfficeWorkItem -OfficeRoot $F.Office -Id $id).pendingDecision | Should -BeNullOrEmpty
        Test-Path (Join-Path $F.Office 'work' $id 'decisions') | Should -BeFalse
        Get-Content -Raw (Join-Path $F.Office 'work' $id 'thread.md') | Should -Match 'build slot is taken'
    }

    It 'blocks (blockedBy builder) when <Name>' -ForEach @(
        @{ Name = 'plan.md lacks a section'; Plan = 'no-tasks'; Profile = $true; Reply = 'done'; Expect = '*missing sections: 任務清單*' }
        @{ Name = 'there is no plan.md'; Plan = $null; Profile = $true; Reply = 'done'; Expect = '*missing sections*' }
        @{ Name = 'the profile draft is missing'; Plan = 'full'; Profile = $false; Reply = 'done'; Expect = '*project-profile.json is missing*' }
        @{ Name = 'the Builder reports blocked'; Plan = 'full'; Profile = $true; Reply = 'blocked'; Expect = 'need the SMTP owner' }
        @{ Name = 'the reply is unparseable'; Plan = 'full'; Profile = $true; Reply = 'garbage'; Expect = 'Unparseable*' }
    ) {
        $F = New-Fixture
        $id = New-Item-InState $F 11
        if ($Plan -eq 'full') { Write-WorkFile $F $id 'plan.md' $script:FullPlan } elseif ($Plan -eq 'no-tasks') { Write-WorkFile $F $id 'plan.md' ($script:FullPlan -replace '## 任務清單\n', '') }
        if ($Profile) { Write-Profile $F $id }
        $text = switch ($Reply) { 'done' { $script:Done } 'blocked' { $script:Blocked } default { 'no yaml here' } }
        $r = Complete-Plan $F $id $text
        $r.Result | Should -Be 'blocked'
        $r.Reason | Should -BeLike $Expect
        $s = Get-OfficeWorkItem -OfficeRoot $F.Office -Id $id
        $s.state | Should -Be 'BLOCKED'
        $s.resumeTo | Should -Be 'BRIEFED'
        $s.blockedBy | Should -Be 'builder'
        $s.pendingDecision | Should -BeNullOrEmpty
        $r.G1 | Should -BeNullOrEmpty
    }

    It 'treats an objection as blocked' {
        $F = New-Fixture
        $id = New-Item-InState $F 12
        Write-WorkFile $F $id 'plan.md' $script:FullPlan
        Write-Profile $F $id
        $reply = "x`n``````yaml`noutcome: objection`nsummary: ""no""`nobjection_to: intake`n```````n"
        (Complete-Plan $F $id $reply).Reason | Should -BeLike "*'objection'*"
    }

    It 'continues from BLOCKED by the Builder to PLANNED with G1' {
        $F = New-Fixture
        $id = New-Item-InState $F 13
        $null = Complete-Plan $F $id $script:Blocked
        Write-WorkFile $F $id 'plan.md' $script:FullPlan
        Write-Profile $F $id
        $r = Complete-Plan $F $id
        $r.From | Should -Be 'BLOCKED'
        $r.State | Should -Be 'PLANNED'
        $r.G1.Result | Should -Be 'raised'
    }

    It 'refuses NEW, BLOCKED by Intake, and PLANNED with a decision pending' {
        $F = New-Fixture
        $new = New-Item-InState $F 14 'NEW'
        { Complete-Plan $F $new } | Should -Throw '*state NEW*'
        $p = New-PlannedWithG1 $F 15
        { Complete-Plan $F $p.Id } | Should -Throw '*decision #1 pending*'
        $bi = New-Item-InState $F 16
        $null = Set-OfficeWorkItemState -OfficeRoot $F.Office -Id $bi -State 'BLOCKED' -Now $script:T0
        { Complete-Plan $F $bi } | Should -Throw '*state BLOCKED*'
    }

    It 'needs no profile for a registered project that already has a baseBranch' {
        $F = New-Fixture
        $c = Get-Config $F
        $c.projects[0].baseBranch = 'main'
        $id = New-Item-InState $F 17
        Write-WorkFile $F $id 'plan.md' $script:FullPlan
        $r = Complete-OfficePlan -OfficeRoot $F.Office -Id $id -ReplyText $script:Done -Config $c -Now $script:T0
        $r.Result | Should -Be 'done'
        $d = Get-Content -Raw (Join-Path $F.Office 'work' $id 'decisions' '1.json') | ConvertFrom-Json
        $d.question | Should -Not -BeLike '*project settings*'
    }
}

Describe 'Invoke-OfficeG1Ruling' {
    It 'option 2 (not approved, revise): stays PLANNED, flags the plan, and changes nothing else' {
        $F = New-Fixture
        $p = New-PlannedWithG1 $F
        $repoBefore = Get-RepoSnapshot $F.Repo
        $configBefore = [IO.File]::ReadAllBytes($F.ConfigPath)
        $r = Invoke-OfficeG1Ruling -OfficeRoot $F.Office -Id $p.Id -DecisionId $p.Decision -Choice 2 -Note 'split the SMTP check' -ConfigPath $F.ConfigPath -Now $script:T0
        $r.State | Should -Be 'PLANNED'
        $r.PlanNeedsReview | Should -BeTrue
        $s = Get-OfficeWorkItem -OfficeRoot $F.Office -Id $p.Id
        $s.pendingDecision | Should -BeNullOrEmpty
        [IO.File]::ReadAllBytes($F.ConfigPath) | Should -Be $configBefore
        $after = Get-RepoSnapshot $F.Repo
        $after.Branches | Should -Be $repoBefore.Branches
        $after.Worktrees | Should -Be $repoBefore.Worktrees
        $after.Head | Should -Be $repoBefore.Head
        $after.Status | Should -Be $repoBefore.Status
        Get-Content -Raw (Join-Path $F.Office 'work' $p.Id 'decisions' "$($p.Decision).md") | Should -Match 'Note: split the SMTP check'
    }

    It 'option 3 (not approved, park): PARKED, config unchanged' {
        $F = New-Fixture
        $p = New-PlannedWithG1 $F
        $configBefore = [IO.File]::ReadAllBytes($F.ConfigPath)
        (Invoke-OfficeG1Ruling -OfficeRoot $F.Office -Id $p.Id -DecisionId $p.Decision -Choice 3 -ConfigPath $F.ConfigPath -Now $script:T0).State | Should -Be 'PARKED'
        [IO.File]::ReadAllBytes($F.ConfigPath) | Should -Be $configBefore
        (Get-OfficeWorkItem -OfficeRoot $F.Office -Id $p.Id).resumeTo | Should -Be 'PLANNED'
    }

    It 'option 1 (approve): saves the project settings, then PLANNED -> BUILDING with the decision id' {
        $F = New-Fixture
        $p = New-PlannedWithG1 $F
        $r = Invoke-OfficeG1Ruling -OfficeRoot $F.Office -Id $p.Id -DecisionId $p.Decision -Choice 1 -ConfigPath $F.ConfigPath -Now $script:T0
        $r.State | Should -Be 'BUILDING'
        $s = Get-OfficeWorkItem -OfficeRoot $F.Office -Id $p.Id
        $s.history[-1].from | Should -Be 'PLANNED'
        $s.history[-1].decision | Should -Be $p.Decision
        $s.pendingDecision | Should -BeNullOrEmpty
        (Get-Config $F).projects[0].baseBranch | Should -Be 'develop'
        Get-Content -Raw (Join-Path $F.Office 'work' $p.Id 'thread.md') | Should -Match 'Project settings saved to config/office.json'
    }

    It 'refuses approval, keeping the decision pending and the config unchanged, when <Name>' -ForEach @(
        @{ Name = 'the plan was flagged for review after G1 was raised'; Setup = 'review'; Expect = '*flagged for review*' }
        @{ Name = 'another work item took the build slot'; Setup = 'busy'; Expect = '*build slot is taken*' }
        @{ Name = 'the profile draft went bad'; Setup = 'profile'; Expect = '*project-profile.json*not valid*' }
    ) {
        $F = New-Fixture
        $p = New-PlannedWithG1 $F
        switch ($Setup) {
            'review' {
                Write-WorkFile $F $p.Id 'brief.md' "# Brief`n## 摘要`n## 排序依據`n## 發現於`n## 驗收條件草稿`n## 範圍`n## 相關程式碼`n## 風險標記`n## 待釐清問題`n"
                $intakeDone = "x`n``````yaml`noutcome: done`nsummary: ""re-brief""`nnext: [builder]`n```````n"
                $null = Complete-OfficeIntake -OfficeRoot $F.Office -Id $p.Id -ReplyText $intakeDone -Now $script:T0
            }
            'busy' { $null = New-Item-InState $F 2 'BUILDING' }
            'profile' { Write-Profile $F $p.Id @{ baseBranch = 'gone' } }
        }
        $configBefore = [IO.File]::ReadAllBytes($F.ConfigPath)
        { Invoke-OfficeG1Ruling -OfficeRoot $F.Office -Id $p.Id -DecisionId $p.Decision -Choice 1 -ConfigPath $F.ConfigPath -Now $script:T0 } |
            Should -Throw $Expect
        $s = Get-OfficeWorkItem -OfficeRoot $F.Office -Id $p.Id
        $s.state | Should -Be 'PLANNED'
        $s.pendingDecision | Should -Be $p.Decision
        [IO.File]::ReadAllBytes($F.ConfigPath) | Should -Be $configBefore
    }

    It 'refuses a decision that is not G1, or not pending' {
        $F = New-Fixture
        $id = New-Item-InState $F 20 'PLANNED'
        $n = New-OfficeDecision -OfficeRoot $F.Office -Id $id -Gate 'G2' -Kind 'issue-changed' -Question 'q' -Options 'a', 'b' -Now $script:T0
        { Invoke-OfficeG1Ruling -OfficeRoot $F.Office -Id $id -DecisionId $n -Choice 1 -ConfigPath $F.ConfigPath } | Should -Throw '*not a G1 decision*'
        $p = New-PlannedWithG1 $F 21
        $null = Invoke-OfficeG1Ruling -OfficeRoot $F.Office -Id $p.Id -DecisionId $p.Decision -Choice 2 -ConfigPath $F.ConfigPath -Now $script:T0
        { Invoke-OfficeG1Ruling -OfficeRoot $F.Office -Id $p.Id -DecisionId $p.Decision -Choice 1 -ConfigPath $F.ConfigPath } | Should -Throw '*not the pending decision*'
    }

    It 'after option 2, a new Builder run raises a fresh G1' {
        $F = New-Fixture
        $p = New-PlannedWithG1 $F
        $null = Invoke-OfficeG1Ruling -OfficeRoot $F.Office -Id $p.Id -DecisionId $p.Decision -Choice 2 -ConfigPath $F.ConfigPath -Now $script:T0
        { Request-OfficeG1 -OfficeRoot $F.Office -Id $p.Id -Config (Get-Config $F) } | Should -Throw '*needs review*'
        $r = Complete-Plan $F $p.Id
        $r.G1.Result | Should -Be 'raised'
        $r.G1.DecisionId | Should -Be ($p.Decision + 1)
    }
}

Describe 'Complete-OfficeAnalysisComment' {
    It 'refuses a work item that has not passed G1' {
        $F = New-Fixture
        $p = New-PlannedWithG1 $F
        { Complete-OfficeAnalysisComment -OfficeRoot $F.Office -Id $p.Id -ReplyText $script:Done } | Should -Throw '*after G1*'
    }

    It 'saves the draft between the markers to analysis-comment.md without changing the state' {
        $F = New-Fixture
        $p = New-PlannedWithG1 $F
        $null = Invoke-OfficeG1Ruling -OfficeRoot $F.Office -Id $p.Id -DecisionId $p.Decision -Choice 1 -ConfigPath $F.ConfigPath -Now $script:T0
        $reply = "Draft below.`r`n`r`n<!-- huddle:draft:begin -->`r`n`r`n## 分析與修正計畫`r`n### 根因`r`n``x``  `r`n`r`n<!-- huddle:draft:end -->`r`nnotes`r`n`r`n" + $script:Done
        $ok = Complete-OfficeAnalysisComment -OfficeRoot $F.Office -Id $p.Id -ReplyText $reply -Now $script:T0
        $ok.Result | Should -Be 'done'
        $ok.State | Should -Be 'BUILDING'
        [IO.File]::ReadAllText($ok.Path) | Should -BeExactly "## 分析與修正計畫`n### 根因`n``x```n"
        (Get-OfficeWorkItem -OfficeRoot $F.Office -Id $p.Id).state | Should -Be 'BUILDING'
    }

    It 'reports blocked and writes nothing when <Name>' -ForEach @(
        @{ Name = 'there are no markers'; Reply = 'Here is the draft: ## 分析與修正計畫'; Expect = '*exactly one*found 0 and 0*' }
        @{ Name = 'the markers are repeated'; Reply = "<!-- huddle:draft:begin -->`nA`n<!-- huddle:draft:end -->`n<!-- huddle:draft:begin -->`nB`n<!-- huddle:draft:end -->"; Expect = '*found 2 and 2*' }
        @{ Name = 'the markers are reversed'; Reply = "<!-- huddle:draft:end -->`nA`n<!-- huddle:draft:begin -->"; Expect = '*end marker comes before*' }
        @{ Name = 'the draft is empty'; Reply = "<!-- huddle:draft:begin -->`n  `n<!-- huddle:draft:end -->"; Expect = '*draft between the markers is empty*' }
        @{ Name = 'a marker is not on its own line'; Reply = "text <!-- huddle:draft:begin -->`nA`n<!-- huddle:draft:end -->"; Expect = '*found 0 and 1*' }
    ) {
        $F = New-Fixture
        $p = New-PlannedWithG1 $F
        $null = Invoke-OfficeG1Ruling -OfficeRoot $F.Office -Id $p.Id -DecisionId $p.Decision -Choice 1 -ConfigPath $F.ConfigPath -Now $script:T0
        $r = Complete-OfficeAnalysisComment -OfficeRoot $F.Office -Id $p.Id -ReplyText ("$Reply`n`n" + $script:Done) -Now $script:T0
        $r.Result | Should -Be 'blocked'
        $r.Reason | Should -BeLike $Expect
        Test-Path -LiteralPath $r.Path | Should -BeFalse
        $r.State | Should -Be 'BUILDING'
    }

    It 'does not save a draft when the Builder reports blocked' {
        $F = New-Fixture
        $p = New-PlannedWithG1 $F
        $null = Invoke-OfficeG1Ruling -OfficeRoot $F.Office -Id $p.Id -DecisionId $p.Decision -Choice 1 -ConfigPath $F.ConfigPath -Now $script:T0
        $reply = "<!-- huddle:draft:begin -->`nA`n<!-- huddle:draft:end -->`n`n" + $script:Blocked
        $r = Complete-OfficeAnalysisComment -OfficeRoot $F.Office -Id $p.Id -ReplyText $reply -Now $script:T0
        $r.Result | Should -Be 'blocked'
        Test-Path -LiteralPath $r.Path | Should -BeFalse
    }
}

Describe 'Complete-OfficeIntake records who blocked' {
    It 'sets blockedBy intake' {
        $F = New-Fixture
        $id = New-Item-InState $F 30 'NEW'
        $reply = "x`n``````yaml`noutcome: blocked`nsummary: ""q""`nnext: []`n```````n"
        $null = Complete-OfficeIntake -OfficeRoot $F.Office -Id $id -ReplyText $reply -Now $script:T0
        (Get-OfficeWorkItem -OfficeRoot $F.Office -Id $id).blockedBy | Should -Be 'intake'
    }
}

Describe 'Invoke-HuddleTakePrep planning actions' {
    BeforeEach {
        $script:F = New-Fixture
        $script:Wcfg = @{ gitlabHost = 'gitlab.example' }
        Mock -ModuleName Huddle Invoke-GitLabApi {
            , @(@{ title = 'Issue'; web_url = 'https://gitlab.example/grp/proj/-/issues/348'; state = 'opened'; updated_at = '2026-11-05T00:00:00.000Z' })
        }
        function Invoke-Prep([string]$Mode = 'take') {
            Invoke-HuddleTakePrep -Ref 'grp/proj#348' -OfficeRoot $script:F.Office -WorkItemConfig $script:Wcfg `
                -OfficeConfig (Get-Config $script:F) -Mode $Mode -Now $script:T0
        }
    }

    It 'BRIEFED: take runs the Builder in plan mode; brief (huddle-tick) does not' {
        $id = New-Item-InState $script:F 348
        $t = Invoke-Prep 'brief'
        $t.action | Should -Be 'briefed'
        $t.replyFile | Should -BeNullOrEmpty
        Get-Content -Raw (Join-Path $script:F.Office 'work' $id 'thread.md') | Should -Not -Match 'Plan requested'

        $r = Invoke-Prep
        $r.ok | Should -BeTrue
        $r.action | Should -Be 'run-planner'
        $r.agent | Should -Be 'builder'
        $r.builderMode | Should -Be 'plan'
        $r.replyFile | Should -BeLike '*replies*builder-20261106-160000.md'
        $r.planPath | Should -BeLike '*grp-proj-348*plan.md'
        $r.profile.needed | Should -BeTrue
        $r.profile.exists | Should -BeFalse
        $r.repo.baseBranch | Should -BeNullOrEmpty
        Get-Content -Raw (Join-Path $script:F.Office 'work' $id 'thread.md') | Should -Match 'office-manager → builder · assign'
    }

    It 'gives the agent a freshly fetched base commit to read, not the stale checkout (T15b)' {
        $id = New-Item-InState $script:F 348
        Set-Content -LiteralPath (Join-Path $script:F.Origin 'app.txt') -Value 'v2'
        $null = G $script:F.Origin commit -q -am 'v2 on origin'
        $new = @(G $script:F.Origin rev-parse HEAD)[0]
        $r = Invoke-Prep
        $r.action | Should -Be 'run-planner'
        $r.repo.baseRef | Should -Be 'refs/remotes/origin/HEAD'
        $r.repo.baseCommit | Should -Be $new
        $r.repo.fetched | Should -BeTrue
        $r.repo.readBaseError | Should -BeNullOrEmpty
        Get-Content -Raw (Join-Path $script:F.Office 'work' $id 'thread.md') | Should -Match ([regex]::Escape("read at $($new.Substring(0, 7))"))
        (Get-Content -Raw (Join-Path $script:F.Repo 'app.txt')).Trim() | Should -Be 'my uncommitted edit'
        # T15c: the plan's base is kept so build-step.ps1 can tell when the worktree's base is newer.
        (Get-OfficeWorkItem -OfficeRoot $script:F.Office -Id $id).planBase | Should -Be $new
    }

    It 'records no plan base for an Intake run (T15c)' {
        $id = New-Item-InState $script:F 348 'NEW'
        $r = Invoke-Prep
        $r.action | Should -Be 'run-intake'
        (Get-OfficeWorkItem -OfficeRoot $script:F.Office -Id $id)['planBase'] | Should -BeNullOrEmpty
    }

    It 'PLANNED with a ready plan: raises G1 once, then reports the pending decision' {
        $id = New-Item-InState $script:F 348 'PLANNED'
        Write-WorkFile $script:F $id 'plan.md' $script:FullPlan
        Write-Profile $script:F $id
        $r = Invoke-Prep
        $r.action | Should -Be 'g1'
        $r.g1.result | Should -Be 'raised'
        $r.g1.decision | Should -Be 1
        $again = Invoke-Prep
        $again.action | Should -Be 'pending-decision'
        $again.pendingDecision | Should -Be 1
        @(Get-ChildItem (Join-Path $script:F.Office 'work' $id 'decisions') -Filter '*.json').Count | Should -Be 1
    }

    It 'PLANNED with a plan flagged for review: runs the Builder again' {
        $p = New-PlannedWithG1 $script:F
        $null = Invoke-OfficeG1Ruling -OfficeRoot $script:F.Office -Id $p.Id -DecisionId $p.Decision -Choice 2 -ConfigPath $script:F.ConfigPath -Now $script:T0
        $r = Invoke-Prep
        $r.action | Should -Be 'run-planner'
        $r.planNeedsReview | Should -BeTrue
        $r.profile.exists | Should -BeTrue
    }

    It 'BUILDING: nothing to do' {
        $null = New-Item-InState $script:F 348 'BUILDING'
        (Invoke-Prep).action | Should -Be 'none'
    }
}

Describe 'Get-HuddleAnalysisInput' {
    It 'gives the Builder its analysis-comment input without calling GitLab' {
        $F = New-Fixture
        Mock -ModuleName Huddle Invoke-GitLabApi { throw 'must not be called' }
        $id = New-Item-InState $F 348 'BUILDING'
        $r = Get-HuddleAnalysisInput -OfficeRoot $F.Office -Id $id -WorkItemConfig @{ gitlabHost = 'gitlab.example' } -OfficeConfig (Get-Config $F) -Now $script:T0
        $r.builderMode | Should -Be 'analysis-comment'
        $r.analysisCommentPath | Should -BeLike '*grp-proj-348*analysis-comment.md'
        $r.replyFile | Should -BeLike '*builder-20261106-160000.md'
        $r.issueApi | Should -Be 'projects/grp%2Fproj/issues/348'
        $r.repo.repoPath | Should -Be $F.Repo
        $r.repo.baseCommit | Should -Be @(G $F.Origin rev-parse HEAD)[0]
        $r.repo.fetched | Should -BeTrue
    }
}

Describe 'Scripts' {
    It 'builder-complete.ps1 -Mode plan and resolve-decision.ps1 (option 2) print the expected JSON' {
        $F = New-Fixture
        $id = New-Item-InState $F 348
        Write-WorkFile $F $id 'plan.md' $script:FullPlan
        Write-Profile $F $id
        $reply = Join-Path $F.Root 'reply.md'
        [IO.File]::WriteAllText($reply, $script:Done, $script:Utf8)
        $out = pwsh -NoProfile -File (Join-Path $script:RepoRoot 'scripts' 'builder-complete.ps1') -Id $id -Mode plan -ReplyFile $reply `
            -OfficeRoot $F.Office -ConfigPath $F.ConfigPath | ConvertFrom-Json
        $out.ok | Should -BeTrue
        $out.state | Should -Be 'PLANNED'
        $out.g1.result | Should -Be 'raised'

        $configBefore = [IO.File]::ReadAllBytes($F.ConfigPath)
        $res = pwsh -NoProfile -File (Join-Path $script:RepoRoot 'scripts' 'resolve-decision.ps1') -Id $id -DecisionId $out.g1.decision -Choice 2 `
            -Note 'revise' -OfficeRoot $F.Office -ConfigPath $F.ConfigPath | ConvertFrom-Json
        $res.ok | Should -BeTrue
        $res.kind | Should -Be 'g1'
        $res.state | Should -Be 'PLANNED'
        $res.builder | Should -BeNullOrEmpty
        [IO.File]::ReadAllBytes($F.ConfigPath) | Should -Be $configBefore
    }

    It 'resolve-decision.ps1 option 1 returns the Builder analysis-comment input' {
        $F = New-Fixture
        $p = New-PlannedWithG1 $F
        $res = pwsh -NoProfile -File (Join-Path $script:RepoRoot 'scripts' 'resolve-decision.ps1') -Id $p.Id -DecisionId $p.Decision -Choice 1 `
            -OfficeRoot $F.Office -ConfigPath $F.ConfigPath | ConvertFrom-Json
        $res.ok | Should -BeTrue
        $res.state | Should -Be 'BUILDING'
        $res.builder.builderMode | Should -Be 'analysis-comment'
        $res.builder.repo.baseBranch | Should -Be 'develop'
    }
}

Describe 'Builder agent definition' {
    BeforeAll { $script:Text = Get-Content -Raw -Encoding utf8 (Join-Path $script:RepoRoot '.claude' 'agents' 'builder.md') }

    It 'inherits the session model (SPEC Q5) and has no Agent tool' {
        $script:Text | Should -Match '(?m)^model: inherit\s*$'
        $script:Text | Should -Match '(?m)^tools: Read, Grep, Glob, Bash, Write, Edit\s*$'
    }

    It 'preloads the gitlab-issue skill instead of copying its rules (SPEC §3.10)' {
        $script:Text | Should -Match '(?m)^\s+- gitlab-convention:gitlab-issue\s*$'
    }

    It 'documents every plan.md section that Complete-OfficePlan checks' {
        foreach ($s in '概要', '分析', '選定做法與理由', '考慮過但沒採用', '任務清單', '預計修改的檔案', '驗證與回退') {
            $script:Text | Should -Match "(?m)^## $s\s*$"
        }
    }
}

Describe 'Builder agent definition: analysis comment draft' {
    It 'returns the draft between the markers that Complete-OfficeAnalysisComment reads, instead of writing the file' {
        $text = Get-Content -Raw -Encoding utf8 (Join-Path $script:RepoRoot '.claude' 'agents' 'builder.md')
        $text | Should -Match '(?m)^\s*<!-- huddle:draft:begin -->\s*$'
        $text | Should -Match '(?m)^\s*<!-- huddle:draft:end -->\s*$'
        $text | Should -Not -Match '寫 `<workDir>/analysis-comment.md`'
    }
}
