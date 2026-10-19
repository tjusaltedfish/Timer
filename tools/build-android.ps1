param([ValidateSet('debug', 'release')][string] $Mode = 'debug')
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'dev-environment.ps1')
$taskEnv = Initialize-PlannerEnvironment
$taskProject = $taskEnv.App
$taskFlutter = $taskEnv.Flutter
if ($Mode -eq 'release') {
    throw 'Personal release signing is not configured yet. Use debug for local verification; see docs/HANDOFF.md section 9.'
}
# Flutter asset copying fails through the ASCII junction on this Windows setup.
# Use the physical project path and scope the Android path-check override to this build.
Push-Location $taskProject
try {
    & $taskFlutter build apk "--$Mode" --split-per-abi --no-pub '--android-project-arg=android.overridePathCheck=true'
    if ($LASTEXITCODE -ne 0) { throw 'Android build failed.' }
} finally { Pop-Location }
