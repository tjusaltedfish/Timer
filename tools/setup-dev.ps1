param([switch] $Clean)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'dev-environment.ps1')
$taskEnv = Initialize-PlannerEnvironment
if (-not (Test-Path -LiteralPath (Join-Path $taskEnv.App 'pubspec.yaml'))) { throw 'Not a planner checkout.' }

# A renamed checkout can leave the optional ASCII alias pointing at a missing folder.
$taskAlias = [IO.Path]::GetFullPath((Join-Path $taskEnv.Shared 'workspace'))
$taskAliasItem = Get-Item -LiteralPath $taskAlias -Force -ErrorAction SilentlyContinue
if ($taskAliasItem) {
    if ($taskAliasItem.LinkType -ne 'Junction') { throw 'Workspace alias is not a junction; left it untouched.' }
    $taskAliasTarget = [IO.Path]::GetFullPath([string]$taskAliasItem.Target)
    if ($taskAliasTarget -ne $taskEnv.Root) {
        # Non-recursive deletion removes only this verified junction, never its target.
        [IO.Directory]::Delete($taskAlias)
        $taskAliasItem = $null
    }
}
if (-not $taskAliasItem) {
    New-Item -ItemType Junction -Path $taskAlias -Target $taskEnv.Root | Out-Null
}

# Local Java properties must follow the selected SDK, not the previous app's AppData view.
$taskLocalProperties = Join-Path $taskEnv.App 'android\local.properties'
$taskPropertyLines = @()
if (Test-Path -LiteralPath $taskLocalProperties) {
    $taskPropertyLines = @([IO.File]::ReadAllLines($taskLocalProperties) |
        Where-Object { $_ -notmatch '^(flutter\.sdk|sdk\.dir)=' })
}
$taskPropertyLines += 'flutter.sdk=' + $taskEnv.FlutterRoot.Replace('\', '/')
$taskPropertyLines += 'sdk.dir=' + $taskEnv.Android.Replace('\', '/')
[IO.File]::WriteAllLines($taskLocalProperties, $taskPropertyLines, [Text.UTF8Encoding]::new($false))

$taskLock = Join-Path $taskEnv.App 'pubspec.lock'
$taskLockHash = (Get-FileHash -LiteralPath $taskLock -Algorithm SHA256).Hash
Push-Location $taskEnv.App
try {
    if ($Clean) {
        # Verify the generated targets before Flutter recursively removes stale build files.
        $taskAppPrefix = $taskEnv.App.TrimEnd('\') + '\'
        foreach ($taskRelative in @('build', '.dart_tool', 'windows\flutter\ephemeral',
                'android\.gradle', 'linux\flutter\ephemeral', 'macos\Flutter\ephemeral', 'ios\Flutter\ephemeral')) {
            $taskGenerated = [IO.Path]::GetFullPath((Join-Path $taskEnv.App $taskRelative))
            if (-not $taskGenerated.StartsWith($taskAppPrefix, [StringComparison]::OrdinalIgnoreCase)) {
                throw 'Generated cleanup target escaped the project.'
            }
            $taskGeneratedItem = Get-Item -LiteralPath $taskGenerated -Force -ErrorAction SilentlyContinue
            if ($taskGeneratedItem -and ($taskGeneratedItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                throw "Generated cleanup root is a reparse point: $taskRelative"
            }
        }
        & $taskEnv.Flutter clean
        if ($LASTEXITCODE -ne 0) { throw 'Flutter cleanup failed.' }
    }
    # Preserve versions and verify hosted package hashes; download only missing dependencies.
    & $taskEnv.Flutter pub get --enforce-lockfile
    $taskPubExit = $LASTEXITCODE
    if ($taskPubExit -ne 0) {
        $taskMetadata = Join-Path $taskEnv.App '.flutter-plugins-dependencies'
        if (-not (Test-Path -LiteralPath $taskMetadata)) { throw 'Dependency restore failed; inspect the output.' }
        & (Join-Path $PSScriptRoot 'prepare-windows-plugins.ps1') -Project $taskEnv.App
        & $taskEnv.Flutter pub get --enforce-lockfile
        if ($LASTEXITCODE -ne 0) { throw 'Dependency restore failed after preparing plugin links.' }
    }
    & (Join-Path $PSScriptRoot 'prepare-windows-plugins.ps1') -Project $taskEnv.App
} finally {
    Pop-Location
    if ($taskLockHash -ne (Get-FileHash -LiteralPath $taskLock -Algorithm SHA256).Hash) {
        throw 'Dependency lock changed unexpectedly; do not commit it as an environment repair.'
    }
}
Write-Output "Ready: Flutter $($taskEnv.Version), checkout $($taskEnv.Root)"
Write-Output "Shared cache: $($taskEnv.PubCache)"
