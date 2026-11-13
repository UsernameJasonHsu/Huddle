# Office core (T4): config loading, work item registration, the state machine (SPEC §3.3),
# append-only thread.md (SPEC §5) and the office summary. Everything runs inside $TestDrive.

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    Import-Module (Join-Path $script:RepoRoot 'scripts' 'Office.psm1') -Force

    $script:T0 = [datetime]::new(2026, 11, 5, 14, 32, 0)

    function New-Office {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $root | Out-Null
        $root
    }

    function Register-Test {
        param([string]$Root, [int]$Iid = 348, [string]$Project = 'acme/SupportDesk')
        Register-OfficeWorkItem -OfficeRoot $Root -ProjectPath $Project -Iid $Iid -Title "Item $Iid" `
            -WebUrl "https://gitlab.example/$Project/-/work_items/$Iid" -Now $script:T0
    }

    # Walks a registered item through the given states with valid decision ids where gates need one.
    function Move-Test {
        param([string]$Root, [string]$Id, [string[]]$States)
        foreach ($s in $States) {
            $current = (Get-OfficeWorkItem -OfficeRoot $Root -Id $Id).state
            $needsDecision = -not (Test-OfficeTransition -From $current -To $s)
            if ($needsDecision) {
                Set-OfficeWorkItemState -OfficeRoot $Root -Id $Id -State $s -DecisionId 1 -Now $script:T0 | Out-Null
            }
            else {
                Set-OfficeWorkItemState -OfficeRoot $Root -Id $Id -State $s -Now $script:T0 | Out-Null
            }
        }
    }
}

Describe 'Get-OfficeConfig' {
    It 'loads the committed config/office.example.json' {
        $c = Get-OfficeConfig -Path (Join-Path $script:RepoRoot 'config' 'office.example.json')
        $c.maxAutoRounds | Should -Be 3
        $c.maxActiveBuilds | Should -Be 1
        $c.retentionDays | Should -Be 30
        $c.unknownProject | Should -Be 'auto-clone'
        $c.projects[0].match | Should -Be 'acme/SupportDesk'
    }

    It 'keeps unverified project settings null instead of guessing (SPEC §3.6)' {
        # A fixture, not the committed config: G1 approval fills the real file's baseBranch and commands
        # (resolve-decision.ps1), so the committed values change as work items are approved.
        $path = Join-Path $TestDrive 'nulls.json'
        '{ "workspaceRoot": "C:\\x", "unknownProject": "auto-clone", "maxAutoRounds": 3, "maxActiveBuilds": 1, "retentionDays": 30,' +
        '  "projects": [ { "match": "g/p", "repoPath": "C:\\p", "baseBranch": null, "commands": { "build": null, "test": null } } ] }' |
            Set-Content -LiteralPath $path -Encoding utf8
        $p = (Get-OfficeConfig -Path $path).projects[0]
        $p.baseBranch | Should -BeNullOrEmpty
        $p.commands.build | Should -BeNullOrEmpty
        $p.commands.test | Should -BeNullOrEmpty
    }

    It 'rejects a config with a missing required key' {
        $path = Join-Path $TestDrive 'bad.json'
        '{ "workspaceRoot": "C:\\x", "unknownProject": "auto-clone", "maxActiveBuilds": 1, "retentionDays": 30, "projects": [] }' |
            Set-Content -LiteralPath $path -Encoding utf8
        { Get-OfficeConfig -Path $path } | Should -Throw '*maxAutoRounds*'
    }

    It 'rejects an unsupported unknownProject mode' {
        $path = Join-Path $TestDrive 'bad2.json'
        '{ "workspaceRoot": "C:\\x", "unknownProject": "ignore", "maxAutoRounds": 3, "maxActiveBuilds": 1, "retentionDays": 30, "projects": [] }' |
            Set-Content -LiteralPath $path -Encoding utf8
        { Get-OfficeConfig -Path $path } | Should -Throw '*unknownProject*'
    }

    It 'rejects a non-positive limit' {
        $path = Join-Path $TestDrive 'bad3.json'
        '{ "workspaceRoot": "C:\\x", "unknownProject": "auto-clone", "maxAutoRounds": 0, "maxActiveBuilds": 1, "retentionDays": 30, "projects": [] }' |
            Set-Content -LiteralPath $path -Encoding utf8
        { Get-OfficeConfig -Path $path } | Should -Throw '*maxAutoRounds*'
    }
}

Describe 'Get-OfficeWorkItemId' {
    It 'joins the lower-cased project path and iid' {
        Get-OfficeWorkItemId -ProjectPath 'acme/SupportDesk' -Iid 348 | Should -Be 'acme-supportdesk-348'
    }

    It 'flattens nested namespaces' {
        Get-OfficeWorkItemId -ProjectPath 'tools/portal/portal' -Iid 7 | Should -Be 'tools-portal-portal-7'
    }

    It 'replaces characters that are unsafe in a folder name' {
        Get-OfficeWorkItemId -ProjectPath 'a b/c:d' -Iid 1 | Should -Be 'a-b-c-d-1'
    }
}

Describe 'Project resolution and path naming (T6)' {
    BeforeAll {
        # A drive letter that is unlikely to exist proves no path is resolved against the file system.
        $script:Cfg = @{
            workspaceRoot  = 'Q:\huddle-workspace'
            unknownProject = 'auto-clone'
            projects       = @(
                @{ match = 'acme/SupportDesk'; repoPath = 'Q:\src\SupportDesk'; baseBranch = $null; commands = @{} },
                @{ match = 'tools/portal/*'; repoPath = 'Q:\src\portal'; baseBranch = 'develop'; commands = @{} },
                @{ match = 'tools/*'; repoPath = 'Q:\src\tools-any'; baseBranch = $null; commands = @{} }
            )
        }
    }

    Context 'Resolve-OfficeProject' {
        It 'resolves a registered project to its repoPath' {
            $r = Resolve-OfficeProject -Config $script:Cfg -ProjectPath 'acme/SupportDesk'
            $r.Registered | Should -BeTrue
            $r.RepoPath | Should -Be 'Q:\src\SupportDesk'
            $r.Project.match | Should -Be 'acme/SupportDesk'
        }

        It 'matches case-insensitively like projectPriority' {
            (Resolve-OfficeProject -Config $script:Cfg -ProjectPath 'ACME/supportdesk').RepoPath |
                Should -Be 'Q:\src\SupportDesk'
        }

        It 'resolves a wildcard match and takes the first matching entry' {
            $r = Resolve-OfficeProject -Config $script:Cfg -ProjectPath 'tools/portal/portal'
            $r.Registered | Should -BeTrue
            $r.Project.match | Should -Be 'tools/portal/*'
            $r.Project.baseBranch | Should -Be 'develop'
            (Resolve-OfficeProject -Config $script:Cfg -ProjectPath 'tools/rpa/ssl-monitor').Project.match |
                Should -Be 'tools/*'
        }

        It 'resolves an unregistered project to the auto-clone path' {
            $r = Resolve-OfficeProject -Config $script:Cfg -ProjectPath 'jason/huddle-sandbox'
            $r.Registered | Should -BeFalse
            $r.Project | Should -BeNullOrEmpty
            $r.RepoPath | Should -Be 'Q:\huddle-workspace\repos\jason\huddle-sandbox'
        }

        It 'treats an empty registry as all unregistered' {
            $cfg = @{ workspaceRoot = 'Q:\w'; projects = @() }
            (Resolve-OfficeProject -Config $cfg -ProjectPath 'a/b').Registered | Should -BeFalse
        }

        It 'resolves against the committed config/office.example.json' {
            $c = Get-OfficeConfig -Path (Join-Path $script:RepoRoot 'config' 'office.example.json')
            (Resolve-OfficeProject -Config $c -ProjectPath 'acme/SupportDesk').Registered | Should -BeTrue
            (Resolve-OfficeProject -Config $c -ProjectPath 'tools/portal/portal').Registered | Should -BeFalse
        }
    }

    Context 'Get-OfficeClonePath' {
        It 'keeps nested namespaces as nested folders' {
            Get-OfficeClonePath -Config $script:Cfg -ProjectPath 'tools/rpa/ssl-monitor' |
                Should -Be 'Q:\huddle-workspace\repos\tools\rpa\ssl-monitor'
        }

        It 'rejects project paths that could escape the workspace: <Path>' -ForEach @(
            @{ Path = '../evil' }, @{ Path = 'a/../../b' }, @{ Path = 'a/..' }, @{ Path = 'single' },
            @{ Path = 'a//b' }, @{ Path = 'a/b\c' }, @{ Path = 'C:/x' }, @{ Path = 'a/.hidden' }
        ) {
            { Get-OfficeClonePath -Config $script:Cfg -ProjectPath $Path } | Should -Throw
            { Resolve-OfficeProject -Config $script:Cfg -ProjectPath $Path } | Should -Throw
        }

        It 'rejects a relative workspaceRoot' {
            { Get-OfficeClonePath -Config @{ workspaceRoot = 'relative\ws' } -ProjectPath 'a/b' } |
                Should -Throw '*workspaceRoot*'
        }
    }

    Context 'Get-OfficeWorktreePath' {
        It 'uses the office work item id as the folder name' {
            Get-OfficeWorktreePath -Config $script:Cfg -ProjectPath 'acme/SupportDesk' -Iid 348 |
                Should -Be 'Q:\huddle-workspace\worktrees\acme-supportdesk-348'
        }

        It 'flattens nested namespaces' {
            Get-OfficeWorktreePath -Config $script:Cfg -ProjectPath 'tools/portal/portal' -Iid 407 |
                Should -Be 'Q:\huddle-workspace\worktrees\tools-portal-portal-407'
        }
    }

    Context 'Get-OfficeBranchName' {
        It 'slugs a mixed CJK / ASCII title: <Title>' -ForEach @(
            @{ Title = '[DESK-91] [報表] Export Filters：報表頁提供可一鍵套用的 filter'; Iid = 422
               Expected = 'huddle/422-desk-91-export-filters-filter' }
            @{ Title = '確認 STAGING 匯出排程：手冊記載 STAGING 未啟用 nightly export 工作'; Iid = 348
               Expected = 'huddle/348-staging-staging-nightly-export' }
            @{ Title = '[Feature] 報表匯出逾時檢查（CSV）'; Iid = 12; Expected = 'huddle/12-feature-csv' }
        ) {
            Get-OfficeBranchName -Iid $Iid -Title $Title | Should -Be $Expected
        }

        It 'folds full-width letters and accents to ASCII' {
            Get-OfficeBranchName -Iid 5 -Title 'ＡＩ Café' | Should -Be 'huddle/5-ai-cafe'
        }

        It 'falls back to huddle/<iid> when nothing ASCII is left' {
            Get-OfficeBranchName -Iid 9 -Title '修正登入問題' | Should -Be 'huddle/9'
            Get-OfficeBranchName -Iid 9 -Title '' | Should -Be 'huddle/9'
        }

        It 'caps the slug length without leaving a trailing dash' {
            $b = Get-OfficeBranchName -Iid 1 -Title ('abcd ' * 30)
            ($b -replace '^huddle/1-', '').Length | Should -BeLessOrEqual 40
            $b | Should -Not -Match '-$'
        }

        It 'produces a valid git branch name for awkward titles: <Title>' -ForEach @(
            @{ Title = '..lock' }, @{ Title = 'a..b.lock' }, @{ Title = '~^:?*[\ @{' }, @{ Title = '/leading/slash/' },
            @{ Title = '中文 / 標題 .. 測試' }, @{ Title = "tab`tand`nnewline" }, @{ Title = 'emoji 🚀 rocket' },
            @{ Title = '-dash-start' }, @{ Title = ('x' * 200) }
        ) {
            $b = Get-OfficeBranchName -Iid 42 -Title $Title
            $b | Should -Match '^huddle/42(-[a-z0-9]+)*$'
            & git check-ref-format --branch $b | Out-Null
            $LASTEXITCODE | Should -Be 0
        }

        It 'rejects a non-positive iid' {
            { Get-OfficeBranchName -Iid 0 -Title 'x' } | Should -Throw
        }
    }
}

Describe 'Register-OfficeWorkItem' {
    It 'creates the work item folder with status.json in state NEW' {
        $root = New-Office
        $s = Register-Test $root
        $s.id | Should -Be 'acme-supportdesk-348'
        $s.state | Should -Be 'NEW'
        $s.round | Should -Be 0
        $s.resumeTo | Should -BeNullOrEmpty
        $s.pendingDecision | Should -BeNullOrEmpty
        Test-Path (Join-Path $root 'work' 'acme-supportdesk-348' 'status.json') | Should -BeTrue
        Test-Path (Join-Path $root 'work' 'acme-supportdesk-348' 'thread.md') | Should -BeTrue
    }

    It 'is idempotent: registering twice keeps one folder and does not reset state (SC #13)' {
        $root = New-Office
        $id = (Register-Test $root).id
        Move-Test $root $id 'BRIEFED'
        $again = Register-Test $root
        $again.state | Should -Be 'BRIEFED'
        @(Get-ChildItem -Directory (Join-Path $root 'work')).Count | Should -Be 1
    }

    It 'stores the reference data given at registration' {
        $root = New-Office
        $s = Register-Test $root -Iid 12 -Project 'tools/rpa/ssl-monitor'
        $s.project | Should -Be 'tools/rpa/ssl-monitor'
        $s.iid | Should -Be 12
        $s.title | Should -Be 'Item 12'
        $s.webUrl | Should -Be 'https://gitlab.example/tools/rpa/ssl-monitor/-/work_items/12'
    }
}

Describe 'Test-OfficeTransition' {
    It 'allows <From> -> <To>' -ForEach @(
        @{ From = 'NEW'; To = 'BRIEFED' }
        @{ From = 'BRIEFED'; To = 'PLANNED' }
        @{ From = 'BUILDING'; To = 'TESTING' }
        @{ From = 'TESTING'; To = 'BUILDING' }
        @{ From = 'TESTING'; To = 'SEC_REVIEW' }
        @{ From = 'SEC_REVIEW'; To = 'BUILDING' }
        @{ From = 'BUILDING'; To = 'REVIEW' }
        @{ From = 'REVIEW'; To = 'BUILDING' }
        @{ From = 'SEC_REVIEW'; To = 'REVIEW' }
        @{ From = 'REVIEW'; To = 'READY' }
        @{ From = 'READY'; To = 'DELIVERED' }
        @{ From = 'DELIVERED'; To = 'PURGED' }
        @{ From = 'NEW'; To = 'BLOCKED' }
        @{ From = 'BUILDING'; To = 'PARKED' }
        @{ From = 'READY'; To = 'BLOCKED' }
    ) {
        Test-OfficeTransition -From $From -To $To | Should -BeTrue
    }

    It 'rejects <From> -> <To>' -ForEach @(
        @{ From = 'NEW'; To = 'BUILDING' }
        @{ From = 'NEW'; To = 'PLANNED' }
        @{ From = 'BRIEFED'; To = 'BUILDING' }
        @{ From = 'READY'; To = 'BUILDING' }
        @{ From = 'DELIVERED'; To = 'READY' }
        @{ From = 'PURGED'; To = 'NEW' }
        @{ From = 'BUILDING'; To = 'BUILDING' }
        @{ From = 'DELIVERED'; To = 'PARKED' }
        @{ From = 'PURGED'; To = 'BLOCKED' }
        @{ From = 'PARKED'; To = 'BLOCKED' }
        @{ From = 'BUILDING'; To = 'DELIVERED' }
    ) {
        Test-OfficeTransition -From $From -To $To | Should -BeFalse
    }

    It 'requires a decision id for the G1 transition PLANNED -> BUILDING' {
        Test-OfficeTransition -From 'PLANNED' -To 'BUILDING' | Should -BeFalse
        Test-OfficeTransition -From 'PLANNED' -To 'BUILDING' -DecisionId 1 | Should -BeTrue
    }

    It 'requires a decision id to re-plan: BUILDING -> BRIEFED (G2 base-moved, T15c), and only from BUILDING' {
        Test-OfficeTransition -From 'BUILDING' -To 'BRIEFED' | Should -BeFalse
        Test-OfficeTransition -From 'BUILDING' -To 'BRIEFED' -DecisionId 1 | Should -BeTrue
        Test-OfficeTransition -From 'TESTING' -To 'BRIEFED' -DecisionId 1 | Should -BeFalse
        Test-OfficeTransition -From 'BUILDING' -To 'PLANNED' -DecisionId 1 | Should -BeFalse
    }

    It 'requires a decision id for a rework: READY -> BUILDING (G2 rework), and only to BUILDING' {
        Test-OfficeTransition -From 'READY' -To 'BUILDING' | Should -BeFalse
        Test-OfficeTransition -From 'READY' -To 'BUILDING' -DecisionId 2 | Should -BeTrue
        Test-OfficeTransition -From 'READY' -To 'TESTING' -DecisionId 2 | Should -BeFalse
        Test-OfficeTransition -From 'DELIVERED' -To 'BUILDING' -DecisionId 2 | Should -BeFalse
    }

    It 'requires a decision id (G2) to reach READY from <From>' -ForEach @(
        @{ From = 'BUILDING' }, @{ From = 'TESTING' }, @{ From = 'SEC_REVIEW' }
    ) {
        Test-OfficeTransition -From $From -To 'READY' | Should -BeFalse
        Test-OfficeTransition -From $From -To 'READY' -DecisionId 3 | Should -BeTrue
    }

    It 'only lets PARKED / BLOCKED resume to the state they were entered from' {
        Test-OfficeTransition -From 'PARKED' -To 'BUILDING' -ResumeTo 'BUILDING' | Should -BeTrue
        Test-OfficeTransition -From 'PARKED' -To 'READY' -ResumeTo 'BUILDING' | Should -BeFalse
        Test-OfficeTransition -From 'BLOCKED' -To 'NEW' -ResumeTo 'NEW' | Should -BeTrue
        Test-OfficeTransition -From 'BLOCKED' -To 'NEW' | Should -BeFalse
    }

    It 'throws on an unknown state name' {
        { Test-OfficeTransition -From 'NEW' -To 'DONE' } | Should -Throw '*DONE*'
    }
}

Describe 'Set-OfficeWorkItemState' {
    It 'throws on an illegal transition and leaves status.json unchanged' {
        $root = New-Office
        $id = (Register-Test $root).id
        { Set-OfficeWorkItemState -OfficeRoot $root -Id $id -State 'BUILDING' } | Should -Throw '*NEW*BUILDING*'
        (Get-OfficeWorkItem -OfficeRoot $root -Id $id).state | Should -Be 'NEW'
    }

    It 'throws for a work item that is not registered' {
        $root = New-Office
        { Set-OfficeWorkItemState -OfficeRoot $root -Id 'nope-1' -State 'BRIEFED' } | Should -Throw '*nope-1*'
    }

    It 'records each transition in history with the decision id' {
        $root = New-Office
        $id = (Register-Test $root).id
        Move-Test $root $id 'BRIEFED', 'PLANNED'
        $s = Set-OfficeWorkItemState -OfficeRoot $root -Id $id -State 'BUILDING' -DecisionId 4 -Now $script:T0
        $s.state | Should -Be 'BUILDING'
        $last = $s.history[-1]
        $last.from | Should -Be 'PLANNED'
        $last.to | Should -Be 'BUILDING'
        $last.decision | Should -Be 4
    }

    It 'counts a return to BUILDING from <From> as one round' -ForEach @(
        @{ From = 'TESTING' }, @{ From = 'SEC_REVIEW' }, @{ From = 'REVIEW' }
    ) {
        $root = New-Office
        $id = (Register-Test $root).id
        Move-Test $root $id 'BRIEFED', 'PLANNED', 'BUILDING', $From
        (Get-OfficeWorkItem -OfficeRoot $root -Id $id).round | Should -Be 0
        Move-Test $root $id 'BUILDING'
        (Get-OfficeWorkItem -OfficeRoot $root -Id $id).round | Should -Be 1
    }

    It 'does not count the first entry into BUILDING (from PLANNED) as a round' {
        $root = New-Office
        $id = (Register-Test $root).id
        Move-Test $root $id 'BRIEFED', 'PLANNED', 'BUILDING'
        (Get-OfficeWorkItem -OfficeRoot $root -Id $id).round | Should -Be 0
    }

    It 'remembers the state before PARKED and resumes to it' {
        $root = New-Office
        $id = (Register-Test $root).id
        Move-Test $root $id 'BRIEFED', 'PLANNED', 'BUILDING', 'TESTING', 'PARKED'
        (Get-OfficeWorkItem -OfficeRoot $root -Id $id).resumeTo | Should -Be 'TESTING'
        { Set-OfficeWorkItemState -OfficeRoot $root -Id $id -State 'READY' -DecisionId 9 } | Should -Throw
        $s = Set-OfficeWorkItemState -OfficeRoot $root -Id $id -State 'TESTING' -Now $script:T0
        $s.state | Should -Be 'TESTING'
        $s.resumeTo | Should -BeNullOrEmpty
    }

    It 'does not count resuming from PARKED into BUILDING as a round' {
        $root = New-Office
        $id = (Register-Test $root).id
        Move-Test $root $id 'BRIEFED', 'PLANNED', 'BUILDING', 'PARKED', 'BUILDING'
        (Get-OfficeWorkItem -OfficeRoot $root -Id $id).round | Should -Be 0
    }

    It 'sets and clears the pending decision' {
        $root = New-Office
        $id = (Register-Test $root).id
        (Set-OfficeWorkItemPendingDecision -OfficeRoot $root -Id $id -DecisionId 2).pendingDecision | Should -Be 2
        (Set-OfficeWorkItemPendingDecision -OfficeRoot $root -Id $id -Clear).pendingDecision | Should -BeNullOrEmpty
    }
}

Describe 'Add-OfficeThreadEntry' {
    It 'appends an entry in the SPEC §5 format' {
        $root = New-Office
        $id = (Register-Test $root).id
        Add-OfficeThreadEntry -OfficeRoot $root -Id $id -From 'security' -To 'builder' -Kind 'objection' `
            -Body 'src/Api/CaseController.cs:88 missing ownership check (IDOR, high).' -Refs 'security-report.md#F-2' -Now $script:T0
        $text = Get-Content -Raw -Encoding utf8 (Join-Path $root 'work' $id 'thread.md')
        $text | Should -Match ([regex]::Escape("### [2026-11-05 14:32] security $([char]0x2192) builder $([char]0x00B7) objection"))
        $text | Should -Match ([regex]::Escape('src/Api/CaseController.cs:88 missing ownership check (IDOR, high).'))
        $text | Should -Match ([regex]::Escape('refs: security-report.md#F-2'))
    }

    It 'only appends: earlier content is preserved byte for byte' {
        $root = New-Office
        $id = (Register-Test $root).id
        $path = Join-Path $root 'work' $id 'thread.md'
        Add-OfficeThreadEntry -OfficeRoot $root -Id $id -From 'intake' -To 'manager' -Kind 'done' -Body 'first' -Now $script:T0
        $before = [IO.File]::ReadAllBytes($path)
        Add-OfficeThreadEntry -OfficeRoot $root -Id $id -From 'builder' -To 'manager' -Kind 'done' -Body 'second' -Now $script:T0
        $after = [IO.File]::ReadAllBytes($path)
        $after.Length | Should -BeGreaterThan $before.Length
        [byte[]]$after[0..($before.Length - 1)] | Should -Be ([byte[]]$before)
    }

    It 'keeps CJK text intact (UTF-8)' {
        $root = New-Office
        $id = (Register-Test $root).id
        $cjk = -join ([char[]](0x6E2C, 0x8A66))
        Add-OfficeThreadEntry -OfficeRoot $root -Id $id -From 'intake' -To 'manager' -Kind 'done' -Body $cjk -Now $script:T0
        Get-Content -Raw -Encoding utf8 (Join-Path $root 'work' $id 'thread.md') | Should -Match $cjk
    }

    It 'rejects a header field containing a newline (would forge a new entry)' {
        $root = New-Office
        $id = (Register-Test $root).id
        { Add-OfficeThreadEntry -OfficeRoot $root -Id $id -From "a`n### [x]" -To 'b' -Kind 'done' -Body 'x' } | Should -Throw
    }

    It 'throws for a work item that is not registered' {
        $root = New-Office
        { Add-OfficeThreadEntry -OfficeRoot $root -Id 'nope-1' -From 'a' -To 'b' -Kind 'done' -Body 'x' } | Should -Throw '*nope-1*'
    }
}

