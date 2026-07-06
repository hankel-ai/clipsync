<#
    setup-ssh-account.ps1 - one-time ELEVATED setup on LOCAL.

    Creates a dedicated low-privilege SSH account ('clipsync') that REMOTEs log
    into, instead of exposing your interactive Administrator account over SSH.
    Also provisions the shared staging directory that file/image payloads
    transit (so scp - which runs as the SSH account - and the bridge - which
    runs as your desktop user - can both reach them).

    Idempotent: safe to re-run. Existing user/dirs/keys/ACLs/service state are
    detected and left intact or refreshed in place - nothing is duplicated and
    authorized_keys is never truncated.

    Run in an ELEVATED PowerShell:
        powershell -ExecutionPolicy Bypass -File .\setup-ssh-account.ps1

    What it does (all require admin, same one-time footprint as enabling sshd):
      1. Creates local user 'clipsync' with a random password.
      2. Denies interactive + RDP logon (SSH network logon still works).
      3. Creates C:\clipsync-share with ACLs granting the desktop user and
         'clipsync' Modify (your private profile stays unreadable to clipsync).
      4. Creates C:\ProgramData\ssh\clipsync_authorized_keys (tight ACLs) and a
         'Match User clipsync' block in sshd_config pointing at it, then restarts
         sshd. (An absolute path is required: a never-logged-in account has no
         profile for sshd to resolve a home-relative .ssh\authorized_keys.)
         Pass the key as trailing tokens to add it now, or paste it later.
      5. Ensures OpenSSH Server is installed, running, Automatic, firewalled.
      6. Sets the machine-wide SSH default shell to PowerShell (for curl.exe).

    After running, add each REMOTE's public key with (no quotes needed; works
    from cmd.exe or PowerShell - or omit the key and paste it when prompted):
        powershell -File .\setup-ssh-account.ps1 -AddKeyOnly ssh-ed25519 AAAA... host
    then REMOVE your admin key from C:\ProgramData\ssh\administrators_authorized_keys.
#>

# PositionalBinding=$false so named params can't be mis-bound. The public key is
# taken as TRAILING TOKENS (ValueFromRemainingArguments), NOT via a -PubKey name -
# so an SSH key that the shell splits on spaces (e.g. from cmd.exe, where single
# quotes don't group) is reassembled instead of scattering across -UserName etc.
# Usage:  setup-ssh-account.ps1 -AddKeyOnly ssh-ed25519 AAAA... comment
#         (or run -AddKeyOnly with no key and paste it when prompted)
[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$UserName    = 'clipsync',
    [string]$ShareDir    = 'C:\clipsync-share',
    [string]$DesktopUser = $env:USERNAME,   # the account that runs the bridge (your interactive login)
    [switch]$AddKeyOnly,                    # only add the key to authorized_keys, skip the rest
    [switch]$SkipDefaultShell,              # don't touch HKLM DefaultShell
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$PubKey                       # the key line as trailing tokens: ssh-ed25519 AAAA... comment
)

$ErrorActionPreference = 'Stop'
function Info($m) { Write-Host "[clipsync-setup] $m" -ForegroundColor Cyan }
function Warn($m) { Write-Host "[clipsync-setup] $m" -ForegroundColor Yellow }
function Fail($m) { Write-Host "[clipsync-setup] $m" -ForegroundColor Red; exit 1 }

# Rejoin the key tokens into one line and strip any stray wrapping quotes (which
# survive as literal chars when invoked from cmd.exe). 39 = ' , 34 = ".
function Clean-KeyLine($tokens) {
    if (-not $tokens) { return '' }
    return (($tokens -join ' ').Trim().Trim([char]39, [char]34)).Trim()
}
$PubKeyLine = Clean-KeyLine $PubKey

# ---------------------------------------------------------------------------
# Elevation check
# ---------------------------------------------------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Fail "This script must run ELEVATED. Right-click PowerShell -> Run as Administrator, then re-run."
}

# authorized_keys lives in ProgramData at an ABSOLUTE path (wired via a Match
# block in sshd_config), NOT in the user's profile. A never-logged-in SSH account
# has no profile, so sshd cannot resolve its $HOME to find .ssh\authorized_keys
# and silently falls back to password. This mirrors the machine's existing
# k3sbackup / mediabackup / authentikbackup Match-User convention.
$sshProgramData = Join-Path $env:ProgramData 'ssh'
$sshdConfig     = Join-Path $sshProgramData 'sshd_config'
$authKeys       = Join-Path $sshProgramData ("{0}_authorized_keys" -f $UserName)

