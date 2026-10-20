param([ValidateSet('debug','release')] [string] $Mode = 'release')
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'dev-environment.ps1')
$taskEnv = Initialize-PlannerEnvironment
# pubspec.yaml is the only version source; the app shows it and compares it
# with the release the computer offers.
$taskVersion = ((Get-Content -LiteralPath (Join-Path $taskEnv.App 'pubspec.yaml')) |
    Where-Object { $_ -match '^version:\s*(\d+\.\d+\.\d+\+\d+)\s*$' } | Select-Object -First 1) -replace '^version:\s*', ''
if (-not $taskVersion) { throw 'pubspec.yaml version must look like 1.2.3+45.' }
$taskProject = $taskEnv.App
$taskFlutter = $taskEnv.Flutter
$taskOriginal = $taskProject
if ($Mode -eq 'release') {
    # gen_snapshot cannot read the non-ASCII app.dill path on this toolchain.
    # A physical ASCII staging copy also avoids Flutter's junction asset-copy bug.
    $taskStageId = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $taskProject = Join-Path $taskEnv.Shared "b\$taskStageId"
    New-Item -ItemType Directory -Path $taskProject | Out-Null
    & robocopy $taskOriginal $taskProject /E /XJ /XD build .dart_tool .gradle .git ephemeral .plugin_symlinks /XF local.properties key.properties '*.jks' '*.keystore' /NFL /NDL /NJH /NJS | Out-Null
    if ($LASTEXITCODE -gt 7) { throw 'Could not prepare ASCII build snapshot.' }
}
& (Join-Path $PSScriptRoot 'prepare-windows-plugins.ps1') -Project $taskProject
$taskPreviousPluginRoot = $env:PLANNER_PLUGIN_SOURCE_ROOT
Push-Location $taskProject
try {
    if ($Mode -eq 'release') {
        & $taskFlutter pub get --enforce-lockfile
        if ($LASTEXITCODE -ne 0) { throw 'Dependency resolution failed in ASCII build snapshot.' }
        $taskPluginSources = Join-Path $taskProject 'plugins'
        New-Item -ItemType Directory -Path $taskPluginSources | Out-Null
        $taskMetadata = Get-Content -LiteralPath (Join-Path $taskProject '.flutter-plugins-dependencies') -Raw | ConvertFrom-Json
        foreach ($taskPlugin in $taskMetadata.plugins.windows) {
            if ($taskPlugin.name -notmatch '^[a-z0-9_]+$') { throw 'Invalid generated plugin name.' }
            $taskPackageCopy = Join-Path $taskPluginSources $taskPlugin.name
            & robocopy $taskPlugin.path $taskPackageCopy /E /XJ /XD build .dart_tool .git /NFL /NDL /NJH /NJS | Out-Null
            if ($LASTEXITCODE -gt 7) { throw 'Could not copy native plugin sources.' }
        }
        $env:PLANNER_PLUGIN_SOURCE_ROOT = $taskPluginSources
    }
    & $taskFlutter build windows "--$Mode" --no-pub "--dart-define=TIMER_VERSION=$taskVersion"
    if ($LASTEXITCODE -ne 0) { throw 'Windows build failed' }
} finally {
    Pop-Location
    if ($null -eq $taskPreviousPluginRoot) {
        Remove-Item -LiteralPath Env:PLANNER_PLUGIN_SOURCE_ROOT -ErrorAction SilentlyContinue
    } else {
        $env:PLANNER_PLUGIN_SOURCE_ROOT = $taskPreviousPluginRoot
    }
}
if ($Mode -eq 'release') {
    $taskOutput = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\artifacts\windows-preview-$taskStageId"))
    New-Item -ItemType Directory -Path $taskOutput | Out-Null
    & robocopy (Join-Path $taskProject 'build\windows\x64\runner\Release') $taskOutput /E /NFL /NDL /NJH /NJS | Out-Null
    if ($LASTEXITCODE -gt 7) { throw 'Could not collect Windows preview files.' }
    $taskRecord = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\artifacts\windows-preview.json'))
    @{source=$taskOriginal; staging=$taskProject; output=$taskOutput; executable=(Join-Path $taskOutput 'time_planner.exe')} |
        ConvertTo-Json | Set-Content -LiteralPath $taskRecord -Encoding utf8
    Write-Output "Windows preview folder: $taskOutput"
}
# robocopy reports success with exit codes 1-7; do not leak them as failure.
exit 0
