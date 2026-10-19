param([Parameter(Mandatory=$true)][string] $Fixture)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'dev-environment.ps1')
$taskEnv = Initialize-PlannerEnvironment
$taskProject = $taskEnv.App
$taskFlutter = $taskEnv.Flutter
$env:PLANNER_E2E_FIXTURE = [System.IO.Path]::GetFullPath($Fixture)
& (Join-Path $PSScriptRoot 'prepare-windows-plugins.ps1')
Push-Location $taskProject
try {
    & $taskFlutter test integration_test/desktop_workflow_test.dart -d windows --no-pub
    if ($LASTEXITCODE -ne 0) { throw 'Native desktop integration test failed' }
} finally { Pop-Location }
