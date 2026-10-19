param([ValidateSet('debug','release')] [string] $Mode = 'release')
$ErrorActionPreference = 'Stop'
$taskProject = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\apps\planner'))
$taskFlutter = Join-Path $env:LOCALAPPDATA 'TimePlanner\toolchains\flutter\bin\flutter.bat'
if (-not (Test-Path -LiteralPath $taskFlutter)) { throw 'Flutter SDK is missing; see docs/STATUS.md' }
$taskATL = Join-Path $env:LOCALAPPDATA 'TimePlanner\toolchains\atl\Contents\VC\Tools\MSVC\14.44.35207\atlmfc'
if (Test-Path -LiteralPath (Join-Path $taskATL 'include\atlbase.h')) { $env:PLANNER_ATL_ROOT = $taskATL }
& (Join-Path $PSScriptRoot 'prepare-windows-plugins.ps1')
Push-Location $taskProject
try {
    & $taskFlutter build windows "--$Mode" --no-pub
    if ($LASTEXITCODE -ne 0) { throw 'Windows build failed' }
} finally { Pop-Location }
