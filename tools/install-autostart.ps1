# Registers a logon task that starts the computer backend and the Cloudflare
# tunnel (Start-Timer.ps1 -BackendOnly) without opening the client window.
# Without it, a reboot leaves the phone unable to connect until someone opens
# the desktop shortcut (2026-10-20: both were down after a restart).
# Run with -Remove to delete the task again; -ValidateOnly only reports state.
param([switch] $Remove, [switch] $ValidateOnly)

$ErrorActionPreference = 'Stop'
$taskName = 'TimePlannerBackend'
$launcher = Join-Path $env:USERPROFILE 'Apps\Timer\Start-Timer.ps1'

function Get-TaskState {
    Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
}

if ($Remove) {
    if (Get-TaskState) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
        Write-Output "Removed scheduled task $taskName."
    } else {
        Write-Output "No scheduled task $taskName; nothing to remove."
    }
    exit 0
}

if ($ValidateOnly) {
    $task = Get-TaskState
    if (-not $task) { Write-Output "Scheduled task $taskName is not registered."; exit 1 }
    Write-Output "Scheduled task $taskName is registered ($($task.State))."
    exit 0
}

if (-not (Test-Path -LiteralPath $launcher)) {
    throw 'Start-Timer.ps1 missing; run tools/install-timer.ps1 first.'
}

$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$launcher`" -BackendOnly"

# Give the network a moment after logon before the tunnel dials out.
$trigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
$trigger.Delay = 'PT30S'

# No execution limit (the launcher is meant to keep running) and a few retries
# if the backend cannot bind immediately after logon.
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" `
    -LogonType Interactive -RunLevel Limited

Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
    -Settings $settings -Principal $principal `
    -Description 'Starts the 瞬时 backend and Cloudflare tunnel at logon.' -Force | Out-Null

$registered = Get-ScheduledTask -TaskName $taskName
Write-Output "Registered $taskName ($($registered.State)); runs at logon of $env:USERDOMAIN\$env:USERNAME after 30 s."
Write-Output "Action: $($registered.Actions[0].Execute) $($registered.Actions[0].Arguments)"
