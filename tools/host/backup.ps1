# Daily online backup of the Timer v2 data directory.
#
# planner.db is copied with SQLite's online backup API (sqlite3.Connection.backup)
# through the repository's own interpreter (server\.venv\Scripts\python.exe), so a
# running backend never yields a torn copy and no sqlite3.exe is required. users/ is
# mirrored next to it with robocopy; -wal / -shm / -journal are excluded because they
# belong to the live copy (the backup file itself is always self-contained).
# A latest.txt pointer and the "14 days + 8 weeks" retention complete the set.
#
# Nothing is written inside -DataDir. Logs default to the folder above -Target,
# i.e. %USERPROFILE%\TimePlanner\backups\backup.log for the default target.
# Safe to re-run; paths with spaces are handled via -LiteralPath and quoted args.
#
# Examples:
#   .\tools\host\backup.ps1
#   .\tools\host\backup.ps1 -DataDir D:\Timer\data -Target D:\Timer\backups\daily -KeepDays 30
#   .\tools\host\backup.ps1 -IncludeSecrets   # also copy data\secrets (opt-in, plaintext)
#
# Exit codes: 0 = backup written and retention applied; 1 = any step failed.
param(
    [string] $DataDir = (Join-Path $env:USERPROFILE 'TimePlanner\data'),
    [string] $Target = (Join-Path $env:USERPROFILE 'TimePlanner\backups\daily'),
    [ValidateRange(1, 3650)][int] $KeepDays = 14,
    [ValidateRange(1, 520)][int] $KeepWeeks = 8,
    # Weekly archives live next to the daily folder by default (...\backups\weekly).
    [string] $WeeklyTarget,
    # Write a weekly archive now even if the newest one is younger than 7 days.
    [switch] $ForceWeekly,
    [string] $LogPath,
    [string] $Python,
    # Off by default: secrets/ holds the WeChat appsecret/Token and the LLM key.
    [switch] $IncludeSecrets
)

$ErrorActionPreference = 'Stop'