Describe 'Get-OfficeSummary' {
    It 'reports an idle office when there is no office folder at all' {
        $s = Get-OfficeSummary -OfficeRoot (Join-Path $TestDrive 'does-not-exist')
        $s.Idle | Should -BeTrue
        @($s.Items).Count | Should -Be 0
        $s.PendingDecisionCount | Should -Be 0
    }

    It 'lists every work item with its state and counts pending decisions' {
        $root = New-Office
        $a = (Register-Test $root -Iid 1).id
        $b = (Register-Test $root -Iid 2).id
        Move-Test $root $b 'BRIEFED', 'PLANNED'
        Set-OfficeWorkItemPendingDecision -OfficeRoot $root -Id $b -DecisionId 1 | Out-Null
        $s = Get-OfficeSummary -OfficeRoot $root
        $s.Idle | Should -BeFalse
        @($s.Items).Count | Should -Be 2
        ($s.Items | Where-Object Id -EQ $a).State | Should -Be 'NEW'
        ($s.Items | Where-Object Id -EQ $b).State | Should -Be 'PLANNED'
        $s.PendingDecisionCount | Should -Be 1
    }

    It 'does not count PURGED items as active' {
        $root = New-Office
        $id = (Register-Test $root).id
        Move-Test $root $id 'BRIEFED', 'PLANNED', 'BUILDING', 'REVIEW', 'READY', 'DELIVERED', 'PURGED'
        (Get-OfficeSummary -OfficeRoot $root).Idle | Should -BeTrue
    }
}

