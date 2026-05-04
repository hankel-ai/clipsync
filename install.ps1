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
    [string]$LocalSshUser = $env:USERNAME,  # account on LOCAL
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
    $url = "https://www.autohotkey.com/download/ahk-v2/AutoHotkey_$AhkVersion.zip"
    $zip = Join-Path $env:TEMP "AutoHotkey_$AhkVersion.zip"
    Info "Downloading AutoHotkey v$AhkVersion ..."
    try {
        Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
    } catch {
        Fail "Download failed: $_`nTry a different -AhkVersion or download AutoHotkey_<ver>.zip manually and extract it to $ahkDir."
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
# 5. Smoke test the SSH alias
# ----------------------------------------------------------------------------
Info "Testing 'ssh clipsync-local' (5s timeout)..."
$test = Start-Process -FilePath ssh -ArgumentList @('-o','BatchMode=yes','-o','ConnectTimeout=5','clipsync-local','powershell -NoProfile -Command "echo clipsync-ok"') -NoNewWindow -PassThru -RedirectStandardOutput "$env:TEMP\clipsync_test.out" -RedirectStandardError "$env:TEMP\clipsync_test.err" -Wait
$out = Get-Content "$env:TEMP\clipsync_test.out" -Raw -ErrorAction SilentlyContinue
$err = Get-Content "$env:TEMP\clipsync_test.err" -Raw -ErrorAction SilentlyContinue
Remove-Item "$env:TEMP\clipsync_test.out","$env:TEMP\clipsync_test.err" -Force -ErrorAction SilentlyContinue
if ($test.ExitCode -eq 0 -and $out -match 'clipsync-ok') {
    Info "SSH ok."
} else {
    Warn "SSH test failed (exit $($test.ExitCode))."
    if ($err) { Warn "stderr: $($err.Trim())" }
    Warn "Fix ssh config / key auth before launching clipsync.ahk."
}

# ----------------------------------------------------------------------------
# 6. Launch now
# ----------------------------------------------------------------------------
Info "Starting clipsync.ahk ..."
Start-Process -FilePath $ahkExe -ArgumentList "`"$clipsyncAhk`"" -WindowStyle Minimized
Info "Done. Hotkeys:"
Info "  Ctrl+Alt+Win+V  pull LOCAL clipboard onto REMOTE"
Info "  Ctrl+Alt+Win+C  push REMOTE clipboard onto LOCAL"
