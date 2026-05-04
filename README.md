# clipsync

Two-way clipboard + file/folder sync between two Windows 11 machines over outbound SSH. Designed for the case where you access **REMOTE** through PIKVM in a browser on **LOCAL** and can't paste between them.

## Topology

```
LOCAL (sshd)  <----- ssh + scp -----  REMOTE (this script)
   ^                                       ^
   |                                       |
   keyboard ---PIKVM (HID over web)--------+
```

- `Ctrl+Alt+Win+V` &mdash; pull LOCAL clipboard onto REMOTE
- `Ctrl+Alt+Win+C` &mdash; push REMOTE clipboard onto LOCAL

Works with plain text **and** Explorer file/folder selections (CF_HDROP). Files transit via `scp -r` into `%LOCALAPPDATA%\clipsync\incoming\<timestamp>\` on the destination, and the destination clipboard is set to the staged paths so a normal Ctrl+V in Explorer pastes them.

## Requirements

- **REMOTE**: Windows 11, OpenSSH client (default), key-based SSH already working to LOCAL. **No admin rights needed.**
- **LOCAL**: Windows 11, OpenSSH server running, your REMOTE pubkey in `authorized_keys`.

## Install (on REMOTE)

Run from PowerShell **or** cmd.exe (single line works in both):

```
powershell -ExecutionPolicy Bypass -File .\install.ps1 -LocalSshHost 192.168.1.50 -LocalSshUser admin
```

> If you split the command over multiple lines, use PowerShell with backtick (\`) continuations. cmd.exe doesn't understand backticks and will treat each line as a separate command.

Pass `-LocalSshKey <path>` if you want to pin a specific private key, or `-SkipSshConfig` if you've already got a working `Host clipsync-local` alias in `~/.ssh/config`.

What it does (all user-scope, no elevation):

1. Downloads AutoHotkey v2 portable .zip and extracts to `%LOCALAPPDATA%\AHK\`
2. Drops `clipsync.ahk` at `%LOCALAPPDATA%\clipsync\clipsync.ahk`
3. Creates a Startup shortcut so it auto-runs at login
4. Adds a `Host clipsync-local` block to `~/.ssh/config` (skipped if one exists)
5. Smoke-tests the SSH alias
6. Launches the script

## Verify

After install, on REMOTE:

```powershell
ssh clipsync-local 'powershell -NoProfile -c "echo ok"'
```

Should print `ok` with no prompt. Then:

| Test | Steps |
|---|---|
| pull text  | copy text on LOCAL &rarr; press Ctrl+Alt+Win+V &rarr; paste on REMOTE |
| push text  | copy text on REMOTE &rarr; press Ctrl+Alt+Win+C &rarr; paste on LOCAL |
| pull files | select files in LOCAL Explorer &rarr; Ctrl+C &rarr; Ctrl+Alt+Win+V &rarr; Ctrl+V in REMOTE Explorer |
| push files | select files in REMOTE Explorer &rarr; Ctrl+C &rarr; Ctrl+Alt+Win+C &rarr; Ctrl+V in LOCAL Explorer |

Tray tips on REMOTE confirm success/failure for each transfer.

## Uninstall

```powershell
powershell -ExecutionPolicy Bypass -File .\uninstall.ps1
```

Flags:
- `-RemoveAhk`         also delete `%LOCALAPPDATA%\AHK`
- `-RemoveStaging`     also delete `%LOCALAPPDATA%\clipsync\incoming`
- `-RemoveSshConfig`   strip the `Host clipsync-local` block from `~/.ssh/config`

## Notes

- Staged transfer folders auto-prune after 7 days (configurable in `clipsync.ahk` &rarr; `PRUNE_DAYS`).
- Large transfers block the script while `scp` runs; tray tip says "Copying N item(s)..." up front.
- Hotkeys fire on REMOTE only when REMOTE has input focus &mdash; which is whenever the PIKVM tab is focused on LOCAL.
- AutoHotkey version is pinned to **v2.0.26**. Pass `-AhkVersion <ver>` to `install.ps1` to override.
- All PowerShell snippets pin `[Console]::OutputEncoding = UTF-8` so Unicode survives the SSH pipe.
