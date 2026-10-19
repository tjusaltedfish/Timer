param([string] $Project = (Join-Path $PSScriptRoot '..\apps\planner'))
$ErrorActionPreference = 'Stop'
$taskApp = [System.IO.Path]::GetFullPath($Project)
$taskMetadata = Get-Content -LiteralPath (Join-Path $taskApp '.flutter-plugins-dependencies') -Raw | ConvertFrom-Json
$taskLinks = Join-Path $taskApp 'windows\flutter\ephemeral\.plugin_symlinks'
New-Item -ItemType Directory -Force -Path $taskLinks | Out-Null
foreach ($taskPlugin in $taskMetadata.plugins.windows) {
    if ($taskPlugin.name -notmatch '^[a-z0-9_]+$') { throw 'Invalid generated plugin name' }
    $taskTarget = [System.IO.Path]::GetFullPath($taskPlugin.path)
    if (-not (Test-Path -LiteralPath $taskTarget -PathType Container)) { throw 'Plugin package directory is missing' }
    $taskLink = Join-Path $taskLinks $taskPlugin.name
    if (-not (Test-Path -LiteralPath $taskLink)) {
        New-Item -ItemType Junction -Path $taskLink -Target $taskTarget | Out-Null
    }
}
Write-Output 'Prepared local plugin directory junctions; no Windows Developer Mode change.'
