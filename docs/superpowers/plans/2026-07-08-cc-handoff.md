# cc-handoff Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an F7 hotkey to clipsync that copies the git-tracked working set of the selected Explorer folder to the home box, puts its staged path on the home box clipboard, and offers a paused laptop console to **repeatedly** sync edits back (scoped, deletion-safe) until you choose done — enabling continuous develop-from-home iteration without re-pushing.

**Architecture:** Folds into the existing **clipsync** project. `clipsync.ahk` gains one F7 hotkey that resolves the Explorer selection via COM and launches a visible PowerShell console running the new `cc-handoff.ps1`. That script does the whole cycle: filter files with `git` itself → stage a clean tree → `scp -r` to `C:\clipsync-share\incoming\<ts>\<name>` → set the home box clipboard to that path via the clipsync bridge's `POST /text` → show a **repeating** `[1] sync back / [2] done` menu → each `[1]` pulls the copy back and reconciles changes/deletions **scoped to a self-refreshing manifest** (never touching `.git`, secrets, or build junk in the original), then returns to the menu so you can iterate.

**Tech Stack:** AutoHotkey v2.0 (portable, `%LOCALAPPDATA%\AHK\AutoHotkey64.exe`), Windows PowerShell 5.1, OpenSSH (`ssh`/`scp`), `git`, `robocopy`, `curl.exe`. Tests: Pester v5.

## Global Constraints

- **Edit the ClaudeCode source only.** All edits go to `C:\Users\admin\OneDrive\ClaudeCode\_idle_projects_hankel-ai\clipsync\`. **Never edit `C:\Users\admin\OneDrive\Programs\clipsync\`** (that is the deployed copy).
- **Stage only; never commit or push.** End each task with `git add`; the user reviews and commits via ai-commit. Never run `git commit` / `git push`. If clipsync is not a git repo, skip staging.
- **Never auto-run deployment.** `deploy.cmd` and `install.ps1` are run by the user (deploy.cmd ends with `pause`).
- **PowerShell 5.1:** no `??` null-coalescing; use `if`/`else`. ASCII identifiers and ASCII hyphens only.
- **Remote shell on LOCAL is PowerShell.** Use `curl.exe` (not `curl`). Run remote PowerShell via `-EncodedCommand` (base64 of UTF-16LE). Single-quote any remote argument containing `@ ; | ( )` so the remote PowerShell treats it literally.
- **scp remote paths use forward slashes** (the Windows sftp server mangles backslashes on the remote glob). Local Windows paths keep backslashes.
- **Sync-back must NEVER delete files outside the managed manifest.** Do not mirror (`robocopy /MIR` / `/PURGE`) into the original — that would delete `.git/`, gitignored secrets (`.env`), and build dirs that were deliberately never transferred. The sync-back does a deterministic per-file **overwrite** (copy-only, never deletes) and propagates deletions only for paths in the manifest.
- **Never pipe a POST body over ssh stdin** to the PowerShell-hosted `curl.exe` (delivers an empty body). Always `scp` the body file up, then `curl.exe --data-binary '@<path>'`.
- Config values: ssh alias `clipsync-local`; share root `C:/clipsync-share`; bridge `http://127.0.0.1:8765`; deployed script dir `%LOCALAPPDATA%\clipsync`.

---

## File Structure

- **Create** `cc-handoff.ps1` — all handoff logic as dot-sourceable functions + a guarded `Invoke-Handoff` entry point.
- **Create** `cc-handoff.Tests.ps1` — Pester v5 tests for the pure/local functions.
- **Modify** `clipsync.ahk` — add one config var, the `F7` hotkey, and `GetCcHandoffSelection()`.
- **Modify** `install.ps1` — also copy `cc-handoff.ps1` into `%LOCALAPPDATA%\clipsync`.
- **Modify** `CLAUDE.md` and `README.md` — document the F7 feature.

All under `C:\Users\admin\OneDrive\ClaudeCode\_idle_projects_hankel-ai\clipsync\`.

**Function surface of `cc-handoff.ps1` (defined across tasks):**

| Function | Signature | Tested by |
|---|---|---|
| `Get-HandoffName` | `([string]$Source) -> [string]` | Task 1 |
| `Get-IncludedFiles` | `([string]$Source) -> [string[]]` (forward-slash repo-relative paths; `@()` if none) | Task 2 |
| `Copy-IncludeTree` | `([string]$Source,[string[]]$Files,[string]$Dest) -> [void]` | Task 3 |
| `Copy-Changes` | `([string]$From,[string]$To) -> [int]` (count copied; deterministic per-file overwrite, never deletes) | Task 4 |
| `Remove-DeletedFromManifest` | `([string]$Source,[string]$PulledRoot,[string[]]$Manifest) -> [string[]]` (removed rels) | Task 4 |
| `Remove-IgnoredFiles` | `([string]$Repo,[string]$Root) -> [string[]]` (removed rels) | Task 5 |
| `Get-TreeRelPaths` | `([string]$Root) -> [string[]]` (all files' forward-slash rels; refreshes the managed manifest each sync) | Task 4 |
| `Invoke-RemotePwsh` | `([string]$Script) -> [string]` (remote stdout) | manual (Task 6) |
| `New-RemoteDir` | `([string]$RemotePath) -> [void]` | manual (Task 6) |
| `Send-Tree` | `([string]$LocalTree,[string]$RemoteParent) -> [void]` | manual (Task 6) |
| `Set-LocalClipboardText` | `([string]$Text) -> [bool]` | manual (Task 6) |
| `Receive-Tree` | `([string]$RemotePath,[string]$LocalParent) -> [void]` | manual (Task 6) |
| `Invoke-Handoff` | `([string]$Source) -> [void]` (entry point) | manual (Task 6) |

---

### Task 1: Scaffold `cc-handoff.ps1` + `Get-HandoffName`

Establishes the dot-sourceable structure (functions load without running `main`, so tests can import them) and the first pure function.

**Files:**
- Create: `cc-handoff.ps1`
- Test: `cc-handoff.Tests.ps1`

**Interfaces:**
- Produces: `Get-HandoffName([string]$Source) -> [string]` — the leaf folder name, tolerant of trailing slashes.
- Produces: the dot-source guard idiom (`$MyInvocation.InvocationName -ne '.'`) that all later tasks rely on so `. .\cc-handoff.ps1` defines functions without executing.

- [ ] **Step 1: Ensure Pester v5 is available**

Run:
```powershell
$p = Get-Module -ListAvailable Pester | Sort-Object Version -Descending | Select-Object -First 1
if (-not $p -or $p.Version.Major -lt 5) { Install-Module Pester -Scope CurrentUser -Force -SkipPublisherCheck }
(Get-Module -ListAvailable Pester | Sort-Object Version -Descending | Select-Object -First 1).Version
```
Expected: prints a version `5.x` or higher.

- [ ] **Step 2: Write the scaffold with `Get-HandoffName`**

Create `cc-handoff.ps1`:
```powershell
<#
    cc-handoff.ps1 - clipsync extension. Copies the git working set of a folder
    to LOCAL (home box) through clipsync's transport, sets LOCAL's clipboard to
    the staged path, then offers [1] sync-back / [2] cancel.

    Run:   powershell -NoProfile -ExecutionPolicy Bypass -File cc-handoff.ps1 -Source "C:\path\to\folder"
    Test:  dot-source (. .\cc-handoff.ps1) to load functions without running.
