#Requires AutoHotkey v2.0
#SingleInstance Force

; ----------------------------------------------------------------------------
; clipsync.ahk - Two-way clipboard + file sync between REMOTE (this machine)
; and LOCAL over outbound SSH. Runs on REMOTE only.
;
;   Ctrl+Alt+Win+V  ->  pull LOCAL's clipboard onto REMOTE
;   Ctrl+Alt+Win+C  ->  push REMOTE's clipboard onto LOCAL
;
; Handles text and Explorer file/folder selections (CF_HDROP).
; Text is shipped via a UTF-8 temp file over scp (no encoding/quoting drama).
; ----------------------------------------------------------------------------

; --- Configuration ----------------------------------------------------------
SSH_HOST     := "clipsync-local"                              ; ssh config alias
STAGING_BASE := EnvGet("LOCALAPPDATA") "\clipsync\incoming"   ; on REMOTE
LOG_PATH     := EnvGet("LOCALAPPDATA") "\clipsync\clipsync.log"
PRUNE_DAYS   := 7
TRAY_MS      := 2500

; PowerShell prefix that pins UTF-8 in/out so Unicode survives the SSH pipe.
PS_UTF8 := "[Console]::OutputEncoding=[Text.Encoding]::UTF8;[Console]::InputEncoding=[Text.Encoding]::UTF8;"

DirCreate(STAGING_BASE)
PruneOldStaging()

; --- Hotkeys ----------------------------------------------------------------
^!#v::PullFromLocal()
^!#c::PushToLocal()

; ============================================================================
;  Direction 1: LOCAL -> REMOTE
; ============================================================================
PullFromLocal() {
    Tip("Checking LOCAL clipboard...")
    kind := RemoteClipboardKind()
    if (kind = "empty") {
        Tip("LOCAL clipboard is empty.", true)
        return
    }
    if (kind = "text")
        PullText()
    else if (kind = "files")
        PullFiles()
    else
        Tip("Could not read LOCAL clipboard: " kind, true)
}

PullText() {
    ps := PS_UTF8 "Get-Clipboard -Raw"
    res := SshPs(ps)
    if (res.exitCode != 0) {
        Tip("SSH failed: " Trim(res.stderr), true)
        return
    }
    text := res.stdout
    ; SSH/PS often appends a CRLF. Trim a single trailing newline.
    if (SubStr(text, -1) = "`n")
        text := SubStr(text, 1, -1)
    if (SubStr(text, -1) = "`r")
        text := SubStr(text, 1, -1)
    A_Clipboard := text
    Tip("Pulled " StrLen(text) " chars from LOCAL.")
}

PullFiles() {
    ps := PS_UTF8 "(Get-Clipboard -Format FileDropList).FullName"
    res := SshPs(ps)
    if (res.exitCode != 0) {
        Tip("SSH failed: " Trim(res.stderr), true)
        return
    }
    paths := SplitLines(res.stdout)
    if (paths.Length = 0) {
        Tip("LOCAL had no file paths.", true)
        return
    }

    stage := MakeStagingDir()
    ok := 0, fail := 0
    Tip("Copying " paths.Length " item(s) from LOCAL...")
    for path in paths {
        cmd := 'scp -r -q ' SSH_HOST ':"' path '" "' stage '"'
        scp := Run2(cmd)
        if (scp.exitCode = 0)
            ok++
        else {
            fail++
            OutputDebug("scp pull failed for " path ": " scp.stderr "`n")
        }
    }
    if (ok = 0) {
        Tip("All scp pulls failed.", true)
        return
    }

    staged := []
    for f in DirItems(stage)
        staged.Push(f)
    SetClipboardFiles(staged)
    Tip("Pulled " ok " item(s) from LOCAL" (fail ? " (" fail " failed)" : "") ".")
}

; ============================================================================
;  Direction 2: REMOTE -> LOCAL
; ============================================================================
PushToLocal() {
    kind := LocalClipboardKind()
    if (kind = "empty") {
        Tip("REMOTE clipboard is empty.", true)
        return
    }
    if (kind = "text")
        PushText()
    else if (kind = "files")
        PushFiles()
    else
        Tip("Unknown REMOTE clipboard format.", true)
}

