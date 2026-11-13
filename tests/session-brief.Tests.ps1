# T5: scripts/session-brief.ps1 keeps the ranked list exactly as before and appends the office status.
# The script runs for real in a sandbox copy where WorkItems.psm1 is replaced by a stub (no GitLab).
# tests/fixtures/session-brief/snapshot.json was recorded from the script BEFORE the office section existed.

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:Fixtures = Join-Path $PSScriptRoot 'fixtures' 'session-brief'
    $script:Snapshot = Get-Content -Raw -Encoding utf8 (Join-Path $script:Fixtures 'snapshot.json') | ConvertFrom-Json -AsHashtable
    Import-Module (Join-Path $script:RepoRoot 'scripts' 'Office.psm1') -Force

    function New-Sandbox {
        $sb = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $scripts = Join-Path $sb 'scripts'
        New-Item -ItemType Directory -Path $scripts -Force | Out-Null
        foreach ($f in 'session-brief.ps1', 'office-brief.ps1', 'Office.psm1', 'Huddle.psm1') {
            Copy-Item (Join-Path $script:RepoRoot 'scripts' $f) $scripts
        }
        Copy-Item (Join-Path $script:Fixtures 'WorkItems.stub.psm1') (Join-Path $scripts 'WorkItems.psm1')
        $sb
    }

    function Invoke-Brief {
        param([string]$Sandbox, [string]$Mode = 'items')
        $env:BRIEF_STUB_MODE = $Mode
        try { $raw = & pwsh -NoProfile -File (Join-Path $Sandbox 'scripts' 'session-brief.ps1') }
        finally { Remove-Item Env:BRIEF_STUB_MODE -ErrorAction SilentlyContinue }
        $j = ($raw -join "`n") | ConvertFrom-Json
        $norm = { param($s) $s -replace '\d{4}-\d{2}-\d{2} \d{2}:\d{2}', '<STAMP>' }
        [pscustomobject]@{
            Display = & $norm $j.systemMessage
            Context = & $norm $j.hookSpecificOutput.additionalContext
        }
    }
}

