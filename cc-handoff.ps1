<#
    cc-handoff.ps1 - clipsync extension. Copies the git working set of a folder
    to LOCAL (home box) through clipsync's transport, sets LOCAL's clipboard to
    the staged path, then offers a REPEATING [1] sync-back / [2] done menu.

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

# --- Transport (ssh / scp / bridge) -----------------------------------------
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

# --- Entry point ------------------------------------------------------------
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

# --- Guard: run only when executed, not when dot-sourced --------------------
if ($MyInvocation.InvocationName -ne '.') {
    if (-not $Source) { Write-Error 'cc-handoff.ps1 requires -Source <folder>'; exit 2 }
    Invoke-Handoff -Source $Source
}