PushText() {
    text := A_Clipboard

    ; Resolve LOCAL %TEMP% so we have an absolute path to scp into.
    res := SshPs(PS_UTF8 "$env:TEMP")
    if (res.exitCode != 0) {
        Tip("SSH failed: " Trim(res.stderr), true)
        return
    }
    localTemp := Trim(res.stdout, "`r`n `t")
    if (localTemp = "") {
        Tip("LOCAL %TEMP% was empty.", true)
        return
    }
    target := localTemp "\clipsync_text_" A_TickCount ".txt"

    ; Write clipboard to a UTF-8 temp file and scp it up
    tmp := A_Temp "\clipsync_text_" A_TickCount ".txt"
    FileAppend(text, tmp, "UTF-8-RAW")  ; no BOM; raw bytes
    scp := Run2('scp -q "' tmp '" ' SSH_HOST ':"' target '"')
    try FileDelete(tmp)
    if (scp.exitCode != 0) {
        Tip("scp push failed: " Trim(scp.stderr), true)
        return
    }

    ; On LOCAL: read the file as UTF-8, set clipboard, delete the file
    ps := PS_UTF8 . "Set-Clipboard ([IO.File]::ReadAllText('" target "',[Text.Encoding]::UTF8));Remove-Item -LiteralPath '" target "' -Force"
    res2 := SshPs(ps)
    if (res2.exitCode != 0) {
        Tip("Set-Clipboard failed: " Trim(res2.stderr), true)
        return
    }
    Tip("Pushed " StrLen(text) " chars to LOCAL.")
}

