# T8: notify-new.ps1 also writes office/inbox/<id>.json (SPEC §3.5).
# The script runs for real in a sandbox copy where WorkItems.psm1 is replaced by a stub that returns
# fixed items and shadows Invoke-RestMethod (no GitLab, no Teams).
# tests/fixtures/notify-new/dryrun-snapshot.json was recorded from the script BEFORE the inbox existed.

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:Fixtures = Join-Path $PSScriptRoot 'fixtures' 'notify-new'
    $script:Snapshot = Get-Content -Raw -Encoding utf8 (Join-Path $script:Fixtures 'dryrun-snapshot.json') | ConvertFrom-Json -AsHashtable
    Import-Module (Join-Path $script:RepoRoot 'scripts' 'Office.psm1') -Force

    function New-Sandbox {
        $sb = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $scripts = Join-Path $sb 'scripts'
        New-Item -ItemType Directory -Path $scripts -Force | Out-Null
        foreach ($f in 'notify-new.ps1', 'Office.psm1') { Copy-Item (Join-Path $script:RepoRoot 'scripts' $f) $scripts }
        Copy-Item (Join-Path $script:Fixtures 'WorkItems.stub.psm1') (Join-Path $scripts 'WorkItems.psm1')
        $sb
    }

    function Set-Seen([string]$Sandbox, [long[]]$Ids) {
        New-Item -ItemType Directory -Path (Join-Path $Sandbox 'state') -Force | Out-Null
        ConvertTo-Json -InputObject $Ids | Set-Content -Encoding utf8 -LiteralPath (Join-Path $Sandbox 'state' 'seen-work-items.json')
    }

    function Get-Seen([string]$Sandbox) {
        @(Get-Content -Raw -Encoding utf8 (Join-Path $Sandbox 'state' 'seen-work-items.json') | ConvertFrom-Json)
    }

    function Get-Inbox([string]$Sandbox) {
        $dir = Join-Path $Sandbox 'office' 'inbox'
        if (-not (Test-Path -LiteralPath $dir)) { return @() }
        @(Get-ChildItem -LiteralPath $dir -File | Sort-Object Name)
    }

    function Invoke-Notify {
        param([string]$Sandbox, [string]$Set = 'two', [switch]$DryRun, [switch]$Fail)
        $log = Join-Path $Sandbox 'posts.log'
        $env:NOTIFY_STUB_SET = $Set
        $env:NOTIFY_STUB_LOG = $log
        $env:NOTIFY_STUB_FAIL = if ($Fail) { '1' } else { '' }
        $env:NOTIFY_STUB_WEBHOOK = 'https://example.invalid/hook'
        $prev = [Console]::OutputEncoding
        [Console]::OutputEncoding = [Text.Encoding]::UTF8
        try {
            $argList = @('-NoProfile', '-File', (Join-Path $Sandbox 'scripts' 'notify-new.ps1'))
            if ($DryRun) { $argList += '-DryRun' }
            $out = (& pwsh @argList *>&1 | ForEach-Object { "$_" }) -join "`n"
            $code = $LASTEXITCODE
        }
        finally {
            [Console]::OutputEncoding = $prev
            foreach ($v in 'NOTIFY_STUB_SET', 'NOTIFY_STUB_LOG', 'NOTIFY_STUB_FAIL', 'NOTIFY_STUB_WEBHOOK') {
                Remove-Item "Env:$v" -ErrorAction SilentlyContinue
            }
        }
        $posts = if (Test-Path -LiteralPath $log) { @(Get-Content -LiteralPath $log) } else { @() }
        [pscustomobject]@{ Output = $out; ExitCode = $code; Posts = $posts }
    }
}

Describe 'notify-new.ps1 -DryRun output is unchanged (snapshot recorded before T8)' {
    It 'matches when there is no state file' {
        (Invoke-Notify (New-Sandbox) -DryRun).Output | Should -BeExactly $script:Snapshot.noState
    }

    It 'matches when nothing is new' {
        $sb = New-Sandbox; Set-Seen $sb 1001, 1002
        (Invoke-Notify $sb -DryRun).Output | Should -BeExactly $script:Snapshot.noNew
    }

    It 'matches with one new item (CJK title)' {
        $sb = New-Sandbox; Set-Seen $sb 1001, 1002
        (Invoke-Notify $sb -Set three -DryRun).Output | Should -BeExactly $script:Snapshot.oneNew
    }

    It 'matches with two new items' {
        $sb = New-Sandbox; Set-Seen $sb 1001
        (Invoke-Notify $sb -Set three -DryRun).Output | Should -BeExactly $script:Snapshot.twoNew
    }

    It 'writes no inbox, state or posts in dry-run' {
        $sb = New-Sandbox; Set-Seen $sb 1001
        $r = Invoke-Notify $sb -Set three -DryRun
        $r.Posts.Count | Should -Be 0
        @(Get-Inbox $sb).Count | Should -Be 0
        Get-Seen $sb | Should -Be @(1001)
    }
}

