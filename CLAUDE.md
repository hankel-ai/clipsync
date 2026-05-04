# clipsync &mdash; project notes

## Purpose

Two-way clipboard + file/folder sync between two Windows 11 machines (LOCAL and REMOTE) when access to REMOTE is via PIKVM (browser-based KVM with HID forwarding but no clipboard bridge). Driven by hotkeys on REMOTE only.

## Topology / constraints

- Outbound SSH only: REMOTE &rarr; LOCAL. No reverse direction available.
- LOCAL runs `sshd` and accepts the REMOTE user's key. Already configured.
- REMOTE has **no admin rights**. Everything stays in user-scope.
- All software runs on REMOTE; LOCAL gets nothing new beyond runtime files in `%LOCALAPPDATA%\clipsync\`.

## Tech stack

- **AutoHotkey v2 (portable)** &mdash; hotkey host, clipboard reader/writer, dispatcher.
- **OpenSSH client** (Windows 11 built-in) &mdash; transport for both text and files.
- **PowerShell** on both ends &mdash; clipboard read/write via `Get-Clipboard` / `Set-Clipboard`.
- **scp -r** for file/folder payloads.

## Files

| Path | Role |
|---|---|
| `clipsync.ahk` | The hotkey script. Two hotkeys, dispatch by clipboard kind (text vs CF_HDROP), text via UTF-8 temp file + scp, files via `scp -r` + `Set-Clipboard -Path`. |
| `install.ps1` | Bootstraps REMOTE: downloads AHK v2 portable, places script, creates Startup shortcut, optionally writes `~/.ssh/config` alias, smoke-tests. |
| `uninstall.ps1` | Reverses the install. |
| `README.md` | User-facing usage. |

## Key design choices

- **Text payload**: written to a UTF-8 temp file on REMOTE, scp'd to LOCAL %TEMP%, then `[IO.File]::ReadAllText(..., UTF8)` &rarr; `Set-Clipboard`. Avoids stdin/encoding/quoting drama vs piping base64 through `ssh`.
- **File payload**: `scp -r` per item into a per-transfer staging dir (`%LOCALAPPDATA%\clipsync\incoming\<timestamp>\`). Destination clipboard is then set to a CF_HDROP of the staged paths via `Set-Clipboard -Path`.
- **Encoding**: every PowerShell call is prefixed with `[Console]::OutputEncoding=[Text.Encoding]::UTF8;[Console]::InputEncoding=...` so Unicode survives the SSH pipe.
- **Staging**: per-transfer timestamped folder &rarr; no name collisions, easy cleanup. Old folders pruned (>7 days) on script start.
- **Hotkey choice**: `Ctrl+Alt+Win+V` / `Ctrl+Alt+Win+C` &mdash; four-finger chord, low collision risk, browsers don't intercept it before PIKVM forwards.

## Gotchas

- `Set-Clipboard -Path` is the supported way to put a CF_HDROP on the clipboard from PowerShell. Don't try to assemble HDROP by hand.
- AHK `Run2()` captures stdout/stderr via temp files (not COM `Exec`) to avoid deadlocks on large output.
- PowerShell's default output encoding is the console code page, not UTF-8 &mdash; always set `[Console]::OutputEncoding` before `Get-Clipboard -Raw`.
- AHK `EscapeForCmd` doubles `"` &rarr; `""` so a PowerShell snippet can be embedded inside cmd's `"..."` argument.
- `ssh` adds a trailing CRLF on stdout &mdash; trim once after `Get-Clipboard -Raw`.

## Build / run

No build step. To iterate:
1. Edit `clipsync.ahk` here in OneDrive.
2. Copy to REMOTE's `%LOCALAPPDATA%\clipsync\clipsync.ahk` (or rerun `install.ps1`).
3. Right-click the AHK tray icon &rarr; Reload Script (or kill it; the Startup shortcut will respawn at next login).

## Verification

See README.md "Verify" table. Cover: text both ways, file/folder both ways, Unicode, spaces in filenames, mixed selections, empty clipboard, reboot persistence.

## Open questions / future work

- Image clipboard format not handled (CF_BITMAP). Would need PNG round-trip via temp file + `Set-Clipboard -Format Image`.
- Transfer is synchronous (blocks AHK while scp runs). Tray-tip warns up front; could move to a background thread for huge payloads.
- No per-direction throttling. Spamming the hotkey will spawn overlapping scp processes; consider a busy guard.
