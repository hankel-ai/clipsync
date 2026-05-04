<#
    restart-bridge.ps1 - kill the running clipsync-bridge and relaunch it.
    Run on LOCAL:  powershell -ExecutionPolicy Bypass -File .\restart-bridge.ps1
#>

$ErrorActionPreference = 'Stop'
$installDir = Join-Path $env:LOCALAPPDATA 'clipsync'
$bridgePath = Join-Path $installDir 'clipsync-bridge.ps1'

if (-not (Test-Path $bridgePath)) {
    Write-Host "[clipsync] Bridge not installed at $bridgePath" -ForegroundColor Red
    exit 1
}

# Copy updated source if running from the project folder
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$src = Join-Path $scriptDir 'clipsync-bridge.ps1'
if ((Test-Path $src) -and ($src -ne $bridgePath)) {
    Copy-Item -Force $src $bridgePath
    Write-Host "[clipsync] Updated $bridgePath from $src" -ForegroundColor Cyan
}

# Kill existing
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -match 'clipsync-bridge\.ps1' } |
    ForEach-Object {
        Write-Host "[clipsync] Stopping bridge pid $($_.ProcessId)" -ForegroundColor Yellow
        Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
    }

Start-Sleep -Milliseconds 300

# Relaunch
$psExe = (Get-Command powershell.exe).Source
Start-Process -FilePath $psExe `
    -ArgumentList @(
        '-NoProfile', '-WindowStyle', 'Hidden',
        '-ExecutionPolicy', 'Bypass', '-Sta',
        '-File', $bridgePath
    ) `
    -WindowStyle Hidden | Out-Null

Start-Sleep -Milliseconds 800
try {
    $r = Invoke-WebRequest -Uri "http://127.0.0.1:8765/ping" -UseBasicParsing -TimeoutSec 3
    if ($r.Content.Trim() -eq 'pong') {
        Write-Host "[clipsync] Bridge restarted and responding." -ForegroundColor Green
    } else {
        Write-Host "[clipsync] Bridge started but /ping returned unexpected: $($r.Content)" -ForegroundColor Yellow
    }
} catch {
    Write-Host "[clipsync] Bridge not responding to /ping. Check log at $installDir\clipsync-bridge.log" -ForegroundColor Red
}
