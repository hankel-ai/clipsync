# clipsync

Two-way clipboard + file/folder sync between two Windows 11 machines, driven by hotkeys on **REMOTE**. Designed for the case where you access REMOTE through PIKVM in a browser and can't paste between LOCAL and REMOTE.

## Hotkeys

| Hotkey | Action |
|---|---|
| `Ctrl+Alt+Win+V` | Pull LOCAL clipboard onto REMOTE and auto-paste (Ctrl+V) |
| `Ctrl+Alt+Win+C` | Auto-copy (Ctrl+C) on REMOTE, then push clipboard to LOCAL |

Both hotkeys handle plain text **and** Explorer file/folder selections (CF_HDROP). The auto Ctrl+C / Ctrl+V makes the workflow seamless — just select and press the hotkey.

## Topology

```
LOCAL                                       REMOTE
-----                                       ------
clipsync-bridge.ps1                         clipsync.ahk
  - runs in user logon session                - hotkeys
  - listens on 127.0.0.1:8765                 - per hotkey:
  - reads/writes interactive clipboard          ssh local "curl http://127.0.0.1:8765/..."
  - system tray icon (green sync icon)        - file payloads via scp -r
        ^                                       |
        | (loopback, same machine)              | (existing ssh + key auth)
        '---------------------------------------'
```

Why a bridge on LOCAL? On Windows the clipboard is **per-window-station**. SSH-launched processes land in a non-interactive window station, so they can't see the desktop clipboard. The bridge runs in your logon session, so it can — and the SSH session on LOCAL just dials its own loopback to reach it.

## File locations

### REMOTE

| Path | Purpose |
|---|---|
| `%LOCALAPPDATA%\AHK\AutoHotkey64.exe` | AutoHotkey v2 portable runtime |
| `%LOCALAPPDATA%\clipsync\clipsync.ahk` | Hotkey driver script |
| `%LOCALAPPDATA%\clipsync\clipsync.log` | REMOTE-side log (every command, exit codes, stderr) |
| `%LOCALAPPDATA%\clipsync\incoming\` | Staging folder for files pulled from LOCAL (cleared on startup) |
| `%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\clipsync.lnk` | Auto-start shortcut |

### LOCAL

| Path | Purpose |
|---|---|
| `%LOCALAPPDATA%\clipsync\clipsync-bridge.ps1` | Clipboard bridge script |
| `%LOCALAPPDATA%\clipsync\clipsync-bridge.log` | LOCAL-side log (every HTTP request) |
| `%LOCALAPPDATA%\clipsync\incoming\` | Staging folder for files pushed from REMOTE (cleared on startup) |
| `%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\clipsync-bridge.lnk` | Auto-start shortcut |

### Source / development

| Path | Purpose |
|---|---|
| `clipsync.ahk` | Source for REMOTE hotkey script |
| `clipsync-bridge.ps1` | Source for LOCAL bridge |
| `install.ps1` | REMOTE installer |
| `install-local.ps1` | LOCAL installer |
| `uninstall.ps1` | REMOTE uninstaller |
| `restart-ahk.bat` | Copy updated script to REMOTE AppData + restart AHK |
| `restart-bridge.bat` | Copy updated bridge to LOCAL AppData + restart bridge |

## Requirements

- **REMOTE**: Windows 11, OpenSSH client (default). **No admin rights needed.**
- **LOCAL**: Windows 11, OpenSSH **server** running, with key-based auth set up so REMOTE can SSH in without a password. PowerShell 5.1 (default). Admin needed once on LOCAL to install/enable OpenSSH Server; the rest of clipsync needs no admin on either side.

## SSH key setup (one-time)

If REMOTE can already do `ssh <user>@<local-host>` and land at a prompt without typing a password, skip this section.

### Step 0a - on LOCAL: enable OpenSSH Server (admin)

Open PowerShell **as Administrator**:

```powershell
# Install + start the SSH server
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
Start-Service sshd
Set-Service -Name sshd -StartupType Automatic

# Open the firewall (the install usually creates this rule, but verify)
Get-NetFirewallRule -Name *ssh* | Format-Table Name,Enabled,Direction,Action
```

Optional but recommended: set the SSH default shell to PowerShell so the install scripts and `curl.exe` calls in clipsync work as documented:

```powershell
New-ItemProperty -Path "HKLM:\SOFTWARE\OpenSSH" -Name DefaultShell `
    -Value "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" `
    -PropertyType String -Force
