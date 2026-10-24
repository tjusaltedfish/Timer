# One-step release for daily use:
#   1. bump the build number in apps/planner/pubspec.yaml (Android versionCode must rise),
#   2. build Windows (release) and Android (release, signed with this PC's debug key; arm64 used by the phone),
#   3. install the Windows client (tools/install-timer.ps1),
#   4. publish the phone APK into <data>/releases for in-app updates (not in Git),
#   5. restart the computer backend the way the desktop shortcut starts it.
# Usage: ./tools/release.ps1 [-Version 1.1.0] [-RequireUpdate]
#   -Version        new x.y.z (default: keep the current one, only the build number rises)
#   -RequireUpdate  phones older than this build are told they must update
param([string] $Version, [switch] $RequireUpdate, [switch] $Prepared, [switch] $ValidateOnly)
$ErrorActionPreference = 'Stop'
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$pubspec = Join-Path $repo 'apps\planner\pubspec.yaml'
$python = Join-Path $repo 'server\.venv\Scripts\python.exe'
$client = Join-Path $env:USERPROFILE 'Apps\Timer\client'
$launcher = Join-Path $env:USERPROFILE 'Apps\Timer\Start-Timer.ps1'
$data = if ($env:PLANNER_DATA_DIR) { $env:PLANNER_DATA_DIR } else { Join-Path $env:USERPROFILE 'TimePlanner\data' }
$utf8 = New-Object System.Text.UTF8Encoding($false)

if ($ValidateOnly -and -not $Prepared) { throw '-ValidateOnly requires -Prepared.' }
if (-not ($Prepared -and $ValidateOnly) -and (Get-Process -Name time_planner -ErrorAction SilentlyContinue | Where-Object { -not $_.Path -or $_.Path -like "$client*" })) {
    throw 'Timer (computer version) is open. Close the Timer window, then run tools/release.ps1 again.'
}
if ($Version -and $Version -notmatch '^\d+\.\d+\.\d+$') { throw "-Version must look like 1.2.3, got: $Version" }

# A prepared build can be activated from the user's ordinary terminal without
# rebuilding, or inheriting a packaged development app's AppData redirection.
if ($Prepared) {
    if ($Version) { throw '-Prepared reads its version from the prepared manifest; omit -Version.' }
    $preparedPath = Join-Path $repo 'artifacts\prepared-release.json'
    if (-not (Test-Path -LiteralPath $preparedPath)) { throw 'No prepared release found.' }
    $preparedRelease = Get-Content -LiteralPath $preparedPath -Raw | ConvertFrom-Json
    if ($preparedRelease.version -notmatch '^\d+\.\d+\.\d+\+\d+$' -or -not $preparedRelease.files -or
        -not ($preparedRelease.files | Where-Object { $_.path -eq 'time_planner.exe' })) { throw 'Prepared release manifest is incomplete.' }
    $sourceVersion = [regex]::Match([IO.File]::ReadAllText($pubspec), '(?m)^version:\s*(\S+)').Groups[1].Value
    if ($sourceVersion -ne $preparedRelease.version) { throw 'Prepared release differs from pubspec.yaml.' }
    $artifactPrefix = [IO.Path]::GetFullPath((Join-Path $repo 'artifacts')).TrimEnd('\') + '\'
    $preparedWindows = [IO.Path]::GetFullPath([string]$preparedRelease.windows)
    $preparedApk = [IO.Path]::GetFullPath([string]$preparedRelease.apk)
    if (-not $preparedWindows.StartsWith($artifactPrefix, [StringComparison]::OrdinalIgnoreCase) -or
        -not $preparedApk.StartsWith($artifactPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Prepared files must be inside this checkout artifacts folder.' }
    if ((Get-FileHash -LiteralPath $preparedApk -Algorithm SHA256).Hash -ne $preparedRelease.apk_sha256) { throw 'Prepared APK checksum differs.' }
    foreach ($entry in $preparedRelease.files) {
        $candidate = [IO.Path]::GetFullPath((Join-Path $preparedWindows $entry.path))
        if (-not $candidate.StartsWith($preparedWindows.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Invalid prepared Windows file path.' }
        if ((Get-FileHash -LiteralPath $candidate -Algorithm SHA256).Hash -ne $entry.sha256) { throw 'Prepared Windows file checksum differs.' }
    }
    if ($ValidateOnly) {
        Write-Output "Verified prepared release $($preparedRelease.version); no installed files or data changed."
        exit 0
    }
    & (Join-Path $PSScriptRoot 'install-timer.ps1') -Build $preparedWindows
    if ($LASTEXITCODE -ne 0) { throw 'Prepared Windows install failed.' }
    $preparedArgs = @('-m', 'app.releases', 'publish', $preparedApk, '--version', $preparedRelease.version, '--data', $data)
    if ($RequireUpdate) { $preparedArgs += '--require' }
    Push-Location (Join-Path $repo 'server')
    try {
        & $python @preparedArgs
        if ($LASTEXITCODE -ne 0) { throw 'Prepared phone publish failed.' }
    } finally { Pop-Location }
    & (Join-Path $PSScriptRoot 'restart-backend.ps1') -ExpectVersion $preparedRelease.version
    Write-Output "Activated prepared version $($preparedRelease.version). Open the phone app to update."
    exit 0
}

$original = [IO.File]::ReadAllText($pubspec, $utf8)
$match = [regex]::Match($original, '(?m)^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$')
if (-not $match.Success) { throw 'pubspec.yaml version must look like 1.2.3+45.' }
$published = 0
$record = Join-Path $data 'releases\latest.json'
if (Test-Path -LiteralPath $record) {
    $published = [int]((Get-Content -LiteralPath $record -Raw | ConvertFrom-Json).build)
}
$build = [Math]::Max([int]$match.Groups[2].Value, $published) + 1
$name = if ($Version) { $Version } else { $match.Groups[1].Value }
$next = "$name+$build"
$old = "$($match.Groups[1].Value)+$($match.Groups[2].Value)"
Write-Output "Release: $old -> $next"
[IO.File]::WriteAllText($pubspec, [regex]::Replace($original, '(?m)^version:.*$', "version: $next", 1), $utf8)

try {
    & (Join-Path $PSScriptRoot 'build-windows.ps1') -Mode release
    & (Join-Path $PSScriptRoot 'build-android.ps1') -Mode release
    & (Join-Path $PSScriptRoot 'install-timer.ps1')
    $apk = Join-Path $repo 'apps\planner\build\app\outputs\flutter-apk\app-arm64-v8a-release.apk'
    if (-not (Test-Path -LiteralPath $apk)) { throw "Android build did not produce $apk" }
    $publishArgs = @('-m', 'app.releases', 'publish', $apk, '--version', $next, '--data', $data)
    if ($RequireUpdate) { $publishArgs += '--require' }
    Push-Location (Join-Path $repo 'server')
    try {
        & $python @publishArgs
        if ($LASTEXITCODE -ne 0) { throw 'Publishing the phone release failed.' }
    } finally { Pop-Location }
} catch {
    # Nothing was released: put the version number back so the next try reuses it.
    [IO.File]::WriteAllText($pubspec, $original, $utf8)
    throw
}

# Restart the backend so it reports the new version and serves the new APK.
& (Join-Path $PSScriptRoot 'restart-backend.ps1') -ExpectVersion $next
Write-Output "Released $next. Computer: installed, backend restarted. Phone: open Timer to get the update prompt."
exit 0
