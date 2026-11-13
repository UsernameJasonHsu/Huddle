# T15: delivery READY -> DELIVERED. The MR draft is checked and saved, the push and the MR request (`glab api --method POST`)
# commands are printed (and must be gated by gate-guard), and the opened MR is recorded. GitLab is mocked
# inside the Huddle module; nothing is pushed.

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    Import-Module (Join-Path $script:RepoRoot 'scripts' 'Office.psm1') -Force
    Import-Module (Join-Path $script:RepoRoot 'scripts' 'Huddle.psm1') -Force
    Import-Module (Join-Path $script:RepoRoot 'scripts' 'GateGuard.psm1') -Force
    $script:T0 = [datetime]::new(2026, 11, 9, 14, 0, 0)
    $script:Utf8 = [Text.UTF8Encoding]::new($false)
    $script:Id = 'grp-proj-7'
    $script:Head = 'a' * 40
    $script:A1 = '> 🤖 本內容由 AI 撰寫，經開發者確認'

    # A work item in READY with a build record (written directly: these tests do not run the loop).
    function New-Fixture([string]$State = 'READY') {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N').Substring(0, 8))
        $office = Join-Path $root 'office'
        $config = @{
            workspaceRoot = (Join-Path $root 'ws'); unknownProject = 'auto-clone'; maxAutoRounds = 3; maxActiveBuilds = 1; retentionDays = 30
            projects = @(@{ match = 'grp/proj'; repoPath = (Join-Path $root 'mine'); baseBranch = 'main'; commands = @{ build = $null; test = 'pwsh -c test' } })
        }
        $configPath = Join-Path $root 'office.json'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        [IO.File]::WriteAllText($configPath, ($config | ConvertTo-Json -Depth 6), $script:Utf8)
        $null = Register-OfficeWorkItem -OfficeRoot $office -ProjectPath 'grp/proj' -Iid 7 -Title 'Fix average' -WebUrl 'https://example.invalid/grp/proj/-/issues/7' -IssueUpdatedAt '2026-11-01T00:00:00.000Z' -Now $script:T0
        $status = Join-Path $office 'work' $script:Id 'status.json'
        $s = Get-Content -Raw -Encoding utf8 $status | ConvertFrom-Json -AsHashtable
        $s.state = $State
        $s.build = [ordered]@{ worktree = (Join-Path $root 'ws' 'worktrees' $script:Id); branch = 'huddle/7-fix-average'; baseCommit = 'b' * 40; head = $script:Head; repoSnapshot = $null }
        [IO.File]::WriteAllText($status, ($s | ConvertTo-Json -Depth 6), $script:Utf8)
        [pscustomobject]@{ Root = $root; Office = $office; ConfigPath = $configPath; Config = (Get-OfficeConfig -Path $configPath) }
    }
    function Item($F) { Get-OfficeWorkItem -OfficeRoot $F.Office -Id $script:Id }
    function Prep($F, [string[]]$Labels = @('type::bug', 'backend'), [object[]]$Mrs = @(), [string]$Note) {
        Get-OfficeDeliveryInput -OfficeRoot $F.Office -Id $script:Id -Config $F.Config -Labels $Labels -OpenMrs $Mrs -Note $Note -GitLabHost 'gitlab.example.invalid' -Now $script:T0
    }
    function Draft([string]$Labels = 'type::bug', [string]$Title = 'Fix Get-Average rounding', [string]$Body) {
        if (-not $PSBoundParameters.ContainsKey('Body')) { $Body = "$script:A1`n`n## 說明`n修正平均值被捨入。`n`nCloses #7" }
        "---`ntitle: $Title`nlabels: $Labels`n---`n$Body"
    }
    function Reply([string]$Draft, [string]$Outcome = 'done') {
        $r = "Draft ready.`n`n"
        if ($null -ne $Draft) { $r += "<!-- huddle:draft:begin -->`n$Draft`n<!-- huddle:draft:end -->`n`n" }
        $r + "``````yaml`noutcome: $Outcome`nsummary: ""mr draft""`nnext: []`n```````n"
    }
    function Complete($F, [string]$Text) { Complete-OfficeMrDraft -OfficeRoot $F.Office -Id $script:Id -ReplyText $Text -Config $F.Config -Now $script:T0 }
    function Mr([int]$Iid = 3, [string]$Branch = 'huddle/7-fix-average', [string]$Sha = $script:Head) {
        @{ iid = $Iid; web_url = "https://example.invalid/grp/proj/-/merge_requests/$Iid"; source_branch = $Branch; sha = $Sha }
    }
}

