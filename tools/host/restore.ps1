# Restores a Timer v2 backup made by tools/host/backup.ps1 into a data directory.
#
# Safety rules, in order:
#   * the backup must live under -AllowedBackupRoot (default ...\TimePlanner\backups);
#   * -DataDir must live under an allowed root (default ...\TimePlanner and %TEMP%);
#     restoring into the repository or a drive root is refused;
#   * a backend listening on -Port makes the script stop with exit 2 unless -Force;
#   * nothing is deleted: the current planner.db (and users/ when replaced) is renamed
#     to *.pre-restore-<timestamp>, so the previous state can be put back by hand;
#   * the backup database is opened and integrity-checked before anything is touched.
#
# -BackupDir accepts a planner-YYYYMMDD-HHMMSS.db file, a backup folder (newest
# planner-*.db inside is used), or that folder's latest.txt pointer.
#
# Examples:
#   .\tools\host\restore.ps1 -BackupDir "%USERPROFILE%\TimePlanner\backups\daily"
#   .\tools\host\restore.ps1 -BackupDir D:\backups\weekly\planner-20261018-030000.db
#   .\tools\host\restore.ps1 -BackupDir ... -DataDir D:\Timer\data -Force
#
# Exit codes: 0 = restored; 1 = validation/IO failure; 2 = port in use without -Force.
param(
    [Parameter(Mandatory = $true)][string] $BackupDir,
    [string] $DataDir = (Join-Path $env:USERPROFILE 'TimePlanner\data'),
    [switch] $Force,
    [ValidateRange(1, 65535)][int] $Port = 8765,
    # Semicolon-separated list also accepted: -AllowedDataRoots "D:\Timer;E:\Timer".
    [string[]] $AllowedDataRoots = @((Join-Path $env:USERPROFILE 'TimePlanner'), $env:TEMP),
    [string] $AllowedBackupRoot = (Join-Path $env:USERPROFILE 'TimePlanner\backups'),
    [string] $Python,
    [string] $LogPath
)

$ErrorActionPreference = 'Stop'

