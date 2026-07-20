# clipsync &mdash; project notes

## Purpose

Two-way clipboard + file/folder sync between a LOCAL machine and one or more REMOTE machines, when access to REMOTE is via a browser-based remote-desktop transport that can't move files (PIKVM for a Windows REMOTE, Chrome Remote Desktop for a macOS REMOTE). Hotkeys live on REMOTE only.

- **LOCAL** is Windows 11 (`admin` desktop session runs the bridge). REMOTE SSHes into LOCAL as a **dedicated low-privilege `clipsync` account** — NOT `admin` — so a key compromise can't hand over an administrator session. File/image payloads transit a **shared staging dir** (`C:\clipsync-share`) both accounts can read/write.
- **REMOTE** can be **Windows** (hotkeys via AutoHotkey, `clipsync.ahk`) or **macOS** (hotkeys via Hammerspoon, `clipsync.lua`). Both talk to the same bridge over the same endpoints.

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
- **Clipboard read/write**: REMOTE runs `ssh local "curl http://127.0.0.1:8765/<endpoint>"`. The SSH session on LOCAL hits its own loopback, where the bridge (which is in the `admin` interactive session) handles the actual clipboard call. Works even though the SSH account is a *different* (non-admin) user — any local account can dial loopback.
- **File payloads**: `scp -r` from REMOTE in either direction, staged through `C:\clipsync-share`. scp runs as the `clipsync` SSH account, which can't read `admin`'s profile, so all payloads go through the shared dir instead.

## cc-handoff (F7) — folder handoff for Claude Code

An **extension** of clipsync (Windows REMOTE only), not a separate project. `clipsync.ahk` has an `F7` hotkey (`CcHandoff` / `GetCcHandoffSelection`) that resolves the selected Explorer folder via COM and launches a console running **`cc-handoff.ps1`**. Reuses the `clipsync-local` alias, `clipsync` account, `C:\clipsync-share`, `scp`, and the bridge — no watcher, no new staging dir. Spec: `docs/superpowers/specs/2026-07-08-cc-handoff-design.md`; plan: `docs/superpowers/plans/2026-07-08-cc-handoff.md`.

Flow: **push** the folder's git working set → `C:\clipsync-share\incoming\<ts>\<name>`, set LOCAL's clipboard to that path via bridge **`POST /text`** (paste into Claude Code), then a **repeating** `[1] sync-back / [2] done` menu.

Key rules (all enforced by `cc-handoff.Tests.ps1`):
- **git is the exact filter, never reimplemented.** Push set = `git ls-files --cached --others --exclude-standard`; sync-back drops newly-ignored files via `git check-ignore`. The **laptop is the git authority both directions** (LOCAL copy has no `.git`). Non-repo → all files except `.git/`.
- **`.git/`, gitignored secrets (`.env`), build junk never transfer.**
- **Never `robocopy /MIR`/`/PURGE` into the source**, and **not even `robocopy /E`** — its timestamp/size change-detection can silently skip a same-size content edit. `Copy-Changes` does a deterministic **per-file overwrite** (copy-only, never deletes). Deletions propagate **only** for paths in the manifest (the managed set), which **refreshes after each sync** so files added in later rounds also get their deletions propagated.
- **`git check-ignore` is called with paths as ARGS (chunked), not `--stdin`** — PowerShell's pipeline appends a CR that breaks suffix patterns like `*.log`.
- Bridge `POST /text` reuses clipsync's ScpThenPost pattern (scp a body file up, `curl.exe --data-binary '@file'` — never pipe the POST body over ssh stdin).

`install.ps1` deploys `cc-handoff.ps1` alongside `clipsync.ahk` into `%LOCALAPPDATA%\clipsync`.

## The non-admin SSH account (`clipsync`) + shared staging dir

REMOTE authenticates to LOCAL as a dedicated **`clipsync`** account (SSH-only: interactive/RDP logon denied), provisioned once by `setup-ssh-account.ps1` (elevated). The bridge still runs as `admin` in the desktop session. The tension is files: `scp` runs as `clipsync`, but the clipboard lives under `admin`. Resolution — a shared dir `C:\clipsync-share` (ACL: Modify for both `admin` and `clipsync`):

