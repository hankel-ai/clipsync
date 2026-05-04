#Requires AutoHotkey v2.0
#SingleInstance Force

; ----------------------------------------------------------------------------
; clipsync.ahk - REMOTE-side hotkey driver.
;
;   Ctrl+Alt+Win+V  ->  pull LOCAL's clipboard onto REMOTE
;   Ctrl+Alt+Win+C  ->  push REMOTE's clipboard onto LOCAL
;
; Architecture:
;   - LOCAL runs clipsync-bridge.ps1 in its interactive logon session
;     (so it can actually access the user's clipboard). It listens on
;     127.0.0.1:8765 with HTTP-style endpoints.
;   - REMOTE talks to that bridge via:  ssh local "curl http://127.0.0.1:8765/..."
;     The SSH session itself can't see the clipboard, but it can dial
;     localhost on LOCAL, and the bridge (which IS in the desktop session)
;     handles the actual clipboard read/write.
;   - File payloads still go directly over scp; only clipboard read/write
;     uses the bridge.
;
; REMOTE-side clipboard ops (this script's own clipboard) are done locally
; through PowerShell or AHK directly - no bridge needed because AHK runs
; in REMOTE's interactive session and CAN see its own clipboard.
; ----------------------------------------------------------------------------

; --- Configuration ----------------------------------------------------------
SSH_HOST       := "clipsync-local"                              ; ssh config alias
BRIDGE_URL     := "http://127.0.0.1:8765"                       ; bridge on LOCAL loopback
STAGING_BASE   := EnvGet("LOCALAPPDATA") "\clipsync\incoming"   ; on REMOTE
LOG_PATH       := EnvGet("LOCALAPPDATA") "\clipsync\clipsync.log"
PRUNE_DAYS     := 7
TRAY_MS        := 2500
HTTP_TIMEOUT_S := 15
PS_UTF8        := "[Console]::OutputEncoding=[Text.Encoding]::UTF8;[Console]::InputEncoding=[Text.Encoding]::UTF8;"

DirCreate(STAGING_BASE)
PruneOldStaging()
Log("=== clipsync started ===")

; --- Hotkeys ----------------------------------------------------------------
^!#v::PullFromLocal()
^!#c::PushToLocal()

; ============================================================================
;  Direction 1: LOCAL -> REMOTE
; ============================================================================
PullFromLocal() {
    Tip("Checking LOCAL clipboard...")
    res := SshGet("/kind")
    if (res.exitCode != 0) {
        Tip("Bridge unreachable: " Trim(res.stderr), true)
        return
    }
    kind := Trim(res.stdout, "`r`n `t")
    if (kind = "empty") {
        Tip("LOCAL clipboard is empty.", true)
        return
    }
    if (kind = "text")
        PullText()
    else if (kind = "files")
        PullFiles()
    else
        Tip("Bridge returned unknown kind: " kind, true)
}

PullText() {
    res := SshGet("/text")
    if (res.exitCode != 0) {
        Tip("GET /text failed: " Trim(res.stderr), true)
        return
    }
    A_Clipboard := res.stdout
    Tip("Pulled " StrLen(res.stdout) " chars from LOCAL.")
    Sleep 100
    Send "^v"
}

PullFiles() {
    res := SshGet("/files")
    if (res.exitCode != 0) {
        Tip("GET /files failed: " Trim(res.stderr), true)
        return
    }
    paths := SplitLines(res.stdout)
    if (paths.Length = 0) {
        Tip("Bridge returned no file paths.", true)
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
            Log("scp pull failed for " path ": " scp.stderr)
        }
    }
    if (ok = 0) {
        Tip("All scp pulls failed.", true)
        return
    }

    staged := []
    for f in DirItems(stage)
        staged.Push(f)
    SetLocalClipboardFiles(staged)
    Tip("Pulled " ok " item(s) from LOCAL" (fail ? " (" fail " failed)" : "") ".")
    Sleep 100
    Send "^v"
}

; ============================================================================
;  Direction 2: REMOTE -> LOCAL
; ============================================================================
PushToLocal() {
    Send "^c"
    Tip("Checking REMOTE clipboard...")
    Sleep 300
    kind := MyClipboardKind()
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
    ; Write the text to a UTF-8 temp file on REMOTE, scp it up, POST to bridge.
    tmp := A_Temp "\clipsync_pushtext_" A_TickCount ".txt"
    FileAppend(text, tmp, "UTF-8-RAW")
    res := ScpThenPost(tmp, "/text")
    try FileDelete(tmp)
    if (res.exitCode != 0 || !ResponseOk(res)) {
        Tip("Push text failed: " Trim(res.stderr) " " Trim(res.stdout), true)
        return
    }
    Tip("Pushed " StrLen(text) " chars to LOCAL.")
}

PushFiles() {
    paths := MyClipboardFiles()
    if (paths.Length = 0) {
        Tip("No files on REMOTE clipboard.", true)
        return
    }

    ; Make a timestamped staging dir on LOCAL via plain SSH (filesystem ops
    ; don't need the interactive session).
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
            Log("scp push failed for " p ": " scp.stderr)
        }
    }
    if (ok = 0) {
        Tip("All scp pushes failed.", true)
        return
    }

    ; Tell the bridge to set LOCAL's clipboard to the newly-staged paths.
    list := ""
    for n in names
        list .= (list = "" ? "" : "`n") n
    tmp := A_Temp "\clipsync_pushfiles_" A_TickCount ".txt"
    FileAppend(list, tmp, "UTF-8-RAW")
    res2 := ScpThenPost(tmp, "/files")
    try FileDelete(tmp)
    if (res2.exitCode != 0 || !ResponseOk(res2)) {
        Tip("POST /files failed: " Trim(res2.stderr) " " Trim(res2.stdout), true)
        return
    }
    Tip("Pushed " ok " item(s) to LOCAL" (fail ? " (" fail " failed)" : "") ".")
}