function Get-FullPath([string] $path) {
    if ([string]::IsNullOrWhiteSpace($path)) { throw 'A required path is empty.' }
    return ([IO.Path]::GetFullPath($path)).TrimEnd('\')
}

# True when $child is $parent or lives below it (case-insensitive, Windows rules).
function Test-Inside([string] $child, [string] $parent) {
    $c = Get-FullPath $child
    $p = Get-FullPath $parent
    if ($c.Equals($p, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    return $c.StartsWith($p + '\', [StringComparison]::OrdinalIgnoreCase)
}

# planner-20261022-030000.db / .users / .secrets -> [datetime]; $null for other names.
function Get-BackupTime([string] $name) {
    $match = [regex]::Match($name, '^planner-(\d{8}-\d{6})(\.db|\.users|\.secrets)$')
    if (-not $match.Success) { return $null }
    return [datetime]::ParseExact($match.Groups[1].Value, 'yyyyMMdd-HHmmss',
        [Globalization.CultureInfo]::InvariantCulture)
}

$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
if (-not $Python) {
    $Python = Join-Path $repo 'server\.venv\Scripts\python.exe'
    if (-not (Test-Path -LiteralPath $Python)) {
        $found = Get-Command python.exe -ErrorAction SilentlyContinue
        if (-not $found) { throw 'No Python found: expected server\.venv\Scripts\python.exe; pass -Python.' }
        $Python = $found.Source
    }
}

$resolvedTarget = Get-FullPath $Target
if (-not $LogPath) { $LogPath = Join-Path (Split-Path -Parent $resolvedTarget) 'backup.log' }
$logFull = Get-FullPath $LogPath

function Write-Log([string] $message) {
    $line = '{0:yyyy-MM-dd HH:mm:ss} {1}' -f (Get-Date), $message
    $dir = Split-Path -Parent $logFull
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    if ((Test-Path -LiteralPath $logFull) -and (Get-Item -LiteralPath $logFull).Length -gt 2MB) {
        Move-Item -LiteralPath $logFull -Destination ($logFull + '.old') -Force
    }
    Add-Content -LiteralPath $logFull -Value $line -Encoding utf8
    Write-Host $line
}

function Copy-Tree([string] $source, [string] $destination) {
    New-Item -ItemType Directory -Force -Path $destination | Out-Null
    # /XF drops WAL side files; robocopy success is 0-7.
    & robocopy $source $destination /E /XF '*-wal' '*-shm' '*-journal' /NFL /NDL /NJH /NJS /R:2 /W:2 | Out-Null
    $code = $LASTEXITCODE
    $global:LASTEXITCODE = 0
    if ($code -gt 7) { throw "robocopy failed copying '$source' (exit $code)." }
}

# SQLite writes the copy through its own online backup API; the child process keeps
# this script independent of any Python packages installed in server/.venv.
$backupCode = @'
import sqlite3
import sys

source_path, target_path = sys.argv[1], sys.argv[2]
source = sqlite3.connect(source_path, timeout=30)
target = sqlite3.connect(target_path)
try:
    source.backup(target)
finally:
    target.close()
    source.close()
check = sqlite3.connect(target_path)
try:
    integrity = check.execute('PRAGMA integrity_check').fetchone()[0]
    tables = check.execute("SELECT count(*) FROM sqlite_master WHERE type='table'").fetchone()[0]
finally:
    check.close()
if integrity != 'ok':
    print('integrity_check failed: %s' % integrity, file=sys.stderr)
    sys.exit(3)
print('integrity=ok tables=%d' % tables)
'@

function Remove-BackupSet([string] $folder, [string] $baseName) {
    foreach ($candidate in @(
            (Join-Path $folder ($baseName + '.db')),
            (Join-Path $folder ($baseName + '.users')),
            (Join-Path $folder ($baseName + '.secrets')))) {
        if (Test-Path -LiteralPath $candidate) {
            Remove-Item -LiteralPath $candidate -Recurse -Force
            Write-Log "prune: removed $candidate"
        }
    }
}

$started = Get-Date
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'

try {
    $resolvedData = Get-FullPath $DataDir
    if (-not (Test-Path -LiteralPath $resolvedData -PathType Container)) {
        throw "Data directory does not exist: $resolvedData"
    }
    $sourceDb = Join-Path $resolvedData 'planner.db'
    if (-not (Test-Path -LiteralPath $sourceDb -PathType Leaf)) {
        throw "No planner.db in $resolvedData (wrong -DataDir?)."
    }
    # Never write a backup inside the data directory, and never treat the data
    # directory as a backup folder (retention would otherwise delete live files).
    if (Test-Inside $resolvedTarget $resolvedData) { throw "-Target must not be inside -DataDir ($resolvedData)." }
    if (Test-Inside $resolvedData $resolvedTarget) { throw "-DataDir must not be inside -Target ($resolvedTarget)." }

    Write-Log "backup: start data=$resolvedData target=$resolvedTarget keep=${KeepDays}d/${KeepWeeks}w python=$Python"
    New-Item -ItemType Directory -Force -Path $resolvedTarget | Out-Null

    $baseName = "planner-$stamp"
    $dbDest = Join-Path $resolvedTarget ($baseName + '.db')
    $usersDest = Join-Path $resolvedTarget ($baseName + '.users')
    $secretsDest = Join-Path $resolvedTarget ($baseName + '.secrets')

    # 1. Database through SQLite's online backup API.
    $output = $backupCode | & $Python - $sourceDb $dbDest
    if ($LASTEXITCODE -ne 0) {
        Remove-Item -LiteralPath $dbDest -Force -ErrorAction SilentlyContinue
        throw "SQLite backup failed (python exit $LASTEXITCODE)."
    }
    $db = Get-Item -LiteralPath $dbDest
    Write-Log ("sqlite: {0}; size={1} bytes" -f (($output | Out-String).Trim()), $db.Length)

    # 2. users/ (materials, memes, avatars) with WAL side files excluded.
    $usersSource = Join-Path $resolvedData 'users'
    if (Test-Path -LiteralPath $usersSource -PathType Container) {
        Copy-Tree $usersSource $usersDest
        Write-Log "users: copied $usersSource -> $usersDest"
    } else {
        Write-Log 'users: directory absent; nothing to copy'
    }

    # 3. secrets/ only when asked: it contains the WeChat appsecret/Token and LLM key.
    if ($IncludeSecrets) {
        $secretsSource = Join-Path $resolvedData 'secrets'
        if (Test-Path -LiteralPath $secretsSource -PathType Container) {
            Copy-Tree $secretsSource $secretsDest
            Write-Log "secrets: copied $secretsSource -> $secretsDest (plaintext; protect the backup folder)"
        } else {
            Write-Log 'secrets: directory absent; nothing to copy'
        }
    }

    # 4. latest pointer (written only after the copy is usable).
    $latestFile = Join-Path $resolvedTarget 'latest.txt'
    $latestLines = @(
        "stamp=$stamp",
        "time=$((Get-Date).ToString('s'))",
        "db=$baseName.db",
        "users=$(if (Test-Path -LiteralPath $usersDest) { $baseName + '.users' } else { '' })",
        "secrets=$(if (Test-Path -LiteralPath $secretsDest) { $baseName + '.secrets' } else { '' })",
        "source=$resolvedData",
        'integrity=ok'
    )
    Set-Content -LiteralPath $latestFile -Value $latestLines -Encoding utf8
    Write-Log "latest: wrote $latestFile"

    # 5. Weekly archive: next to the daily folder, at most one per 7 days.
    $resolvedWeekly = if ($WeeklyTarget) { Get-FullPath $WeeklyTarget } else { Join-Path (Split-Path -Parent $resolvedTarget) 'weekly' }
    $weeklyDb = $null
    $weeklyTimes = @()
    if (Test-Path -LiteralPath $resolvedWeekly -PathType Container) {
        foreach ($entry in @(Get-ChildItem -LiteralPath $resolvedWeekly -File -Force -ErrorAction SilentlyContinue)) {
            $parsed = Get-BackupTime $entry.Name
            if ($parsed -and $entry.Name.EndsWith('.db')) { $weeklyTimes += $parsed }
        }
    }
    $newestWeekly = if ($weeklyTimes.Count -gt 0) { ($weeklyTimes | Sort-Object -Descending)[0] } else { $null }
    $weeklyDue = $ForceWeekly -or (-not $newestWeekly) -or (((Get-Date) - $newestWeekly).TotalDays -ge 7)
    if ($weeklyDue) {
        New-Item -ItemType Directory -Force -Path $resolvedWeekly | Out-Null
        $candidateDb = Join-Path $resolvedWeekly ($baseName + '.db')
        Copy-Item -LiteralPath $dbDest -Destination $candidateDb -Force
        if (Test-Path -LiteralPath $usersDest) {
            Copy-Tree $usersDest (Join-Path $resolvedWeekly ($baseName + '.users'))
        }
        if (Test-Path -LiteralPath $secretsDest) {
            Copy-Tree $secretsDest (Join-Path $resolvedWeekly ($baseName + '.secrets'))
        }
        $weeklyDb = $candidateDb
        Write-Log "weekly: wrote $candidateDb"
    } else {
        Write-Log ("weekly: not due (newest {0:yyyy-MM-dd HH:mm:ss}); skipped" -f $newestWeekly)
    }

    # 6. Retention: daily by age, weekly by count. The set just written is never removed.
    $cutoff = (Get-Date).AddDays(-$KeepDays)
    foreach ($entry in @(Get-ChildItem -LiteralPath $resolvedTarget -File -Force -ErrorAction SilentlyContinue)) {
        if ($entry.Name -eq ($baseName + '.db')) { continue }
        $parsed = Get-BackupTime $entry.Name
        if ($parsed -and $entry.Name.EndsWith('.db') -and $parsed -lt $cutoff) {
            Remove-BackupSet $resolvedTarget ([IO.Path]::GetFileNameWithoutExtension($entry.Name))
        }
    }
    # Companion folders whose database disappeared are cleaned up the same way.
    foreach ($entry in @(Get-ChildItem -LiteralPath $resolvedTarget -Directory -Force -ErrorAction SilentlyContinue)) {
        $parsed = Get-BackupTime $entry.Name
        if (-not $parsed -or $parsed -ge $cutoff) { continue }
        $companionDb = Join-Path $resolvedTarget ($entry.Name.Substring(0, $entry.Name.LastIndexOf('.')) + '.db')
        if (-not (Test-Path -LiteralPath $companionDb)) {
            Remove-Item -LiteralPath $entry.FullName -Recurse -Force
            Write-Log "prune: removed orphan $($entry.FullName)"
        }
    }
    if (Test-Path -LiteralPath $resolvedWeekly -PathType Container) {
        $weeklyDbs = @(Get-ChildItem -LiteralPath $resolvedWeekly -File -Filter 'planner-*.db' -Force |
            Sort-Object Name -Descending)
        if ($weeklyDbs.Count -gt $KeepWeeks) {
            foreach ($old in @($weeklyDbs[$KeepWeeks..($weeklyDbs.Count - 1)])) {
                Remove-BackupSet $resolvedWeekly ([IO.Path]::GetFileNameWithoutExtension($old.Name))
            }
        }
    }

    $elapsed = ((Get-Date) - $started).TotalSeconds
    Write-Log ("backup: done in {0:N1}s db={1} bytes" -f $elapsed, $db.Length)
    Write-Output "Backup OK: $dbDest"
    Write-Output "Latest pointer: $latestFile"
    if ($weeklyDb) { Write-Output "Weekly archive: $weeklyDb" }
    exit 0
} catch {
    $message = $_.Exception.Message
    try { Write-Log "backup: FAILED: $message" } catch { }
    [Console]::Error.WriteLine("Backup failed: $message")
    exit 1
}