Describe 'Get-OfficeDeliveryInput' {
    It 'returns the Builder mr-draft input and saves the labels it was given' {
        $f = New-Fixture
        $in = Prep $f
        $in.action | Should -Be 'run-agent'
        $in.builderMode | Should -Be 'mr-draft'
        $in.baseBranch | Should -Be 'main'
        $in.worktree.head | Should -Be $script:Head
        $in.availableLabels | Should -Be @('type::bug', 'backend')
        $in.a1Line | Should -Be $script:A1
        $in.revisionNote | Should -BeNullOrEmpty
        $ctx = Get-Content -Raw (Join-Path $f.Office 'work' $script:Id 'delivery.json') | ConvertFrom-Json
        @($ctx.labels) | Should -Be @('type::bug', 'backend')
        $ctx.head | Should -Be $script:Head
        Get-Content -Raw (Join-Path $f.Office 'work' $script:Id 'thread.md') | Should -Match 'office-manager → builder · assign'
    }

    It 'passes a revision note' {
        $f = New-Fixture
        (Prep $f -Note 'shorter title').revisionNote | Should -Be 'shorter title'
    }

    It 'stops when the branch already has an open MR (gitlab-mr G2)' {
        $f = New-Fixture
        $in = Prep $f -Mrs @(Mr 5)
        $in.action | Should -Be 'existing-mr'
        $in.reason | Should -Match '!5'
        Test-Path (Join-Path $f.Office 'work' $script:Id 'delivery.json') | Should -BeFalse
    }

    It 'does nothing outside READY' {
        $f = New-Fixture 'REVIEW'
        (Prep $f).action | Should -Be 'none'
    }
}

Describe 'Complete-OfficeMrDraft' {
    It 'saves the draft and the body, and prints the push and MR commands' {
        $f = New-Fixture
        $null = Prep $f
        $r = Complete $f (Reply (Draft))
        $r.Result | Should -Be 'done'
        $r.State | Should -Be 'READY'
        $r.Title | Should -Be 'Fix Get-Average rounding'
        $r.Labels | Should -Be @('type::bug')
        (Get-Content -Raw $r.BodyPath).StartsWith($script:A1) | Should -BeTrue
        Get-Content -Raw $r.DraftPath | Should -Match '(?m)^title: Fix Get-Average rounding$'
        $r.Commands.push | Should -Match "^git -C '.+/ws/worktrees/grp-proj-7' push origin 'huddle/7-fix-average'$"
        $r.Commands.push | Should -Not -Match ' -u | --force'
        $r.Commands.mrCreate | Should -Match "^glab api --method POST --hostname 'gitlab\.example\.invalid' 'projects/grp%2Fproj/merge_requests' -f 'source_branch=huddle/7-fix-average' -f 'target_branch=main' -f 'title=Fix Get-Average rounding' -f `"description=\`$\(cat '.+/mr-body.md'\)`" -f 'labels=type::bug'$"
    }

    It 'opens the MR through the API, not glab mr create, so no git runs in the directory it is started from' {
        # glab mr create resolves the source project from the current directory's git remote and adds a
        # remote (glab-base / glab-head) plus a fetch to it; started from my own clone, that changes my clone.
        $f = New-Fixture
        $null = Prep $f
        $r = Complete $f (Reply (Draft))
        $r.Commands.mrCreate | Should -Not -Match 'glab mr create'
        $r.Commands.mrCreate | Should -Not -Match ':(fullpath|id|repo|namespace|branch|group|user|username)\b'
        $r.Commands.mrCreate | Should -Match "--hostname 'gitlab\.example\.invalid' 'projects/grp%2Fproj/merge_requests' "
    }

    It 'leaves out labels when the draft has none' {
        $f = New-Fixture
        $null = Prep $f -Labels @()
        $r = Complete $f (Reply (Draft -Labels ''))
        $r.Result | Should -Be 'done'
        $r.Commands.mrCreate | Should -Not -Match 'labels='
    }

    It 'refuses a delivery.json without the GitLab host (written before the host was saved)' {
        $f = New-Fixture
        $null = Prep $f
        $ctxPath = Join-Path $f.Office 'work' $script:Id 'delivery.json'
        $ctx = Get-Content -Raw $ctxPath | ConvertFrom-Json -AsHashtable
        $ctx.Remove('gitlabHost')
        [IO.File]::WriteAllText($ctxPath, ($ctx | ConvertTo-Json -Depth 4), $script:Utf8)
        $r = Complete $f (Reply (Draft))
        $r.Result | Should -Be 'blocked'
        $r.Problems -join ';' | Should -Match 'gitlabHost'
        $r.Commands | Should -BeNullOrEmpty
    }

    It 'refuses a label that does not exist, and never writes the draft (L1, L2)' {
        $f = New-Fixture
        $null = Prep $f
        $r = Complete $f (Reply (Draft -Labels 'type::bug, made-up'))
        $r.Result | Should -Be 'blocked'
        $r.Problems -join ';' | Should -Match "label 'made-up' does not exist"
        $r.Commands | Should -BeNullOrEmpty
        Test-Path $r.BodyPath | Should -BeFalse
    }

    It 'requires the A1 line as the first line of the description' {
        $f = New-Fixture
        $null = Prep $f
        (Complete $f (Reply (Draft -Body "## 說明`nx`n`nCloses #7"))).Problems -join ';' | Should -Match 'must start with the line'
        (Complete $f (Reply (Draft -Body "## 說明`n$script:A1`n`nCloses #7"))).Problems -join ';' | Should -Match 'must start with the line'
        (Complete $f (Reply (Draft -Body "> 🤖 本內容由 AI 撰寫`n`nCloses #7"))).Problems -join ';' | Should -Match 'must start with the line'
    }

    It 'requires Closes #<iid>' {
        $f = New-Fixture
        $null = Prep $f
        (Complete $f (Reply (Draft -Body "$script:A1`n`nRelated to #7"))).Problems -join ';' | Should -Match "Closes #7"
        (Complete $f (Reply (Draft -Body "$script:A1`n`nCloses #70"))).Problems -join ';' | Should -Match "Closes #7"
    }

    It 'requires the front matter with title and labels' {
        $f = New-Fixture
        $null = Prep $f
        (Complete $f (Reply "$script:A1`n`nCloses #7")).Problems -join ';' | Should -Match 'front matter'
        (Complete $f (Reply "---`ntitle: x`n---`n$script:A1`nCloses #7")).Problems -join ';' | Should -Match "no 'labels:' line"
        (Complete $f (Reply "---`ntitle: x`nlabels:`nowner: me`n---`n$script:A1`nCloses #7")).Problems -join ';' | Should -Match "unknown front matter line"
    }

    It 'quotes a title with an apostrophe safely for Bash' {
        $f = New-Fixture
        $null = Prep $f
        $r = Complete $f (Reply (Draft -Title "Don't round averages"))
        $r.Commands.mrCreate | Should -Match ([regex]::Escape("-f 'title=Don'\''t round averages'"))
    }

    It 'refuses the draft when the build changed after deliver-prep' {
        $f = New-Fixture
        $null = Prep $f
        $status = Join-Path $f.Office 'work' $script:Id 'status.json'
        $s = Get-Content -Raw $status | ConvertFrom-Json -AsHashtable
        $s.build.head = 'c' * 40
        [IO.File]::WriteAllText($status, ($s | ConvertTo-Json -Depth 6), $script:Utf8)
        (Complete $f (Reply (Draft))).Problems -join ';' | Should -Match 'build changed since deliver-prep'
    }

    It 'refuses to run without deliver-prep, and outside READY' {
        $f = New-Fixture
        { Complete $f (Reply (Draft)) } | Should -Throw '*delivery.json*'
        $g = New-Fixture 'REVIEW'
        { Complete $g (Reply (Draft)) } | Should -Throw '*READY*'
    }

    It 'reports a blocked Builder without writing anything' {
        $f = New-Fixture
        $null = Prep $f
        $r = Complete $f (Reply $null 'blocked')
        $r.Result | Should -Be 'blocked'
        Test-Path $r.DraftPath | Should -BeFalse
    }
}

