# Emits the ranked work item list as JSON for the work-items Claude Code mod.
# Output: { ok, fetchedAt, host, mrLookupFailed: [reference],
#           items: [{ reference, project, title, severitySource, idleDays, dueDate, webUrl,
#                     openMrs: [{ iid, webUrl, draft }] }] }
# On failure: { ok: false, error, check }. Always exits 0 so the caller reads the JSON.
[Console]::OutputEncoding = [Text.Encoding]::UTF8

try {
    Import-Module (Join-Path $PSScriptRoot 'WorkItems.psm1') -Force
    $config = Get-WorkItemConfig
    $items = Get-SortedWorkItems -Config $config
    if ($null -eq $items) { $items = @() }

    # Open MRs that close an item (it waits for review or merge). A failed lookup leaves openMrs
    # empty for that item and lists its reference in mrLookupFailed.
    $openMrs = @{}
    $mrErrors = @()
    try {
        $lookup = Get-WorkItemOpenMrs -Config $config -Items $items
        $openMrs = $lookup.Map
        $mrErrors = @($lookup.Errors)
    }
    catch { $mrErrors = @($items | ForEach-Object Reference) }

    $out = [ordered]@{
        ok             = $true
        fetchedAt      = (Get-Date).ToString('yyyy-MM-dd HH:mm')
        host           = $config.gitlabHost
        items          = @($items | ForEach-Object {
                [ordered]@{
                    reference      = $_.Reference
                    project        = $_.Project
                    title          = $_.Title
                    severitySource = $_.SeveritySource
                    idleDays       = $_.IdleDays
                    dueDate        = $_.DueDate
                    webUrl         = $_.WebUrl
                    openMrs        = @($openMrs[$_.Reference] | Where-Object { $_ } | ForEach-Object {
                            [ordered]@{ iid = $_.Iid; webUrl = $_.WebUrl; draft = $_.Draft }
                        })
                }
            })
        mrLookupFailed = $mrErrors
    }
}
catch {
    $out = [ordered]@{
        ok    = $false
        error = "Fetching work items failed: $($_.Exception.Message)"
        check = 'Check `glab auth status --hostname gitlab.example.com`.'
    }
}

ConvertTo-Json -InputObject $out -Depth 5 -Compress
