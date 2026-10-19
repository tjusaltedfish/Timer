param([string] $Project = (Join-Path $PSScriptRoot '..\apps\planner'))
$ErrorActionPreference = 'Stop'
$taskApp = [System.IO.Path]::GetFullPath($Project)
$taskMetadata = Get-Content -LiteralPath (Join-Path $taskApp '.flutter-plugins-dependencies') -Raw | ConvertFrom-Json
$taskLinks = Join-Path $taskApp 'windows\flutter\ephemeral\.plugin_symlinks'
New-Item -ItemType Directory -Force -Path $taskLinks | Out-Null
if ((Get-Item -LiteralPath $taskLinks).Attributes -band [IO.FileAttributes]::ReparsePoint) {
    throw 'Plugin link container must be a regular generated project directory.'
}
foreach ($taskPlugin in $taskMetadata.plugins.windows) {
    if ($taskPlugin.name -notmatch '^[a-z0-9_]+$') { throw 'Invalid generated plugin name' }
    $taskTarget = [System.IO.Path]::GetFullPath($taskPlugin.path)
    if (-not (Test-Path -LiteralPath $taskTarget -PathType Container)) { throw 'Plugin package directory is missing' }
    $taskLink = Join-Path $taskLinks $taskPlugin.name
    $taskExisting = Get-Item -LiteralPath $taskLink -Force -ErrorAction SilentlyContinue
    if ($taskExisting) {
        if ($taskExisting.LinkType -notin @('Junction', 'SymbolicLink')) {
            throw 'Generated plugin entry is not a link; left it untouched.'
        }
        $taskOldTarget = [IO.Path]::GetFullPath([string]$taskExisting.Target).TrimEnd('\', '/')
        if ($taskOldTarget -ne $taskTarget.TrimEnd('\', '/')) {
            # The validated plugin name keeps this path inside taskLinks. Remove only the link.
            [IO.Directory]::Delete($taskLink)
            $taskExisting = $null
        }
    }
    if (-not $taskExisting) {
        New-Item -ItemType Junction -Path $taskLink -Target $taskTarget | Out-Null
    }
}
Write-Output 'Prepared local plugin directory junctions; no Windows Developer Mode change.'