```

### Step 0b - on REMOTE: generate a key

```powershell
ssh-keygen -t ed25519 -f $env:USERPROFILE\.ssh\id_ed25519 -C "clipsync-$env:COMPUTERNAME"
```

Press Enter twice to skip the passphrase (the key needs to be usable non-interactively from the AHK script). The public key lands at `%USERPROFILE%\.ssh\id_ed25519.pub`.

> Use a Windows path with `-f` (`$env:USERPROFILE\.ssh\id_ed25519`), not `~/.ssh/...` — `~` is unreliable for ssh-keygen on Windows.

Print the public key so you can copy it:

```powershell
type $env:USERPROFILE\.ssh\id_ed25519.pub
```

### Step 0c - on LOCAL: authorize the key

This is the **important Windows-specific gotcha**: on Windows OpenSSH server, where you put the public key depends on whether the LOCAL user is an Administrator.

| LOCAL user is in... | `authorized_keys` file |
|---|---|
| Administrators group (typical home user) | `C:\ProgramData\ssh\administrators_authorized_keys` |
| Standard user | `%USERPROFILE%\.ssh\authorized_keys` |

If you put the key in the wrong file the login silently falls back to password and key auth never works.

**For an Administrator user** (PowerShell as Administrator on LOCAL):

```powershell
# Paste the line from REMOTE here (one line, no trailing whitespace)
$pubkey = 'ssh-ed25519 AAAA... clipsync-REMOTEHOSTNAME'

$path = 'C:\ProgramData\ssh\administrators_authorized_keys'
Add-Content -Path $path -Value $pubkey -Encoding ASCII

# OpenSSH refuses to use the file unless ACLs are tight: only Admins + SYSTEM
icacls $path /inheritance:r
icacls $path /grant 'Administrators:F' 'SYSTEM:F'
```

**For a standard (non-admin) user on LOCAL**:

```powershell
$pubkey = 'ssh-ed25519 AAAA... clipsync-REMOTEHOSTNAME'

$dir = "$env:USERPROFILE\.ssh"
if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
Add-Content -Path "$dir\authorized_keys" -Value $pubkey -Encoding ASCII
```

### Step 0d - on REMOTE: verify and add a Host alias

```powershell
ssh <local-user>@<local-ip-or-hostname> "hostname"
```

Should print LOCAL's hostname with no password prompt. If it asks for a password, the key isn't being used — double-check the file from Step 0c.

The clipsync REMOTE installer (`install.ps1`) will add a `Host clipsync-local` block to `~/.ssh/config` for you when you pass `-LocalSshHost` and `-LocalSshUser`. If you want to do it manually, append to `%USERPROFILE%\.ssh\config`:

```
Host clipsync-local
    HostName 192.168.1.50
    User admin
    IdentityFile ~/.ssh/id_ed25519
    IdentitiesOnly yes
```

Then `ssh clipsync-local "hostname"` should also succeed.

## Install

### Step 1 - on LOCAL

Copy the `clipsync` folder to LOCAL, then:

```
powershell -ExecutionPolicy Bypass -File .\install-local.ps1
```

What it does (user-scope, no elevation):

1. Copies `clipsync-bridge.ps1` to `%LOCALAPPDATA%\clipsync\`
2. Drops a Startup shortcut so the bridge auto-starts at every login
3. Launches the bridge now and pings `http://127.0.0.1:8765/ping`

You should see "Bridge responded to /ping. Install complete." and a green sync icon in the system tray.

### Step 2 - on REMOTE

Copy the `clipsync` folder to REMOTE, then (single line works in cmd or PowerShell):

```
powershell -ExecutionPolicy Bypass -File .\install.ps1 -LocalSshHost 192.168.1.50 -LocalSshUser admin
```

Pass `-LocalSshKey <path>` to pin a specific private key, or `-SkipSshConfig` if you've already got a `Host clipsync-local` block in `~/.ssh/config`.

What it does (user-scope, no elevation):

