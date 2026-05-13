# clipsync &mdash; project notes

## Purpose

Two-way clipboard + file/folder sync between two Windows 11 machines (LOCAL and REMOTE) when access to REMOTE is via PIKVM (browser-based KVM with HID forwarding but no clipboard bridge). Hotkeys live on REMOTE only.

## Architecture

```
LOCAL (interactive logon session)        REMOTE (interactive desktop)
    clipsync-bridge.ps1                      clipsync.ahk
    127.0.0.1:8765                            hotkeys + dispatcher
        ^                                     |
        | loopback                            | ssh + curl
        |                                     v
    sshd  <----------- ssh ---------- ssh client
                                              |
                                              | scp -r for file payloads
                                              v
```

Two transports:
- **Clipboard read/write**: REMOTE runs `ssh local "curl http://127.0.0.1:8765/<endpoint>"`. The SSH session on LOCAL hits its own loopback, where the bridge (which is in the user's interactive session) handles the actual clipboard call.
- **File payloads**: plain `scp -r` from REMOTE in either direction. Files don't need the bridge.

## The "why a bridge" gotcha

On Windows the clipboard is **per-window-station**. SSH-launched processes land in a non-interactive window station, so they can't see the desktop clipboard. We discovered this when `ssh local "Get-Clipboard -Raw"` returned empty even though LOCAL's clipboard had text. The bridge has to run in the user's logon session for `[Windows.Forms.Clipboard]` to work.

## Tech stack

- **AutoHotkey v2 (portable)** &mdash; hotkey host on REMOTE.
- **PowerShell 5.1** &mdash; both ends. Bridge needs STA threading (default for powershell.exe; explicitly passed via `-Sta` in the Startup shortcut).
- **OpenSSH client** &mdash; built-in on Windows 11. Used for both `ssh "curl ..."` (clipboard channel) and `scp -r` (file payloads).
- **`curl.exe`** &mdash; built-in on Windows 10/11. Used inside the SSH session on LOCAL to dial the bridge.
- **TcpListener (System.Net.Sockets)** &mdash; bridge transport. Avoids `HttpListener` which needs URL-ACL reservation (admin) for non-default prefixes.

## Files

| Path | Role | Runs on |
|---|---|---|
| `clipsync.ahk` | Hotkey driver. Two hotkeys, dispatch by clipboard kind, GET/POST against the bridge for clipboard, scp for file bytes. | REMOTE |
| `install.ps1` | REMOTE installer: AHK portable download, script placement, Startup shortcut, ssh config alias, smoke test. | REMOTE |
| `uninstall.ps1` | REMOTE uninstaller. | REMOTE |
| `clipsync-bridge.ps1` | TCP listener on 127.0.0.1:8765, handles GET/POST for /kind /text /files /ping. STA-required. | LOCAL |
| `install-local.ps1` | LOCAL installer: copies bridge, creates Startup shortcut, launches it, /ping check. | LOCAL |
| `README.md` | User-facing usage. | both |

## Bridge endpoints

- `GET /ping`  &rarr; `pong`
- `GET /kind`  &rarr; `text` | `files` | `image` | `empty`
- `GET /text`  &rarr; clipboard text (UTF-8 body)
- `POST /text` &rarr; sets clipboard from request body (UTF-8); empty body clears
- `GET /files` &rarr; CF_HDROP paths, one per line
- `POST /files` &rarr; sets clipboard FileDropList from newline-separated body
- `GET /image` &rarr; saves clipboard image as PNG under `%LOCALAPPDATA%\clipsync\outgoing\img_<ticks>.png`, returns the absolute LOCAL path (AHK scp's it down)
- `POST /image` &rarr; body is a LOCAL absolute path to a PNG the caller has scp'd up; bridge loads it via `[Drawing.Image]::FromFile`, calls `SetImage`, deletes the file

## Key design decisions

- **Why not HttpListener**: needs URL-ACL reservation for non-default prefixes; reservation requires admin. TcpListener with hand-rolled HTTP avoids that.
- **Why bind 127.0.0.1 only**: bridge is reachable only via SSH-session loopback. Zero LAN exposure, no auth needed.
- **Why -EncodedCommand for SSH PowerShell calls** (`SshPs` in clipsync.ahk): cmd + ssh + remote-cmd quoting layers were corrupting characters like `|`, `(`, `;`. UTF-16 base64 is opaque to all of them.
- **Why scp for file payloads, bridge only for clipboard**: scp uses sftp-server which works regardless of session, has built-in recursion, and would be silly to reinvent in PS.
- **Per-transfer staging dirs**: `%LOCALAPPDATA%\clipsync\incoming\<timestamp>\` on both sides. Avoids name collisions and makes cleanup obvious. Pruned >7 days old on script start.

## Gotchas to remember

- PS 5.1 is STA by default; PS 7 is MTA. Bridge asserts STA on startup. Startup shortcut passes `-Sta` explicitly to be safe.
- `[Windows.Forms.Clipboard]::SetFileDropList` requires a `StringCollection`, not a string array.
- `$headers['content-length'] ?? 0` is PS 7-only; bridge uses `if ($headers.ContainsKey(...))` for 5.1 compat (per global CLAUDE.md).
- `ssh host "command"` joins remaining args via the remote shell; quotes in the local shell get stripped before transmission. Use `-EncodedCommand` for any PS script with metacharacters.
- AutoHotkey strings are UTF-16 internally; `StrPtr(s)` gives a pointer to the raw UTF-16 buffer, which we copy directly for `EncodeUtf16Base64` rather than fighting `StrPut`'s null-terminator semantics.
- curl.exe at C:\Windows\System32\curl.exe is on PATH in SSH sessions on Windows 11. Don't worry about pathing.

## Verification

Quick sanity from REMOTE: `ssh clipsync-local "curl -s http://127.0.0.1:8765/ping"` should return `pong`. Then end-to-end: pull/push text + files in both directions. Logs: `%LOCALAPPDATA%\clipsync\clipsync.log` (REMOTE) and `clipsync-bridge.log` (LOCAL).

## Open work

- Push/pull of huge files blocks the AHK script while scp runs. Tray tip warns up front; not a real issue at typical sizes.
- No throttling; spamming the hotkey will queue overlapping ssh+scp processes.
- Bridge has no idle timeout; runs until logoff. Could add `$IdleMinutes` param, but the marginal win is small.
