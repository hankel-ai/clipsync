# clipsync

Two-way clipboard + file/folder sync between two Windows 11 machines, driven by hotkeys on **REMOTE**. Designed for the case where you access REMOTE through PIKVM in a browser and can't paste between LOCAL and REMOTE.

## Topology

```
LOCAL                                       REMOTE
-----                                       ------
clipsync-bridge.ps1                         clipsync.ahk
  - runs in user logon session                - hotkeys
  - listens on 127.0.0.1:8765                 - per hotkey:
  - reads/writes interactive clipboard          ssh local "curl http://127.0.0.1:8765/..."
                                              - file payloads via scp -r
        ^                                       |
        | (loopback, same machine)              | (existing ssh + key auth)
        '---------------------------------------'
```

Why a bridge on LOCAL? On Windows the clipboard is **per-window-station**. SSH-launched processes land in a non-interactive window station, so they can't see the desktop clipboard. The bridge runs in your logon session, so it can — and the SSH session on LOCAL just dials its own loopback to reach it.

- `Ctrl+Alt+Win+V` &mdash; pull LOCAL clipboard onto REMOTE
- `Ctrl+Alt+Win+C` &mdash; push REMOTE clipboard onto LOCAL

Handles plain text **and** Explorer file/folder selections (CF_HDROP).

## Requirements

- **REMOTE**: Windows 11, OpenSSH client (default), key-based SSH already working to LOCAL. **No admin rights needed.**
- **LOCAL**: Windows 11, OpenSSH server with your REMOTE pubkey in `authorized_keys`. PowerShell 5.1 (default). **No admin rights needed.**

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

You should see "Bridge responded to /ping. Install complete."

### Step 2 - on REMOTE

Copy the `clipsync` folder to REMOTE, then (single line works in cmd or PowerShell):

```
powershell -ExecutionPolicy Bypass -File .\install.ps1 -LocalSshHost 192.168.1.50 -LocalSshUser admin
```

> Multi-line continuations: PowerShell uses backtick (\`); cmd doesn't. Use a single line in cmd.

Pass `-LocalSshKey <path>` to pin a specific private key, or `-SkipSshConfig` if you've already got a `Host clipsync-local` block in `~/.ssh/config`.

What it does (user-scope, no elevation):

1. Downloads AutoHotkey v2.0.26 portable .zip and extracts to `%LOCALAPPDATA%\AHK\`
2. Drops `clipsync.ahk` at `%LOCALAPPDATA%\clipsync\clipsync.ahk`
3. Creates a Startup shortcut so it auto-runs at login
4. Adds a `Host clipsync-local` block to `~/.ssh/config` (skipped if one exists)
5. Smoke-tests SSH and the bridge `/ping` endpoint
6. Launches the script

## Verify

After install, on REMOTE:

```
ssh clipsync-local "curl -s http://127.0.0.1:8765/ping"
```

Should print `pong`. Then:

| Test | Steps |
|---|---|
| pull text  | copy text on LOCAL &rarr; press Ctrl+Alt+Win+V &rarr; paste on REMOTE |
| push text  | copy text on REMOTE &rarr; press Ctrl+Alt+Win+C &rarr; paste on LOCAL |
| pull files | select files in LOCAL Explorer &rarr; Ctrl+C &rarr; Ctrl+Alt+Win+V &rarr; Ctrl+V in REMOTE Explorer |
| push files | select files in REMOTE Explorer &rarr; Ctrl+C &rarr; Ctrl+Alt+Win+C &rarr; Ctrl+V in LOCAL Explorer |

Tray tips on REMOTE confirm success/failure for each transfer.

## Troubleshooting

Logs:
- REMOTE: `%LOCALAPPDATA%\clipsync\clipsync.log` (every command run, exit code, stderr snippet)
- LOCAL: `%LOCALAPPDATA%\clipsync\clipsync-bridge.log` (every request)

Common failures:

| Tray tip on REMOTE | Likely cause |
|---|---|
| "Bridge unreachable: ..." | bridge not running on LOCAL, or wrong port. Restart from `%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\clipsync-bridge.lnk` |
| "GET /text failed: connect: ..." | SSH itself is fine but bridge isn't listening |
| "scp ... failed" | a path on LOCAL has unusual characters or the file is locked |
| Hotkey does nothing at all | clipsync.ahk isn't running on REMOTE; relaunch from Startup folder shortcut |

## Uninstall

On REMOTE:
```
powershell -ExecutionPolicy Bypass -File .\uninstall.ps1
```

Flags: `-RemoveAhk`, `-RemoveStaging`, `-RemoveSshConfig`.

On LOCAL: stop `powershell.exe` running `clipsync-bridge.ps1`, delete `%LOCALAPPDATA%\clipsync\` and the Startup shortcut.

## Notes

- Staged transfer folders auto-prune after 7 days (`PRUNE_DAYS` in `clipsync.ahk`).
- AutoHotkey version is pinned to v2.0.26. Override with `-AhkVersion <ver>`.
- Hotkeys fire on REMOTE only when REMOTE has input focus &mdash; which is whenever the PIKVM tab is focused on LOCAL.
- The bridge binds **127.0.0.1 only** &mdash; not reachable from the LAN. All access goes through your existing SSH connection.
