param([ValidateSet('debug', 'release')][string] $Mode = 'debug')
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'dev-environment.ps1')
$taskEnv = Initialize-PlannerEnvironment
$taskProject = $taskEnv.App
$taskFlutter = $taskEnv.Flutter
# pubspec.yaml is the only version source; the app shows it and compares it
# with the release the computer offers.
$taskVersion = ((Get-Content -LiteralPath (Join-Path $taskEnv.App 'pubspec.yaml')) |
    Where-Object { $_ -match '^version:\s*(\d+\.\d+\.\d+\+\d+)\s*$' } | Select-Object -First 1) -replace '^version:\s*', ''
if (-not $taskVersion) { throw 'pubspec.yaml version must look like 1.2.3+45.' }
if ($Mode -eq 'release') {
    throw 'Personal release signing is not configured yet. Use debug for local verification; see docs/HANDOFF.md section 9.'
}
# Flutter asset copying fails through the ASCII junction on this Windows setup.
# Use the physical project path and scope the Android path-check override to this build.
Push-Location $taskProject
try {
    & $taskFlutter build apk "--$Mode" --split-per-abi --no-pub '--android-project-arg=android.overridePathCheck=true' "--dart-define=TIMER_VERSION=$taskVersion"
    if ($LASTEXITCODE -ne 0) { throw 'Android build failed.' }
} finally { Pop-Location }
