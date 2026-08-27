<#
    install.ps1 - bootstrap clipsync on REMOTE (no admin rights required).

    What it does:
      1. Downloads AutoHotkey v2 portable .zip from autohotkey.com
      2. Extracts to %LOCALAPPDATA%\AHK\
      3. Copies clipsync.ahk to %LOCALAPPDATA%\clipsync\
      4. Creates a Startup shortcut so it auto-runs at login
      5. Generates %USERPROFILE%\.ssh\id_clipsync if it doesn't exist, then adds
         (or, with your OK, refreshes) a 'clipsync-local' Host alias in
         %USERPROFILE%\.ssh\config - prompting for LOCAL's host
      6. Smoke-tests ssh + the LOCAL bridge, then launches clipsync.ahk

    Needs NO parameters and is idempotent - run it from the same folder that
    contains clipsync.ahk and answer the prompt:
        powershell -ExecutionPolicy Bypass -File .\install.ps1

    Rerunning it is the supported way to point clipsync at a new LOCAL host: it
    prints the existing alias and asks whether to keep or replace it.

    The -LocalSsh* params below are optional non-interactive overrides (CI /
    unattended); a run with -LocalSshHost never prompts for the host.
#>

[CmdletBinding()]
param(
    [string]$LocalSshHost,                  # e.g. 192.168.1.50 or local-pc.lan.
                                            #   Omit it and you're prompted (default: the
                                            #   HostName already in ssh config).
    [string]$LocalSshUser = 'clipsync',     # dedicated low-privilege SSH account on LOCAL
                                            #   (see setup-ssh-account.ps1). Was the desktop
                                            #   admin user; now a separate SSH-only account.
    [string]$LocalSshKey,                   # private key on REMOTE. Default (and generated
                                            #   on first run): %USERPROFILE%\.ssh\id_clipsync
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
$ccHandoffSrc = Join-Path $scriptDir 'cc-handoff.ps1'
$ccHandoffDst = Join-Path $clipsyncDir 'cc-handoff.ps1'
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
if (Test-Path $ccHandoffSrc) {
    Copy-Item -Force $ccHandoffSrc $ccHandoffDst
    Info "Installed cc-handoff at $ccHandoffDst"
} else {
    Warn "cc-handoff.ps1 not found next to install.ps1 - F7 handoff will be unavailable."
}

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
# 4. SSH key + 'clipsync-local' config alias  (interactive, idempotent)
# ----------------------------------------------------------------------------
# No params required. A missing key is generated, a missing alias is prompted
# for, and an existing alias is printed so you can keep it (Enter) or replace it
# - so a rerun after LOCAL's IP changes fixes the alias instead of no-opping.
# The -LocalSsh* params still work as non-interactive overrides.
if (-not $SkipSshConfig) {
    $sshDir  = Join-Path $env:USERPROFILE '.ssh'
    $sshConf = Join-Path $sshDir 'config'
    # An explicit -LocalSshHost is a non-interactive override: it suppresses BOTH
    # prompts (keep/replace and the host itself), so an unattended rerun with a
    # new host actually rewrites the alias instead of keeping the stale one.
    $hostFromParam = [bool]$LocalSshHost
    if (-not (Test-Path $sshDir)) { New-Item -ItemType Directory -Force -Path $sshDir | Out-Null }

    # -- 4a. key ------------------------------------------------------------
    # A clipsync-DEDICATED key: authorizing it on LOCAL grants clipsync access
    # and nothing else, and we never touch an id_ed25519 you use elsewhere.
    if ($LocalSshKey) { $keyPath = $LocalSshKey } else { $keyPath = Join-Path $sshDir 'id_clipsync' }
    $pubPath = "$keyPath.pub"
    if (Test-Path $keyPath) {
        Info "SSH key already at $keyPath - reusing."
    } else {
        Info "No SSH key at $keyPath - generating one ..."
        # cmd /c, NOT PowerShell: PS 5.1 passes -N "" as the LITERAL two chars
        # `""`, so the key silently ends up passphrase-encrypted and BatchMode
        # auth then fails. cmd treats "" as truly empty.
        & cmd /c "ssh-keygen -t ed25519 -f ""$keyPath"" -N """" -C ""clipsync-$env:COMPUTERNAME"" -q"
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path $keyPath)) {
            Fail "ssh-keygen failed (exit $LASTEXITCODE) - see above."
        }
        Info "Key generated: $keyPath"
    }
    if (-not (Test-Path $pubPath)) {
        # Derive the .pub. -P "" makes it fail fast (non-zero exit) rather than
        # hang on a prompt if the private key IS passphrase-protected.
        $derived = & cmd /c "ssh-keygen -y -P """" -f ""$keyPath"""
        if ($LASTEXITCODE -eq 0 -and $derived) {
            [IO.File]::WriteAllText($pubPath, (($derived -join "`n").Trim() + "`n"), [Text.Encoding]::ASCII)
            Info "Derived public key: $pubPath"
        } else {
            Warn "Could not derive $pubPath (key may be passphrase-protected)."
        }
    }

    # -- 4b. the 'clipsync-local' alias --------------------------------------
    $lines = @()
    if (Test-Path $sshConf) { $lines = @(Get-Content -Path $sshConf) }
    $start = -1
    $end   = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '(?i)^\s*Host\s+.*\bclipsync-local\b') { $start = $i; break }
    }
    if ($start -ge 0) {
        # The block runs to the next 'Host ' line (or EOF).
        $end = $lines.Count - 1
        for ($i = $start + 1; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '(?i)^\s*Host\s') { $end = $i - 1; break }
        }
    }

    $curHost = ''
    if ($start -ge 0) {
        foreach ($l in $lines[$start..$end]) {
            if ($l -match '(?i)^\s*HostName\s+(.+?)\s*$') { $curHost = $Matches[1] }
        }
    }

    $writeBlock = $true
    if ($start -ge 0) {
        Info "ssh config already has a 'clipsync-local' alias:"
        foreach ($l in $lines[$start..$end]) { if ($l.Trim()) { Info "    $l" } }
        if ($hostFromParam) { $reply = 'n' } else { $reply = Read-Host "[clipsync] Keep this alias? [Y/n]" }
        if ($reply -match '(?i)^\s*n') {
            Info "Replacing it."
        } else {
            Info "Keeping it."
            $writeBlock = $false
        }
    }

    if ($writeBlock) {
        $defHost = $LocalSshHost
        if (-not $defHost) { $defHost = $curHost }
        if ($hostFromParam) {
            $answer = ''
        } elseif ($defHost) {
            $answer = Read-Host "[clipsync] LOCAL host - ip / hostname / tailscale name [$defHost]"
        } else {
            $answer = Read-Host "[clipsync] LOCAL host - ip / hostname / tailscale name"
        }
        if ($answer -and $answer.Trim()) { $LocalSshHost = $answer.Trim() } else { $LocalSshHost = $defHost }
        if (-not $LocalSshHost) {
            Warn "No host given - leaving ssh config alone."
            Warn "Rerun install.ps1 and answer the prompt, or add a 'Host clipsync-local' block to $sshConf yourself."
            $writeBlock = $false
        }
    }

    if ($writeBlock) {
        $block = @(
            "Host clipsync-local",
            "    HostName $LocalSshHost",
            "    User $LocalSshUser",
            "    IdentityFile $keyPath",
            "    IdentitiesOnly yes"
        )
        $keep = @()
        if ($start -ge 0) {
            if ($start -gt 0)               { $keep += $lines[0..($start - 1)] }
            if ($end -lt $lines.Count - 1)  { $keep += $lines[($end + 1)..($lines.Count - 1)] }
        } else {
            $keep = $lines
        }
        # Blank line before the block so it can never glue onto a previous
        # Host's options.
        $new = @()
        $new += $keep
        if ($new.Count -gt 0 -and $new[-1].Trim() -ne '') { $new += '' }
        $new += $block
        # WriteAllLines, not Set-Content: PS 5.1's -Encoding UTF8 prepends a BOM,
        # and a BOM at the top of ssh config breaks parsing.
        [IO.File]::WriteAllLines($sshConf, [string[]]$new, (New-Object Text.UTF8Encoding($false)))
        Info "ssh config: clipsync-local -> $LocalSshUser@$LocalSshHost (key $keyPath)"
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
    if ($pubPath -and (Test-Path $pubPath)) {
        Warn "  powershell -File .\setup-ssh-account.ps1 -AddKeyOnly $((Get-Content -Raw $pubPath).Trim())"
    } else {
        Warn "  powershell -File .\setup-ssh-account.ps1 -AddKeyOnly <paste $pubPath line>"
    }
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
