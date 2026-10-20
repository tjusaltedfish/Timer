# Restarts the computer backend on 127.0.0.1:8787 the same way the desktop
# shortcut starts it (Start-Timer.ps1 -BackendOnly), then reports /health.
# Safe to call from scripts whose output is captured: the launcher runs
# detached, so the long-lived backend never holds the caller's output pipe.
param([string] $ExpectVersion)
$ErrorActionPreference = 'Stop'
$launcher = Join-Path $env:USERPROFILE 'Apps\Timer\Start-Timer.ps1'
if (-not (Test-Path -LiteralPath $launcher)) { throw 'Start-Timer.ps1 missing; run tools/install-timer.ps1 first.' }

foreach ($owner in @(Get-NetTCPConnection -LocalPort 8787 -State Listen -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty OwningProcess -Unique)) {
    Stop-Process -Id $owner -Force
}
foreach ($i in 1..20) {
    if (-not (Get-NetTCPConnection -LocalPort 8787 -State Listen -ErrorAction SilentlyContinue)) { break }
    Start-Sleep -Milliseconds 500
}
# Launch through WMI so the backend and tunnel are not children of this shell:
# a process started directly from a terminal or an agent session belongs to its
# job and is killed when that session ends (2026-10-20 the backend and tunnel
# vanished this way after a release). WMI also hands over none of our handles.
$command = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$launcher`" -BackendOnly"
$created = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = $command }
if ($created.ReturnValue -ne 0) { throw "Could not start the launcher (Win32_Process.Create returned $($created.ReturnValue))." }
$health = $null
foreach ($i in 1..40) {
    try { $health = Invoke-RestMethod -TimeoutSec 2 'http://127.0.0.1:8787/health'; break } catch { Start-Sleep -Milliseconds 500 }
}
if (-not $health) { throw 'Backend did not come back on 127.0.0.1:8787; see %USERPROFILE%\TimePlanner\logs\server.err.log' }
if ($ExpectVersion -and ($health.version -ne $ExpectVersion -or $health.app_latest -ne $ExpectVersion)) {
    throw "Backend reports version $($health.version) / phone $($health.app_latest), expected $ExpectVersion."
}
Write-Output "Backend running: version $($health.version), phone release $($health.app_latest)"
exit 0
