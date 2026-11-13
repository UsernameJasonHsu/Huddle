# Registers a per-user scheduled task that runs notify-new.ps1 every N minutes
# while the user is logged on. Re-running overwrites the task of the same name.
param([int]$Minutes = 10)

$ErrorActionPreference = 'Stop'
$script = Join-Path $PSScriptRoot 'notify-new.ps1'
$taskName = 'SupervisorAgent-WorkItemNotify'

# Task Scheduler does not search the per-user WindowsApps folder, where a
# Store/MSIX install of PowerShell lives, so resolve pwsh to a full path.
$pwsh = (Get-Command pwsh.exe -CommandType Application | Select-Object -First 1).Source
$action = New-ScheduledTaskAction -Execute $pwsh `
    -Argument "-NoProfile -WindowStyle Hidden -File `"$script`"" `
    -WorkingDirectory (Split-Path -Parent $PSScriptRoot)
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
    -RepetitionInterval (New-TimeSpan -Minutes $Minutes)
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew

Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings `
    -Description 'Notify Teams chat about GitLab work items newly assigned to me' -Force | Out-Null
Write-Output "Registered scheduled task '$taskName' (every $Minutes min)."