Describe 'notify-new.ps1 inbox' {
    It 'does not write the inbox on the first run (no state file)' {
        $sb = New-Sandbox
        $r = Invoke-Notify $sb -Set three
        $r.ExitCode | Should -Be 0
        $r.Posts.Count | Should -Be 0
        Test-Path (Join-Path $sb 'office') | Should -BeFalse
        Get-Seen $sb | Should -Be @(1001, 1002, 1003)
    }

    It 'writes one inbox file per new item, named by the global issue id' {
        $sb = New-Sandbox; Set-Seen $sb 1001
        $r = Invoke-Notify $sb -Set three
        $r.ExitCode | Should -Be 0
        $r.Posts.Count | Should -Be 2
        (Get-Inbox $sb).Name | Should -Be @('1002.json', '1003.json')
        $e = Get-Content -Raw -Encoding utf8 (Join-Path $sb 'office' 'inbox' '1003.json') | ConvertFrom-Json -AsHashtable -DateKind String
        $e.id | Should -Be 1003
        $e.reference | Should -Be 'tools/rpa/ssl-monitor#12'
        $e.project | Should -Be 'tools/rpa/ssl-monitor'
        $e.iid | Should -Be 12
        $e.title | Should -Be '報表匯出逾時檢查（CSV）'
        $e.webUrl | Should -Be 'https://gitlab.example/tools/rpa/ssl-monitor/-/work_items/12'
        $e.issueUpdatedAt | Should -Be '2026-11-01T02:03:04.500Z'
        $e.receivedAt | Should -Match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}[+-]\d{2}:\d{2}$'
    }

    It 'keeps exactly one inbox file when a failed post is retried on the next run' {
        $sb = New-Sandbox; Set-Seen $sb 1001, 1002
        $first = Invoke-Notify $sb -Set three -Fail
        $first.ExitCode | Should -Be 1
        $first.Posts.Count | Should -Be 1
        (Get-Inbox $sb).Name | Should -Be @('1003.json')
        Get-Seen $sb | Should -Be @(1001, 1002)

        $second = Invoke-Notify $sb -Set three
        $second.ExitCode | Should -Be 0
        $second.Posts.Count | Should -Be 2   # one failed + one retried, in the same log
        (Get-Inbox $sb).Name | Should -Be @('1003.json')
        @(Get-ChildItem -LiteralPath (Join-Path $sb 'office' 'inbox') -Force).Count | Should -Be 1
        Get-Seen $sb | Should -Be @(1001, 1002, 1003)
    }

    It 'still posts to Teams when the inbox cannot be written' {
        $sb = New-Sandbox; Set-Seen $sb 1001, 1002
        # A file where the office folder should be makes every inbox write fail.
        Set-Content -LiteralPath (Join-Path $sb 'office') -Value 'not a folder'
        $r = Invoke-Notify $sb -Set three
        $r.ExitCode | Should -Be 0
        $r.Posts.Count | Should -Be 1
        $r.Output | Should -Match 'Failed to write inbox entry for tools/rpa/ssl-monitor#12'
        $r.Output | Should -Match 'Notified: tools/rpa/ssl-monitor#12'
        Get-Seen $sb | Should -Be @(1001, 1002, 1003)
    }

    It 'writes nothing when nothing is new' {
        $sb = New-Sandbox; Set-Seen $sb 1001, 1002
        $r = Invoke-Notify $sb
        $r.Output | Should -Be 'No new work items.'
        @(Get-Inbox $sb).Count | Should -Be 0
    }
}

Describe 'Write-OfficeInboxItem' {
    It 'overwrites the same id instead of adding a file' {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $a = Write-OfficeInboxItem -OfficeRoot $root -Id 7 -Reference 'a/b#1' -Title 'old' -WebUrl 'u'
        $b = Write-OfficeInboxItem -OfficeRoot $root -Id 7 -Reference 'a/b#1' -Title 'new' -WebUrl 'u'
        $a | Should -Be $b
        @(Get-ChildItem -LiteralPath (Join-Path $root 'inbox') -Force).Count | Should -Be 1
        (Get-Content -Raw -Encoding utf8 $b | ConvertFrom-Json).title | Should -Be 'new'
    }

    It 'stores a null issueUpdatedAt when none is given' {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $p = Write-OfficeInboxItem -OfficeRoot $root -Id 8 -Reference 'a/b#2' -Title 't' -WebUrl 'u'
        (Get-Content -Raw -Encoding utf8 $p | ConvertFrom-Json).issueUpdatedAt | Should -BeNullOrEmpty
    }

    It 'rejects bad input: <Name>' -ForEach @(
        @{ Name = 'zero id'; Id = 0; Ref = 'a/b#1' }
        @{ Name = 'no iid'; Id = 1; Ref = 'a/b' }
        @{ Name = 'traversal'; Id = 1; Ref = '../x#1' }
        @{ Name = 'single segment'; Id = 1; Ref = 'ab#1' }
    ) {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        { Write-OfficeInboxItem -OfficeRoot $root -Id $Id -Reference $Ref -Title 't' -WebUrl 'u' } | Should -Throw
        Test-Path (Join-Path $root 'inbox') | Should -BeFalse
    }
}