Describe 'The printed commands are gated (G3, Success Criteria #5)' {
    It 'asks before the push and before the MR' {
        $f = New-Fixture
        $null = Prep $f
        $r = Complete $f (Reply (Draft))
        foreach ($c in $r.Commands.push, $r.Commands.mrCreate) {
            (Get-GateDecision -Command $c -Cwd $script:RepoRoot -RepoRoot $script:RepoRoot).Decision | Should -Be 'ask'
        }
    }

    It 'also matches an ask rule in settings.json for the MR command' {
        $f = New-Fixture
        $null = Prep $f
        $r = Complete $f (Reply (Draft))
        $settings = Get-Content -Raw (Join-Path $script:RepoRoot '.claude' 'settings.json') | ConvertFrom-Json
        @($settings.permissions.ask) | Should -Contain 'Bash(glab api --method POST *)'
        @($settings.permissions.ask) | Should -Contain 'PowerShell(glab api --method POST *)'
        $r.Commands.mrCreate.StartsWith('glab api --method POST ') | Should -BeTrue
    }
}

Describe 'Complete-OfficeDelivery' {
    It 'records the MR, stores the new issue updated_at, moves to DELIVERED and frees the build slot' {
        $f = New-Fixture
        @(Get-OfficeActiveBuilds -OfficeRoot $f.Office) | Should -Be @($script:Id)
        $r = Complete-OfficeDelivery -OfficeRoot $f.Office -Id $script:Id -OpenMrs @((Mr 3 'other'), (Mr 4)) -IssueUpdatedAt '2026-11-09T06:00:00.000Z' -Now $script:T0
        $r.State | Should -Be 'DELIVERED'
        $r.MrIid | Should -Be 4
        $s = Item $f
        $s.mr.iid | Should -Be 4
        $s.mr.sha | Should -Be $script:Head
        $s.issueUpdatedAt | Should -Be '2026-11-09T06:00:00.000Z'
        @(Get-OfficeActiveBuilds -OfficeRoot $f.Office).Count | Should -Be 0
    }

    It 'records nothing without exactly one MR from the branch' {
        $f = New-Fixture
        { Complete-OfficeDelivery -OfficeRoot $f.Office -Id $script:Id -OpenMrs @() } | Should -Throw '*found 0*'
        { Complete-OfficeDelivery -OfficeRoot $f.Office -Id $script:Id -OpenMrs @((Mr 4), (Mr 5)) } | Should -Throw '*found 2*'
        (Item $f).state | Should -Be 'READY'
    }

    It 'records nothing when the MR is not at the reviewed commit' {
        $f = New-Fixture
        { Complete-OfficeDelivery -OfficeRoot $f.Office -Id $script:Id -OpenMrs @(Mr 4 -Sha ('d' * 40)) } | Should -Throw '*not the reviewed build*'
        (Item $f).state | Should -Be 'READY'
    }
}