1. Downloads AutoHotkey v2.0.26 portable .zip and extracts to `%LOCALAPPDATA%\AHK\`
2. Drops `clipsync.ahk` at `%LOCALAPPDATA%\clipsync\clipsync.ahk`
3. Creates a Startup shortcut so it auto-runs at login
4. Adds a `Host clipsync-local` block to `~/.ssh/config` (skipped if one exists)
5. Smoke-tests SSH and the bridge `/ping` endpoint
6. Launches the script

## Updating after code changes

After editing the source files, deploy to the target machines:

- **LOCAL**: Copy the `clipsync` folder to LOCAL, double-click `restart-bridge.bat`. It copies the updated bridge into `%LOCALAPPDATA%\clipsync\`, kills the old process, relaunches, and verifies `/ping`.
- **REMOTE**: Copy the `clipsync` folder to REMOTE, double-click `restart-ahk.bat`. It copies the updated script into `%LOCALAPPDATA%\clipsync\`, kills the old AHK process, and relaunches.

## Bridge tray icon

The bridge on LOCAL shows a green sync icon in the system tray. Right-click for:

| Menu item | Action |
|---|---|
| Listening on 127.0.0.1:8765 | Status indicator (disabled) |
| Open Log | Opens `clipsync-bridge.log` in Notepad |
| Restart | Stops and relaunches the bridge |
| Exit | Shuts down the bridge cleanly |

## Verify

After install, on REMOTE:

```
ssh clipsync-local "curl.exe -s http://127.0.0.1:8765/ping"
```

Should print `pong`. Then:

| Test | Steps |
|---|---|
| pull text  | copy text on LOCAL &rarr; press Ctrl+Alt+Win+V on REMOTE &rarr; auto-pastes |
| push text  | select text on REMOTE &rarr; press Ctrl+Alt+Win+C &rarr; auto-copies then pushes to LOCAL |
| pull files | select files in LOCAL Explorer &rarr; Ctrl+C &rarr; Ctrl+Alt+Win+V on REMOTE &rarr; auto-pastes in Explorer |
| push files | select files in REMOTE Explorer &rarr; Ctrl+Alt+Win+C &rarr; auto-copies then pushes to LOCAL &rarr; Ctrl+V on LOCAL |

A tooltip near the cursor on REMOTE confirms success/failure for each transfer. For large file transfers, the tooltip persists until the operation completes.

## Troubleshooting

Logs:
- REMOTE: `%LOCALAPPDATA%\clipsync\clipsync.log` (every command run, exit code, stderr snippet)
- LOCAL: `%LOCALAPPDATA%\clipsync\clipsync-bridge.log` (every HTTP request)

Common failures:

| Tooltip on REMOTE | Likely cause |
|---|---|
| "Bridge unreachable: ..." | Bridge not running on LOCAL, or wrong port. Right-click tray icon &rarr; Restart, or relaunch from Startup shortcut |
| "GET /text failed: connect: ..." | SSH itself is fine but bridge isn't listening |
| "scp ... failed" | A path on LOCAL has unusual characters or the file is locked |
| Hotkey does nothing at all | clipsync.ahk isn't running on REMOTE; double-click `restart-ahk.bat` or relaunch from Startup shortcut |
| No tray icon on LOCAL | Bridge not running; double-click `restart-bridge.bat` |

## Staging folders

Both machines use `%LOCALAPPDATA%\clipsync\incoming\` as a staging area for file transfers. Each transfer creates a timestamped subfolder (e.g. `20260504-152206\`). All staging folders are **cleared automatically on startup** — the files are always copies, originals are never moved or deleted.

## Uninstall

On REMOTE:
```
powershell -ExecutionPolicy Bypass -File .\uninstall.ps1
```

Flags: `-RemoveAhk`, `-RemoveStaging`, `-RemoveSshConfig`.

On LOCAL: right-click tray icon &rarr; Exit, then delete `%LOCALAPPDATA%\clipsync\` and the Startup shortcut at `%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\clipsync-bridge.lnk`.

## Notes

- AutoHotkey version is pinned to v2.0.26. Override with `-AhkVersion <ver>`.
- Hotkeys fire on REMOTE only when REMOTE has input focus — which is whenever the PIKVM tab is focused on LOCAL.
- The bridge binds **127.0.0.1 only** — not reachable from the LAN. All access goes through your existing SSH connection.
- When LOCAL's SSH default shell is PowerShell, clipsync uses `curl.exe` (not `curl`) to avoid the `Invoke-WebRequest` alias, and `-EncodedCommand` for complex PowerShell snippets to avoid shell-quoting issues.