Describe 'Get-AgentOutcome (T7, SPEC §3.2 contract)' {
    BeforeAll {
        $script:Fx = Join-Path $script:RepoRoot 'tests' 'fixtures' 'agent-outputs'
        function Read-Fixture([string]$Name) { Get-Content -Raw -Encoding utf8 -LiteralPath (Join-Path $script:Fx $Name) }
        $script:Fence = '```'
        function New-Reply([string[]]$Lines) { "$script:Fence" + "yaml`n" + ($Lines -join "`n") + "`n$script:Fence`n" }
    }

    It 'parses a done reply, ignoring trailing comments' {
        $o = Get-AgentOutcome -Text (Read-Fixture 'done.md')
        $o.Valid | Should -BeTrue
        $o.Outcome | Should -Be 'done'
        $o.Summary | Should -Be 'brief 完成：STAGING 匯出需確認 nightly export 排程'
        $o.Next | Should -Be @('builder')
    }

    It 'parses a blocked reply with single quotes, a comment line and an empty list' {
        $o = Get-AgentOutcome -Text (Read-Fixture 'blocked.md')
        $o.Valid | Should -BeTrue
        $o.Outcome | Should -Be 'blocked'
        $o.Summary | Should -BeLike '需要開單人確認*Q1）'
        $o.Next.Count | Should -Be 0
    }

    It 'parses needs_decision written as block lists and mappings' {
        $o = Get-AgentOutcome -Text (Read-Fixture 'needs-decision.md')
        $o.Valid | Should -BeTrue
        $o.Next | Should -Be @('builder')
        $o.Decision.Question | Should -Be 'F-2（IDOR, high）要在這張單修嗎？'
        $o.Decision.Options | Should -Be @('這張單一起修', '另開 issue 追蹤')
        $o.Decision.Recommendation | Should -Be '這張單一起修'
    }

    It 'parses needs_decision written as a flow mapping, keeping # inside quotes' {
        $o = Get-AgentOutcome -Text (Read-Fixture 'decision-flow.md')
        $o.Valid | Should -BeTrue
        $o.Decision.Question | Should -Be '要繼續嗎？ # 不是註解'
        $o.Decision.Options | Should -Be @('繼續一輪', "It's done")
        $o.Decision.Recommendation | Should -BeNullOrEmpty
    }

    It 'parses an objection and drops the decision field it does not need' {
        $o = Get-AgentOutcome -Text (Read-Fixture 'objection.md')
        $o.Valid | Should -BeTrue
        $o.Outcome | Should -Be 'objection'
        $o.ObjectionTo | Should -Be 'security'
        $o.Decision | Should -BeNullOrEmpty
    }

    It 'uses the last yaml block when the reply quotes an example earlier' {
        $o = Get-AgentOutcome -Text (Read-Fixture 'earlier-block.md')
        $o.Outcome | Should -Be 'done'
        $o.Summary | Should -Be '以最後一個區塊為準'
    }

    It 'accepts CRLF line endings' {
        $o = Get-AgentOutcome -Text ((Read-Fixture 'done.md') -replace "`r?`n", "`r`n")
        $o.Valid | Should -BeTrue
        $o.Next | Should -Be @('builder')
    }

    It 'treats a malformed reply as blocked: <File>' -ForEach @(
        @{ File = 'malformed-no-block.md'; Err = '*no fenced*' }
        @{ File = 'malformed-bad-outcome.md'; Err = '*outcome must be one of*' }
        @{ File = 'malformed-trailing-text.md'; Err = '*not the last thing*' }
        @{ File = 'malformed-unterminated.md'; Err = '*unterminated*' }
        @{ File = 'malformed-missing-summary.md'; Err = '*summary*' }
        @{ File = 'malformed-unknown-agent.md'; Err = "*unknown agent 'office-manager'*" }
        @{ File = 'malformed-decision-one-option.md'; Err = '*at least two*' }
    ) {
        $o = Get-AgentOutcome -Text (Read-Fixture $File)
        $o.Valid | Should -BeFalse
        $o.Outcome | Should -Be 'blocked'
        $o.Error | Should -BeLike $Err
    }

    It 'treats an empty reply and odd YAML as blocked: <Name>' -ForEach @(
        @{ Name = 'empty'; Lines = $null }
        @{ Name = 'empty block'; Lines = @('') }
        @{ Name = 'unknown key'; Lines = @('outcome: done', 'summary: x', 'extra: 1') }
        @{ Name = 'duplicate key'; Lines = @('outcome: done', 'outcome: blocked', 'summary: x') }
        @{ Name = 'anchor'; Lines = @('outcome: &a done', 'summary: x') }
        @{ Name = 'indented top level'; Lines = @('  outcome: done', '  summary: x') }
        @{ Name = 'tab'; Lines = @('outcome: done', "summary:`tx") }
        @{ Name = 'objection without target'; Lines = @('outcome: objection', 'summary: x') }
    ) {
        $text = if ($null -eq $Lines) { '' } else { New-Reply $Lines }
        $o = Get-AgentOutcome -Text $text
        $o.Valid | Should -BeFalse
        $o.Outcome | Should -Be 'blocked'
    }

    It 'builds valid replies with the same helper (guards the negative cases above)' {
        (Get-AgentOutcome -Text (New-Reply @('outcome: done', 'summary: x'))).Valid | Should -BeTrue
    }

    It 'records a malformed reply in thread.md when given a work item' {
        $root = New-Office
        $id = (Register-Test $root).id
        $o = Get-AgentOutcome -Text (Read-Fixture 'malformed-no-block.md') -OfficeRoot $root -Id $id -Agent 'intake' -Now $script:T0
        $o.Outcome | Should -Be 'blocked'
        $thread = Get-Content -Raw -Encoding utf8 (Join-Path $root 'work' $id 'thread.md')
        $thread | Should -BeLike '*intake → office-manager · blocked*'
        $thread | Should -BeLike '*no fenced*'
    }

    It 'does not touch thread.md for a valid reply' {
        $root = New-Office
        $id = (Register-Test $root).id
        $before = Get-Content -Raw -Encoding utf8 (Join-Path $root 'work' $id 'thread.md')
        $null = Get-AgentOutcome -Text (Read-Fixture 'done.md') -OfficeRoot $root -Id $id -Agent 'intake'
        Get-Content -Raw -Encoding utf8 (Join-Path $root 'work' $id 'thread.md') | Should -Be $before
    }
}

