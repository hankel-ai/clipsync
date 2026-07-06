<#
    install.ps1 - bootstrap clipsync on REMOTE (no admin rights required).

    What it does:
      1. Downloads AutoHotkey v2 portable .zip from autohotkey.com
      2. Extracts to %LOCALAPPDATA%\AHK\
      3. Copies clipsync.ahk to %LOCALAPPDATA%\clipsync\
      4. Creates a Startup shortcut so it auto-runs at login
      5. Optionally adds a 'clipsync-local' Host alias to ~/.ssh/config

    Run from the same folder that contains clipsync.ahk:
        powershell -ExecutionPolicy Bypass -File .\install.ps1
#>

[CmdletBinding()]
param(
    [string]$LocalSshHost,                  # e.g. 192.168.1.50 or local-pc.lan
    [string]$LocalSshUser = 'clipsync',     # dedicated low-privilege SSH account on LOCAL
                                            #   (see setup-ssh-account.ps1). Was the desktop
                                            #   admin user; now a separate SSH-only account.
    [string]$LocalSshKey,                   # path to private key on REMOTE
    [string]$AhkVersion = "2.0.26",         # bump as needed
    [switch]$SkipSshConfig
)

$ErrorActionPreference = 'Stop'
function Info($m)  { Write-Host "[clipsync] $m" -ForegroundColor Cyan }
function Warn($m)  { Write-Host "[clipsync] $m" -ForegroundColor Yellow }
function Fail($m)  { Write-Host "[clipsync] $m" -ForegroundColor Red; exit 1 }

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ahkSource = Join-Path $scriptDir 'clipsync.ahk'
if (-not (Test-Path $ahkSource)) {
    Fail "clipsync.ahk not found next to install.ps1 ($ahkSource)"
}

$ahkDir       = Join-Path $env:LOCALAPPDATA 'AHK'
$ahkExe       = Join-Path $ahkDir 'AutoHotkey64.exe'
$clipsyncDir  = Join-Path $env:LOCALAPPDATA 'clipsync'
$clipsyncAhk  = Join-Path $clipsyncDir 'clipsync.ahk'
$startupDir   = [Environment]::GetFolderPath('Startup')
$shortcutPath = Join-Path $startupDir 'clipsync.lnk'

# ----------------------------------------------------------------------------
# 1. AutoHotkey v2 portable
# ----------------------------------------------------------------------------
if (Test-Path $ahkExe) {
    Info "AutoHotkey already at $ahkExe - skipping download."
} else {
    New-Item -ItemType Directory -Force -Path $ahkDir | Out-Null
    $zip  = Join-Path $env:TEMP "AutoHotkey_$AhkVersion.zip"
    $urls = @(
        "https://github.com/AutoHotkey/AutoHotkey/releases/download/v$AhkVersion/AutoHotkey_$AhkVersion.zip",
        "https://www.autohotkey.com/download/2.0/AutoHotkey_$AhkVersion.zip"
    )
    $downloaded = $false
    foreach ($url in $urls) {
        Info "Downloading AutoHotkey v$AhkVersion from $url ..."
        try {
            Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
            $downloaded = $true
            break
        } catch {
            Warn "  failed: $($_.Exception.Message)"
        }
    }
    if (-not $downloaded) {
        Fail "All download URLs failed. Download AutoHotkey_$AhkVersion.zip manually from https://github.com/AutoHotkey/AutoHotkey/releases and extract it to $ahkDir."
    }
    Info "Extracting to $ahkDir ..."
    Expand-Archive -LiteralPath $zip -DestinationPath $ahkDir -Force
    Remove-Item $zip -Force
    if (-not (Test-Path $ahkExe)) {
        Fail "Expected $ahkExe after extraction but did not find it. Inspect $ahkDir."
    }
}

# ----------------------------------------------------------------------------
# 2. Place clipsync.ahk
# ----------------------------------------------------------------------------
New-Item -ItemType Directory -Force -Path $clipsyncDir | Out-Null
Copy-Item -Force $ahkSource $clipsyncAhk
Info "Installed script at $clipsyncAhk"