#>
[CmdletBinding()]
param([string]$Source)

$ErrorActionPreference = 'Stop'

# --- Config -----------------------------------------------------------------
$script:SshHost   = 'clipsync-local'
$script:Share     = 'C:/clipsync-share'
$script:BridgeUrl = 'http://127.0.0.1:8765'

# --- Pure helpers -----------------------------------------------------------
function Get-HandoffName {
    param([Parameter(Mandatory)][string]$Source)
    $trimmed = $Source.TrimEnd('\', '/')
    return (Split-Path -Leaf $trimmed)
}

# --- Entry point (defined in Task 6) ----------------------------------------
# function Invoke-Handoff { ... }

# --- Guard: run only when executed, not when dot-sourced --------------------
if ($MyInvocation.InvocationName -ne '.') {
    if (-not $Source) { Write-Error 'cc-handoff.ps1 requires -Source <folder>'; exit 2 }
    Invoke-Handoff -Source $Source
}
```

Note: `Invoke-Handoff` does not exist yet, so the guard block would error **only when executed**. Tests dot-source (guard skipped), so that is fine until Task 6.

- [ ] **Step 3: Write the failing test**

Create `cc-handoff.Tests.ps1`:
```powershell
BeforeAll {
    . $PSScriptRoot/cc-handoff.ps1
}

Describe 'Get-HandoffName' {
    It 'returns the leaf folder name' {
        Get-HandoffName -Source 'C:\work\my-project' | Should -Be 'my-project'
    }
    It 'tolerates a trailing backslash' {
        Get-HandoffName -Source 'C:\work\my-project\' | Should -Be 'my-project'
    }
    It 'tolerates a trailing forward slash' {
        Get-HandoffName -Source 'C:/work/my-project/' | Should -Be 'my-project'
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `Invoke-Pester -Path .\cc-handoff.Tests.ps1 -Output Detailed`
Expected: 3 passing tests under `Get-HandoffName`. (Dot-sourcing loads functions; the guard is skipped because `InvocationName` is `.`.)

- [ ] **Step 5: Stage for ai-commit**

Run: `git add cc-handoff.ps1 cc-handoff.Tests.ps1`
(Do NOT commit — the user commits via ai-commit. Skip if clipsync is not a git repo.)

---

### Task 2: `Get-IncludedFiles` — the git-driven filter

The correctness core: use `git` itself for exact gitignore semantics; fall back to "everything except `.git/`" for non-repos.

**Files:**
- Modify: `cc-handoff.ps1` (add `Get-IncludedFiles`)
- Test: `cc-handoff.Tests.ps1`

**Interfaces:**
- Consumes: nothing from other tasks.
- Produces: `Get-IncludedFiles([string]$Source) -> [string[]]` — repo-relative paths with **forward slashes**, excluding all gitignored files and `.git/`. Returns `@()` when empty. Non-repo → every file recursively except anything under `.git/`.

- [ ] **Step 1: Write the failing tests**

Add to `cc-handoff.Tests.ps1`:
```powershell
Describe 'Get-IncludedFiles' {
    BeforeAll {
        function New-TempDir {
            $d = Join-Path $env:TEMP ("cchandoff_" + [Guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Force -Path $d | Out-Null
            return $d
        }
    }

    It 'includes tracked + untracked-not-ignored, excludes ignored and .git' {
        $repo = New-TempDir
        try {
            Push-Location $repo
            git init -q
            git config user.email t@t.t; git config user.name t
            Set-Content -Path (Join-Path $repo '.gitignore') -Value @('secret.env','build/','*.log') -Encoding ascii
            Set-Content -Path (Join-Path $repo 'app.js')     -Value 'x' -Encoding ascii
            Set-Content -Path (Join-Path $repo 'secret.env') -Value 'K=1' -Encoding ascii
            Set-Content -Path (Join-Path $repo 'debug.log')  -Value 'l' -Encoding ascii
            New-Item -ItemType Directory -Force -Path (Join-Path $repo 'build') | Out-Null
            Set-Content -Path (Join-Path $repo 'build\out.o') -Value 'o' -Encoding ascii
            git add app.js .gitignore | Out-Null
            git commit -qm init | Out-Null
            Set-Content -Path (Join-Path $repo 'new-untracked.js') -Value 'y' -Encoding ascii
            Pop-Location

            $got = Get-IncludedFiles -Source $repo
            $got | Should -Contain 'app.js'
            $got | Should -Contain '.gitignore'
            $got | Should -Contain 'new-untracked.js'
            $got | Should -Not -Contain 'secret.env'
            $got | Should -Not -Contain 'debug.log'
            ($got -join '|') | Should -Not -Match 'build/'
            ($got -join '|') | Should -Not -Match '\.git/'
        } finally { Remove-Item -Recurse -Force $repo -ErrorAction SilentlyContinue }
    }

    It 'falls back to all files except .git for a non-repo' {
        $dir = New-TempDir
        try {
            Set-Content -Path (Join-Path $dir 'a.txt') -Value 'a' -Encoding ascii
            New-Item -ItemType Directory -Force -Path (Join-Path $dir '.git') | Out-Null
            Set-Content -Path (Join-Path $dir '.git\config') -Value 'x' -Encoding ascii
            $got = Get-IncludedFiles -Source $dir
            $got | Should -Contain 'a.txt'
            ($got -join '|') | Should -Not -Match '\.git/'
        } finally { Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue }
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `Invoke-Pester -Path .\cc-handoff.Tests.ps1 -Output Detailed`
Expected: FAIL — `Get-IncludedFiles` is not recognized.

- [ ] **Step 3: Implement `Get-IncludedFiles`**

Add to `cc-handoff.ps1` (after `Get-HandoffName`):
```powershell
function Get-IncludedFiles {
    param([Parameter(Mandatory)][string]$Source)

    $isRepo = $false
    try {
        $inside = (& git -C $Source rev-parse --is-inside-work-tree 2>$null)
        if ($LASTEXITCODE -eq 0 -and $inside -eq 'true') { $isRepo = $true }
    } catch { $isRepo = $false }

    if ($isRepo) {
        $out = & git -C $Source ls-files --cached --others --exclude-standard
        $files = @($out | Where-Object { $_ -ne '' })
        return @($files | Select-Object -Unique)
    }

    # Fallback: every file, recursively, except anything under .git/
    $root = (Resolve-Path -LiteralPath $Source).Path.TrimEnd('\')
    $all = Get-ChildItem -LiteralPath $root -Recurse -File -Force |
        Where-Object { $_.FullName -notmatch '\\\.git(\\|$)' }
    return @($all | ForEach-Object {
        $_.FullName.Substring($root.Length + 1).Replace('\', '/')
    })
}
```

- [ ] **Step 4: Run to verify pass**

Run: `Invoke-Pester -Path .\cc-handoff.Tests.ps1 -Output Detailed`
Expected: all `Get-IncludedFiles` tests pass (plus Task 1 tests still green).

- [ ] **Step 5: Stage for ai-commit**

Run: `git add cc-handoff.ps1 cc-handoff.Tests.ps1`

---

### Task 3: `Copy-IncludeTree` — stage the clean tree

Builds the temp tree that gets `scp`'d up: only the included files, structure preserved.

**Files:**
- Modify: `cc-handoff.ps1`
- Test: `cc-handoff.Tests.ps1`

**Interfaces:**
- Consumes: forward-slash relative paths from `Get-IncludedFiles`.
- Produces: `Copy-IncludeTree([string]$Source,[string[]]$Files,[string]$Dest) -> [void]` — copies each `$Source/<rel>` to `$Dest/<rel>`, creating parent dirs. Does not copy anything not listed.

- [ ] **Step 1: Write the failing test**

Add to `cc-handoff.Tests.ps1`:
```powershell
Describe 'Copy-IncludeTree' {
    It 'copies only the listed files, preserving structure' {
        $src = Join-Path $env:TEMP ("cchsrc_" + [Guid]::NewGuid().ToString('N'))
        $dst = Join-Path $env:TEMP ("cchdst_" + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path (Join-Path $src 'sub') | Out-Null
        Set-Content (Join-Path $src 'keep.txt')     'k' -Encoding ascii
        Set-Content (Join-Path $src 'sub\deep.txt') 'd' -Encoding ascii
        Set-Content (Join-Path $src 'skip.txt')     's' -Encoding ascii
        try {
            Copy-IncludeTree -Source $src -Files @('keep.txt','sub/deep.txt') -Dest $dst
            Test-Path (Join-Path $dst 'keep.txt')     | Should -BeTrue
            Test-Path (Join-Path $dst 'sub\deep.txt') | Should -BeTrue
            Test-Path (Join-Path $dst 'skip.txt')     | Should -BeFalse
        } finally {
            Remove-Item -Recurse -Force $src,$dst -ErrorAction SilentlyContinue
        }
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `Invoke-Pester -Path .\cc-handoff.Tests.ps1 -Output Detailed`
Expected: FAIL — `Copy-IncludeTree` not recognized.

- [ ] **Step 3: Implement `Copy-IncludeTree`**

Add to `cc-handoff.ps1`:
```powershell
function Copy-IncludeTree {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Files,
        [Parameter(Mandatory)][string]$Dest
    )
    New-Item -ItemType Directory -Force -Path $Dest | Out-Null
    foreach ($rel in $Files) {
        if (-not $rel) { continue }
        $from = Join-Path $Source $rel
        $to   = Join-Path $Dest   $rel
        $toDir = Split-Path -Parent $to
        if ($toDir -and -not (Test-Path -LiteralPath $toDir)) {
            New-Item -ItemType Directory -Force -Path $toDir | Out-Null
        }
        Copy-Item -LiteralPath $from -Destination $to -Force
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `Invoke-Pester -Path .\cc-handoff.Tests.ps1 -Output Detailed`
Expected: `Copy-IncludeTree` test passes; earlier tests still green.

- [ ] **Step 5: Stage for ai-commit**

Run: `git add cc-handoff.ps1 cc-handoff.Tests.ps1`

---

### Task 4: Sync-back local mechanics — `Copy-Changes` + `Remove-DeletedFromManifest` + `Get-TreeRelPaths`

The deletion-safe reconciliation: copy changes/additions with `/E` (no purge), delete only manifest paths Claude removed. This is where the `/MIR` data-loss bug is designed out.

**Files:**
- Modify: `cc-handoff.ps1`
- Test: `cc-handoff.Tests.ps1`

**Interfaces:**
- Consumes: the push manifest (`Get-IncludedFiles` output) held across the pause.
- Produces:
  - `Copy-Changes([string]$From,[string]$To) -> [int]` — deterministic per-file overwrite of every file in `$From` onto `$To` (copy-only, never deletes); returns the count copied. **Not** `robocopy /E` — its timestamp/size change-detection can silently skip a same-size content edit.
  - `Remove-DeletedFromManifest([string]$Source,[string]$PulledRoot,[string[]]$Manifest) -> [string[]]` — for each manifest rel now absent under `$PulledRoot`, delete it from `$Source`; returns the removed rels.
  - `Get-TreeRelPaths([string]$Root) -> [string[]]` — every file under `$Root` as forward-slash relative paths; used to refresh the managed manifest after each sync-back round.

- [ ] **Step 1: Write the failing tests**

Add to `cc-handoff.Tests.ps1`:
```powershell
Describe 'Copy-Changes' {
    It 'copies new and changed files without deleting extras in dest' {
        $from = Join-Path $env:TEMP ("cchf_" + [Guid]::NewGuid().ToString('N'))
        $to   = Join-Path $env:TEMP ("ccht_" + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $from,$to | Out-Null
        Set-Content (Join-Path $from 'a.txt') 'new'  -Encoding ascii   # changed
        Set-Content (Join-Path $from 'b.txt') 'b'    -Encoding ascii   # added
        Set-Content (Join-Path $to   'a.txt') 'old'  -Encoding ascii
        Set-Content (Join-Path $to   '.env')  'K=1'  -Encoding ascii   # extra in dest, must survive
        try {
            $code = Copy-Changes -From $from -To $to
            $code | Should -Be 2   # both source files copied deterministically
            (Get-Content (Join-Path $to 'a.txt')) | Should -Be 'new'
            Test-Path (Join-Path $to 'b.txt') | Should -BeTrue
            Test-Path (Join-Path $to '.env')  | Should -BeTrue   # NOT purged
        } finally { Remove-Item -Recurse -Force $from,$to -ErrorAction SilentlyContinue }
    }
}

Describe 'Get-TreeRelPaths' {
    It 'returns every file as forward-slash relative paths' {
        $root = Join-Path $env:TEMP ("cchtree_" + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path (Join-Path $root 'sub') | Out-Null
        Set-Content (Join-Path $root 'a.txt')     'a' -Encoding ascii
        Set-Content (Join-Path $root 'sub\b.txt') 'b' -Encoding ascii
        try {
            $got = Get-TreeRelPaths -Root $root
            $got | Should -Contain 'a.txt'
            $got | Should -Contain 'sub/b.txt'
            $got.Count | Should -Be 2
        } finally { Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue }
    }
}

Describe 'Remove-DeletedFromManifest' {
    It 'deletes only manifest files missing from the pulled tree' {
        $src    = Join-Path $env:TEMP ("cchs_" + [Guid]::NewGuid().ToString('N'))
        $pulled = Join-Path $env:TEMP ("cchp_" + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $src,$pulled | Out-Null
        # Source has a tracked file, a deleted-by-Claude file, plus untracked .git/.env
        Set-Content (Join-Path $src 'keep.txt')  'k' -Encoding ascii
        Set-Content (Join-Path $src 'gone.txt')  'g' -Encoding ascii
        Set-Content (Join-Path $src '.env')      'K' -Encoding ascii
        New-Item -ItemType Directory -Force -Path (Join-Path $src '.git') | Out-Null
        Set-Content (Join-Path $src '.git\cfg')  'c' -Encoding ascii
        # Pulled tree still has keep.txt but NOT gone.txt
        Set-Content (Join-Path $pulled 'keep.txt') 'k' -Encoding ascii
        try {
            $removed = Remove-DeletedFromManifest -Source $src -PulledRoot $pulled -Manifest @('keep.txt','gone.txt')
            $removed | Should -Contain 'gone.txt'
            Test-Path (Join-Path $src 'gone.txt') | Should -BeFalse   # propagated deletion
            Test-Path (Join-Path $src 'keep.txt') | Should -BeTrue    # still present
            Test-Path (Join-Path $src '.env')     | Should -BeTrue    # NOT in manifest -> untouched
            Test-Path (Join-Path $src '.git\cfg') | Should -BeTrue    # NOT in manifest -> untouched
        } finally { Remove-Item -Recurse -Force $src,$pulled -ErrorAction SilentlyContinue }
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `Invoke-Pester -Path .\cc-handoff.Tests.ps1 -Output Detailed`
Expected: FAIL — `Copy-Changes` / `Remove-DeletedFromManifest` not recognized.

- [ ] **Step 3: Implement the three functions**

Add to `cc-handoff.ps1`:
```powershell
function Copy-Changes {
    param([Parameter(Mandatory)][string]$From,[Parameter(Mandatory)][string]$To)
    # Deterministic, content-authoritative overwrite of every file in $From onto
    # $To. We deliberately do NOT use robocopy /E: its default change-detection
    # skips a content change that keeps the same file size unless the source is
    # newer, silently dropping edits. This copy NEVER deletes anything in $To
    # (deletions are handled by Remove-DeletedFromManifest), so files present
    # only in the original (.git, secrets, build dirs) stay safe.
    $rels = @(Get-TreeRelPaths -Root $From)
    Copy-IncludeTree -Source $From -Files $rels -Dest $To
    # The file-list copy skips EMPTY directories (Get-TreeRelPaths is files-only),
    # so a new folder Claude created with no files would never sync. Replicate the
    # full directory structure, including empty dirs.
    $base = (Resolve-Path -LiteralPath $From).Path.TrimEnd('\')
    foreach ($d in (Get-ChildItem -LiteralPath $base -Recurse -Directory -Force)) {
        $target = Join-Path $To ($d.FullName.Substring($base.Length + 1))
        if (-not (Test-Path -LiteralPath $target)) {
            New-Item -ItemType Directory -Force -Path $target | Out-Null
        }
    }
    return $rels.Count
}

function Remove-DeletedFromManifest {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$PulledRoot,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Manifest
    )
    $removed = @()
    foreach ($rel in $Manifest) {
        if (-not $rel) { continue }
        $inPulled = Join-Path $PulledRoot $rel
        if (-not (Test-Path -LiteralPath $inPulled)) {
            $inSource = Join-Path $Source $rel
            if (Test-Path -LiteralPath $inSource) {
                Remove-Item -LiteralPath $inSource -Force -Recurse -ErrorAction SilentlyContinue
                $removed += $rel
            }
        }
    }
    return @($removed)
}

function Get-TreeRelPaths {
    param([Parameter(Mandatory)][string]$Root)
    if (-not (Test-Path -LiteralPath $Root)) { return @() }
    $base = (Resolve-Path -LiteralPath $Root).Path.TrimEnd('\')
    return @(Get-ChildItem -LiteralPath $base -Recurse -File -Force |
        ForEach-Object { $_.FullName.Substring($base.Length + 1).Replace('\', '/') })
}
```

- [ ] **Step 4: Run to verify pass**

Run: `Invoke-Pester -Path .\cc-handoff.Tests.ps1 -Output Detailed`
Expected: both new describes pass; earlier tests still green.

- [ ] **Step 5: Stage for ai-commit**

Run: `git add cc-handoff.ps1 cc-handoff.Tests.ps1`

---

### Task 5: `Remove-IgnoredFiles` — drop Claude's newly-created ignored files

Before copying the pulled tree back, discard anything Claude created on the home box that the repo's rules ignore (e.g. a `bin/` from a build), using `git check-ignore` on the laptop's authoritative repo.

**Files:**
- Modify: `cc-handoff.ps1`
- Test: `cc-handoff.Tests.ps1`

**Interfaces:**
- Consumes: the original repo path (holds `.git`) + the pulled tree root.
- Produces: `Remove-IgnoredFiles([string]$Repo,[string]$Root) -> [string[]]` — deletes files under `$Root` whose repo-relative path is ignored by `$Repo`'s rules; returns removed rels. No-op when `$Repo` is not a git repo.

- [ ] **Step 1: Write the failing test**

Add to `cc-handoff.Tests.ps1`:
```powershell
Describe 'Remove-IgnoredFiles' {
    It 'removes files ignored by the repo rules, keeps the rest' {
        $repo = Join-Path $env:TEMP ("cchr_" + [Guid]::NewGuid().ToString('N'))
        $root = Join-Path $env:TEMP ("cchpull_" + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $repo,$root | Out-Null
        Push-Location $repo
        git init -q; git config user.email t@t.t; git config user.name t
        Set-Content (Join-Path $repo '.gitignore') @('*.log','dist/') -Encoding ascii
        Pop-Location
        # Pulled tree: a good file + a newly-created ignored file + ignored dir
        Set-Content (Join-Path $root 'app.js')  'x' -Encoding ascii
        Set-Content (Join-Path $root 'run.log') 'l' -Encoding ascii
        New-Item -ItemType Directory -Force -Path (Join-Path $root 'dist') | Out-Null
        Set-Content (Join-Path $root 'dist\bundle.js') 'b' -Encoding ascii
        try {
            $removed = Remove-IgnoredFiles -Repo $repo -Root $root
            Test-Path (Join-Path $root 'app.js')         | Should -BeTrue
            Test-Path (Join-Path $root 'run.log')        | Should -BeFalse
            Test-Path (Join-Path $root 'dist\bundle.js') | Should -BeFalse
            ($removed -join '|') | Should -Match 'run.log'
        } finally { Remove-Item -Recurse -Force $repo,$root -ErrorAction SilentlyContinue }
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `Invoke-Pester -Path .\cc-handoff.Tests.ps1 -Output Detailed`
Expected: FAIL — `Remove-IgnoredFiles` not recognized.

- [ ] **Step 3: Implement `Remove-IgnoredFiles`**

Add to `cc-handoff.ps1`:
```powershell
function Remove-IgnoredFiles {
    param([Parameter(Mandatory)][string]$Repo,[Parameter(Mandatory)][string]$Root)

    $inside = (& git -C $Repo rev-parse --is-inside-work-tree 2>$null)
    if ($LASTEXITCODE -ne 0 -or $inside -ne 'true') { return @() }

    $root = (Resolve-Path -LiteralPath $Root).Path.TrimEnd('\')
    $rels = @(Get-TreeRelPaths -Root $root)
    if ($rels.Count -eq 0) { return @() }

    # Pass paths as ARGS (chunked to stay under the command-line length limit).
    # We deliberately avoid `check-ignore --stdin`: PowerShell's pipeline appends
    # a CR to each line, so `run.log` becomes `run.log\r` and stops matching
    # patterns like `*.log`. The args form is clean.
    $ignored = New-Object System.Collections.Generic.List[string]
    $batch = 200
    for ($i = 0; $i -lt $rels.Count; $i += $batch) {
        $end = [Math]::Min($i + $batch - 1, $rels.Count - 1)
        $chunk = $rels[$i..$end]
        $res = & git -C $Repo check-ignore -- $chunk 2>$null
        foreach ($r in $res) {
            if ($r) { $ignored.Add(($r -replace "`r$", '')) }
        }
    }

    $removed = @()
    foreach ($rel in $ignored) {
        if (-not $rel) { continue }
        $p = Join-Path $root $rel
        if (Test-Path -LiteralPath $p) {
            Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
            $removed += $rel
        }
    }
    return @($removed)
}
```

- [ ] **Step 4: Run to verify pass**

Run: `Invoke-Pester -Path .\cc-handoff.Tests.ps1 -Output Detailed`
Expected: all describes pass (Task 1-5).

- [ ] **Step 5: Stage for ai-commit**

Run: `git add cc-handoff.ps1 cc-handoff.Tests.ps1`

---

### Task 6: Transport + orchestration (`Invoke-Handoff`) — integration

Wires the remaining ssh/scp/bridge functions and the push → pause → sync-back/cancel flow. Not unit-tested (needs the live home box + bridge); verified by a documented manual smoke test from the laptop.

**Files:**
- Modify: `cc-handoff.ps1`

**Interfaces:**
- Consumes: `Get-HandoffName`, `Get-IncludedFiles`, `Copy-IncludeTree`, `Copy-Changes`, `Remove-DeletedFromManifest`, `Remove-IgnoredFiles`, `Get-TreeRelPaths`.
- Produces: `Invoke-RemotePwsh`, `New-RemoteDir`, `Send-Tree`, `Set-LocalClipboardText`, `Receive-Tree`, `Invoke-Handoff` (entry point called by the guard).

- [ ] **Step 1: Implement the transport helpers**

Add to `cc-handoff.ps1` (before the `Invoke-Handoff` placeholder comment):
```powershell
function Invoke-RemotePwsh {
    param([Parameter(Mandatory)][string]$Script)
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Script))
    $out = & ssh $script:SshHost powershell -NoProfile -EncodedCommand $enc
    if ($LASTEXITCODE -ne 0) { throw "remote pwsh failed (exit $LASTEXITCODE)" }
    return ($out -join "`n")
}

function New-RemoteDir {
    param([Parameter(Mandatory)][string]$RemotePath)   # forward-slash LOCAL path
    Invoke-RemotePwsh "New-Item -ItemType Directory -Force -Path '$RemotePath' | Out-Null" | Out-Null
}

function Send-Tree {
    param(
        [Parameter(Mandatory)][string]$LocalTree,       # e.g. C:\Temp\xyz\name  (contains files)
        [Parameter(Mandatory)][string]$RemoteParent     # forward-slash: .../incoming/<ts>
    )
    # scp -r the whole tree; it lands as <RemoteParent>/<leaf-of-LocalTree>.
    & scp -r -q -- "$LocalTree" ("{0}:{1}" -f $script:SshHost, $RemoteParent)
    if ($LASTEXITCODE -ne 0) { throw "scp push failed (exit $LASTEXITCODE)" }
}

function Set-LocalClipboardText {
    param([Parameter(Mandatory)][string]$Text)
    # Mirrors clipsync ScpThenPost: scp a body file up, curl.exe --data-binary '@file'.
    $localTemp = (Invoke-RemotePwsh '$env:TEMP').Trim()
    if (-not $localTemp) { return $false }
    $remoteBody = ($localTemp.Replace('\','/')) + ('/cc_body_{0}.bin' -f ([DateTime]::Now.Ticks))
    $body = Join-Path $env:TEMP ("cc_body_{0}.txt" -f ([DateTime]::Now.Ticks))
    [IO.File]::WriteAllText($body, $Text, (New-Object Text.UTF8Encoding($false)))
    try {
        & scp -q -- "$body" ("{0}:{1}" -f $script:SshHost, $remoteBody)
        if ($LASTEXITCODE -ne 0) { return $false }
        # Single-quote '@path' and the header (contains ';') so remote PowerShell keeps them literal.
        $resp = & ssh $script:SshHost curl.exe -s -m 15 -X POST `
            --data-binary "'@$remoteBody'" `
            -H "'Content-Type:text/plain;charset=utf-8'" `
            ("{0}/text" -f $script:BridgeUrl)
        Invoke-RemotePwsh "Remove-Item -LiteralPath '$remoteBody' -Force -ErrorAction SilentlyContinue" | Out-Null
        return (("" + $resp).Trim() -eq 'ok')
    } finally {
        Remove-Item -LiteralPath $body -Force -ErrorAction SilentlyContinue
    }
}

function Receive-Tree {
    param(
        [Parameter(Mandatory)][string]$RemotePath,      # forward-slash: .../incoming/<ts>/<name>
        [Parameter(Mandatory)][string]$LocalParent      # local dir to receive into
    )
    New-Item -ItemType Directory -Force -Path $LocalParent | Out-Null
    & scp -r -q -- ("{0}:{1}" -f $script:SshHost, $RemotePath) "$LocalParent"
    if ($LASTEXITCODE -ne 0) { throw "scp pull failed (exit $LASTEXITCODE)" }
}
```

- [ ] **Step 2: Implement `Invoke-Handoff` (replace the placeholder comment)**

```powershell
function Invoke-Handoff {
    param([Parameter(Mandatory)][string]$Source)

    if (-not (Test-Path -LiteralPath $Source -PathType Container)) {
        Write-Host "cc-handoff: not a folder: $Source" -ForegroundColor Red; return
    }
    $Source = (Resolve-Path -LiteralPath $Source).Path.TrimEnd('\')
    $name   = Get-HandoffName -Source $Source
    $ts     = Get-Date -Format 'yyyyMMdd-HHmmss'
    $remoteParent = "{0}/incoming/{1}" -f $script:Share, $ts
    $remotePath   = "{0}/{1}" -f $remoteParent, $name

    Write-Host "cc-handoff: filtering '$name' with git..." -ForegroundColor Cyan
    $include = @(Get-IncludedFiles -Source $Source)
    Write-Host ("  {0} file(s) in scope" -f $include.Count)

    $stageBase = Join-Path $env:TEMP ("cchstage_" + [Guid]::NewGuid().ToString('N'))
    $stageTree = Join-Path $stageBase $name
    try {
        Copy-IncludeTree -Source $Source -Files $include -Dest $stageTree
        Write-Host "cc-handoff: pushing to $remotePath ..." -ForegroundColor Cyan
        New-RemoteDir  -RemotePath $remoteParent
        Send-Tree      -LocalTree $stageTree -RemoteParent $remoteParent
    } catch {
        Write-Host "cc-handoff: push failed: $($_.Exception.Message)" -ForegroundColor Red
        Remove-Item -Recurse -Force $stageBase -ErrorAction SilentlyContinue
        return   # stop BEFORE the menu; no half state
    } finally {
        Remove-Item -Recurse -Force $stageBase -ErrorAction SilentlyContinue
    }

    $winPath = $remotePath.Replace('/', '\')
    if (Set-LocalClipboardText -Text $winPath) {
        Write-Host "cc-handoff: home box clipboard set. Paste into Claude Code:" -ForegroundColor Green
    } else {
        Write-Host "cc-handoff: could NOT set the home box clipboard. Paste this manually:" -ForegroundColor Yellow
    }
    Write-Host "  $winPath"

    # The manifest is the "managed set": starts as the push list, refreshed after
    # each sync so deletions of files added in later rounds also propagate.
    $manifest = $include

    while ($true) {
        Write-Host ""
        Write-Host "  [1] Sync updates back to  $Source   (repeatable)"
        Write-Host "  [2] Done (leave the copy in the share; pruned in 7 days)"
        $choice = (Read-Host "Choose 1 or 2").Trim()
        if ($choice -eq '2') { Write-Host "cc-handoff: done." -ForegroundColor Yellow; break }
        if ($choice -ne '1') {
            Write-Host "  Enter 1 (sync) or 2 (done) - Enter alone won't do anything." -ForegroundColor Yellow
            continue
        }

        $pullBase = Join-Path $env:TEMP ("cchpull_" + [Guid]::NewGuid().ToString('N'))
        try {
            Write-Host "cc-handoff: pulling changes..." -ForegroundColor Cyan
            Receive-Tree -RemotePath $remotePath -LocalParent $pullBase
            $pulledTree = Join-Path $pullBase $name
            $dropped = @(Remove-IgnoredFiles -Repo $Source -Root $pulledTree)
            if ($dropped.Count) { Write-Host ("  dropped {0} newly-ignored file(s)" -f $dropped.Count) }
            [void](Copy-Changes -From $pulledTree -To $Source)
            $deleted = @(Remove-DeletedFromManifest -Source $Source -PulledRoot $pulledTree -Manifest $manifest)
            $manifest = @(Get-TreeRelPaths -Root $pulledTree)   # refresh the managed set
            Write-Host ("cc-handoff: synced back. {0} deletion(s) propagated; {1} file(s) now managed." -f $deleted.Count, $manifest.Count) -ForegroundColor Green
        } catch {
            Write-Host "cc-handoff: sync-back failed: $($_.Exception.Message)" -ForegroundColor Red
        } finally {
            Remove-Item -Recurse -Force $pullBase -ErrorAction SilentlyContinue
        }
        # loop back to the menu for another round
    }
}
```

- [ ] **Step 3: Sanity-check the script still loads and unit tests stay green**

Run: `Invoke-Pester -Path .\cc-handoff.Tests.ps1 -Output Detailed`
Expected: all Task 1-5 tests still pass (dot-source loads the new functions without error).

- [ ] **Step 4: Manual smoke test — end to end (needs the live home box + bridge)**

Prereqs: clipsync installed and working on this laptop (`ssh clipsync-local curl.exe -s http://127.0.0.1:8765/ping` returns `pong`); `git` on PATH.

1. Pick a small git repo folder `C:\work\demo` on the laptop with a `.gitignore` that ignores a `.env` and a `build/` dir; create those ignored files.
2. Run: `powershell -NoProfile -ExecutionPolicy Bypass -File .\cc-handoff.ps1 -Source "C:\work\demo"`
3. Expected console: "N file(s) in scope" (excludes `.env`, `build/`, `.git`), "pushing to C:/clipsync-share/incoming/<ts>/demo", "home box clipboard set", the pasteable path, then the `[1]/[2]` menu.
4. On the home box: confirm `C:\clipsync-share\incoming\<ts>\demo` exists and contains the tracked files but **no** `.env`, `build/`, or `.git`. Paste (Ctrl+V) somewhere — you get the path text.
5. On the home box: edit a tracked file, create a new tracked-style file `added.txt`, create an ignored `out.log`, and delete one tracked file.
6. Back on the laptop, choose `1`. Expected: "dropped 1 newly-ignored file" (the `out.log`), "synced back. 1 deletion(s) propagated; N file(s) now managed", **then the menu reappears** (does not exit).
7. Verify on the laptop `C:\work\demo`: the edit is present, `added.txt` present, the deleted file is gone, `out.log` is **absent**, and crucially `.env`, `build/`, and `.git/` are **still intact**.
8. **Round 2 (proves the loop + manifest refresh):** on the home box, edit `added.txt`, create another new file `added2.txt`, then delete `added.txt`. Back on the laptop, choose `1` again. Expected: "synced back. 1 deletion(s) propagated" — verify on the laptop that `added2.txt` appeared and `added.txt` is gone (deletion of a file that was created *after* the original push still propagates, because the manifest refreshed in round 1).
9. Choose `2`: prints "done", the console exits, and the copy remains in the share.

Record PASS/FAIL for each numbered expectation before moving on.

- [ ] **Step 5: Stage for ai-commit**

Run: `git add cc-handoff.ps1`

---

### Task 7: F7 hotkey in `clipsync.ahk`

Add the hotkey that resolves the Explorer selection and launches the console. Edit the **ClaudeCode source** copy only.

**Files:**
- Modify: `clipsync.ahk` (config block near line 44; hotkeys near line 84)

**Interfaces:**
- Consumes: `cc-handoff.ps1` at `%LOCALAPPDATA%\clipsync\cc-handoff.ps1`.
- Produces: an `F7::` hotkey and `GetCcHandoffSelection()`; reuses existing `Tip`, `Log`, `EnvGet`.

- [ ] **Step 1: Add the config path**

In `clipsync.ahk`, right after the `SCRIPT_PATH := ...` line (~line 45), add:
```autohotkey
CC_HANDOFF_PS1 := EnvGet("LOCALAPPDATA") "\clipsync\cc-handoff.ps1"
```

- [ ] **Step 2: Add the hotkey + selection resolver**

After the existing hotkey lines (`^!#v::PullFromLocal()` / `^!#c::PushToLocal()`, ~line 84), add:
```autohotkey
F7::CcHandoff()

CcHandoff() {
    global CC_HANDOFF_PS1
    path := GetCcHandoffSelection()
    if (path = "") {
        Tip("cc-handoff: select a folder in Explorer first.", true)
        return
    }
    if (!DirExist(path)) {
        Tip("cc-handoff: selection is not a folder.", true)
        return
    }
    if (!FileExist(CC_HANDOFF_PS1)) {
        Tip("cc-handoff: script missing at " CC_HANDOFF_PS1, true)
        return
    }
    Log("cc-handoff F7 -> " path)
    Run('powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' CC_HANDOFF_PS1 '" -Source "' path '"')
}

; Return the filesystem path of the first selected item in the active Explorer
; window, or "" if the foreground window is not an Explorer window / nothing
; is selected.
GetCcHandoffSelection() {
    hwnd := WinActive("A")
    if (!hwnd)
        return ""
    for win in ComObject("Shell.Application").Windows {
        try {
            if (win.HWND = hwnd) {
                sel := win.Document.SelectedItems
                if (sel.Count >= 1)
                    return sel.Item(0).Path
                return ""
            }
        }
    }
    return ""
}
```

- [ ] **Step 3: Verify the script parses**

Run: `& "$env:LOCALAPPDATA\AHK\AutoHotkey64.exe" /validate ".\clipsync.ahk"; $LASTEXITCODE`
Expected: exit `0` (no syntax errors). If AHK is not on this machine, load it on the laptop instead and confirm no error dialog on launch.

- [ ] **Step 4: Manual smoke test (on the laptop, after deploy in Task 8)**

1. Reload clipsync (`restart-ahk.bat` or re-launch). Confirm the tray icon is present and existing Ctrl+Alt+Win+V/C still work.
2. Open Explorer, select a folder, press **F7** → a PowerShell console appears running the handoff (same flow verified in Task 6 Step 4).
3. Select nothing (or a file) and press F7 → a tray tip says to select a folder / not a folder; no console launches.

Record PASS/FAIL.

- [ ] **Step 5: Stage for ai-commit**

Run: `git add clipsync.ahk`
(Announce to the user if you create a branch — they rely on ai-commit.)

---

### Task 8: Deploy hook + docs

Make `install.ps1` place `cc-handoff.ps1` next to `clipsync.ahk`, and document the feature.

**Files:**
- Modify: `install.ps1` (~lines 39-40 and section 2, ~lines 78-83)
- Modify: `CLAUDE.md`
- Modify: `README.md`

**Interfaces:**
- Consumes: `cc-handoff.ps1` in the source dir (deployed to `Programs\clipsync` by `deploy.cmd` automatically).
- Produces: nothing consumed by other tasks (final task).

- [ ] **Step 1: Add the path var in `install.ps1`**

After the `$clipsyncAhk = Join-Path $clipsyncDir 'clipsync.ahk'` line (~line 40), add:
```powershell
$ccHandoffSrc = Join-Path $scriptDir 'cc-handoff.ps1'
$ccHandoffDst = Join-Path $clipsyncDir 'cc-handoff.ps1'
```

- [ ] **Step 2: Copy it in section 2**

In section 2, right after `Copy-Item -Force $ahkSource $clipsyncAhk` (~line 82), add:
```powershell
if (Test-Path $ccHandoffSrc) {
    Copy-Item -Force $ccHandoffSrc $ccHandoffDst
    Info "Installed cc-handoff at $ccHandoffDst"
} else {
    Warn "cc-handoff.ps1 not found next to install.ps1 - F7 handoff will be unavailable."
}
```

- [ ] **Step 3: Verify install.ps1 still parses**

Run: `powershell -NoProfile -Command "[void][ScriptBlock]::Create((Get-Content -Raw .\install.ps1)); 'parsed ok'"`
Expected: prints `parsed ok`.

- [ ] **Step 4: Document in `CLAUDE.md`**

Add a `## cc-handoff (F7)` section summarizing: F7 copies the selected folder's git working set to LOCAL via clipsync's transport; git (`ls-files`/`check-ignore`) is the exact filter; secrets/`.git`/build junk never transfer; clipboard gets the staged path via `POST /text`; console shows a **repeating** menu — `[1]` scoped, deletion-safe sync-back (repeatable, with a self-refreshing manifest) / `[2]` done; **never `/MIR` into the source**. Point to `docs/superpowers/specs/2026-07-08-cc-handoff-design.md`.

- [ ] **Step 5: Document in `README.md`**

Add a short "F7 folder handoff" subsection: select a folder in Explorer, press F7, paste the path from the clipboard into Claude Code on the home box, then choose `[1]` to sync edits back — as many times as you like while you keep developing — and `[2]` when you're done.

- [ ] **Step 6: Full deployment dry-run (manual, user-run)**

Tell the user to run `deploy.cmd` (copies source → `Programs\clipsync`, `.git` excluded) then, on the laptop, `install.ps1`. Confirm `%LOCALAPPDATA%\clipsync\cc-handoff.ps1` exists afterward. (Never auto-run these.)

- [ ] **Step 7: Stage for ai-commit**

Run: `git add install.ps1 CLAUDE.md README.md`

---

## Self-Review

**Spec coverage:**
- F7 → resolve Explorer selection → launch console: Task 7. ✓
- git-driven exact filter (`ls-files`), non-repo fallback: Task 2. ✓
- Stage clean tree + scp push to `incoming/<ts>/<name>`: Tasks 3, 6. ✓
- Set home box clipboard to path via bridge `POST /text`: Task 6 (`Set-LocalClipboardText`). ✓
- Menu + pause `[1]`/`[2]`: Task 6 (`Invoke-Handoff`). ✓
- Sync-back: pull → `check-ignore` drop → copy `/E` → scoped manifest deletion: Tasks 5, 4, 6. ✓
- Never `/MIR`/`/PURGE` into source (safety): Task 4 (`Copy-Changes` + test asserting `.env` survives) + Global Constraints. ✓
- Cancel path: Task 6. ✓
- Push failure stops before menu; bridge-unreachable prints path: Task 6. ✓
- Deploy via install.ps1 / deploy.cmd, user-run: Task 8. ✓
- Edit ClaudeCode source not Programs; stage-only: Global Constraints + every task's final step. ✓

**Placeholder scan:** No TBD/TODO; every code step shows complete code; manual-test steps enumerate exact expectations. ✓

**Type consistency:** `Get-IncludedFiles` returns forward-slash rels consumed identically by `Copy-IncludeTree`, `Remove-DeletedFromManifest` (as `$Manifest`), and manual `$include`. `Copy-Changes`/`Remove-DeletedFromManifest`/`Remove-IgnoredFiles` names match between definition (Tasks 4/5) and use (Task 6). Config `$script:SshHost/$script:Share/$script:BridgeUrl` defined in Task 1, used in Task 6. ✓
