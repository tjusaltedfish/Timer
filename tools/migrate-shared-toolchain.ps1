# One-time copy from the existing installation to a location outside AppData redirection.
$ErrorActionPreference = 'Stop'
$taskPin = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'toolchain.json') -Raw | ConvertFrom-Json
$taskShared = [IO.Path]::GetFullPath((Join-Path $env:USERPROFILE $taskPin.sharedDirectory))
$taskLegacyTools = Join-Path $env:LOCALAPPDATA 'TimePlanner\toolchains'
$taskSourceVersion = Join-Path $taskLegacyTools 'flutter\bin\cache\flutter.version.json'
if (-not (Test-Path -LiteralPath $taskSourceVersion)) {
    throw 'No existing SDK to migrate. Install the pinned official SDK as described in docs/development-environment.md.'
}
$taskVersion = Get-Content -LiteralPath $taskSourceVersion -Raw | ConvertFrom-Json
if ($taskVersion.frameworkRevision -ne $taskPin.frameworkRevision) { throw 'Existing SDK does not match the pinned revision.' }
$taskTargetTools = Join-Path $taskShared 'toolchains'
$taskTargetVersion = Join-Path $taskTargetTools 'flutter\bin\cache\flutter.version.json'
if (Test-Path -LiteralPath $taskTargetVersion) {
    $taskExistingVersion = Get-Content -LiteralPath $taskTargetVersion -Raw | ConvertFrom-Json
    if ($taskExistingVersion.frameworkRevision -ne $taskPin.frameworkRevision) { throw 'Target has a different SDK; left it untouched.' }
}
New-Item -ItemType Directory -Force -Path $taskShared | Out-Null
Write-Output 'Copying existing SDKs and ATL to the shared toolchain directory...'
& robocopy $taskLegacyTools $taskTargetTools /E /XJ /R:2 /W:1 /XF lockfile index.lock /NFL /NDL /NJH /NJS | Out-Null
if ($LASTEXITCODE -gt 7) { throw 'Toolchain copy failed; original installation was preserved.' }
Write-Output 'Copying existing Pub packages to the shared cache...'
$taskLegacyPub = Join-Path $env:LOCALAPPDATA 'Pub\Cache'
$taskSharedPub = Join-Path $taskShared 'pub-cache'
if (Test-Path -LiteralPath $taskLegacyPub) {
    & robocopy $taskLegacyPub $taskSharedPub /E /XJ /R:2 /W:1 /XD _temp /NFL /NDL /NJH /NJS | Out-Null
    if ($LASTEXITCODE -gt 7) { throw 'Package cache copy failed; original cache was preserved.' }
}
# Regenerate the SDK tool's package metadata against the shared cache, without upgrades.
$env:PUB_CACHE = $taskSharedPub
$env:FLUTTER_ROOT = Join-Path $taskTargetTools 'flutter'
Push-Location (Join-Path $env:FLUTTER_ROOT 'packages\flutter_tools')
try {
    & (Join-Path $env:FLUTTER_ROOT 'bin\cache\dart-sdk\bin\dart.exe') pub get --enforce-lockfile
    if ($LASTEXITCODE -ne 0) { throw 'Flutter tool metadata restoration failed.' }
} finally { Pop-Location }
Write-Output "Shared toolchains ready: $taskShared"
exit 0