; ============================================================================
;  Bridge transport (HTTP via SSH+curl)
; ============================================================================

; GET <bridge>/<path>
;
; The remote default shell is PowerShell, so:
;   - 'curl' is an alias for Invoke-WebRequest -> use 'curl.exe' to bypass.
;   - URL contains no PS metachars so unquoted is fine.
SshGet(path) {
    cmd := 'ssh ' SSH_HOST ' curl.exe -s -m ' HTTP_TIMEOUT_S ' ' BRIDGE_URL path
    return Run2(cmd)
}

; scp a local file up to LOCAL %TEMP%, POST it to <bridge>/<endpoint> via
; curl --data-binary, then delete the temp file. The body file lives on LOCAL.
;
; Args that contain PS metachars are wrapped in single quotes so PowerShell
; treats them as literals (otherwise: '@<path>' triggers splatting, ';' is a
; statement separator, etc.).
ScpThenPost(localFile, endpoint) {
    res := SshPs(PS_UTF8 "$env:TEMP")
    if (res.exitCode != 0)
        return res
    localTemp := Trim(res.stdout, "`r`n `t")
    if (localTemp = "")
        return {exitCode: 1, stdout: "", stderr: "could not resolve LOCAL %TEMP%"}
    target := localTemp "\clipsync_body_" A_TickCount ".bin"

    scp := Run2('scp -q "' localFile '" ' SSH_HOST ':"' target '"')
    if (scp.exitCode != 0)
        return scp

    cmd := 'ssh ' SSH_HOST ' curl.exe -s -m ' HTTP_TIMEOUT_S " -X POST --data-binary '@" target "' -H 'Content-Type:text/plain;charset=utf-8' " BRIDGE_URL endpoint
    res2 := Run2(cmd)

    ; Best-effort cleanup of the LOCAL temp file
    SshPs(PS_UTF8 "Remove-Item -LiteralPath '" target "' -Force -ErrorAction SilentlyContinue")
    return res2
}

; The bridge always returns "ok" body on success for POSTs. Treat anything
; else as failure even if curl exit was 0.
ResponseOk(res) {
    return Trim(res.stdout, "`r`n `t") = "ok"
}

; ============================================================================
;  REMOTE-side clipboard (this machine - works directly, no bridge needed)
; ============================================================================
MyClipboardKind() {
    if (DllCall("IsClipboardFormatAvailable", "uint", 15))   ; CF_HDROP
        return "files"
    if (A_Clipboard != "")
        return "text"
    return "empty"
}

MyClipboardFiles() {
    res := PsLocal(PS_UTF8 "(Get-Clipboard -Format FileDropList).FullName")
    if (res.exitCode != 0)
        return []
    return SplitLines(res.stdout)
}

SetLocalClipboardFiles(paths) {
    if (paths.Length = 0)
        return
    quoted := ""
    for p in paths
        quoted .= (quoted = "" ? "" : ",") . "'" . StrReplace(p, "'", "''") . "'"
    PsLocal(PS_UTF8 "Set-Clipboard -Path " quoted)
}

; ============================================================================
;  Generic helpers
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

; PowerShell snippet over SSH via -EncodedCommand (no shell-quoting hazards).
SshPs(ps) {
    enc := EncodeUtf16Base64(ps)
    return Run2('ssh ' SSH_HOST ' powershell -NoProfile -EncodedCommand ' enc)
}

; PowerShell snippet on this machine via -EncodedCommand.
PsLocal(ps) {
    enc := EncodeUtf16Base64(ps)
    return Run2('powershell -NoProfile -EncodedCommand ' enc)
}

; UTF-16-LE base64 of a string, no CRLFs - the format powershell.exe expects
; for -EncodedCommand. AHK strings are already UTF-16 internally.
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

Tip(msg, isError := false) {
    ToolTip((isError ? "[!] " : "") msg)
    SetTimer(() => ToolTip(), -TRAY_MS)
    Log((isError ? "TIP-ERR " : "TIP ") msg)
}

Log(msg) {
    global LOG_PATH
    try {
        line := FormatTime(, "yyyy-MM-dd HH:mm:ss") " " msg "`r`n"
        FileAppend(line, LOG_PATH, "UTF-8")
    }
}