# ---------------------------------------------------------------------------
# Helper: authorize a public key line into the ProgramData authorized_keys.
# OpenSSH StrictModes for a ProgramData key file requires it be owned by and
# writable only by SYSTEM + Administrators (sshd reads it as SYSTEM); the SSH
# account itself needs no access.
# ---------------------------------------------------------------------------
function Add-AuthorizedKey([string]$key) {
    $key = $key.Trim()
    if (-not $key) { Fail "public key was empty." }
    if ($key -notmatch '^(ssh-ed25519|ssh-rsa|ecdsa-sha2-|sk-)') {
        Warn "Key doesn't look like an OpenSSH public key line; adding anyway."
    }
    if (-not (Test-Path $sshProgramData)) {
        New-Item -ItemType Directory -Force -Path $sshProgramData | Out-Null
    }
    $existing = if (Test-Path $authKeys) { Get-Content -Raw $authKeys } else { '' }
    if ($existing -and ($existing -split "`r?`n" | Where-Object { $_.Trim() -eq $key })) {
        Info "Key already present in $authKeys - skipping."
    } else {
        # ASCII, no BOM - a BOM breaks OpenSSH parsing.
        Add-Content -Path $authKeys -Value $key -Encoding ASCII
        Info "Added public key to $authKeys"
    }
    # Lock down ACLs: disable inheritance, own + grant only SYSTEM + Administrators.
    # Repair-then-lock in a way that can't lock us out mid-way:
    #   /reset restores inherited (admin-accessible) ACEs - repairs a broken DACL
    #   from an earlier failed run - then one call strips inheritance AND grants,
    #   so the DACL is never momentarily empty. sshd reads the file as SYSTEM.
    icacls $authKeys /reset | Out-Null
    icacls $authKeys /inheritance:r /grant "SYSTEM:F" "Administrators:F" | Out-Null
}

# ===========================================================================
# -AddKeyOnly fast path
# ===========================================================================
if ($AddKeyOnly) {
    if (-not (Get-LocalUser -Name $UserName -ErrorAction SilentlyContinue)) {
        Fail "User '$UserName' does not exist yet. Run without -AddKeyOnly first."
    }
    # If no key was passed as trailing tokens, prompt: Read-Host takes the whole
    # pasted line intact - no arg-splitting or quoting to get wrong.
    if (-not $PubKeyLine) {
        $PubKeyLine = Clean-KeyLine (Read-Host "Paste the REMOTE public key line, then press Enter")
    }
    if (-not $PubKeyLine) { Fail "No key provided." }
    Add-AuthorizedKey $PubKeyLine
    Info "Done. '$UserName' now authorizes that key."
    exit 0
}