- **Pull** (LOCAL→REMOTE): `GET /files` makes the bridge *copy* `admin`'s selected files into `C:\clipsync-share\outgoing\<ts>` and return those paths; REMOTE scp's them from there. `GET /image` saves the PNG under the share too.
- **Push** (REMOTE→LOCAL): REMOTE scp's into `C:\clipsync-share\incoming\<ts>`, then `POST /files`/`POST /image` hands the bridge the share paths to set on `admin`'s clipboard.

`admin`'s private profile stays unreadable to `clipsync`. Once all REMOTEs use `clipsync`, remove `admin`'s key from `C:\ProgramData\ssh\administrators_authorized_keys` so `admin` is no longer SSH-reachable.

## The "why a bridge" gotcha

On Windows the clipboard is **per-window-station**. SSH-launched processes land in a non-interactive window station, so they can't see the desktop clipboard. We discovered this when `ssh local "Get-Clipboard -Raw"` returned empty even though LOCAL's clipboard had text. The bridge has to run in the user's logon session for `[Windows.Forms.Clipboard]` to work.

## Tech stack

- **AutoHotkey v2 (portable)** &mdash; hotkey host on a **Windows** REMOTE.
- **Hammerspoon (Lua)** &mdash; hotkey host on a **macOS** REMOTE (`clipsync.lua`). Needs Accessibility permission (granted once). User-scope, no admin.
- **PowerShell 5.1** &mdash; LOCAL bridge + Windows REMOTE + setup. Bridge needs STA threading (default for powershell.exe; explicitly passed via `-Sta` in the Startup shortcut).
- **OpenSSH client** &mdash; built-in on Windows 11 and macOS. Used for both `ssh "curl ..."` (clipboard channel) and `scp -r` (file payloads).
- **`curl.exe`** &mdash; built-in on Windows 10/11. Used inside the SSH session **on LOCAL** to dial the bridge (both REMOTE kinds call it via `ssh clipsync-local curl.exe ...`).
- **TcpListener (System.Net.Sockets)** &mdash; bridge transport. Avoids `HttpListener` which needs URL-ACL reservation (admin) for non-default prefixes.

## Files

| Path | Role | Runs on |
|---|---|---|
| `clipsync.ahk` | Windows REMOTE hotkey driver. Two hotkeys (Ctrl+Alt+Win+V/C), dispatch by clipboard kind, GET/POST against the bridge for clipboard, scp (via `C:\clipsync-share`) for file bytes. | Windows REMOTE |
| `clipsync.lua` | macOS REMOTE hotkey driver (Hammerspoon). Ctrl+Alt+Cmd+V/C, same bridge/endpoints, Finder selection via AppleScript, pasteboard file URLs, auto Cmd+C/V. | macOS REMOTE |
| `install.ps1` | Windows REMOTE installer: AHK portable download, script placement, Startup shortcut, ssh config alias (`User clipsync`), smoke test. | Windows REMOTE |
| `install-mac.sh` | macOS REMOTE installer: Hammerspoon, `~/.hammerspoon/clipsync.lua` + `require`, ssh key + `clipsync-local` alias, Accessibility prompt, /ping. | macOS REMOTE |
| `uninstall.ps1` | Windows REMOTE uninstaller. | Windows REMOTE |
| `setup-ssh-account.ps1` | **Elevated, one-time on LOCAL.** Creates the `clipsync` SSH-only account, `C:\clipsync-share` + ACLs, authorized_keys, ensures sshd. `-AddKeyOnly ssh-ed25519 AAAA... comment` (key as trailing tokens, or paste when prompted) to authorize a REMOTE's key. | LOCAL (admin) |
| `clipsync-bridge.ps1` | TCP listener on 127.0.0.1:8765, GET/POST for /ping /kind /text /files /image. Routes files/images through `C:\clipsync-share` (`-ShareDir`). STA-required. Runs as `admin`. | LOCAL |
| `install-local.ps1` | LOCAL installer: copies bridge, Startup shortcut (passes `-ShareDir`), launches it, /ping check. Non-elevated. | LOCAL |
| `README.md` | User-facing usage. | all |

## Bridge endpoints

