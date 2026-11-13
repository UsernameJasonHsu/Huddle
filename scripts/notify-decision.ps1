# Pushes a Teams card for each Huddle decision that is waiting for me (SPEC §3.4): the pending G1, G2
# or Clarify decision of a work item, or a work item that is BLOCKED on a question.
#
# This is the one outward write that runs without a G3 prompt: .claude/settings.json allows exactly
# "pwsh -NoProfile -File scripts/notify-decision.ps1" (no arguments). The script therefore takes no
# input that reaches the card. It reads the office folder itself, and each card has only the work item
# reference, the gate and a one-line summary: no title, issue text, brief, diff or decision context.
#
# The webhook URL comes only from the environment variable named in config/work-items.json
# (teamsWebhookEnvVar); there is no parameter for it and it is never printed.
# Each notification is recorded once in office/work/<id>/notifications.json, sent or failed. A failure
# is written to thread.md and the decision flow goes on. Always prints JSON and exits 0.
param(
    # For tests only. The allowed command passes no arguments, so this is office/ under the repo.
    [string]$OfficeRoot
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8

$result = [ordered]@{ ok = $true; sent = @(); failed = @() }
$webhook = $null
try {
    Import-Module (Join-Path $PSScriptRoot 'WorkItems.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot 'Office.psm1') -Force
    if (-not $OfficeRoot) { $OfficeRoot = Join-Path (Split-Path -Parent $PSScriptRoot) 'office' }
    elseif (-not (Test-Path -LiteralPath $OfficeRoot -PathType Container)) { throw "Office folder not found: $OfficeRoot" }

    $envVar = (Get-WorkItemConfig).teamsWebhookEnvVar
    $webhook = [Environment]::GetEnvironmentVariable($envVar)

    foreach ($n in @(Get-OfficePendingNotifications -OfficeRoot $OfficeRoot)) {
        $row = [ordered]@{ id = $n.Id; reference = $n.Reference; gate = $n.Gate; key = $n.Key }
        $errorMessage = $null
        if (-not $webhook) {
            $errorMessage = "Environment variable $envVar is not set."
        }
        else {
            $card = @{
                type        = 'message'
                attachments = @(
                    @{
                        contentType = 'application/vnd.microsoft.card.adaptive'
                        content     = @{
                            '$schema' = 'http://adaptivecards.io/schemas/adaptive-card.json'
                            type      = 'AdaptiveCard'
                            version   = '1.4'
                            body      = @(
                                @{ type = 'TextBlock'; text = 'Huddle: a decision is waiting for you'; weight = 'Bolder'; size = 'Medium' }
                                @{ type = 'TextBlock'; text = "$($n.Reference) · $($n.Gate)"; wrap = $true }
                                @{ type = 'TextBlock'; text = $n.Summary; wrap = $true }
                            )
                        }
                    }
                )
            }
            $body = ConvertTo-Json -InputObject $card -Depth 10
            try {
                Invoke-RestMethod -Method Post -Uri $webhook -ContentType 'application/json; charset=utf-8' `
                    -Body ([Text.Encoding]::UTF8.GetBytes($body)) | Out-Null
            }
            catch {
                $errorMessage = $_.Exception.Message
                if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $errorMessage += " | response: $($_.ErrorDetails.Message)" }
                $errorMessage = $errorMessage.Replace($webhook, '<webhook>')
            }
        }
        if ($errorMessage) {
            $row.error = $errorMessage
            Add-OfficeNotificationRecord -OfficeRoot $OfficeRoot -Id $n.Id -Key $n.Key -Gate $n.Gate -Result failed -ErrorMessage $errorMessage
            $result.failed += [pscustomobject]$row
        }
        else {
            Add-OfficeNotificationRecord -OfficeRoot $OfficeRoot -Id $n.Id -Key $n.Key -Gate $n.Gate -Result sent
            $result.sent += [pscustomobject]$row
        }
    }
}
catch {
    $message = $_.Exception.Message
    if ($webhook) { $message = $message.Replace($webhook, '<webhook>') }
    $result.ok = $false
    $result.error = $message
}
ConvertTo-Json -InputObject $result -Depth 5
exit 0