# ----------------------------------------------------------------------------
# 3. Startup shortcut
# ----------------------------------------------------------------------------
$ws = New-Object -ComObject WScript.Shell
$lnk = $ws.CreateShortcut($shortcutPath)
$lnk.TargetPath = $ahkExe
$lnk.Arguments = "`"$clipsyncAhk`""
$lnk.WorkingDirectory = $clipsyncDir
$lnk.Description = "Clipboard + file sync between LOCAL and REMOTE over SSH"
$lnk.WindowStyle = 7   # minimized
$lnk.Save()
Info "Startup shortcut: $shortcutPath"

# ----------------------------------------------------------------------------
# 4. SSH config - add 'clipsync-local' Host alias if needed
# ----------------------------------------------------------------------------
if (-not $SkipSshConfig) {
    $sshDir   = Join-Path $env:USERPROFILE '.ssh'
    $sshConf  = Join-Path $sshDir 'config'
    if (-not (Test-Path $sshDir)) {
        New-Item -ItemType Directory -Force -Path $sshDir | Out-Null
    }
    $existing = if (Test-Path $sshConf) { Get-Content -Raw $sshConf } else { "" }
    if ($existing -match '(?im)^\s*Host\s+clipsync-local\b') {
        Info "ssh config already has 'clipsync-local' alias - leaving it alone."
    } else {
        if (-not $LocalSshHost) {
            Warn "No -LocalSshHost passed; skipping ssh config."
            Warn "Either rerun with -LocalSshHost <ip-or-hostname> [-LocalSshUser <user>] [-LocalSshKey <path>],"
            Warn "or edit $sshConf yourself to add a 'Host clipsync-local' block."
        } else {
            $block = @"

Host clipsync-local
    HostName $LocalSshHost
    User $LocalSshUser
"@
            if ($LocalSshKey) {
                $block += "    IdentityFile $LocalSshKey`n    IdentitiesOnly yes`n"
            }
            Add-Content -Path $sshConf -Value $block -Encoding UTF8
            Info "Appended 'clipsync-local' alias to $sshConf"
        }
    }
}

# ----------------------------------------------------------------------------
# 5. Smoke test the SSH alias and the LOCAL bridge
# ----------------------------------------------------------------------------
Info "Testing 'ssh clipsync-local' (5s timeout)..."
$test = Start-Process -FilePath ssh `
    -ArgumentList @(
        '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=5',
        'clipsync-local', 'echo clipsync-ok'
    ) `
    -NoNewWindow -PassThru -Wait `
    -RedirectStandardOutput "$env:TEMP\clipsync_test.out" `
    -RedirectStandardError  "$env:TEMP\clipsync_test.err"
$out = Get-Content "$env:TEMP\clipsync_test.out" -Raw -ErrorAction SilentlyContinue
$err = Get-Content "$env:TEMP\clipsync_test.err" -Raw -ErrorAction SilentlyContinue
Remove-Item "$env:TEMP\clipsync_test.out","$env:TEMP\clipsync_test.err" -Force -ErrorAction SilentlyContinue
if ($test.ExitCode -eq 0 -and $out -match 'clipsync-ok') {
    Info "SSH ok."
} else {
    Warn "SSH test failed (exit $($test.ExitCode))."
    if ($err) { Warn "stderr: $($err.Trim())" }
    Warn "Fix ssh config / key auth before launching clipsync.ahk."
    Warn "REMOTE now logs into LOCAL as the '$LocalSshUser' account (not admin)."
    Warn "On LOCAL, authorize THIS machine's public key:"
    Warn "  powershell -File .\setup-ssh-account.ps1 -AddKeyOnly <paste id_ed25519.pub line>"
}

Info "Pinging the LOCAL clipsync-bridge via SSH (10s timeout)..."
# Use curl.exe (not curl) - on LOCAL the default shell is PowerShell, where
# 'curl' is an alias for Invoke-WebRequest with different arg syntax.
$pingTest = Start-Process -FilePath ssh `
    -ArgumentList @(
        '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=5',
        'clipsync-local',
        'curl.exe -s -m 5 http://127.0.0.1:8765/ping'
    ) `
    -NoNewWindow -PassThru -Wait `
    -RedirectStandardOutput "$env:TEMP\clipsync_ping.out" `
    -RedirectStandardError  "$env:TEMP\clipsync_ping.err"
$pingOut = Get-Content "$env:TEMP\clipsync_ping.out" -Raw -ErrorAction SilentlyContinue
Remove-Item "$env:TEMP\clipsync_ping.out","$env:TEMP\clipsync_ping.err" -Force -ErrorAction SilentlyContinue
if ($pingTest.ExitCode -eq 0 -and $pingOut -match 'pong') {
    Info "Bridge ok - LOCAL is ready."
} else {
    Warn "Bridge ping failed. The bridge needs to be installed on LOCAL:"
    Warn "  copy clipsync-bridge.ps1 + install-local.ps1 to LOCAL"
    Warn "  on LOCAL: powershell -ExecutionPolicy Bypass -File .\install-local.ps1"
    Warn "Hotkeys won't work until the bridge responds to /ping."
}

# ----------------------------------------------------------------------------
# 6. Launch now
# ----------------------------------------------------------------------------
Info "Starting clipsync.ahk ..."
Start-Process -FilePath $ahkExe -ArgumentList "`"$clipsyncAhk`"" -WindowStyle Minimized
Info "Done. Hotkeys:"
Info "  Ctrl+Alt+Win+V  pull LOCAL clipboard onto REMOTE"
Info "  Ctrl+Alt+Win+C  push REMOTE clipboard onto LOCAL"
