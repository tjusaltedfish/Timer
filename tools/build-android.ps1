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
    # Release builds sign with the machine's debug key for now (see
    # apps/planner/android/app/build.gradle.kts). That keeps in-place upgrades
    # working for personal installs, and a release APK is ~4x smaller than a
    # debug one. Configure the personal keystore before handing the APK to
    # other people (docs/HANDOFF.md section 9).
    Write-Warning 'Release APK signs with the debug key until the personal keystore is configured.'
}
# Flutter asset copying fails through the ASCII junction on this Windows setup.
# Use the physical project path and scope the Android path-check override to this build.
Push-Location $taskProject
try {
    & $taskFlutter build apk "--$Mode" --split-per-abi --no-pub '--android-project-arg=android.overridePathCheck=true' "--dart-define=TIMER_VERSION=$taskVersion"
    if ($LASTEXITCODE -ne 0) { throw 'Android build failed.' }
} finally { Pop-Location }
