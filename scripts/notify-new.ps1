# Polls GitLab for work items newly assigned to me and posts each one to a
# Teams Workflows webhook (personal chat). Intended to run from Task Scheduler.
#
# First run (no state file) only records current items and sends nothing.
# Items whose post fails are left out of the state file so they retry next run.
# Each new item is also written to office/inbox/<id>.json for the Huddle office (SPEC §3.5);
# a failed inbox write only warns and never stops the Teams post. -DryRun writes no inbox files.
param([switch]$DryRun)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
Import-Module (Join-Path $PSScriptRoot 'WorkItems.psm1') -Force

$config = Get-WorkItemConfig
$repoRoot = Split-Path -Parent $PSScriptRoot
$stateDir = Join-Path $repoRoot 'state'
$statePath = Join-Path $stateDir 'seen-work-items.json'
$officeRoot = Join-Path $repoRoot 'office'

$webhook = [Environment]::GetEnvironmentVariable($config.teamsWebhookEnvVar)
if (-not $DryRun -and -not $webhook) {
    Write-Error "Environment variable $($config.teamsWebhookEnvVar) is not set."
    exit 2
}

function New-TeamsCard {
    param($Item)
    $facts = @(
        @{ title = 'Project'; value = $Item.Project }
        @{ title = 'Severity'; value = $Item.SeveritySource }
        @{ title = 'Labels'; value = ($Item.Labels -join ', ') }
    )
    @{
        type        = 'message'
        attachments = @(
            @{
                contentType = 'application/vnd.microsoft.card.adaptive'
                content     = @{
                    '$schema' = 'http://adaptivecards.io/schemas/adaptive-card.json'
                    type      = 'AdaptiveCard'
                    version   = '1.4'
                    body      = @(
                        @{ type = 'TextBlock'; text = 'New work item assigned to you'; weight = 'Bolder'; size = 'Medium' }
                        @{ type = 'TextBlock'; text = "$($Item.Reference) $($Item.Title)"; wrap = $true }
                        @{ type = 'FactSet'; facts = $facts }
                    )
                    actions   = @(
                        @{ type = 'Action.OpenUrl'; title = 'Open in GitLab'; url = $Item.WebUrl }
                    )
                }
            }
        )
    }
}

$items = Get-SortedWorkItems -Config $config
$currentIds = @($items | ForEach-Object { $_.Id })

if (-not (Test-Path -LiteralPath $statePath)) {
    if ($DryRun) {
        Write-Output "[dry-run] No state file; a real run would seed $($currentIds.Count) item(s) without notifying."
        exit 0
    }
    New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
    ConvertTo-Json -InputObject $currentIds | Set-Content -Encoding utf8 -LiteralPath $statePath
    Write-Output "Seeded state with $($currentIds.Count) item(s); no notifications sent."
    exit 0
}

$seen = @(Get-Content -Raw -Encoding utf8 -LiteralPath $statePath | ConvertFrom-Json)
$new = @($items | Where-Object { $seen -notcontains $_.Id })
$failed = [System.Collections.Generic.List[object]]::new()

foreach ($item in $new) {
    $body = ConvertTo-Json -InputObject (New-TeamsCard -Item $item) -Depth 10
    if ($DryRun) {
        Write-Output "[dry-run] Would notify: $($item.Reference) $($item.Title)"
        continue
    }
    try {
        Import-Module (Join-Path $PSScriptRoot 'Office.psm1')
        $null = Write-OfficeInboxItem -OfficeRoot $officeRoot -Id $item.Id -Reference $item.Reference `
            -Title $item.Title -WebUrl $item.WebUrl -IssueUpdatedAt $item.UpdatedAt
    }
    catch {
        Write-Warning "Failed to write inbox entry for $($item.Reference): $($_.Exception.Message)"
    }
    try {
        Invoke-RestMethod -Method Post -Uri $webhook -ContentType 'application/json; charset=utf-8' `
            -Body ([Text.Encoding]::UTF8.GetBytes($body)) | Out-Null
        Write-Output "Notified: $($item.Reference)"
    }
    catch {
        $failed.Add($item.Id)
        $detail = if ($_.ErrorDetails -and $_.ErrorDetails.Message) { " | response: $($_.ErrorDetails.Message)" } else { '' }
        Write-Warning "Failed to notify $($item.Reference): $($_.Exception.Message)$detail"
    }
}

if (-not $DryRun) {
    # Keep only currently-assigned items, minus failures, so failures retry and
    # an item reassigned back to me later counts as new again.
    $nextSeen = @($currentIds | Where-Object { $failed -notcontains $_ })
    ConvertTo-Json -InputObject $nextSeen | Set-Content -Encoding utf8 -LiteralPath $statePath
}
if ($new.Count -eq 0) { Write-Output 'No new work items.' }
if ($failed.Count -gt 0) { exit 1 }
