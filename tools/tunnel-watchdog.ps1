# Keeps the Timer backend and its Cloudflare tunnel reachable without a person.
# The TimePlannerWatchdog logon task starts this loop; if it exits, the task's
# restart policy starts it again. On 2026-10-20 the tunnel lost every edge
# connection during a release and stayed down until it was restarted by hand.
#
# Every IntervalSeconds it checks the local backend and the public host. A
# process that exists but cannot serve is restarted too, which a process check
# alone would miss. -Once runs a single check (for manual verification).
param(
    [switch] $Once,
    [int] $IntervalSeconds = 60,
    [int] $FailureThreshold = 3,
    [int] $RestartCooldownSeconds = 300,
    [string] $ProbeUrl = 'https://timer.studydazi.top/api/v1/snapshot'
)

$ErrorActionPreference = 'Stop'
$launcher = Join-Path $env:USERPROFILE 'Apps\Timer\Start-Timer.ps1'
$cloudflared = Join-Path $env:USERPROFILE 'Apps\cloudflared\cloudflared.exe'
$tunnelConfig = Join-Path $env:USERPROFILE 'Apps\cloudflared\timer.yml'
$logs = Join-Path $env:USERPROFILE 'TimePlanner\logs'
$logFile = Join-Path $logs 'watchdog.log'

function Write-Log([string] $line) {
    New-Item -ItemType Directory -Force -Path $logs | Out-Null
    if ((Test-Path -LiteralPath $logFile) -and (Get-Item -LiteralPath $logFile).Length -gt 1MB) {
        Move-Item -LiteralPath $logFile -Destination "$logFile.old" -Force
    }
    Add-Content -LiteralPath $logFile -Encoding ascii `
        -Value ('{0:yyyy-MM-dd HH:mm:ss} {1}' -f (Get-Date), $line)
}

function Test-Backend {
    try {
        (Invoke-WebRequest -UseBasicParsing -TimeoutSec 5 'http://127.0.0.1:8787/health').StatusCode -eq 200
    } catch {
        $false
    }
}

# 401 is the healthy answer for this probe (no credentials); 200 is accepted in
# case the route ever becomes public. Anything else, or no answer, is a failure.
function Test-Public {
    $code = (& curl.exe -s -o NUL -w '%{http_code}' -m 15 $ProbeUrl 2>$null | Out-String).Trim()
    # A failed probe sets a native exit code; do not leak it into the task result.
    $global:LASTEXITCODE = 0
    return @('200', '401') -contains $code
}

function Start-Tunnel {
    if (-not (Test-Path -LiteralPath $tunnelConfig)) {
        Write-Log 'tunnel config missing; cannot start cloudflared'
        return $false
    }
    New-Item -ItemType Directory -Force -Path $logs | Out-Null
    Start-Process -FilePath $cloudflared -WindowStyle Hidden `
        -ArgumentList 'tunnel', '--config', $tunnelConfig,
            '--logfile', (Join-Path $logs 'tunnel.log'), '--loglevel', 'warn', 'run', 'timer'
    foreach ($i in 1..30) {
        if (Get-Process -Name cloudflared -ErrorAction SilentlyContinue) { break }
        Start-Sleep -Milliseconds 500
    }
    return [bool](Get-Process -Name cloudflared -ErrorAction SilentlyContinue)
}

function Repair-Tunnel {
    Write-Log 'cloudflared: restarting'
    Stop-Process -Name cloudflared -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    if (-not (Start-Tunnel)) {
        Write-Log 'cloudflared: failed to start'
        return
    }
    # The edge usually accepts a connection within a few seconds.
    Start-Sleep -Seconds 10
    if (Test-Public) {
        Write-Log 'cloudflared: recovered'
    } else {
        Write-Log 'cloudflared: public endpoint still failing after restart'
    }
}

$mutex = $null
if (-not $Once) {
    $mutex = [System.Threading.Mutex]::new($false, 'Local\TimePlannerTunnelWatchdog')
    if (-not $mutex.WaitOne(0)) {
        Write-Log "watchdog: another instance is running; pid $PID exits"
        exit 0
    }
    Write-Log "watchdog: started (pid $PID)"
}

try {
    $failures = 0
    $lastRepair = [datetime]::MinValue
    while ($true) {
        if (-not (Test-Backend)) {
            Write-Log 'backend: not responding; asking the launcher to start it'
            if (Test-Path -LiteralPath $launcher) { & $launcher -BackendOnly }
            Start-Sleep -Seconds 5
        }
        if (-not (Get-Process -Name cloudflared -ErrorAction SilentlyContinue)) {
            Write-Log 'cloudflared: not running'
            Repair-Tunnel
            $lastRepair = Get-Date
            $failures = 0
        } elseif (-not (Test-Public)) {
            if (((Get-Date) - $lastRepair).TotalSeconds -lt $RestartCooldownSeconds) {
                Write-Log 'public endpoint: failing during restart cooldown'
            } else {
                $failures++
                Write-Log ('public endpoint: failed ({0}/{1})' -f $failures, $FailureThreshold)
                if ($failures -ge $FailureThreshold) {
                    Repair-Tunnel
                    $lastRepair = Get-Date
                    $failures = 0
                }
            }
        } elseif ($failures -gt 0) {
            Write-Log 'public endpoint: healthy again'
            $failures = 0
        }
        if ($Once) { break }
        Start-Sleep -Seconds $IntervalSeconds
    }
} finally {
    if ($mutex) { $mutex.ReleaseMutex() }
}
