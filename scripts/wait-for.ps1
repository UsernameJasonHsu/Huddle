# Makes a work item wait for a merge request, or clears its waits (T21, SPEC §3.11).
#   wait-for.ps1 -Ref <group/project#iid> -Mr <group/project!iid | !iid | MR URL> [-Note "<one line>"]
#   wait-for.ps1 -Ref <group/project#iid> -Clear
# While a work item has an unmet wait, /huddle-tick does not brief it and /huddle-take does not start
# it. /huddle-tick and the session brief report when the MR is merged. A work item that is not in the
# office yet is registered as NEW. Reads the issue and the MR from GitLab; writes nothing there.
# Prints JSON:
#   { ok, action: waiting | already-waiting | already-merged | cleared, id, reference, ... }
# On failure: { ok: false, ref, error }. Always exits 0 so the caller reads the JSON.
param(
    [Parameter(Mandatory)][string]$Ref,
    [string]$Mr,
    [string]$Note,
    [switch]$Clear,
    [string]$OfficeRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) 'office')
)
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

try {
    Import-Module (Join-Path $PSScriptRoot 'Huddle.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot 'WorkItems.psm1')
    Import-Module (Join-Path $PSScriptRoot 'Office.psm1')
    $wcfg = Get-WorkItemConfig
    # Only a short reference ('project#iid') needs the assigned list to find its project.
    $sorted = @()
    if ($Ref -notmatch '/') {
        $sorted = Get-SortedWorkItems -Config $wcfg
        if ($null -eq $sorted) { $sorted = @() }
    }
    $out = Invoke-HuddleWaitFor -Ref $Ref -Mr $Mr -Note $Note -Clear:$Clear -OfficeRoot $OfficeRoot -WorkItemConfig $wcfg -SortedItems $sorted
}
catch {
    $out = [ordered]@{ ok = $false; ref = $Ref; error = $_.Exception.Message }
}
$out | ConvertTo-Json -Depth 5
exit 0