PushFiles() {
    paths := GetClipboardFiles()
    if (paths.Length = 0) {
        Tip("No files on REMOTE clipboard.", true)
        return
    }

    ; Make a timestamped staging dir on LOCAL and get its absolute path back
    ts := FormatTime(, "yyyyMMdd-HHmmss")
    mkdirPs := PS_UTF8 . "$d=Join-Path $env:LOCALAPPDATA 'clipsync\incoming\" ts "';(New-Item -ItemType Directory -Force -Path $d).FullName"
    res := SshPs(mkdirPs)
    if (res.exitCode != 0) {
        Tip("Could not create LOCAL staging: " Trim(res.stderr), true)
        return
    }
    stageAbs := Trim(res.stdout, "`r`n `t")
    if (stageAbs = "") {
        Tip("LOCAL staging path was empty.", true)
        return
    }

    ok := 0, fail := 0, names := []
    Tip("Copying " paths.Length " item(s) to LOCAL...")
    for p in paths {
        cmd := 'scp -r -q "' p '" ' SSH_HOST ':"' stageAbs '"'
        scp := Run2(cmd)
        if (scp.exitCode = 0) {
            ok++
            SplitPath(p, &name)
            names.Push(stageAbs "\" name)
        } else {
            fail++
            OutputDebug("scp push failed for " p ": " scp.stderr "`n")
        }
    }
    if (ok = 0) {
        Tip("All scp pushes failed.", true)
        return
    }

    quoted := ""
    for n in names
        quoted .= (quoted = "" ? "" : ",") . "'" . StrReplace(n, "'", "''") . "'"
    setPs := PS_UTF8 . "Set-Clipboard -Path " quoted
    res2 := SshPs(setPs)
    if (res2.exitCode != 0) {
        Tip("Set-Clipboard failed: " Trim(res2.stderr), true)
        return
    }
    Tip("Pushed " ok " item(s) to LOCAL" (fail ? " (" fail " failed)" : "") ".")
}

; ============================================================================
;  Helpers
; ============================================================================

; Run any command, capture stdout/stderr/exit code via temp files.
Run2(cmd) {
    tmpOut := A_Temp "\clipsync_" A_TickCount "_out.txt"
    tmpErr := A_Temp "\clipsync_" A_TickCount "_err.txt"
    full   := A_ComSpec ' /c ' cmd ' >"' tmpOut '" 2>"' tmpErr '"'
    code   := RunWait(full, , "Hide")
    out    := FileExist(tmpOut) ? FileRead(tmpOut, "UTF-8") : ""
    err    := FileExist(tmpErr) ? FileRead(tmpErr, "UTF-8") : ""
    try FileDelete(tmpOut)
    try FileDelete(tmpErr)
    Log("RUN ec=" code " out=" StrLen(out) "B err=" StrLen(err) "B :: " SubStr(cmd, 1, 200))
    if (err != "")
        Log("  stderr: " SubStr(Trim(err), 1, 400))
    return {exitCode: code, stdout: out, stderr: err}
}

; Run a PowerShell snippet on LOCAL via SSH using -EncodedCommand
; (UTF-16-LE base64). This avoids ALL shell-quoting hazards because the
; encoded blob has no metacharacters that cmd or the remote shell can mangle.
SshPs(ps) {
    enc := EncodeUtf16Base64(ps)
    cmd := 'ssh ' SSH_HOST ' powershell -NoProfile -EncodedCommand ' enc
    return Run2(cmd)
}

; Run a PowerShell snippet locally on REMOTE via -EncodedCommand.
PsLocal(ps) {
    enc := EncodeUtf16Base64(ps)
    return Run2('powershell -NoProfile -EncodedCommand ' enc)
}

; UTF-16-LE base64 of a string, no CRLFs - the format powershell.exe expects
; for -EncodedCommand. AHK strings are already UTF-16 internally, so we copy
; raw bytes directly out of the string buffer.
EncodeUtf16Base64(s) {
    n := StrLen(s)
    if (n = 0)
        return ""
    bytes := n * 2
    bin := Buffer(bytes)
    DllCall("RtlMoveMemory", "ptr", bin, "ptr", StrPtr(s), "ptr", bytes)

    flags := 0x40000001  ; CRYPT_STRING_BASE64 | CRYPT_STRING_NOCRLF
    sizeOut := 0
    DllCall("crypt32\CryptBinaryToStringW"
        , "ptr", bin, "uint", bytes
        , "uint", flags
        , "ptr", 0, "uint*", &sizeOut)
    if (sizeOut = 0)
        return ""
    out := Buffer(sizeOut * 2, 0)
    DllCall("crypt32\CryptBinaryToStringW"
        , "ptr", bin, "uint", bytes
        , "uint", flags
        , "ptr", out, "uint*", &sizeOut)
    return StrGet(out, "UTF-16")
}

; Inspect REMOTE (this machine) clipboard.
LocalClipboardKind() {
    if (DllCall("IsClipboardFormatAvailable", "uint", 15))   ; CF_HDROP
        return "files"
    if (A_Clipboard != "")
        return "text"
    return "empty"
}

RemoteClipboardKind() {
    ps := PS_UTF8 "if ((Get-Clipboard -Format FileDropList | Measure-Object).Count -gt 0) { 'files' } elseif (Get-Clipboard -Raw) { 'text' } else { 'empty' }"
    res := SshPs(ps)
    if (res.exitCode != 0)
        return "ssh-error: " Trim(res.stderr)
    return Trim(res.stdout, "`r`n `t")
}

; Read CF_HDROP from REMOTE clipboard via PowerShell.
GetClipboardFiles() {
    res := PsLocal(PS_UTF8 "(Get-Clipboard -Format FileDropList).FullName")
    if (res.exitCode != 0)
        return []
    return SplitLines(res.stdout)
}

; Set REMOTE clipboard to a FileDropList.
SetClipboardFiles(paths) {
    if (paths.Length = 0)
        return
    quoted := ""
    for p in paths
        quoted .= (quoted = "" ? "" : ",") . "'" . StrReplace(p, "'", "''") . "'"
    PsLocal(PS_UTF8 "Set-Clipboard -Path " quoted)
}

MakeStagingDir() {
    ts := FormatTime(, "yyyyMMdd-HHmmss")
    dir := STAGING_BASE "\" ts
    DirCreate(dir)
    return dir
}

PruneOldStaging() {
    if (!DirExist(STAGING_BASE))
        return
    cutoff := DateAdd(A_Now, -PRUNE_DAYS, "Days")
    Loop Files, STAGING_BASE "\*", "D" {
        if (A_LoopFileTimeModified < cutoff) {
            try DirDelete(A_LoopFileFullPath, true)
        }
    }
}

DirItems(dir) {
    out := []
    Loop Files, dir "\*", "FD"
        out.Push(A_LoopFileFullPath)
    return out
}

SplitLines(s) {
    out := []
    for line in StrSplit(s, "`n", "`r") {
        if (line != "")
            out.Push(line)
    }
    return out
}

; cmd's "..." quoting: " -> ""  (PowerShell receives a single ").
; Kept around for reference/legacy; no longer used now that we go through
; -EncodedCommand.
EscapeForCmd(s) {
    return StrReplace(s, '"', '""')
}

Tip(msg, isError := false) {
    title := isError ? "clipsync (error)" : "clipsync"
    TrayTip(msg, title, isError ? 0x2 : 0x1)
    SetTimer(() => TrayTip(), -TRAY_MS)
    Log((isError ? "TIP-ERR " : "TIP ") msg)
}

; --- Debug log --------------------------------------------------------------
Log(msg) {
    global LOG_PATH
    try {
        line := FormatTime(, "yyyy-MM-dd HH:mm:ss") " " msg "`r`n"
        FileAppend(line, LOG_PATH, "UTF-8")
    }
}
