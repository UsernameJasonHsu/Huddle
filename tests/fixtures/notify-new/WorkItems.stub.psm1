# Stand-in for scripts/WorkItems.psm1 used by tests/notify-new.Tests.ps1 and
# tests/notify-decision.Tests.ps1 (no GitLab, no Teams).
#   $env:NOTIFY_STUB_SET   'two' (default) or 'three': which assigned items Get-SortedWorkItems returns.
#   $env:NOTIFY_STUB_LOG   file that the Invoke-RestMethod stand-in appends one line per post to.
#   $env:NOTIFY_STUB_FAIL  '1' makes every post fail (the error message includes the webhook URL).
#   $env:NOTIFY_STUB_BODIES optional file that each posted body is appended to (tests/notify-decision.Tests.ps1).
# Exporting Invoke-RestMethod from this module shadows the real cmdlet inside notify-new.ps1.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-WorkItemConfig {
    @{ gitlabHost = 'gitlab.example'; projectPriority = @('acme/SupportDesk'); teamsWebhookEnvVar = 'NOTIFY_STUB_WEBHOOK' }
}

function New-StubItem([long]$Id, [string]$Project, [int]$Iid, [string]$Title) {
    [pscustomobject]@{
        Id = $Id; Reference = "$Project#$Iid"; Project = $Project; Title = $Title; Type = 'issue'
        Labels = @('priority::medium'); WebUrl = "https://gitlab.example/$Project/-/work_items/$Iid"; DueDate = $null
        ProjectRank = 0; SeverityRank = 2; SeveritySource = 'priority::medium (fallback)'
        UpdatedAt = [DateTimeOffset]::Parse('2026-11-01T02:03:04.5Z'); IdleDays = 5
    }
}

function Get-SortedWorkItems {
    param([hashtable]$Config)
    $items = @(
        New-StubItem 1001 'acme/SupportDesk' 348 'Check staging export'
        New-StubItem 1002 'tools/portal/portal' 407 'Search index'
    )
    if ($env:NOTIFY_STUB_SET -eq 'three') { $items += New-StubItem 1003 'tools/rpa/ssl-monitor' 12 '報表匯出逾時檢查（CSV）' }
    , $items
}

function Invoke-RestMethod {
    param($Method, $Uri, $ContentType, $Body)
    if ($env:NOTIFY_STUB_LOG) { Add-Content -LiteralPath $env:NOTIFY_STUB_LOG -Value "$Method $Uri" -Encoding utf8 }
    if ($env:NOTIFY_STUB_BODIES) {
        $text = if ($Body -is [byte[]]) { [Text.Encoding]::UTF8.GetString($Body) } else { "$Body" }
        Add-Content -LiteralPath $env:NOTIFY_STUB_BODIES -Value $text -Encoding utf8
    }
    if ($env:NOTIFY_STUB_FAIL -eq '1') { throw "stub: webhook unavailable at $Uri" }
}

Export-ModuleMember -Function Get-WorkItemConfig, Get-SortedWorkItems, Invoke-RestMethod
