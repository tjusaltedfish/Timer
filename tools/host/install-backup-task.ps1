# Registers the daily Windows task that runs tools/host/backup.ps1.
#
# Task: TimePlannerBackup, every day at -Time (default 03:00), as the current
# user with the standard (limited) token. It runs backup.ps1 hidden, with
# -KeepDays / -KeepWeeks passed through, and starts at the next opportunity
# after a missed run. Execution is capped at one hour; a failed run is retried
# twice, a minute apart. The task does not need network access, so the logon
# (interactive) principal used by the other Timer tasks is enough.
#
# Run with -Remove to delete the task; -ValidateOnly only reports its state.
# The documentation also lists the equivalent schtasks.exe command line.
#
# Examples:
#   .\tools\host\install-backup-task.ps1
#   .\tools\host\install-backup-task.ps1 -Time 03:30 -KeepDays 30
#   .\tools\host\install-backup-task.ps1 -ValidateOnly
#   .\tools\host\install-backup-task.ps1 -Remove
param(
    [string] $Time = '03:00',
    [ValidateRange(1, 3650)][int] $KeepDays = 14,
    [ValidateRange(1, 520)][int] $KeepWeeks = 8,
    [switch] $Remove,
    [switch] $ValidateOnly
)

$ErrorActionPreference = 'Stop'
$taskName = 'TimePlannerBackup'
$backup = Join-Path $PSScriptRoot 'backup.ps1'

$existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue

if ($Remove) {
    if ($existing) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
        Write-Output "Removed scheduled task $taskName."
    } else {
        Write-Output "Scheduled task $taskName is not registered; nothing to remove."
    }
    exit 0
}

if ($ValidateOnly) {
    if (-not $existing) {
        Write-Output "Scheduled task $taskName is not registered."
        exit 1
    }
    $info = Get-ScheduledTaskInfo -TaskName $taskName
    Write-Output "Scheduled task $taskName is registered ($($existing.State))."
    Write-Output "  Last run:    $($info.LastRunTime) ($($info.LastTaskResult))"
    Write-Output "  Next run:    $($info.NextRunTime)"
    Write-Output "  Action:      $($existing.Actions[0].Execute) $($existing.Actions[0].Arguments)"
    exit 0
}

if (-not (Test-Path -LiteralPath $backup)) { throw "backup.ps1 missing next to this script: $backup" }
$at = [datetime]::ParseExact($Time, 'HH:mm', [Globalization.CultureInfo]::InvariantCulture)

$user = "$env:USERDOMAIN\$env:USERNAME"
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 1) `
    -RestartCount 2 -RestartInterval (New-TimeSpan -Minutes 1)
$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited

$arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -KeepDays {1} -KeepWeeks {2}' -f `
    $backup, $KeepDays, $KeepWeeks
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arguments -WorkingDirectory $PSScriptRoot
$trigger = New-ScheduledTaskTrigger -Daily -At $at

Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
    -Settings $settings -Principal $principal `
    -Description 'SQLite online backup of the Timer data directory (daily; 14 days + 8 weeks retention).' -Force | Out-Null

$task = Get-ScheduledTask -TaskName $taskName
$info = Get-ScheduledTaskInfo -TaskName $taskName
Write-Output "Registered scheduled task $taskName ($($task.State))."
Write-Output "  Daily at: $($at.ToString('HH:mm'))"
Write-Output "  Script:   $backup"
Write-Output "  Keep:     $KeepDays days / $KeepWeeks weeks"
Write-Output "  Next run: $($info.NextRunTime)"
Write-Output 'Verify now: schtasks /Run /TN TimePlannerBackup   (then check backups\backup.log)'
exit 0