Describe 'ConvertFrom-OfficeWorkItemRef (T7)' {
    BeforeAll {
        $script:Assigned = @('acme/SupportDesk#348', 'acme/SupportDesk#422', 'tools/portal/portal#407',
            'tools/rpa/ssl-monitor#12', 'other/portal#3')
    }

    It 'reads <Ref>' -ForEach @(
        @{ Ref = 'acme/SupportDesk#348'; P = 'acme/SupportDesk'; I = 348 }
        @{ Ref = ' tools/portal/portal#407 '; P = 'tools/portal/portal'; I = 407 }
        @{ Ref = 'https://gitlab.example.com/acme/SupportDesk/-/work_items/348'; P = 'acme/SupportDesk'; I = 348 }
        @{ Ref = 'https://gitlab.example.com/tools/rpa/ssl-monitor/-/issues/12#note_5'; P = 'tools/rpa/ssl-monitor'; I = 12 }
        @{ Ref = 'SupportDesk#348'; P = 'acme/SupportDesk'; I = 348 }
        @{ Ref = 'supportdesk#999'; P = 'acme/SupportDesk'; I = 999 }
        @{ Ref = 'ssl-monitor#12'; P = 'tools/rpa/ssl-monitor'; I = 12 }
    ) {
        $r = ConvertFrom-OfficeWorkItemRef -Ref $Ref -AssignedReferences $script:Assigned
        $r.ProjectPath | Should -Be $P
        $r.Iid | Should -Be $I
    }

    It 'rejects an ambiguous short project name' {
        { ConvertFrom-OfficeWorkItemRef -Ref 'portal#1' -AssignedReferences $script:Assigned } | Should -Throw '*ambiguous*'
    }

    It 'rejects an unknown short project name' {
        { ConvertFrom-OfficeWorkItemRef -Ref 'nope#1' -AssignedReferences $script:Assigned } | Should -Throw '*full path*'
    }

    It 'rejects unreadable or unsafe references: <Ref>' -ForEach @(
        @{ Ref = '348' }, @{ Ref = 'SupportDesk' }, @{ Ref = 'a/b#0' }, @{ Ref = '../x/y#1' }, @{ Ref = 'a/b#12abc' }
    ) {
        { ConvertFrom-OfficeWorkItemRef -Ref $Ref -AssignedReferences $script:Assigned } | Should -Throw
    }
}