- `GET /ping`  &rarr; `pong`
- `GET /kind`  &rarr; `text` | `files` | `image` | `empty`
- `GET /text`  &rarr; clipboard text (UTF-8 body)
- `POST /text` &rarr; sets clipboard from request body (UTF-8); empty body clears
- `GET /files` &rarr; **copies** the clipboard's files into `C:\clipsync-share\outgoing\<ts>\` and returns those share paths, one per line (so the non-admin scp account can read them)
- `POST /files` &rarr; sets clipboard FileDropList from newline-separated body (paths the caller has scp'd into `C:\clipsync-share\incoming\`)
- `GET /image` &rarr; saves clipboard image as PNG under `C:\clipsync-share\outgoing\img_<ticks>.png`, returns the absolute LOCAL path (REMOTE scp's it down)
- `POST /image` &rarr; body is a LOCAL absolute path to a PNG under the share the caller has scp'd up; bridge loads it via `[Drawing.Image]::FromFile`, calls `SetImage`, deletes the file

## Key design decisions

- **Why not HttpListener**: needs URL-ACL reservation for non-default prefixes; reservation requires admin. TcpListener with hand-rolled HTTP avoids that.
- **Why bind 127.0.0.1 only**: bridge is reachable only via SSH-session loopback. Zero LAN exposure, no auth needed.
- **Why -EncodedCommand for SSH PowerShell calls** (`SshPs` in clipsync.ahk): cmd + ssh + remote-cmd quoting layers were corrupting characters like `|`, `(`, `;`. UTF-16 base64 is opaque to all of them.
- **Why scp for file payloads, bridge only for clipboard**: scp uses sftp-server which works regardless of session, has built-in recursion, and would be silly to reinvent in PS.
- **Why a separate `clipsync` SSH account (not `admin`)**: don't expose an administrator session over SSH. The clipboard channel is unaffected (loopback); files need the shared dir because scp runs as the non-admin account.
- **Why a shared dir instead of granting `clipsync` into `admin`'s profile**: keeps `admin`'s private files unreadable to the SSH account — the isolation is the whole point.
- **macOS pasteboard file paste**: `clipsync.lua` writes `{url="file://..."}` objects via `hs.pasteboard.writeObjects` to register `public.file-url` so Finder can paste. If a future macOS changes this, it's the spot to revisit.
- **macOS scp SOURCE paths must use forward slashes.** Pulling files LOCAL->Mac failed with `scp: C:\...: No such file or directory` even though the file existed. macOS scp runs a remote **glob** on the source path and mangles backslashes; the Windows OpenSSH sftp server also prefers `/`. Fix: `winPath:gsub("\\", "/")` before building the `host:path` source (`scpRemote()` in `clipsync.lua`). Destinations (push) are NOT globbed, so `C:\...` works there and is left as-is.
- **Auto-copy on push (Mac): wait for the hotkey modifiers to release before synthesizing Cmd+C.** The hotkey callback fires while Ctrl+Alt+Cmd is physically held, so an immediate synthetic Cmd+C is seen by the app as Ctrl+Alt+Cmd+C and copies nothing - push then sends the STALE clipboard. `waitModifiersReleased()` polls `hs.eventtap.checkKeyboardModifiers()` (bounded ~600ms) first. Pull's Cmd+V is unaffected because it fires ~1s later (after ssh), by which point the user has let go - which is why pull always worked and only push was broken.
- **Auto-copy on push (Mac): confirm the pasteboard actually CHANGED, never a fixed sleep.** `waitModifiersReleased` fixed the *modifiers-held* stale push, but a second stale-push path survived: `sendCmd("c")` + a blind `usleep(300ms)` + `readImage()`. If the focused app is slow to serve the copy (an **image** takes far longer than text) or ignores Cmd+C, the pasteboard still holds the PREVIOUS payload — so clipsync re-pushed the OLD image and reported "Pushed image to LOCAL." Symptom: first image syncs, every later one silently lands as image #1 (diagnosed 2026-07-20: bridge log showed 7 `POST /image` all `ok`, and `GET /image` proved the clipboard still held the *first* screenshot). `copyAndWait(maxMs)` now polls `hs.pasteboard.changeCount()` (25ms, ≤1500ms). A non-increment is **not** fatal — the user may have deliberately pre-copied (the Windows REMOTE's only mode) — so the push still happens but the tip is suffixed `(existing clipboard - Cmd+C didn't register)`. Never let a stale push look like a fresh one.
- **The auto-Cmd+C can DESTROY a manual copy (Messages).** In Messages — and any app where a text field holds focus — the synthetic Cmd+C applies to an *empty selection*, and macOS replaces the pasteboard with nothing. So "copy the image yourself, then hit the hotkey" fails too: the hotkey wipes what you just copied. `copyAndWait` snapshots `readImage()`/`readString()` **before** the Cmd+C and puts it back if the copy leaves nothing usable. Note `changeCount` bumps *before* the data is written (declared first, served lazily), so the empty check polls for a 400ms grace period — reading once would false-positive on a good copy and "restore" over it.
- **Per-transfer staging dirs**: LOCAL uses `C:\clipsync-share\{incoming,outgoing}\<timestamp>\`; each REMOTE uses its own `incoming\<timestamp>\` (`%LOCALAPPDATA%\clipsync\incoming` on Windows, `~/.clipsync/incoming` on macOS). Avoids name collisions. LOCAL share pruned >7 days old on bridge start; REMOTE staging cleared on script start.

## Gotchas to remember

- **`install-mac.sh` must stay mode `100755` in the index, and `core.filemode` is `false` here.** The repo is authored on Windows, where git ignores worktree permission bits entirely — so `chmod +x` in the working copy is a no-op and the file was committed `100644`, forcing a manual `chmod +x` on every Mac. Fixed with `git update-index --chmod=+x install-mac.sh` (the *only* way to set it from Windows; a plain `git add` won't). Verify with `git ls-files -s install-mac.sh`, not `ls -l`. `.gitattributes` pins `*.sh` to `eol=lf` so a clone on a machine with `core.autocrlf=true` can't append a CR to the shebang (→ `bad interpreter: bash^M`). Caveat: a raw `curl` of a GitHub file **cannot** carry the bit — HTTP has no mode concept, so that path always lands `644` and must be run as `bash install-mac.sh`.

- PS 5.1 is STA by default; PS 7 is MTA. Bridge asserts STA on startup. Startup shortcut passes `-Sta` explicitly to be safe.
- `[Windows.Forms.Clipboard]::SetFileDropList` requires a `StringCollection`, not a string array.
- `$headers['content-length'] ?? 0` is PS 7-only; bridge uses `if ($headers.ContainsKey(...))` for 5.1 compat (per global CLAUDE.md).
- `ssh host "command"` joins remaining args via the remote shell; quotes in the local shell get stripped before transmission. Use `-EncodedCommand` for any PS script with metacharacters.
- AutoHotkey strings are UTF-16 internally; `StrPtr(s)` gives a pointer to the raw UTF-16 buffer, which we copy directly for `EncodeUtf16Base64` rather than fighting `StrPut`'s null-terminator semantics.
- curl.exe at C:\Windows\System32\curl.exe is on PATH in SSH sessions on Windows 11. Don't worry about pathing.
- **Non-admin `authorized_keys` location — use ProgramData + a Match block, NOT the profile.** A dedicated SSH account that never logs in interactively has **no Windows profile** (empty `ProfileImagePath`), so sshd can't resolve `$HOME` to find a home-relative `.ssh\authorized_keys` and silently falls back to password. Fix: put the key at `C:\ProgramData\ssh\clipsync_authorized_keys` and add `Match User clipsync` / `AuthorizedKeysFile __PROGRAMDATA__/ssh/clipsync_authorized_keys` to `sshd_config`, then restart sshd. This mirrors the box's existing `k3sbackup`/`mediabackup`/`authentikbackup` accounts. ACLs: inheritance off, owner + access only SYSTEM + Administrators (sshd reads as SYSTEM; the account itself needs no access). A BOM in the key file or `sshd_config` breaks parsing — write ASCII. `setup-ssh-account.ps1` section 7 does all this idempotently and validates with `sshd -t` before restarting.
- **Blank-password accounts can't do network logon**: `clipsync` gets a random password (not `-NoPassword`), else the default "limit blank-password use to console" policy blocks SSH.
- **DefaultShell is machine-wide**: `HKLM:\SOFTWARE\OpenSSH\DefaultShell` applies to all SSH logins, so `clipsync` inherits PowerShell and `curl.exe`/`-EncodedCommand` work the same as for `admin`.
- **macOS remote command quoting**: `clipsync.lua` passes the whole remote command as one sh-quoted arg to `ssh`.
- **Do NOT pipe POST bodies over ssh stdin to a PowerShell-hosted curl.** `ssh host "curl.exe --data-binary '@-'" < file` delivers an EMPTY body when LOCAL's default shell is PowerShell — the ssh channel's stdin isn't wired through to the child curl.exe. `POST /text` then *clears* the clipboard but the bridge still returns `ok`, so the push falsely reports success (symptom: "Pushed N chars" but nothing pastes). Fix (matches `clipsync.ahk`'s `ScpThenPost`): `scp` the body file up to `C:\clipsync-share\incoming\clipsync_body_*.bin`, then `curl.exe --data-binary '@<that path>'` reads it as a FILE, then delete it. Verified on LOCAL: a `@file` POST sets the clipboard (metachars intact); an empty-stdin POST clears it and returns `ok`.
- **`clipsync.lua` runs remote PowerShell via `-EncodedCommand` (base64 of UTF-16LE), NOT `powershell -Command "..."`.** A nested `-Command "..."` with double-quotes collides with how sshd wraps the command for the PowerShell default shell → the inner command breaks (observed: `Remove-Item` cleanup exited 2, leaving body files behind; `New-Item` staging-dir creation would fail the same way). Same rationale as `clipsync.ahk`'s `SshPs`. The Lua has a dependency-free `base64()` + a UTF-16LE encoder; verified byte-identical to `[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes(...))`. Only used for ASCII commands (staging paths are ASCII), so 1 zero-high-byte per char is a valid UTF-16LE.

- **macOS passthrough while at the physical Mac using Microsoft Remote Desktop.** When you sit AT the Mac (not via CRD) and focus Microsoft Remote Desktop, the global Hammerspoon hotkeys would swallow `Ctrl+Alt+Cmd+V/C` before they reach the RDP window. `clipsync.lua` runs an `hs.application.watcher`: when a bundle id in `PASSTHROUGH_BUNDLES` (`com.microsoft.rdc.macos` / `com.microsoft.rdc.osx`) is frontmost it `:disable()`s both hotkeys; otherwise `:enable()`. A *disabled* `hs.hotkey` does not intercept the key, so macOS delivers the chord into the RDP session — where macOS `Cmd` maps to the Windows key, so it arrives in the guest as `Ctrl+Alt+Win+V/C` and `clipsync.ahk` (running inside RDP / on the PIKVM'd Windows) handles it. Verify your bundle id with `osascript -e 'id of app "Microsoft Remote Desktop"'` and add it to `PASSTHROUGH_BUNDLES` if Microsoft renamed the app. Tradeoff: the chord is app-scoped, so any press while RDP is frontmost goes to the guest, never the Mac.

- **`GET /files` is synchronous copy-then-respond → the 15s curl cap is the real file limit (not a count).** The bridge copies *every* selected item recursively into `C:\clipsync-share\outgoing\<ts>\` before it writes the response. The REMOTE caps that call at `curl.exe -m <HTTP_TIMEOUT>` (15s default). Many/large folders take longer to stage, so curl aborts and the bridge then fails to write to the closed socket — logged as `ERR ... "Write" ... An established connection was aborted by the software in your host machine.` (2 small items finish in time, so "2 works / 20 fails" looks like a count limit but is really a timeout). Fix in place: `/files` pulls use a longer budget — `HTTP_TIMEOUT_FILES_S = 120` in `clipsync.ahk`, `HTTP_TIMEOUT_FILES = 120` in `clipsync.lua`, passed via the new optional `timeout` arg on `SshGet`/`sshGet`. The bridge's own `ReceiveTimeout`/`SendTimeout` (10s) don't fire during the copy — there's no socket I/O mid-copy — so only curl's `-m` mattered. Data is copied twice (admin→share, then share→REMOTE via scp); a background-stage redesign would avoid that but wasn't needed.

## Verification

Quick sanity from REMOTE: `ssh clipsync-local "curl -s http://127.0.0.1:8765/ping"` should return `pong`. Then end-to-end: pull/push text + files in both directions. Logs: `%LOCALAPPDATA%\clipsync\clipsync.log` (REMOTE) and `clipsync-bridge.log` (LOCAL).

## Open work

- Push/pull of huge files blocks the AHK script while scp runs. Tray tip warns up front; not a real issue at typical sizes.
- No throttling; spamming the hotkey will queue overlapping ssh+scp processes.
- Bridge has no idle timeout; runs until logoff. Could add `$IdleMinutes` param, but the marginal win is small.
