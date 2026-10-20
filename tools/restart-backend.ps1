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
# Start-Process without redirection does not hand our handles to the backend.
# Wait for the launcher only; Start-Process -Wait would also wait for the backend it starts.
$launch = Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -PassThru `
    -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$launcher`"", '-BackendOnly'
$launch.WaitForExit()
$health = $null
foreach ($i in 1..40) {
    try { $health = Invoke-RestMethod -TimeoutSec 2 'http://127.0.0.1:8787/health'; break } catch { Start-Sleep -Milliseconds 500 }
}
if (-not $health) { throw 'Backend did not come back on 127.0.0.1:8787; see %LOCALAPPDATA%\TimePlanner\logs\server.err.log' }
if ($ExpectVersion -and ($health.version -ne $ExpectVersion -or $health.app_latest -ne $ExpectVersion)) {
    throw "Backend reports version $($health.version) / phone $($health.app_latest), expected $ExpectVersion."
}
Write-Output "Backend running: version $($health.version), phone release $($health.app_latest)"
exit 0