Describe 'Initialize-OfficeProjectRepo (T7)' {
    BeforeEach {
        $script:Ws = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:Mine = Join-Path $script:Ws 'mine'
        New-Item -ItemType Directory -Path $script:Mine -Force | Out-Null
        $script:Cfg2 = @{
            workspaceRoot = $script:Ws
            projects      = @(@{ match = 'acme/SupportDesk'; repoPath = $script:Mine; baseBranch = $null; commands = @{} })
        }
        $global:HuddleTestCloneHost = $null
        Mock -ModuleName Office glab {
            $global:HuddleTestCloneHost = $env:GITLAB_HOST
            $global:LASTEXITCODE = 0; New-Item -ItemType Directory -Path $args[3] -Force | Out-Null
        }
    }
    AfterAll { Remove-Variable -Name HuddleTestCloneHost -Scope Global -ErrorAction SilentlyContinue }

    It 'uses a registered repoPath as is, without cloning' {
        $r = Initialize-OfficeProjectRepo -Config $script:Cfg2 -ProjectPath 'acme/SupportDesk' -GitLabHost 'gitlab.example'
        $r.Registered | Should -BeTrue
        $r.RepoPath | Should -Be $script:Mine
        $r.Cloned | Should -BeFalse
        Should -Invoke -ModuleName Office glab -Times 0 -Exactly
    }

    It 'fails when a registered repoPath is missing' {
        Remove-Item -LiteralPath $script:Mine
        { Initialize-OfficeProjectRepo -Config $script:Cfg2 -ProjectPath 'acme/SupportDesk' -GitLabHost 'gitlab.example' } |
            Should -Throw '*does not exist*'
        Should -Invoke -ModuleName Office glab -Times 0 -Exactly
    }

    It 'clones an unregistered project into repos\<namespace>\<project> with glab repo clone' {
        $r = Initialize-OfficeProjectRepo -Config $script:Cfg2 -ProjectPath 'tools/rpa/ssl-monitor' -GitLabHost 'gitlab.example'
        $expected = Join-Path $script:Ws 'repos' 'tools' 'rpa' 'ssl-monitor'
        $r.Registered | Should -BeFalse
        $r.Cloned | Should -BeTrue
        $r.RepoPath | Should -Be $expected
        Should -Invoke -ModuleName Office glab -Times 1 -Exactly -ParameterFilter {
            $args[0] -eq 'repo' -and $args[1] -eq 'clone' -and $args[2] -eq 'tools/rpa/ssl-monitor' -and $args[3] -eq $expected
        }
        $global:HuddleTestCloneHost | Should -Be 'gitlab.example'
    }

    It 'passes the host through GITLAB_HOST only for the clone (an https URL would bypass the SSH setup)' {
        $before = $env:GITLAB_HOST
        try {
            $env:GITLAB_HOST = 'other.example'
            $null = Initialize-OfficeProjectRepo -Config $script:Cfg2 -ProjectPath 'a/b' -GitLabHost 'gitlab.example'
            $env:GITLAB_HOST | Should -Be 'other.example'
            Should -Invoke -ModuleName Office glab -Times 0 -Exactly -ParameterFilter { "$args" -match 'https?://' }
        }
        finally { $env:GITLAB_HOST = $before }
    }

    It 'reuses an existing clone' {
        New-Item -ItemType Directory -Path (Join-Path $script:Ws 'repos' 'a' 'b') -Force | Out-Null
        (Initialize-OfficeProjectRepo -Config $script:Cfg2 -ProjectPath 'a/b' -GitLabHost 'gitlab.example').Cloned | Should -BeFalse
        Should -Invoke -ModuleName Office glab -Times 0 -Exactly
    }

    It 'reports a failed clone' {
        Mock -ModuleName Office glab { $global:LASTEXITCODE = 1; 'fatal: repository not found' }
        { Initialize-OfficeProjectRepo -Config $script:Cfg2 -ProjectPath 'a/b' -GitLabHost 'gitlab.example' } |
            Should -Throw '*repository not found*'
    }

    It 'rejects a host that is not a plain host name' {
        { Initialize-OfficeProjectRepo -Config $script:Cfg2 -ProjectPath 'a/b' -GitLabHost 'evil.example/x?' } |
            Should -Throw '*Invalid GitLab host*'
        Should -Invoke -ModuleName Office glab -Times 0 -Exactly
    }
}

