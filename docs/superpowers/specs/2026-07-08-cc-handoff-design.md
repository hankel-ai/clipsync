# cc-handoff — F7 folder handoff (clipsync extension)

**Date:** 2026-07-08
**Status:** Approved design
**Home project:** folds into **clipsync** (this repo). No separate project.

## Purpose

Press **F7** on the work laptop with a folder selected in Explorer → the folder's
git-tracked working set is copied to the home box through clipsync's existing
transport, its staged path is placed on the home box clipboard so you paste it
into Claude Code, and a console on the laptop shows a **repeating** menu: **[1]**
sync the edited copy back to the original folder (as many times as you like), or
**[2]** done/cancel. You push once, then keep syncing edits back as you develop
on the home box — no re-push between rounds. It is an extension of clipsync,
reusing the same alias, account, shared dir, `scp`, and bridge — no watcher, no
dedicated staging dir.

## Roles (clipsync's existing model)

| Role | Machine | Provides |
|---|---|---|
| REMOTE | Work laptop | `clipsync.ahk` (adds F7) + `cc-handoff.ps1`; OpenSSH client; **git** (the git authority) |
| LOCAL | Home box `192.168.1.65` | `sshd`, non-admin `clipsync` account, `clipsync-bridge.ps1`, `C:\clipsync-share`; runs Claude Code |

- **ssh alias:** `clipsync-local` (existing). **Account:** `clipsync` (non-admin).
- **Transport:** `scp -r` for bytes (through `C:\clipsync-share`, as clipsync does);
  the bridge (`127.0.0.1:8765` via `ssh clipsync-local curl.exe …`) only sets
  LOCAL's clipboard. All initiated from the laptop.
- **Working copy on LOCAL:** `C:\clipsync-share\incoming\<ts>\<name>` — Claude Code
  edits it in place (runs as `admin`, which has Modify on the share). clipsync's
  existing 7-day prune of the share reaps it.

## The git-driven filter (the core requirement)

Exclusions for **both** transfer directions are decided by **git itself** — never
a reimplemented matcher — so gitignore semantics are exact (nested `.gitignore`,
`!` negations, anchoring, `**`, `.git/info/exclude`, global excludes, trailing
spaces). The laptop is the git authority in both directions because it always
holds `.git`.

- **In-scope set (push):**
  `git -C <src> ls-files --cached --others --exclude-standard`
  → tracked + untracked-but-not-ignored files, inherently excluding every ignored
  file **and** `.git/`.
- **Consequences:** `.git/` is never transferred; gitignored **secrets (`.env`)**
  and build junk (`node_modules/`, `bin/`, `obj/`, `.venv/`, …) never reach the
  home box; net transfer both ways is only the non-ignored working files.
- **Not a git repo / no matches:** fall back to transferring everything **except
  `.git/`**.
- **Why the laptop filters both legs:** the home-box copy has no `.git`, so it
  cannot run git. On sync-back the laptop re-applies the original repo's rules via
  `git check-ignore` to drop anything Claude *newly* created that is ignored.

### Sync-back safety — never `robocopy /MIR` into `<src>`

A mirror (`robocopy /MIR` / `/PURGE`) deletes anything in the destination absent
from the source. The original folder still holds `.git/`, gitignored **secrets
(`.env`)**, and build dirs that were *deliberately never transferred* — a mirror
would wipe all of them. So the sync-back does a deterministic **per-file
overwrite** (copy-only, never deletes) and propagates deletions **only** for paths
in the manifest (the "managed set") that Claude removed. Deletion is scoped to
files cc-handoff put under management; everything else in `<src>` is untouched.

> Note: we also avoid `robocopy /E` for the copy itself — its default
> timestamp/size change-detection can silently skip a same-size content edit. The
> per-file overwrite is content-authoritative.

### Repeatable sync-back + a self-refreshing manifest

The menu **loops**: `[1]` syncs back and returns to the menu, so you push once and
keep syncing edits back across many rounds without re-pushing; `[2]` ends the
session. The manifest starts as the push set (`$include`) and is **refreshed after
each sync** to "every file currently in the pulled tree." Without the refresh, a
file you *add* on the home box in round 2 and *delete* in round 3 would never get
its deletion propagated — it was never in the original push manifest. Refreshing
keeps deletion-scoping correct across rounds while still never touching files
outside the managed set (`.git/`, secrets, build junk).

## Flow

