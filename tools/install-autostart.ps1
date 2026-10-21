# Registers the logon tasks that keep Timer reachable without the client window:
#   TimePlannerBackend   starts the computer backend and the Cloudflare tunnel
#                        (Start-Timer.ps1 -BackendOnly) after a 30 s delay.
#   TimePlannerWatchdog  runs tools/tunnel-watchdog.ps1, which restarts the
#                        tunnel if it is down or cannot be reached from outside.
# Without them, a reboot leaves the phone unable to connect until someone opens
# the desktop shortcut (2026-10-20), and a dropped tunnel stays down until it
# is restarted by hand (same day, during a release).
# Run with -Remove to delete both tasks; -ValidateOnly only reports state.
param([switch] $Remove, [switch] $ValidateOnly)

$ErrorActionPreference = 'Stop'
$backendTask = 'TimePlannerBackend'
$watchdogTask = 'TimePlannerWatchdog'
$launcher = Join-Path $env:USERPROFILE 'Apps\Timer\Start-Timer.ps1'
$watchdog = Join-Path $PSScriptRoot 'tunnel-watchdog.ps1'

function Get-TaskState([string] $name) {
    Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
}

if ($Remove) {
    $removed = @()
    foreach ($name in @($backendTask, $watchdogTask)) {
        if (Get-TaskState $name) {
            Unregister-ScheduledTask -TaskName $name -Confirm:$false
            $removed += $name
        }
    }
    if ($removed.Count) {
        Write-Output "Removed scheduled tasks: $($removed -join ', ')."
    } else {
        Write-Output "No scheduled tasks $backendTask / $watchdogTask; nothing to remove."
    }
    exit 0
}

if ($ValidateOnly) {
    $missing = @()
    foreach ($name in @($backendTask, $watchdogTask)) {
        $task = Get-TaskState $name
        if (-not $task) {
            Write-Output "Scheduled task $name is not registered."
            $missing += $name
        } else {
            Write-Output "Scheduled task $name is registered ($($task.State))."
        }
    }
    if ($missing.Count) { exit 1 }
    exit 0
}

if (-not (Test-Path -LiteralPath $launcher)) {
    throw 'Start-Timer.ps1 missing; run tools/install-timer.ps1 first.'
}
if (-not (Test-Path -LiteralPath $watchdog)) {
    throw "tunnel-watchdog.ps1 missing next to $PSScriptRoot."
}

$user = "$env:USERDOMAIN\$env:USERNAME"
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited

# Give the network a moment after logon before the tunnel dials out.
$backendAction = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$launcher`" -BackendOnly"
$backendTrigger = New-ScheduledTaskTrigger -AtLogOn -User $user
$backendTrigger.Delay = 'PT30S'
Register-ScheduledTask -TaskName $backendTask -Action $backendAction -Trigger $backendTrigger `
    -Settings $settings -Principal $principal `
    -Description 'Starts the Timer backend and Cloudflare tunnel at logon.' -Force | Out-Null

# The watchdog starts after the backend task, then keeps checking every minute.
$watchdogAction = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$watchdog`""
$watchdogTrigger = New-ScheduledTaskTrigger -AtLogOn -User $user
$watchdogTrigger.Delay = 'PT60S'
Register-ScheduledTask -TaskName $watchdogTask -Action $watchdogAction -Trigger $watchdogTrigger `
    -Settings $settings -Principal $principal `
    -Description 'Restarts the Timer Cloudflare tunnel when it drops or is unreachable.' -Force | Out-Null

foreach ($name in @($backendTask, $watchdogTask)) {
    $registered = Get-ScheduledTask -TaskName $name
    Write-Output "Registered $name ($($registered.State)); runs at logon of $user after $($registered.Triggers[0].Delay)."
    Write-Output "Action: $($registered.Actions[0].Execute) $($registered.Actions[0].Arguments)"
}
