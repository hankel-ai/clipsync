# clipsync

Two-way clipboard + file/folder sync between a **LOCAL** Windows machine and one or more **REMOTE** machines, driven by hotkeys on REMOTE. Designed for the case where you reach REMOTE through a browser-based remote desktop that can't move files:

- **Windows REMOTE** via PIKVM (hotkeys via AutoHotkey)
- **macOS REMOTE** via Chrome Remote Desktop (hotkeys via Hammerspoon) — adds the file transfer CRD lacks

REMOTE logs into LOCAL as a dedicated **low-privilege `clipsync` SSH account** (not your admin desktop user). See [SSH account setup](#ssh-account-setup-one-time-on-local).

## Hotkeys

| Windows REMOTE | macOS REMOTE | Action |
|---|---|---|
| `Ctrl+Alt+Win+V` | `Ctrl+Alt+Cmd+V` | Pull LOCAL clipboard onto REMOTE and auto-paste |
| `Ctrl+Alt+Win+C` | `Ctrl+Alt+Cmd+C` | Auto-copy on REMOTE, then push clipboard to LOCAL |

Both hotkeys handle plain text, images, **and** file/folder selections (Explorer CF_HDROP on Windows, Finder selection on macOS). The auto copy/paste makes the workflow seamless — just select and press the hotkey.

> **macOS + Chrome Remote Desktop caveat:** CRD is picky about forwarding modifier combos (the local Windows OS can swallow Win-key combos; CRD remaps Win→Cmd). `Ctrl+Alt+Cmd+V/C` is the default; if CRD won't forward it, change the `MODS`/`KEY_*` lines near the top of `clipsync.lua` (e.g. to an F-key).

## F7 folder handoff (cc-handoff)

On a **Windows REMOTE**, press **F7** with a folder selected in Explorer to hand
that folder to LOCAL for a Claude Code session, then sync your edits back:

1. F7 copies the folder's **git working set** to LOCAL via clipsync's transport,
   into `C:\clipsync-share\incoming\<ts>\<name>`. Only git-tracked / not-ignored
   files go — `.git/`, gitignored **secrets (`.env`)**, and build junk never leave
   the laptop (the filter is `git ls-files` / `git check-ignore`, i.e. exact git
   semantics).
2. The staged path lands on **LOCAL's clipboard** — paste it into Claude Code on
   LOCAL as the project folder.
3. A console stays open on REMOTE with a **repeating** menu: **`[1]`** sync edits
   back to the original folder (repeatable — keep developing and syncing), **`[2]`**
   done. Sync-back overwrites changed/new files and propagates Claude's deletions,
   but is scoped so it **never** touches `.git`, secrets, or anything outside the
   files it sent.

Requires clipsync installed (F7 rides its alias/account/share/bridge) and `git`
on PATH. See `docs/superpowers/specs/2026-07-08-cc-handoff-design.md`.

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

## Setup at a glance

clipsync has a **LOCAL** side (the Windows machine you sit at — runs the SSH server + the clipboard bridge) and a **REMOTE** side (each machine you reach by remote desktop — runs the hotkeys). Do it in this order:

**On LOCAL — once:**
1. **(elevated)** `setup-ssh-account.ps1` — create the low-priv `clipsync` SSH account, the `C:\clipsync-share` staging dir, and the sshd wiring.
2. **(normal user)** `install-local.ps1` — install + auto-start the bridge.

**For each REMOTE:**
3. Generate an SSH key (Windows: `ssh-keygen`; macOS: `install-mac.sh` does it for you).
4. Back on LOCAL **(elevated)**: authorize that key — `setup-ssh-account.ps1 -AddKeyOnly <pubkey>`.
5. On the REMOTE: install the driver — `install.ps1` (Windows) or `install-mac.sh` (macOS).
6. Verify: `ssh clipsync-local hostname` (no password prompt), then a real hotkey pull **and** push (files, not just text).

**Finally — once every REMOTE works as `clipsync`:**
7. On LOCAL, remove `admin`'s key from `C:\ProgramData\ssh\administrators_authorized_keys` so `admin` is no longer SSH-reachable.

All scripts are **idempotent** — safe to re-run. Already had clipsync running as `admin`? Jump to [Migrating an existing setup](#migrating-an-existing-setup-off-the-admin-login).

## File locations

### REMOTE (Windows)

| Path | Purpose |
|---|---|
| `%LOCALAPPDATA%\AHK\AutoHotkey64.exe` | AutoHotkey v2 portable runtime |
| `%LOCALAPPDATA%\clipsync\clipsync.ahk` | Hotkey driver script |
| `%LOCALAPPDATA%\clipsync\cc-handoff.ps1` | F7 folder-handoff script (push/sync-back) |
| `%LOCALAPPDATA%\clipsync\clipsync.log` | REMOTE-side log (every command, exit codes, stderr) |
| `%LOCALAPPDATA%\clipsync\incoming\` | Staging folder for files pulled from LOCAL (cleared on startup) |
| `%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\clipsync.lnk` | Auto-start shortcut |

### REMOTE (macOS)

| Path | Purpose |
|---|---|
| `~/.hammerspoon/clipsync.lua` | Hotkey driver (loaded via `require("clipsync")` in `init.lua`) |
| `~/.clipsync/clipsync.log` | REMOTE-side log |
| `~/.clipsync/incoming/` | Staging folder for files pulled from LOCAL (cleared on startup) |
| Hammerspoon auto-starts at login (its own "Launch at login" setting) | Auto-start |

### LOCAL

| Path | Purpose |
|---|---|
| `%LOCALAPPDATA%\clipsync\clipsync-bridge.ps1` | Clipboard bridge script |
| `%LOCALAPPDATA%\clipsync\clipsync-bridge.log` | LOCAL-side log (every HTTP request) |
| `C:\clipsync-share\incoming\` | Files/images pushed **from** REMOTE (both accounts can read/write) |
| `C:\clipsync-share\outgoing\` | Files/images the bridge stages **for** REMOTE to pull |
| `%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\clipsync-bridge.lnk` | Auto-start shortcut |

### Source / development

| Path | Purpose |
|---|---|
| `setup-ssh-account.ps1` | **LOCAL, elevated, one-time.** Creates the `clipsync` account, shared dir, ProgramData `authorized_keys` + `Match` block, sshd. `-AddKeyOnly <pubkey>` to authorize a REMOTE's key. Idempotent. |
| `clipsync-bridge.ps1` | Source for LOCAL bridge |
| `install-local.ps1` | LOCAL bridge installer (+ auto-start shortcut) |
| `clipsync.ahk` | Source for **Windows** REMOTE hotkey script (incl. the F7 cc-handoff hotkey) |
| `cc-handoff.ps1` | Source for the F7 folder-handoff (git-filtered push + repeatable sync-back). Copied to REMOTE by `install.ps1`. |
| `cc-handoff.Tests.ps1` | Pester tests for cc-handoff's pure functions |
| `install.ps1` | **Windows** REMOTE installer (also deploys `cc-handoff.ps1`) |
| `restart-ahk.bat` | Copy updated `.ahk` to REMOTE AppData + restart AHK |
| `uninstall.ps1` | **Windows** REMOTE uninstaller |
| `clipsync.lua` | Source for **macOS** REMOTE hotkey daemon (Hammerspoon) |
| `install-mac.sh` | **macOS** REMOTE installer |
| `restart-bridge.bat` / `restart-bridge.ps1` | Copy updated bridge to LOCAL AppData + restart bridge |

## Requirements

- **REMOTE (Windows)**: Windows 11, OpenSSH client (default). **No admin rights needed.**
- **REMOTE (macOS)**: macOS, OpenSSH client (default), Hammerspoon (user-scope, no admin; Accessibility granted once). On the same LAN as LOCAL.
- **LOCAL**: Windows 11, OpenSSH **server**, PowerShell 5.1 (default). Admin needed **once** to run `setup-ssh-account.ps1` (creates the `clipsync` SSH account + shared staging dir, wires an sshd `Match` block, and enables sshd). After that, the bridge and everything else runs **as your normal desktop user, no elevation**.

## SSH account setup (one-time, on LOCAL)

REMOTE logs into LOCAL as a dedicated **`clipsync`** account (SSH-only, non-admin), not your desktop admin user. This is provisioned once by an elevated script.

### Step A - on LOCAL: run the setup script (admin)

Copy the `clipsync` folder to LOCAL, then in an **elevated** PowerShell:

```
powershell -ExecutionPolicy Bypass -File .\setup-ssh-account.ps1
```

It creates the `clipsync` user (random password, interactive/RDP logon denied), the shared staging dir `C:\clipsync-share` with ACLs for both your desktop user and `clipsync`, an empty `C:\ProgramData\ssh\clipsync_authorized_keys` with tight ACLs, wires a `Match User clipsync` block into `sshd_config` pointing at that file (see the note in Step C), validates the config with `sshd -t`, restarts sshd, and ensures OpenSSH Server is installed/running/firewalled with PowerShell as the default shell. It's **idempotent** — safe to re-run. You authorize each REMOTE's key in Step C.

### Step B - on each REMOTE: generate a key

**Windows REMOTE:**
```powershell
ssh-keygen -t ed25519 -f $env:USERPROFILE\.ssh\id_ed25519 -C "clipsync-$env:COMPUTERNAME"
type $env:USERPROFILE\.ssh\id_ed25519.pub
```
> Use a Windows path with `-f`, not `~/.ssh/...` — `~` is unreliable for ssh-keygen on Windows. Press Enter twice (no passphrase; the key must work non-interactively).

**macOS REMOTE:** `install-mac.sh` (below) generates the key and prints the public line for you.

### Step C - on LOCAL: authorize each REMOTE's key (admin)

Paste each REMOTE's **public** key line as trailing tokens — no quotes needed, works from cmd.exe or PowerShell:

```
powershell -File .\setup-ssh-account.ps1 -AddKeyOnly ssh-ed25519 AAAA... clipsync-REMOTEHOSTNAME
```

Or run `-AddKeyOnly` with no key and paste the whole line when prompted (most foolproof — no arg-splitting). Either way it appends to `C:\ProgramData\ssh\clipsync_authorized_keys` (an absolute path wired via a `Match User clipsync` block in `sshd_config`) with the correct ACLs. Repeat for every REMOTE.

> **Why ProgramData, not `C:\Users\clipsync\.ssh`?** A dedicated SSH account that never logs in interactively has no Windows profile, so `sshd` can't resolve its home directory to find a home-relative `authorized_keys` — key auth then silently falls back to password. The absolute `Match User` path fixes this. It mirrors the same pattern Windows uses for admin accounts (`administrators_authorized_keys`) and any other SSH-only service accounts on the box.

### Step D - on REMOTE: verify

```
ssh clipsync@<local-ip> "hostname"
```
Should print LOCAL's hostname with no password prompt. (`install.ps1` / `install-mac.sh` create the `clipsync-local` Host alias for you.)

## Install

### Step 1 - on LOCAL (bridge)

After the SSH account setup above, still on LOCAL (no elevation needed):

```
powershell -ExecutionPolicy Bypass -File .\install-local.ps1
```

What it does (user-scope, runs the bridge as **your** desktop user):

1. Copies `clipsync-bridge.ps1` to `%LOCALAPPDATA%\clipsync\`
2. Drops a Startup shortcut (passing `-ShareDir C:\clipsync-share`) so the bridge auto-starts at login
3. Launches the bridge now and pings `http://127.0.0.1:8765/ping`

You should see "Bridge responded to /ping. Install complete." and a green sync icon in the system tray.

### Step 2a - on a Windows REMOTE

Copy the `clipsync` folder to REMOTE, then (single line works in cmd or PowerShell):

```
powershell -ExecutionPolicy Bypass -File .\install.ps1 -LocalSshHost 192.168.1.50
```

`-LocalSshUser` defaults to `clipsync`. Pass `-LocalSshKey <path>` to pin a key, or `-SkipSshConfig` if you already have a `Host clipsync-local` block.

> **Migrating from an `admin` setup?** `install.ps1` **leaves an existing `Host clipsync-local` block untouched** — it will NOT change a leftover `User admin` line to `clipsync`. Edit that line by hand, or delete the block and re-run. See [Migrating an existing setup](#migrating-an-existing-setup-off-the-admin-login).

What it does (user-scope, no elevation):

1. Downloads AutoHotkey v2.0.26 portable and extracts to `%LOCALAPPDATA%\AHK\`
2. Drops `clipsync.ahk` at `%LOCALAPPDATA%\clipsync\clipsync.ahk`
3. Creates a Startup shortcut so it auto-runs at login
4. Adds a `Host clipsync-local` block (`User clipsync`) to `~/.ssh/config`
5. Smoke-tests SSH and the bridge `/ping` endpoint
6. Launches the script

### Step 2b - on a macOS REMOTE

Copy the `clipsync` folder to the Mac, then:

```
chmod +x install-mac.sh
./install-mac.sh --local-host 192.168.1.50
```

What it does (user-scope, no admin):

1. Installs Hammerspoon (via Homebrew if present, else prompts you to drag the app in)
2. Places `clipsync.lua` at `~/.hammerspoon/clipsync.lua` and `require`s it from `init.lua`
3. Generates `~/.ssh/id_ed25519` if needed and **prints the public key** for Step C
4. Adds a `Host clipsync-local` block (`User clipsync`) to `~/.ssh/config`
5. Reminds you to grant Hammerspoon **Accessibility** (System Settings → Privacy & Security → Accessibility) — required for global hotkeys and auto-paste
6. Smoke-tests the bridge `/ping`

After granting Accessibility, reload Hammerspoon's config (menu-bar icon → Reload Config).

## Migrating an existing setup off the `admin` login

If clipsync was already working with REMOTE logging in as `admin`, migrate LOCAL first, then each REMOTE. The two easy-to-miss steps are **2** and **3** — flipping the alias isn't enough on its own, and the driver must be redeployed.

1. **LOCAL (elevated):** run `setup-ssh-account.ps1`, then authorize each REMOTE's existing public key: `setup-ssh-account.ps1 -AddKeyOnly <pubkey>` (Step C). Then **LOCAL (normal user):** `install-local.ps1` to (re)launch the updated bridge.
2. **Each REMOTE — point the alias at the new account.** Edit `~/.ssh/config` and change the `clipsync-local` block's `User admin` to `User clipsync`. `install.ps1` will **not** do this for you — it leaves an existing `Host clipsync-local` block untouched. Either edit the `User` line by hand, or delete the block and re-run `install.ps1`.
3. **Each REMOTE — redeploy the driver.** The updated `clipsync.ahk` (Windows) / `clipsync.lua` (macOS) stages *pushed* files/images through `C:\clipsync-share`. The old script used `%LOCALAPPDATA%`, which — now that you log in as `clipsync` — is a profile the bridge (running as your desktop user) can't read, so **file/image push would silently break**. Deploy the new script with `restart-ahk.bat` (or re-run `install.ps1`); on macOS re-run `install-mac.sh` and reload Hammerspoon.
4. **Verify** on each REMOTE: `ssh clipsync-local hostname` (via the alias, no password prompt), then a real hotkey **file** push *and* pull — not just text — to confirm the shared-dir routing works end to end.
5. **Cut off `admin`.** Only after every REMOTE works as `clipsync`, remove `admin`'s key from `C:\ProgramData\ssh\administrators_authorized_keys`. Until you do, a REMOTE with a stale `User admin` alias can still connect as `admin` and mask a half-finished migration.

## Updating after code changes

> **First-time install uses `install-local.ps1` / `install.ps1`** — they create the auto-start **Startup shortcut**. The `restart-*.bat` helpers below only copy + relaunch the current session's process; they do **not** create the Startup shortcut, so use them for redeploying code changes *after* the initial install.

After editing the source files, deploy to the target machines:

- **LOCAL**: Copy the `clipsync` folder to LOCAL, double-click `restart-bridge.bat`. It copies the updated bridge into `%LOCALAPPDATA%\clipsync\`, kills the old process, relaunches (bridge defaults to `-ShareDir C:\clipsync-share`), and verifies `/ping`. `install-local.ps1` also stops any running bridge first, so you never end up with two.
- **REMOTE (Windows)**: Copy the `clipsync` folder to REMOTE, double-click `restart-ahk.bat`. It copies the updated script into `%LOCALAPPDATA%\clipsync\`, kills the old AHK process, and relaunches.
- **REMOTE (macOS)**: Re-run `install-mac.sh` (it `cp -f`s the new `clipsync.lua`), then reload Hammerspoon's config (menu-bar icon → Reload Config).

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

A tooltip near the cursor on a Windows REMOTE (or an on-screen `hs.alert` on macOS) confirms success/failure for each transfer. For large transfers it persists until the operation completes.

On a **macOS REMOTE** the hotkeys are `Ctrl+Alt+Cmd+V/C`, and the file tests use the **Finder selection** instead of an Explorer copy: select files in Finder, press `Ctrl+Alt+Cmd+C` to push; press `Ctrl+Alt+Cmd+V` in a Finder window to pull + paste.

## Troubleshooting

Logs:
- REMOTE (Windows): `%LOCALAPPDATA%\clipsync\clipsync.log` (every command run, exit code, stderr snippet)
- REMOTE (macOS): `~/.clipsync/clipsync.log`
- LOCAL: `%LOCALAPPDATA%\clipsync\clipsync-bridge.log` (every HTTP request)

Common failures:

| Tooltip on REMOTE | Likely cause |
|---|---|
| "Bridge unreachable: ..." | Bridge not running on LOCAL, or wrong port. Right-click tray icon &rarr; Restart, or relaunch from Startup shortcut |
| "GET /text failed: connect: ..." | SSH itself is fine but bridge isn't listening |
| "scp ... failed" | A path on LOCAL has unusual characters or the file is locked |
| Hotkey does nothing at all | clipsync.ahk isn't running on REMOTE; double-click `restart-ahk.bat` or relaunch from Startup shortcut |
| No tray icon on LOCAL | Bridge not running; double-click `restart-bridge.bat` |

### SSH prompts for a password (key auth not working)

`ssh clipsync@<ip>` or `ssh clipsync-local` asks for a password instead of logging in with the key. On Windows OpenSSH this is almost always the **home-directory / StrictModes** gotcha:

- The `clipsync` account has **no Windows profile** (it never logs in interactively), so `sshd` can't resolve a home-relative `.ssh\authorized_keys`. Fix: the key must live at an **absolute** path — `C:\ProgramData\ssh\clipsync_authorized_keys` — wired via a `Match User clipsync` block in `sshd_config`. `setup-ssh-account.ps1` does this; confirm the block exists and the file is present.
- **ACLs must be tight**: the key file's DACL must grant **only** `SYSTEM:(F)` and `Administrators:(F)` (inheritance off). Check with `icacls C:\ProgramData\ssh\clipsync_authorized_keys` — anything else and OpenSSH refuses the file and falls back to password.
- No **BOM** in the key file or `sshd_config` (write ASCII), and the pasted public key must match the REMOTE's private key.
- Diagnose the real reason on LOCAL via **Event Viewer → Applications and Services Logs → OpenSSH → Operational**, or run `sshd -ddd` — it logs exactly why a key was rejected (bad path, bad permissions, no match).

After changing `sshd_config`, run `sshd -t` to validate and `Restart-Service sshd`. Changes to `authorized_keys` alone need **no** restart.

## Staging folders

File/image transfers are staged, never moved — originals are always left untouched.

- **LOCAL**: `C:\clipsync-share\{incoming,outgoing}\<timestamp>\`. This shared dir is how payloads cross between the non-admin `clipsync` SSH account (which runs `scp`) and your desktop user (which runs the bridge). Subfolders older than 7 days are pruned when the bridge starts.
- **REMOTE**: its own `incoming\<timestamp>\` (`%LOCALAPPDATA%\clipsync\incoming` on Windows, `~/.clipsync/incoming` on macOS), **cleared on startup**.

## Uninstall

On a Windows REMOTE:
```
powershell -ExecutionPolicy Bypass -File .\uninstall.ps1
```
Flags: `-RemoveAhk`, `-RemoveStaging`, `-RemoveSshConfig`.

On a macOS REMOTE: remove the `require("clipsync")` line from `~/.hammerspoon/init.lua`, delete `~/.hammerspoon/clipsync.lua` and `~/.clipsync/`, reload Hammerspoon (or quit it).

On LOCAL: right-click tray icon &rarr; Exit, then delete `%LOCALAPPDATA%\clipsync\` and the Startup shortcut at `%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\clipsync-bridge.lnk`. To also remove the SSH account (elevated): `Remove-LocalUser clipsync`, delete `C:\clipsync-share` and `C:\ProgramData\ssh\clipsync_authorized_keys`, and remove the `Match User clipsync` block from `C:\ProgramData\ssh\sshd_config` (then `Restart-Service sshd`).

## Notes

- AutoHotkey version is pinned to v2.0.26. Override with `-AhkVersion <ver>`.
- Hotkeys fire on REMOTE only when REMOTE has input focus — which is whenever the PIKVM tab is focused on LOCAL.
- The bridge binds **127.0.0.1 only** — not reachable from the LAN. All access goes through your existing SSH connection.
- When LOCAL's SSH default shell is PowerShell, clipsync uses `curl.exe` (not `curl`) to avoid the `Invoke-WebRequest` alias, and `-EncodedCommand` for complex PowerShell snippets to avoid shell-quoting issues.