Describe 'Huddle delivery reads (GitLab mocked)' {
    BeforeAll {
        $script:Wcfg = @{ gitlabHost = 'gitlab.example.invalid' }
    }

    It 'prep reads label names and open MRs from the branch' {
        $f = New-Fixture
        Mock -ModuleName Huddle Invoke-GitLabApi {
            if ($Endpoint -like '*/labels?*') { return , @(@{ name = 'type::bug' }, @{ name = 'severity::high' }) }
            if ($Endpoint -like '*/merge_requests?*source_branch=huddle%2F7-fix-average*') { return , @() }
            throw "unexpected endpoint $Endpoint"
        }
        $in = Invoke-HuddleDeliverPrep -OfficeRoot $f.Office -Id $script:Id -WorkItemConfig $script:Wcfg -OfficeConfig $f.Config -Now $script:T0
        $in.action | Should -Be 'run-agent'
        $in.availableLabels | Should -Be @('type::bug', 'severity::high')
        $in.gitlabHost | Should -Be 'gitlab.example.invalid'
        Should -Invoke -ModuleName Huddle Invoke-GitLabApi -Times 2 -Exactly
    }

    It 'complete reads the MR and the issue, then records the delivery' {
        $f = New-Fixture
        Mock -ModuleName Huddle Invoke-GitLabApi {
            if ($Endpoint -like '*/merge_requests?*') {
                return , @(@{ iid = 8; web_url = 'https://example.invalid/mr/8'; source_branch = 'huddle/7-other'; sha = ('e' * 40) },
                    @{ iid = 9; web_url = 'https://example.invalid/mr/9'; source_branch = 'huddle/7-fix-average'; sha = ('a' * 40) })
            }
            if ($Endpoint -like '*/issues/7') { return , @(@{ updated_at = '2026-11-09T07:00:00.000Z' }) }
            throw "unexpected endpoint $Endpoint"
        }
        $r = Invoke-HuddleDeliverComplete -OfficeRoot $f.Office -Id $script:Id -WorkItemConfig $script:Wcfg -Now $script:T0
        $r.State | Should -Be 'DELIVERED'
        $r.MrUrl | Should -Be 'https://example.invalid/mr/9'
        (Item $f).issueUpdatedAt | Should -Be '2026-11-09T07:00:00.000Z'
    }

    It 'prep sees every open MR from the branch' {
        $f = New-Fixture
        Mock -ModuleName Huddle Invoke-GitLabApi {
            if ($Endpoint -like '*/labels?*') { return , @() }
            return , @(@{ iid = 4; web_url = 'u4' }, @{ iid = 5; web_url = 'u5' })
        }
        $in = Invoke-HuddleDeliverPrep -OfficeRoot $f.Office -Id $script:Id -WorkItemConfig $script:Wcfg -OfficeConfig $f.Config -Now $script:T0
        $in.action | Should -Be 'existing-mr'
        @($in.existingMrs.iid) | Should -Be @(4, 5)
    }
}

Describe 'Builder mr-draft mode definition' {
    BeforeAll { $script:B = Get-Content -Raw -Encoding utf8 (Join-Path $script:RepoRoot '.claude' 'agents' 'builder.md') }

    It 'preloads the gitlab-mr skill and documents the front matter and A1 line' {
        $script:B | Should -Match '(?m)^\s+- gitlab-convention:gitlab-mr\s*$'
        $script:B | Should -Match '(?m)^## mr-draft 模式'
        $script:B | Should -Match 'title: <MR 標題'
        $script:B | Should -Match 'labels: <從 availableLabels 選'
        $script:B | Should -Match ([regex]::Escape($script:A1))
    }
}
