param([ValidateSet('debug', 'release')][string] $Mode = 'debug')
$ErrorActionPreference = 'Stop'
$taskProject = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\apps\planner'))
$taskFlutter = Join-Path $env:LOCALAPPDATA 'TimePlanner\toolchains\flutter\bin\flutter.bat'
$env:ANDROID_HOME = Join-Path $env:LOCALAPPDATA 'TimePlanner\toolchains\android-sdk'
if (-not (Test-Path -LiteralPath $taskFlutter)) { throw 'Flutter SDK is missing.' }
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