Describe 'session-brief.ps1' {
    Context 'the ranked work item list is unchanged (snapshot)' {
        It 'keeps the <Mode> output as a byte-for-byte prefix' -ForEach @(
            @{ Mode = 'items' }, @{ Mode = 'empty' }, @{ Mode = 'fail' }
        ) {
            $r = Invoke-Brief (New-Sandbox) $Mode
            $r.Context.StartsWith($script:Snapshot[$Mode].additionalContext + "`n`n", [StringComparison]::Ordinal) | Should -BeTrue
            $r.Display.StartsWith($script:Snapshot[$Mode].systemMessage + "`n`n", [StringComparison]::Ordinal) | Should -BeTrue
        }
    }

    Context 'work items that already have an open MR get a section of their own' {
        BeforeAll {
            function Invoke-BriefWithMrs([string]$OpenMr) {
                $env:BRIEF_STUB_OPENMR = $OpenMr
                try { Invoke-Brief (New-Sandbox) } finally { Remove-Item Env:BRIEF_STUB_OPENMR -ErrorAction SilentlyContinue }
            }
        }

        It 'lists items without an MR first and items with an open MR after, each keeping its rank' {
            $r = Invoke-BriefWithMrs '348'
            $r.Context | Should -Match 'Open work items assigned to me: 2\.'
            $todo = $r.Context.IndexOf('### Not started or still in progress (no open MR): 1')
            $review = $r.Context.IndexOf('### MR already open, waiting for review or merge: 1')
            $todo | Should -BeGreaterThan 0
            $review | Should -BeGreaterThan $todo
            # portal#407 is rank 2 and still needs work; SupportDesk#348 is rank 1 and has MR !573.
            $r.Context.IndexOf('| 2 | tools/portal/portal#407 | Search index | priority::medium (fallback) |') | Should -BeGreaterThan $todo
            $r.Context.IndexOf('| 2 | tools/portal/portal#407 |') | Should -BeLessThan $review
            $r.Context | Should -Match ([regex]::Escape('| 1 | acme/SupportDesk#348 | Check staging export \| schedule | !573 | priority::high (fallback) | 37 | - |'))
            $r.Context.IndexOf('| 1 | acme/SupportDesk#348 |') | Should -BeGreaterThan $review
            $r.Display | Should -Match 'MR already open, waiting for review or merge \(1\):'
            $r.Display | Should -Match ([regex]::Escape('1. acme/SupportDesk#348  [priority::high (fallback)]  idle 37d  due -  MR !573'))
            $r.Display.IndexOf('2. tools/portal/portal#407') | Should -BeLessThan $r.Display.IndexOf('MR already open')
        }

        It 'says so when every item already has an open MR, and marks a draft MR' {
            $r = Invoke-BriefWithMrs 'all'
            $r.Context | Should -Match '### Not started or still in progress \(no open MR\): 0'
            $r.Context | Should -Match 'None: every open work item already has an open MR\.'
            $r.Context | Should -Match '### MR already open, waiting for review or merge: 2'
            $r.Context | Should -Match ([regex]::Escape('| 2 | tools/portal/portal#407 | Search index | !514 (draft) |'))
        }

        It 'keeps the single table and says which items could not be checked when the lookup fails' {
            $r = Invoke-BriefWithMrs 'error'
            $r.Context | Should -Not -Match '### '
            $r.Context | Should -Match 'MR lookup failed for: tools/portal/portal#407\. These items are listed as having no open MR; that is not confirmed\.'
            $r.Display | Should -Match 'MR lookup failed for 1 item\(s\)'
        }
    }

    It 'reports an idle office when there is no office folder, without failing' {
        $sb = New-Sandbox
        Test-Path (Join-Path $sb 'office') | Should -BeFalse
        $r = Invoke-Brief $sb
        $r.Context | Should -Match '## Office status'
        $r.Context | Should -Match 'Office idle'
        $r.Display | Should -Match 'Office: idle'
    }

    It 'lists office work items with state and pending decisions' {
        $sb = New-Sandbox
        $office = Join-Path $sb 'office'
        $a = (Register-OfficeWorkItem -OfficeRoot $office -ProjectPath 'acme/SupportDesk' -Iid 348 -Title 'Export | queue' -WebUrl 'u1').id
        $b = (Register-OfficeWorkItem -OfficeRoot $office -ProjectPath 'tools/portal/portal' -Iid 407 -Title 'Gateway' -WebUrl 'u2').id
        Set-OfficeWorkItemState -OfficeRoot $office -Id $b -State 'BRIEFED' | Out-Null
        Set-OfficeWorkItemPendingDecision -OfficeRoot $office -Id $b -DecisionId 2 | Out-Null

        $r = Invoke-Brief $sb
        $r.Context | Should -Match 'Work items in the office: 2\. Pending decisions: 1\.'
        $r.Context | Should -Match ([regex]::Escape('| acme/SupportDesk#348 | Export \| queue | NEW | - |'))
        $r.Context | Should -Match ([regex]::Escape("| tools/portal/portal#407 | Gateway | BRIEFED | office/work/$b/decisions/2.md |"))
        $r.Display | Should -Match ([regex]::Escape('tools/portal/portal#407  BRIEFED  decision #2 pending'))
        $a | Should -Not -BeNullOrEmpty
    }

    Context 'delivered MRs are read live (T20)' {
        BeforeAll {
            function New-DeliveredSandbox {
                $sb = New-Sandbox
                $office = Join-Path $sb 'office'
                $id = (Register-OfficeWorkItem -OfficeRoot $office -ProjectPath 'a/b' -Iid 5 -Title 't' -WebUrl 'u').id
                foreach ($s in 'BRIEFED', 'PLANNED') { $null = Set-OfficeWorkItemState -OfficeRoot $office -Id $id -State $s }
                $null = Set-OfficeWorkItemState -OfficeRoot $office -Id $id -State 'BUILDING' -DecisionId 1
                foreach ($s in 'TESTING', 'SEC_REVIEW', 'REVIEW', 'READY', 'DELIVERED') { $null = Set-OfficeWorkItemState -OfficeRoot $office -Id $id -State $s }
                $status = Get-OfficeWorkItem -OfficeRoot $office -Id $id
                $status.mr = [ordered]@{ iid = 9; url = 'https://gitlab.example/a/b/-/merge_requests/9'; sha = 'abc'; at = '2026-11-05T10:00:00+08:00' }
                [IO.File]::WriteAllText((Join-Path $office 'work' $id 'status.json'), ($status | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
                [pscustomobject]@{ Sandbox = $sb; Office = $office; Id = $id }
            }
        }

        It 'shows a merge that happened since the last tick' {
            $d = New-DeliveredSandbox
            $env:BRIEF_STUB_MR = 'merged'
            try { $r = Invoke-Brief $d.Sandbox } finally { Remove-Item Env:BRIEF_STUB_MR -ErrorAction SilentlyContinue }
            $r.Context | Should -Match '\| a/b#5 \| t \| DELIVERED \| - \| !9 merged 2026-11-0\d \|'
            $r.Display | Should -Match 'a/b#5  DELIVERED  !9 merged'
            $r.Context | Should -Not -Match 'could not be refreshed'
            (Get-OfficeWorkItem -OfficeRoot $d.Office -Id $d.Id).mr.state | Should -Be 'merged'
        }

        It 'keeps the last recorded status and says so when GitLab cannot be read' {
            $d = New-DeliveredSandbox
            $r = Invoke-Brief $d.Sandbox
            $r.Context | Should -Match '!9 \(not checked yet\)'
            $r.Context | Should -Match 'MR status could not be refreshed'
            $r.Display | Should -Match 'MR status could not be refreshed'
        }

        It 'adds no note when there is nothing to read' {
            $r = Invoke-Brief (New-Sandbox)
            $r.Context | Should -Not -Match 'could not be refreshed'
        }
    }

    It 'still shows the work item list when the office folder is corrupt' {
        $sb = New-Sandbox
        $office = Join-Path $sb 'office'
        $id = (Register-OfficeWorkItem -OfficeRoot $office -ProjectPath 'p/q' -Iid 1 -Title 't' -WebUrl 'u').id
        Set-Content -LiteralPath (Join-Path $office 'work' $id 'status.json') -Value '{ not json'
        $r = Invoke-Brief $sb
        $r.Context.StartsWith($script:Snapshot['items'].additionalContext, [StringComparison]::Ordinal) | Should -BeTrue
        $r.Context | Should -Match '## Office status unavailable'
        $r.Display | Should -Match 'Office status unavailable'
    }
}

Describe 'office-brief.ps1 (/huddle)' {
    It 'prints the office status markdown' {
        $sb = New-Sandbox
        $out = (& pwsh -NoProfile -File (Join-Path $sb 'scripts' 'office-brief.ps1')) -join "`n"
        $out | Should -Match '## Office status'
        $out | Should -Match 'Office idle'
    }
}