Describe 'Complete-OfficeIntake (T7)' {
    BeforeAll {
        $script:Fx = Join-Path $script:RepoRoot 'tests' 'fixtures' 'agent-outputs'
        function Read-Fixture([string]$Name) { Get-Content -Raw -Encoding utf8 -LiteralPath (Join-Path $script:Fx $Name) }
        $script:FullBrief = "# Brief`n`n## 摘要`nx`n## 排序依據`nx`n## 發現於`nx`n## 驗收條件草稿`nx`n## 範圍`nx`n## 相關程式碼`nx`n## 風險標記`nx`n## 待釐清問題`nx`n"
        function Write-Brief([string]$Root, [string]$Id, [string]$Text) {
            [IO.File]::WriteAllText((Join-Path $Root 'work' $Id 'brief.md'), $Text, [Text.UTF8Encoding]::new($false))
        }
    }

    BeforeEach {
        $script:Root = New-Office
        $script:Id = (Register-Test $script:Root).id
    }

    It 'moves NEW to BRIEFED on done with a complete brief' {
        Write-Brief $script:Root $script:Id $script:FullBrief
        $r = Complete-OfficeIntake -OfficeRoot $script:Root -Id $script:Id -ReplyText (Read-Fixture 'done.md') -Now $script:T0
        $r.Result | Should -Be 'done'
        $r.State | Should -Be 'BRIEFED'
        $thread = Get-Content -Raw -Encoding utf8 (Join-Path $script:Root 'work' $script:Id 'thread.md')
        $thread | Should -BeLike '*intake → office-manager · done*'
        $thread | Should -BeLike '*NEW -> BRIEFED*'
    }

    It 'blocks a done reply when brief.md lacks required sections' {
        Write-Brief $script:Root $script:Id ($script:FullBrief -replace '## 發現於', '## Found in')
        $r = Complete-OfficeIntake -OfficeRoot $script:Root -Id $script:Id -ReplyText (Read-Fixture 'done.md') -Now $script:T0
        $r.Result | Should -Be 'blocked'
        $r.State | Should -Be 'BLOCKED'
        $r.MissingSections | Should -Be @('發現於')
        $r.Reason | Should -BeLike '*missing sections: 發現於*'
    }

    It 'blocks a done reply when brief.md does not exist' {
        $r = Complete-OfficeIntake -OfficeRoot $script:Root -Id $script:Id -ReplyText (Read-Fixture 'done.md') -Now $script:T0
        $r.State | Should -Be 'BLOCKED'
        $r.MissingSections.Count | Should -Be 8
    }

    It 'moves NEW to BLOCKED on blocked' {
        Write-Brief $script:Root $script:Id $script:FullBrief
        $r = Complete-OfficeIntake -OfficeRoot $script:Root -Id $script:Id -ReplyText (Read-Fixture 'blocked.md') -Now $script:T0
        $r.State | Should -Be 'BLOCKED'
        (Get-OfficeWorkItem -OfficeRoot $script:Root -Id $script:Id).resumeTo | Should -Be 'NEW'
    }

    It 'moves NEW to BLOCKED on a malformed reply and logs the parse error' {
        $r = Complete-OfficeIntake -OfficeRoot $script:Root -Id $script:Id -ReplyText 'oops' -Now $script:T0
        $r.Valid | Should -BeFalse
        $r.State | Should -Be 'BLOCKED'
        Get-Content -Raw -Encoding utf8 (Join-Path $script:Root 'work' $script:Id 'thread.md') | Should -BeLike '*Parse error*'
    }

    It 'treats an outcome Intake may not use as blocked' {
        Write-Brief $script:Root $script:Id $script:FullBrief
        $r = Complete-OfficeIntake -OfficeRoot $script:Root -Id $script:Id -ReplyText (Read-Fixture 'objection.md') -Now $script:T0
        $r.Result | Should -Be 'blocked'
        $r.Reason | Should -BeLike "*'objection'*"
    }

    It 'goes from BLOCKED back through NEW to BRIEFED when a re-run is done' {
        $null = Complete-OfficeIntake -OfficeRoot $script:Root -Id $script:Id -ReplyText (Read-Fixture 'blocked.md') -Now $script:T0
        Write-Brief $script:Root $script:Id $script:FullBrief
        $r = Complete-OfficeIntake -OfficeRoot $script:Root -Id $script:Id -ReplyText (Read-Fixture 'done.md') -Now $script:T0
        $r.From | Should -Be 'BLOCKED'
        $r.State | Should -Be 'BRIEFED'
        $h = (Get-OfficeWorkItem -OfficeRoot $script:Root -Id $script:Id).history
        ($h | ForEach-Object { "$($_.from)>$($_.to)" }) -join ',' | Should -Be 'NEW>BLOCKED,BLOCKED>NEW,NEW>BRIEFED'
    }

    It 'keeps BLOCKED when a re-run is still blocked' {
        $null = Complete-OfficeIntake -OfficeRoot $script:Root -Id $script:Id -ReplyText (Read-Fixture 'blocked.md') -Now $script:T0
        (Complete-OfficeIntake -OfficeRoot $script:Root -Id $script:Id -ReplyText (Read-Fixture 'blocked.md') -Now $script:T0).State |
            Should -Be 'BLOCKED'
    }

    It 'never moves past BRIEFED' {
        Write-Brief $script:Root $script:Id $script:FullBrief
        $null = Complete-OfficeIntake -OfficeRoot $script:Root -Id $script:Id -ReplyText (Read-Fixture 'done.md') -Now $script:T0
        (Complete-OfficeIntake -OfficeRoot $script:Root -Id $script:Id -ReplyText (Read-Fixture 'done.md') -Now $script:T0).State |
            Should -Be 'BRIEFED'
    }
}

