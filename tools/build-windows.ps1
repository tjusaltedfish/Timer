param([ValidateSet('debug','release')] [string] $Mode = 'release')
$ErrorActionPreference = 'Stop'
$taskProject = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\apps\planner'))
$taskFlutter = Join-Path $env:LOCALAPPDATA 'TimePlanner\toolchains\flutter\bin\flutter.bat'
if (-not (Test-Path -LiteralPath $taskFlutter)) { throw 'Flutter SDK is missing; see docs/STATUS.md' }
$taskATL = Join-Path $env:LOCALAPPDATA 'TimePlanner\toolchains\atl\Contents\VC\Tools\MSVC\14.44.35207\atlmfc'
if (Test-Path -LiteralPath (Join-Path $taskATL 'include\atlbase.h')) { $env:PLANNER_ATL_ROOT = $taskATL }
$taskOriginal = $taskProject
if ($Mode -eq 'release') {
    # gen_snapshot cannot read the non-ASCII app.dill path on this toolchain.
    # A physical ASCII staging copy also avoids Flutter's junction asset-copy bug.
    $taskStageId = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $taskProject = Join-Path $env:LOCALAPPDATA "TimePlanner\b\$taskStageId"
    New-Item -ItemType Directory -Path $taskProject | Out-Null
    & robocopy $taskOriginal $taskProject /E /XJ /XD build .dart_tool .gradle .git ephemeral .plugin_symlinks /XF local.properties key.properties '*.jks' '*.keystore' /NFL /NDL /NJH /NJS | Out-Null
    if ($LASTEXITCODE -gt 7) { throw 'Could not prepare ASCII build snapshot.' }
}
& (Join-Path $PSScriptRoot 'prepare-windows-plugins.ps1') -Project $taskProject
$taskPreviousPluginRoot = $env:PLANNER_PLUGIN_SOURCE_ROOT
Push-Location $taskProject
try {
    if ($Mode -eq 'release') {
        & $taskFlutter pub get
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
    & $taskFlutter build windows "--$Mode" --no-pub
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