function Get-FullPath([string] $path) {
    if ([string]::IsNullOrWhiteSpace($path)) { throw 'A required path is empty.' }
    return ([IO.Path]::GetFullPath($path)).TrimEnd('\')
}

function Test-Inside([string] $child, [string] $parent) {
    $c = Get-FullPath $child
    $p = Get-FullPath $parent
    if ($c.Equals($p, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    return $c.StartsWith($p + '\', [StringComparison]::OrdinalIgnoreCase)
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

$resolvedData = Get-FullPath $DataDir
if (-not $LogPath) { $LogPath = Join-Path (Split-Path -Parent $resolvedData) 'restore.log' }
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

# Opens a SQLite file read-only-ish and reports integrity plus table count.
$verifyCode = @'
import sqlite3
import sys

path = sys.argv[1]
connection = sqlite3.connect(path)
try:
    row = connection.execute('PRAGMA integrity_check').fetchone()
    tables = connection.execute("SELECT count(*) FROM sqlite_master WHERE type='table'").fetchone()[0]
    quick = connection.execute('PRAGMA quick_check').fetchone()[0]
finally:
    connection.close()
if not row or row[0] != 'ok' or quick != 'ok':
    print('integrity_check failed: %s / %s' % (row, quick), file=sys.stderr)
    sys.exit(3)
print('integrity=ok tables=%d' % tables)
'@

function Get-SqliteReport([string] $path) {
    $report = $verifyCode | & $Python - $path
    if ($LASTEXITCODE -ne 0) { throw "SQLite verification failed for '$path'." }
    return ($report | Out-String).Trim()
}

function Copy-Tree([string] $source, [string] $destination) {
    New-Item -ItemType Directory -Force -Path $destination | Out-Null
    & robocopy $source $destination /E /XF '*-wal' '*-shm' '*-journal' /NFL /NDL /NJH /NJS /R:2 /W:2 | Out-Null
    $code = $LASTEXITCODE
    $global:LASTEXITCODE = 0
    if ($code -gt 7) { throw "robocopy failed copying '$source' (exit $code)." }
}

# Resolves -BackupDir to an existing planner database file.
function Find-BackupDatabase([string] $inputPath) {
    $path = Get-FullPath $inputPath
    if (-not (Test-Path -LiteralPath $path)) { throw "Backup path not found: $path" }
    $item = Get-Item -LiteralPath $path -Force
    if ($item.PSIsContainer) {
        $databases = @(Get-ChildItem -LiteralPath $path -File -Filter 'planner-*.db' -Force -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending)
        if ($databases.Count -gt 0) { return $databases[0].FullName }
        $single = Join-Path $path 'planner.db'
        if (Test-Path -LiteralPath $single -PathType Leaf) { return $single }
        throw "No planner-*.db (or planner.db) in $path"
    }
    if ($item.Name -ieq 'latest.txt') {
        $dbLine = @(Get-Content -LiteralPath $path | Where-Object { $_ -match '^db=' }) | Select-Object -First 1
        if (-not $dbLine) { throw "latest.txt has no db= line: $path" }
        $relative = $dbLine.Substring(3).Trim()
        $resolved = if ([IO.Path]::IsPathRooted($relative)) { $relative } else { Join-Path $item.DirectoryName $relative }
        if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) { throw "latest.txt points at a missing file: $resolved" }
        return (Get-FullPath $resolved)
    }
    if ($item.Extension -ieq '.db') { return $item.FullName }
    throw "Unsupported -BackupDir: $path (pass a planner-*.db, a backup folder, or latest.txt)"
}

$started = Get-Date
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'

try {
    $backupDb = Get-FullPath (Find-BackupDatabase $BackupDir)
    $backupParent = Split-Path -Parent $backupDb
    if (-not (Test-Inside $backupDb $AllowedBackupRoot)) {
        throw "Refusing to restore from '$backupDb': it is outside '$AllowedBackupRoot'. Pass -AllowedBackupRoot to override."
    }
    if (Test-Inside $backupDb $resolvedData) {
        throw "Refusing to restore: the backup file lives inside -DataDir ($resolvedData)."
    }
    if (Test-Inside $resolvedData $backupParent) {
        throw "Refusing to restore into '$resolvedData': it is the backup folder itself."
    }

    $roots = @($AllowedDataRoots | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($roots.Count -eq 0) { throw '-AllowedDataRoots is empty.' }
    $allowedData = $false
    foreach ($root in $roots) {
        if (Test-Inside $resolvedData $root) { $allowedData = $true; break }
    }
    if (-not $allowedData) {
        throw "Refusing to restore into '$resolvedData': not under any allowed root ($($roots -join '; ')). Pass -AllowedDataRoots to override."
    }
    if (Test-Inside $resolvedData $repo) { throw "Refusing to restore inside the repository ($repo)." }
    if ((Split-Path -Parent $resolvedData) -eq $resolvedData) { throw "Refusing to restore into a drive root: $resolvedData" }

    Write-Log "restore: start backup=$backupDb data=$resolvedData port=$Port force=$Force"

    # Verify the source before touching the live directory.
    $sourceReport = Get-SqliteReport $backupDb
    Write-Log "restore: backup check: $sourceReport"
    $backupBytes = (Get-Item -LiteralPath $backupDb).Length

    # A live backend holds the database open; renaming behind its back is unsafe.
    $listeners = @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue)
    if ($listeners.Count -gt 0) {
        $pids = @($listeners | Select-Object -ExpandProperty OwningProcess -Unique) -join ', '
        if (-not $Force) {
            Write-Log "restore: STOP port $Port is listening (pid $pids); no changes made"
            [Console]::Error.WriteLine("Port $Port is in use (pid $pids): stop the backend first, then re-run.")
            [Console]::Error.WriteLine('  schtasks /End /TN TimePlannerBackend')
            [Console]::Error.WriteLine('  # or: Stop-Process -Id <pid> -Force')
            [Console]::Error.WriteLine('Pass -Force only if you are sure the service is not writing.')
            exit 2
        }
        Write-Log "restore: WARN port $Port is still listening (pid $pids); continuing because -Force was given"
    }

    if (-not (Test-Path -LiteralPath $resolvedData -PathType Container)) {
        New-Item -ItemType Directory -Force -Path $resolvedData | Out-Null
        Write-Log "restore: created data directory $resolvedData"
    }

    $currentDb = Join-Path $resolvedData 'planner.db'
    $previousDb = "$currentDb.pre-restore-$stamp"
    if (Test-Path -LiteralPath $currentDb) {
        Move-Item -LiteralPath $currentDb -Destination $previousDb -Force
        Write-Log "restore: kept previous database as $previousDb"
    }
    # Stale WAL/SHM side files belong to the replaced database; move them too.
    foreach ($suffix in @('-wal', '-shm', '-journal')) {
        $side = "$currentDb$suffix"
        if (Test-Path -LiteralPath $side) {
            Move-Item -LiteralPath $side -Destination "$previousDb$suffix" -Force
            Write-Log "restore: moved stale side file to $previousDb$suffix"
        }
    }
    Copy-Item -LiteralPath $backupDb -Destination $currentDb -Force
    Write-Log "restore: copied backup ($backupBytes bytes) to $currentDb"

    # users/ and (opt-in) secrets/ arrive next to the database in the same backup.
    $backupBase = [IO.Path]::GetFileNameWithoutExtension($backupDb)
    $backupUsers = Join-Path $backupParent ($backupBase + '.users')
    $backupSecrets = Join-Path $backupParent ($backupBase + '.secrets')
    $restoredExtras = @()
    if (Test-Path -LiteralPath $backupUsers -PathType Container) {
        $currentUsers = Join-Path $resolvedData 'users'
        if (Test-Path -LiteralPath $currentUsers) {
            $previousUsers = Join-Path $resolvedData "users.pre-restore-$stamp"
            Move-Item -LiteralPath $currentUsers -Destination $previousUsers -Force
            Write-Log "restore: kept previous users folder as $previousUsers"
        }
        Copy-Tree $backupUsers $currentUsers
        $restoredExtras += 'users'
        Write-Log "restore: copied users -> $currentUsers"
    } else {
        Write-Log 'restore: backup has no users snapshot; existing users/ left untouched'
    }
    if (Test-Path -LiteralPath $backupSecrets -PathType Container) {
        $currentSecrets = Join-Path $resolvedData 'secrets'
        if (Test-Path -LiteralPath $currentSecrets) {
            $previousSecrets = Join-Path $resolvedData "secrets.pre-restore-$stamp"
            Move-Item -LiteralPath $currentSecrets -Destination $previousSecrets -Force
            Write-Log "restore: kept previous secrets folder as $previousSecrets"
        }
        Copy-Tree $backupSecrets $currentSecrets
        $restoredExtras += 'secrets'
        Write-Log "restore: copied secrets -> $currentSecrets"
    }

    # Verify the restored copy before telling anyone to start the service.
    $restoredReport = Get-SqliteReport $currentDb
    Write-Log "restore: restored check: $restoredReport"
    if ($restoredReport -ne $sourceReport) {
        throw "Restored database does not match the backup ($sourceReport vs $restoredReport). Previous database is at $previousDb."
    }

    $elapsed = ((Get-Date) - $started).TotalSeconds
    Write-Log ("restore: done in {0:N1}s" -f $elapsed)

    $launcher = Join-Path $repo 'tools\Start-Timer.ps1'
    $installedLauncher = Join-Path $env:USERPROFILE 'Apps\Timer\Start-Timer.ps1'
    $startLine = if (Test-Path -LiteralPath $launcher) { $launcher } else { $installedLauncher }
    Write-Output ''
    Write-Output "Restored: $currentDb"
    Write-Output "From:     $backupDb"
    if (Test-Path -LiteralPath $previousDb) { Write-Output "Previous: $previousDb" }
    if ($restoredExtras.Count) { Write-Output "Also restored: $($restoredExtras -join ', ')" }
    Write-Output "Verified: $restoredReport"
    Write-Output ''
    Write-Output 'Start the backend:'
    Write-Output ('  powershell -NoProfile -ExecutionPolicy Bypass -File "{0}" -BackendOnly' -f $startLine)
    if (-not (Test-Path -LiteralPath $launcher)) {
        Write-Output '  (tools\Start-Timer.ps1 is generated by tools\install-timer.ps1; the installed launcher above is the same thing.)'
    }
    Write-Output ''
    Write-Output 'Rollback before the backend writes anything:'
    Write-Output ('  Move-Item -LiteralPath "{0}" -Destination "{1}" -Force' -f $previousDb, $currentDb)
    exit 0
} catch {
    $message = $_.Exception.Message
    try { Write-Log "restore: FAILED: $message" } catch { }
    [Console]::Error.WriteLine("Restore failed: $message")
    exit 1
}