Describe 'Agent definitions (.claude/agents)' {
    BeforeAll {
        function Get-Frontmatter([string]$Path) {
            $text = Get-Content -Raw -Encoding utf8 -LiteralPath $Path
            $m = [regex]::Match($text, '(?s)^---\r?\n(.*?)\r?\n---')
            $fm = @{}
            foreach ($line in ($m.Groups[1].Value -split '\r?\n')) {
                if ($line -match '^([a-zA-Z]+):\s*(.*)$') { $fm[$Matches[1]] = $Matches[2].Trim() }
            }
            $fm
        }
        $script:AgentFiles = @(Get-ChildItem -LiteralPath (Join-Path $script:RepoRoot '.claude' 'agents') -Filter '*.md')
    }

    It 'has at least the intake agent' {
        $script:AgentFiles.Name | Should -Contain 'intake.md'
    }

    It 'never gives an agent the Agent tool, so all hand-offs go through the Office Manager (SPEC §3.2)' {
        foreach ($f in $script:AgentFiles) {
            $tools = (Get-Frontmatter $f.FullName).tools
            $tools | Should -Not -BeNullOrEmpty -Because "$($f.Name) must list its tools explicitly"
            ($tools -split '\s*,\s*') | Should -Not -Contain 'Agent' -Because $f.Name
            ($tools -split '\s*,\s*') | Should -Not -Contain 'Task' -Because $f.Name
        }
    }

    It 'runs intake on Sonnet (SPEC Q5) without edit or web tools' {
        $fm = Get-Frontmatter (Join-Path $script:RepoRoot '.claude' 'agents' 'intake.md')
        $fm.name | Should -Be 'intake'
        $fm.model | Should -Be 'sonnet'
        ($fm.tools -split '\s*,\s*') | Should -Be @('Read', 'Grep', 'Glob', 'Bash', 'Write')
    }

    It 'documents every brief.md section that Complete-OfficeIntake checks' {
        $text = Get-Content -Raw -Encoding utf8 (Join-Path $script:RepoRoot '.claude' 'agents' 'intake.md')
        foreach ($s in '摘要', '排序依據', '發現於', '驗收條件草稿', '範圍', '相關程式碼', '風險標記', '待釐清問題') {
            $text | Should -Match "(?m)^## $s\s*$"
        }
    }
}

Describe 'Register-OfficeWorkItem issueUpdatedAt (T7)' {
    It 'records the issue updated_at when given' {
        $root = New-Office
        $s = Register-OfficeWorkItem -OfficeRoot $root -ProjectPath 'a/b' -Iid 1 -Title 't' -WebUrl 'u' `
            -IssueUpdatedAt '2026-11-01T02:03:04.000Z' -Now $script:T0
        $s.issueUpdatedAt | Should -Be '2026-11-01T02:03:04.000Z'
    }
}
