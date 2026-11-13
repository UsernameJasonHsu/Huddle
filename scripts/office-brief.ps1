# Prints the Huddle office status as markdown (used by /huddle). Read-only.
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Office.psm1') -Force
$officeRoot = Join-Path (Split-Path -Parent $PSScriptRoot) 'office'
(Format-OfficeBrief -Summary (Get-OfficeSummary -OfficeRoot $officeRoot)).Context -join "`n"
