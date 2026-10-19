param([Parameter(Mandatory=$true)][string] $Fixture)
$ErrorActionPreference = 'Stop'
$taskProject = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\apps\planner'))
$taskFlutter = Join-Path $env:LOCALAPPDATA 'TimePlanner\toolchains\flutter\bin\flutter.bat'
$env:PLANNER_E2E_FIXTURE = [System.IO.Path]::GetFullPath($Fixture)
$taskATL = Join-Path $env:LOCALAPPDATA 'TimePlanner\toolchains\atl\Contents\VC\Tools\MSVC\14.44.35207\atlmfc'
if (Test-Path -LiteralPath $taskATL) { $env:PLANNER_ATL_ROOT = $taskATL }
& (Join-Path $PSScriptRoot 'prepare-windows-plugins.ps1')
Push-Location $taskProject
try {
    & $taskFlutter test integration_test/desktop_workflow_test.dart -d windows --no-pub
    if ($LASTEXITCODE -ne 0) { throw 'Native desktop integration test failed' }
} finally { Pop-Location }
