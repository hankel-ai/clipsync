<#
    install-local.ps1 - install clipsync-bridge on LOCAL.

    What it does (all user-scope, no admin needed):
      1. Copies clipsync-bridge.ps1 to %LOCALAPPDATA%\clipsync\
      2. Drops a Startup-folder shortcut so the bridge auto-launches at logon
      3. Launches the bridge now and confirms /ping responds

    Run from the same folder that contains clipsync-bridge.ps1:
        powershell -ExecutionPolicy Bypass -File .\install-local.ps1
#>

[CmdletBinding()]
param(
    [string]$Bind = '127.0.0.1',
    [int]$Port = 8765,
    [string]$ShareDir = 'C:\clipsync-share'
)

$ErrorActionPreference = 'Stop'
function Info($m) { Write-Host "[clipsync-local] $m" -ForegroundColor Cyan }
function Warn($m) { Write-Host "[clipsync-local] $m" -ForegroundColor Yellow }
function Fail($m) { Write-Host "[clipsync-local] $m" -ForegroundColor Red; exit 1 }

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$bridgeSrc = Join-Path $scriptDir 'clipsync-bridge.ps1'
if (-not (Test-Path $bridgeSrc)) {
    Fail "clipsync-bridge.ps1 not found next to install-local.ps1 ($bridgeSrc)"
}

$installDir = Join-Path $env:LOCALAPPDATA 'clipsync'
$bridgeDst  = Join-Path $installDir 'clipsync-bridge.ps1'
$startupDir = [Environment]::GetFolderPath('Startup')
$lnkPath    = Join-Path $startupDir 'clipsync-bridge.lnk'

# 0. Warn if the shared staging dir hasn't been provisioned with ACLs yet.
#    The bridge will create it on first run, but WITHOUT the ACLs the SSH
#    account needs - run setup-ssh-account.ps1 (elevated) for that.
if (-not (Test-Path $ShareDir)) {
    Warn "Shared staging dir '$ShareDir' does not exist yet."
    Warn "Run setup-ssh-account.ps1 (elevated) first so it gets the right ACLs,"
    Warn "otherwise file/image transfer over the non-admin SSH account will fail."
}

# 1. Copy script into place
New-Item -ItemType Directory -Force -Path $installDir | Out-Null
Copy-Item -Force $bridgeSrc $bridgeDst
Info "Installed bridge at $bridgeDst"

# 2. Stop any previously running bridge instance so we can launch the new copy
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -match 'clipsync-bridge\.ps1' } |
    ForEach-Object {
        Info "Stopping previous bridge pid $($_.ProcessId)"
        Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
    }

# 3. Startup shortcut: powershell -NoProfile -WindowStyle Hidden -Sta -File <path> -Bind <ip> -Port <n>
$psExe = (Get-Command powershell.exe).Source
$ws = New-Object -ComObject WScript.Shell
$lnk = $ws.CreateShortcut($lnkPath)
$lnk.TargetPath       = $psExe
$lnk.Arguments        = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -Sta -File `"$bridgeDst`" -Bind $Bind -Port $Port -ShareDir `"$ShareDir`""
$lnk.WorkingDirectory = $installDir
$lnk.WindowStyle      = 7   # minimized (also hidden by -WindowStyle Hidden)
$lnk.Description      = "clipsync clipboard bridge for REMOTE access"
$lnk.Save()
Info "Startup shortcut: $lnkPath"

# 4. Launch the bridge now (detached) so the current session can use it
Info "Starting bridge on ${Bind}:${Port} ..."
Start-Process -FilePath $psExe `
    -ArgumentList @(
        '-NoProfile', '-WindowStyle', 'Hidden',
        '-ExecutionPolicy', 'Bypass', '-Sta',
        '-File', $bridgeDst,
        '-Bind', $Bind,
        '-Port', $Port,
        '-ShareDir', $ShareDir
    ) `
    -WindowStyle Hidden | Out-Null

# 5. Verify /ping
Start-Sleep -Milliseconds 800
$ok = $false
for ($i = 0; $i -lt 10; $i++) {
    try {
        $r = Invoke-WebRequest -Uri "http://${Bind}:${Port}/ping" -UseBasicParsing -TimeoutSec 2
        if ($r.Content.Trim() -eq 'pong') { $ok = $true; break }
    } catch { Start-Sleep -Milliseconds 300 }
}
if ($ok) {
    Info "Bridge responded to /ping. Install complete."
} else {
    Warn "Bridge did not respond to /ping within ~3s."
    Warn "Check the log at $installDir\clipsync-bridge.log"
    Warn "Try launching manually:  powershell -NoProfile -Sta -File `"$bridgeDst`""
}