```
[laptop] F7 while a folder is selected in the active Explorer window
   │  clipsync.ahk resolves the selection to an absolute folder path,
   │  then Runs a visible console:  powershell cc-handoff.ps1 -Source "<path>"
   ▼
cc-handoff.ps1 -Source "<src>"   (console window; REMOTE)
   name = leaf(<src>)
   1. include = git -C <src> ls-files --cached --others --exclude-standard
        (fallback: all files except .git\ when <src> is not a repo)
   2. stage <include> into a temp clean tree preserving structure
   3. ssh clipsync-local: New-Item C:\clipsync-share\incoming\<ts>\<name>
   4. scp -r <temp clean tree>\*  →  clipsync-local:C:\clipsync-share\incoming\<ts>\<name>
   5. bridge POST /text  with "C:\clipsync-share\incoming\<ts>\<name>"
        → home box clipboard now holds that path (paste into Claude Code)
   manifest = include        (the "managed set"; refreshed after every sync)
   6. REPEATING menu (loop until [2]):
        [1] Sync updates back to <src>   (repeatable)
        [2] Done / cancel
        │
        ▼  (paste the path into Claude Code on the home box, work, come back)
   [1] sync-back  (then RETURN to the menu — do NOT exit):
        a. scp -r clipsync-local:C:\clipsync-share\incoming\<ts>\<name>  →  <laptop temp>\<name>
        b. drop files Claude NEWLY created that are ignored:
             git -C <src> check-ignore over the pulled tree, delete matches from <laptop temp>\<name>
        c. copy changes + new (non-ignored) files back, WITHOUT deleting anything:
             per-file overwrite of every pulled file onto "<src>" (copy-only; NO mirror/purge)
             + recreate every directory in the pulled tree, INCLUDING empty ones
             (a file-list copy alone would silently drop new empty folders)
        d. propagate ONLY managed deletions: for each relative path in `manifest`
             now MISSING from <laptop temp>\<name>, remove it from "<src>"
        e. manifest = every relative path now in <laptop temp>\<name>   (refresh)
        f. remove <laptop temp>;  loop back to the menu
   [2] done/cancel:
        stop; leave the copy in the share; clipsync's 7-day prune reaps it.
```

### Copy-by-copy: source, destination, transport, dataset

`robocopy` never crosses the network — it only reconciles two **local** folders on
the laptop. All network transfer is `scp`, which lands bytes in a laptop temp dir
first; `robocopy` then does the smart local merge/delete.

**Machines:** laptop = clipsync REMOTE (holds the real `C:\work\<name>` + `.git`);
home box `192.168.1.65` = clipsync LOCAL (runs Claude Code).

**PUSH (F7):**