# ===========================================================================
# 1. Create the SSH account
# ===========================================================================
if (Get-LocalUser -Name $UserName -ErrorAction SilentlyContinue) {
    Info "Local user '$UserName' already exists - leaving it in place."
} else {
    Add-Type -AssemblyName System.Web
    $plain  = [System.Web.Security.Membership]::GeneratePassword(24, 6)
    $secure = ConvertTo-SecureString $plain -AsPlainText -Force
    New-LocalUser -Name $UserName -Password $secure `
        -FullName 'clipsync SSH' `
        -Description 'clipsync SSH sync (low-privilege, key-only)' `
        -PasswordNeverExpires -AccountNeverExpires -UserMayNotChangePassword | Out-Null
    Remove-Variable plain, secure
    Info "Created local user '$UserName' (random password; SSH-key auth only)."
}
$sid = (Get-LocalUser -Name $UserName).SID.Value

# ===========================================================================
# 2. Deny interactive + RDP logon (SSH network logon is a different right and
#    stays allowed). Merge our SID into the existing membership via secedit.
# ===========================================================================
function Deny-LogonRights([string]$accountSid) {
    $rights = 'SeDenyInteractiveLogonRight', 'SeDenyRemoteInteractiveLogonRight'
    $tmp    = Join-Path $env:TEMP ("clipsync_secpol_{0}" -f ([guid]::NewGuid().ToString('N')))
    $expCfg = "$tmp.export.inf"
    $newCfg = "$tmp.apply.inf"
    $db     = "$tmp.sdb"
    try {
        secedit /export /areas USER_RIGHTS /cfg $expCfg | Out-Null
        $exported = if (Test-Path $expCfg) { Get-Content $expCfg } else { @() }

        $lines = @('[Unicode]', 'Unicode=yes', '[Version]',
                   'signature="$CHICAGO$"', 'Revision=1', '[Privilege Rights]')
        foreach ($right in $rights) {
            $cur = ($exported | Where-Object { $_ -match "^\s*$right\s*=" }) | Select-Object -First 1
            $members = @()
            if ($cur) {
                $val = ($cur -split '=', 2)[1].Trim()
                if ($val) { $members = $val -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ } }
            }
            $sidToken = '*' + $accountSid
            if ($members -notcontains $sidToken) { $members += $sidToken }
            $lines += ("{0} = {1}" -f $right, ($members -join ','))
        }
        Set-Content -Path $newCfg -Value $lines -Encoding Unicode
        secedit /configure /db $db /cfg $newCfg /areas USER_RIGHTS | Out-Null
        Info "Denied interactive + RDP logon to '$UserName' (SSH still works)."
    } catch {
        Warn "Could not set deny-logon rights: $($_.Exception.Message)"
        Warn "The account still works over SSH; harden manually via secpol.msc if desired."
    } finally {
        Remove-Item "$tmp*" -Force -ErrorAction SilentlyContinue
    }
}
Deny-LogonRights $sid

# ===========================================================================
# 3. Shared staging dir with ACLs for the desktop user + the SSH account
# ===========================================================================
if (-not (Test-Path $ShareDir)) {
    New-Item -ItemType Directory -Force -Path $ShareDir | Out-Null
    Info "Created shared staging dir $ShareDir"
} else {
    Info "Shared staging dir $ShareDir already exists."
}
New-Item -ItemType Directory -Force -Path (Join-Path $ShareDir 'incoming') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $ShareDir 'outgoing') | Out-Null

# Reset inheritance so the share isn't world-readable, then grant exactly:
#   SYSTEM + Administrators : Full   (covers an admin desktop user)
#   <SSH account>           : Modify
#   <desktop user>          : Modify (explicit, in case it isn't an admin)
icacls $ShareDir /inheritance:r | Out-Null
icacls $ShareDir /grant "SYSTEM:(OI)(CI)F" "Administrators:(OI)(CI)F" `
    ("{0}:(OI)(CI)M" -f $UserName) ("{0}:(OI)(CI)M" -f $DesktopUser) | Out-Null
Info "Set ACLs on $ShareDir (Modify for '$UserName' and '$DesktopUser')."

# ===========================================================================
# 4. ProgramData authorized_keys for the SSH account
# ===========================================================================
if (-not (Test-Path $sshProgramData)) {
    New-Item -ItemType Directory -Force -Path $sshProgramData | Out-Null
}
if ($PubKeyLine) {
    Add-AuthorizedKey $PubKeyLine
} else {
    if (-not (Test-Path $authKeys)) {
        # No -Force: never risk truncating an existing authorized_keys on re-run.
        New-Item -ItemType File -Path $authKeys | Out-Null
        Info "Created empty $authKeys - add REMOTE public keys with: -AddKeyOnly ssh-ed25519 AAAA... comment"
    } else {
        Info "$authKeys already exists - leaving its contents intact."
    }
    # Repair-then-lock in a way that can't lock us out mid-way:
    #   /reset restores inherited (admin-accessible) ACEs - repairs a broken DACL
    #   from an earlier failed run - then one call strips inheritance AND grants,
    #   so the DACL is never momentarily empty. sshd reads the file as SYSTEM.
    icacls $authKeys /reset | Out-Null
    icacls $authKeys /inheritance:r /grant "SYSTEM:F" "Administrators:F" | Out-Null
}

# ===========================================================================
# 5. Ensure OpenSSH Server is installed / running / automatic / firewalled
# ===========================================================================
$cap = Get-WindowsCapability -Online -Name 'OpenSSH.Server*' -ErrorAction SilentlyContinue
if ($cap -and $cap.State -ne 'Installed') {
    Info "Installing OpenSSH Server..."
    try { Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0 | Out-Null }
    catch { Warn "Add-WindowsCapability failed: $($_.Exception.Message)" }
}
$sshd = Get-Service -Name sshd -ErrorAction SilentlyContinue
if ($sshd) {
    if ($sshd.StartType -ne 'Automatic') { Set-Service -Name sshd -StartupType Automatic }
    if ($sshd.Status -ne 'Running') { Start-Service sshd }
    $sshd = Get-Service -Name sshd
    Info "OpenSSH Server: $($sshd.Status), StartupType $($sshd.StartType)."
} else {
    Warn "sshd service not found. Install OpenSSH Server (a reboot may be needed), then re-run."
}

if (-not (Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -DisplayName 'OpenSSH Server (sshd)' `
        -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 | Out-Null
    Info "Created inbound firewall rule for TCP 22."
} else {
    Enable-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue
}

# ===========================================================================
# 6. Machine-wide SSH default shell -> PowerShell (so curl.exe resolves and
#    the -EncodedCommand PowerShell calls work as clipsync expects)
# ===========================================================================
if (-not $SkipDefaultShell) {
    if (-not (Test-Path 'HKLM:\SOFTWARE\OpenSSH')) {
        New-Item -Path 'HKLM:\SOFTWARE\OpenSSH' -Force | Out-Null
    }
    $psPath = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
    # -Force overwrites an existing value and creates it if absent (idempotent).
    New-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell `
        -Value $psPath -PropertyType String -Force | Out-Null
    Info "Set SSH DefaultShell to PowerShell."
}

# ===========================================================================
# 7. Wire an absolute AuthorizedKeysFile via a Match block, then restart sshd.
#    Required because a never-logged-in account has no profile for sshd to
#    resolve a home-relative .ssh\authorized_keys. Mirrors the existing
#    k3sbackup / mediabackup / authentikbackup Match-User entries.
# ===========================================================================
$restartNeeded = $false
if (Test-Path $sshdConfig) {
    $cfgText = Get-Content $sshdConfig -Raw
    if ($cfgText -notmatch "(?im)^\s*Match\s+User\s+$UserName\b") {
        # Appended at EOF: a Match block's scope runs to the next Match / EOF.
        $block = "`r`nMatch User $UserName`r`n    AuthorizedKeysFile __PROGRAMDATA__/ssh/${UserName}_authorized_keys"
        Add-Content -Path $sshdConfig -Value $block -Encoding ASCII
        Info "Added 'Match User $UserName' block to sshd_config."
        $restartNeeded = $true
    } else {
        Info "sshd_config already has a 'Match User $UserName' block."
    }
} else {
    Warn "sshd_config not found at $sshdConfig - is OpenSSH Server installed?"
}

# Validate config before restarting; never restart on a bad config.
$sshdExe = Join-Path $env:SystemRoot 'System32\OpenSSH\sshd.exe'
if ($restartNeeded -and (Test-Path $sshdExe)) {
    $test = & $sshdExe -t 2>&1
    if ($LASTEXITCODE -eq 0) {
        Restart-Service sshd
        Info "sshd config valid; restarted sshd."
    } else {
        Warn "sshd config test FAILED - NOT restarting. Review sshd_config:"
        $test | ForEach-Object { Warn "  $_" }
    }
} elseif ($restartNeeded) {
    Warn "sshd.exe not found to validate config; restart manually: Restart-Service sshd"
}

# ===========================================================================
# Next steps
# ===========================================================================
Write-Host ""
Info "Setup complete. Next steps:"
# Double-quoted here-string: $UserName interpolates; literal $ (for REMOTE
# commands to type verbatim) is backtick-escaped. No \" quoting hazards.
$steps = @"

  1. On each REMOTE, generate an SSH key and print its PUBLIC key line:
       Windows REMOTE (PowerShell):
         ssh-keygen -t ed25519 -f `$env:USERPROFILE\.ssh\id_ed25519 -C "clipsync-`$env:COMPUTERNAME"
         type `$env:USERPROFILE\.ssh\id_ed25519.pub
       macOS REMOTE:
         ./install-mac.sh --local-host <this-ip>   (generates the key and prints the public line)

  2. Authorize each REMOTE's PUBLIC key here (elevated; no quotes needed, or omit
     the key and paste it when prompted):
         powershell -File .\setup-ssh-account.ps1 -AddKeyOnly ssh-ed25519 AAAA... host

  3. From the REMOTE, verify key auth (should print LOCAL's hostname, no password prompt):
         ssh $UserName@<this-ip> hostname

  4. Once ALL remotes use '$UserName', remove your admin key from
         C:\ProgramData\ssh\administrators_authorized_keys   (admin no longer SSH-reachable).

  5. Run install-local.ps1 to launch the bridge (it runs as YOUR desktop user).
"@
Write-Host $steps
