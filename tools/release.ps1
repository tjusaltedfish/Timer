# One-step release for daily use:
#   1. bump the build number in apps/planner/pubspec.yaml (Android versionCode must rise),
#   2. build Windows (release) and Android (debug, arm64 used by the phone),
#   3. install the Windows client (tools/install-timer.ps1),
#   4. publish the phone APK into <data>/releases for in-app updates (not in Git),
#   5. restart the computer backend the way the desktop shortcut starts it.
# Usage: ./tools/release.ps1 [-Version 1.1.0] [-RequireUpdate]
#   -Version        new x.y.z (default: keep the current one, only the build number rises)
#   -RequireUpdate  phones older than this build are told they must update
param([string] $Version, [switch] $RequireUpdate)
$ErrorActionPreference = 'Stop'
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$pubspec = Join-Path $repo 'apps\planner\pubspec.yaml'
$python = Join-Path $repo 'server\.venv\Scripts\python.exe'
$client = Join-Path $env:USERPROFILE 'Apps\Timer\client'
$launcher = Join-Path $env:USERPROFILE 'Apps\Timer\Start-Timer.ps1'
$data = if ($env:PLANNER_DATA_DIR) { $env:PLANNER_DATA_DIR } else { Join-Path $env:LOCALAPPDATA 'TimePlanner\data' }
$utf8 = New-Object System.Text.UTF8Encoding($false)

if (Get-Process -Name time_planner -ErrorAction SilentlyContinue | Where-Object { -not $_.Path -or $_.Path -like "$client*" }) {
    throw 'Timer (computer version) is open. Close the Timer window, then run tools/release.ps1 again.'
}
if ($Version -and $Version -notmatch '^\d+\.\d+\.\d+$') { throw "-Version must look like 1.2.3, got: $Version" }

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
    & (Join-Path $PSScriptRoot 'build-android.ps1') -Mode debug
    & (Join-Path $PSScriptRoot 'install-timer.ps1')
    $apk = Join-Path $repo 'apps\planner\build\app\outputs\flutter-apk\app-arm64-v8a-debug.apk'
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