| # | Op | Source → Destination | Runs on | Network? | Dataset (which files) |
|---|----|----------------------|---------|----------|------------------------|
| 1 | `Copy-IncludeTree` | `C:\work\<name>\<files>` → `%TEMP%\cchstage_*\<name>\` | Laptop | Local | **git-filtered set** — `git ls-files --cached --others --exclude-standard` (tracked + untracked-not-ignored). Excludes `.git/`, `.env`, `node_modules/`, build dirs. This step *is* the filter. |
| 2 | `scp -r` push | `%TEMP%\cchstage_*\<name>` → `clipsync-local:C:/clipsync-share/incoming/<ts>/` | Laptop→Home box | **Network** | Same git-filtered set. Nothing ignored crosses the wire. |
| 3 | `scp` + `curl POST /text` | path string → home box clipboard | Laptop→Home box | Network | **No folder files** — just the one-line staged path string. |
| 4 | cleanup | delete `%TEMP%\cchstage_*` | Laptop | Local | git-filtered temp copy (discarded). |

**Claude edits in place** at `C:\clipsync-share\incoming\<ts>\<name>` (home box):
dataset = git-filtered set + Claude's additions (⚠ may include newly-created
ignored junk, e.g. `dist/`) − Claude's deletions.

**SYNC-BACK (`[1]`):**

| # | Op | Source → Destination | Runs on | Network? | Dataset (which files) |
|---|----|----------------------|---------|----------|------------------------|
| 5 | `scp -r` pull | `clipsync-local:…/incoming/<ts>/<name>` → `%TEMP%\cchpull_*\` | Home box→Laptop | **Network** | Claude's whole current copy: filtered set + edits/additions (⚠ may include ignored junk) − deletions. Full copy, no delta. |
| 6 | `Remove-IgnoredFiles` | inside `%TEMP%\cchpull_*\<name>` | Laptop | Local | Removes **only Claude's newly-ignored files** (`git check-ignore`). Temp becomes non-ignored only. |
| 7 | `Copy-Changes` (per-file overwrite) | `%TEMP%\cchpull_*\<name>` → `C:\work\<name>` | Laptop | **Local** | Non-ignored changed + new files. Deterministic copy/overwrite only — **deletes nothing**. |
| 8 | `Remove-DeletedFromManifest` | delete from `C:\work\<name>` | Laptop | Local | **Only manifest paths Claude deleted** (files we sent in step 1, now missing from temp). Never touches `.git`, `.env`, or anything not sent. |
| 9 | cleanup | delete `%TEMP%\cchpull_*` | Laptop | Local | pulled temp copy (discarded). |

## Reused clipsync building blocks

- **`clipsync.ahk` helpers** (already present): `Run2`, `SshPs` (`-EncodedCommand`),
  `ScpThenPost` (scp a body file up, then `curl.exe --data-binary '@file'` — never
  pipe a POST body over ssh stdin), `LOCAL_SHARE`, `SSH_HOST`, `Tip`, `Log`.
- **Bridge endpoint:** `POST /text` sets LOCAL's clipboard from the request body.
  Used to deliver the staged path. (Text, **not** a FileDropList — you paste a path
  string into the Claude Code prompt.)
- **Share + prune:** `C:\clipsync-share\incoming\<ts>\…`, pruned >7 days on bridge
  start. cc-handoff adds nothing new to clean up.

## Components (each independently testable)

| Component | Machine | Responsibility |
|---|---|---|
| F7 block in `clipsync.ahk` | laptop | On F7: resolve the foreground Explorer window's selected item via COM; if it's a folder, `Run` a visible console for `cc-handoff.ps1 -Source "<path>"`. AHK v2.0. |
| `cc-handoff.ps1` | laptop | git filter → stage → `scp` push → bridge `POST /text` → menu/pause → `[1]` mirror-back / `[2]` cancel. PowerShell 5.1. |

No changes to `clipsync-bridge.ps1` — `POST /text` already exists.

## Component contracts

- **F7 block (`clipsync.ahk`)**
  - *Does:* resolve Explorer selection → launch the console handoff for a folder.
  - *Depends on:* the running clipsync AHK process (for COM + config), `cc-handoff.ps1`.
  - *Edge cases:* no Explorer focused / nothing selected / a file (not a folder)
    selected → tray tip and abort. Does not disturb clipsync's existing hotkeys.

- **`cc-handoff.ps1 -Source <path>`**
  - *Does:* the full filtered push → clipboard → pause → mirror-back / cancel cycle.
  - *Depends on:* `git`, OpenSSH client (`ssh`/`scp`), `robocopy`, `curl.exe`, the
    `clipsync-local` alias + key, a running bridge on LOCAL.
  - *Edge cases:* not a git repo → fallback filter (all but `.git\`); `scp`/`ssh`
    failure on push → report and stop **before** the menu (no half state);
    bridge unreachable → still show the menu but warn the path wasn't put on the
    clipboard (print it so the user can copy it manually); `[2]`/window-close →
    no sync-back.

## Setup / integration steps (one-time)

1. Add the F7 block to `clipsync.ahk` (ClaudeCode source) and `cc-handoff.ps1` to
   this repo; ship both via clipsync's existing `deploy.cmd` (user runs it — never
   auto-deployed here).
2. No new SSH account, key, share, or bridge change — cc-handoff rides entirely on
   clipsync's existing LOCAL setup.
3. Confirm `git` is on PATH in the laptop's console session.

## Out of scope

- Copying work code onto a personal machine is the user's decision; no policy,
  encryption-at-rest, or audit here (gitignore keeps secrets off the wire, which
  is the main practical safeguard).
- No conflict detection if `<src>` changes on the laptop while Claude edits the
  copy — the mirror-back is authoritative (home box wins for in-scope files).
- No signal from the home box that Claude Code exited; the user decides when to
  choose `[1]`/`[2]`.
- Claude Code is launched manually (paste the clipboard path); not auto-started.
- Files Claude *newly* creates that are ignored are pulled then discarded by the
  `check-ignore` step — a small, bounded waste, accepted to keep the home box
  git-free.
