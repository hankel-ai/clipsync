-- clipsync.lua - macOS REMOTE hotkey driver (Hammerspoon).
--
--   Ctrl+Alt+Cmd+V  ->  pull LOCAL's clipboard onto this Mac  (auto Cmd+V)
--   Ctrl+Alt+Cmd+C  ->  push this Mac's clipboard onto LOCAL  (auto Cmd+C first)
--
-- This is the macOS equivalent of clipsync.ahk. LOCAL is a Windows machine
-- running clipsync-bridge.ps1 in its interactive session; this Mac reaches the
-- bridge over SSH+curl and moves file/image payloads with scp, exactly like the
-- Windows REMOTE does. See CLAUDE.md / README.md.
--
-- Requires: Hammerspoon (with Accessibility granted), OpenSSH client (built in),
-- and an ssh config 'clipsync-local' Host alias pointing at LOCAL's LAN IP with
-- User = the low-privilege 'clipsync' account. See install-mac.sh.
--
-- Load from ~/.hammerspoon/init.lua with:  require("clipsync")

local M = {}

-- === Configuration =========================================================
local SSH_HOST     = "clipsync-local"                 -- ssh config alias
local BRIDGE_URL   = "http://127.0.0.1:8765"          -- bridge on LOCAL loopback
local LOCAL_SHARE  = [[C:\clipsync-share]]            -- shared staging dir ON LOCAL (Windows path)
local HTTP_TIMEOUT = 15                               -- curl -m seconds
-- GET /files makes the bridge copy every selected item (recursively) into the
-- share BEFORE it responds, so many/large folders can exceed the default 15s
-- cap and curl aborts the whole pull. Give that call a much longer budget.
local HTTP_TIMEOUT_FILES = 120
local ALERT_SECS   = 2.5

local HOME         = os.getenv("HOME")
local STAGING_BASE = HOME .. "/.clipsync/incoming"    -- on this Mac
local LOG_PATH     = HOME .. "/.clipsync/clipsync.log"

-- Hotkey modifiers/keys (one-line change if Chrome Remote Desktop won't forward
-- this combo - e.g. swap to {"ctrl"} + "f13"). See README "CRD caveat".
local MODS = {"ctrl", "alt", "cmd"}
local KEY_PULL = "v"
local KEY_PUSH = "c"

-- === Small utilities =======================================================
local _seq = 0
local function nextSeq()
    _seq = _seq + 1
    return _seq
end

local function log(msg)
    local f = io.open(LOG_PATH, "a")
    if f then
        f:write(os.date("%Y-%m-%d %H:%M:%S") .. " " .. tostring(msg) .. "\n")
        f:close()
    end
end

-- Single-quote a string for /bin/sh so its contents are passed literally.
local function q(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function trim(s)
    return (tostring(s):gsub("^%s*(.-)%s*$", "%1"))
end

local function readFile(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    return data
end

local function ensureDir(path)
    hs.fs.mkdir(path)  -- no-op if it exists; parent must exist
end

-- Ensure a possibly-deep local dir exists (mkdir -p semantics).
local function ensureDirp(path)
    os.execute("/bin/mkdir -p " .. q(path))
end

-- Run a shell command, capturing stdout/stderr/exit separately (like AHK Run2).
local function runCmd(cmd)
    local id = tostring(os.time()) .. "-" .. nextSeq()
    local outFile = "/tmp/clipsync_" .. id .. ".out"
    local errFile = "/tmp/clipsync_" .. id .. ".err"
    local full = cmd .. " >" .. q(outFile) .. " 2>" .. q(errFile)
    local _, _, _, rc = hs.execute(full, true)
    local out = readFile(outFile) or ""
    local err = readFile(errFile) or ""
    os.remove(outFile)
    os.remove(errFile)
    local code = rc or 0
    log(string.format("RUN ec=%s out=%dB err=%dB :: %s", tostring(code), #out, #err, cmd:sub(1, 200)))
    if err ~= "" then log("  stderr: " .. trim(err):sub(1, 400)) end
    return { exit = code, stdout = out, stderr = err }
end

-- === On-screen feedback ====================================================
local function tip(msg, isError)
    local text = (isError and "[!] " or "") .. msg
    hs.alert.closeAll()
    hs.alert.show(text, ALERT_SECS)
    log((isError and "TIP-ERR " or "TIP ") .. msg)
end

local function persistTip(msg)
    hs.alert.closeAll()
    hs.alert.show(msg, 3600)  -- until closeAll()
    log("TIP " .. msg)
end

-- === Keystroke helpers =====================================================
local function sendCmd(letter)
    hs.eventtap.keyStroke({"cmd"}, letter, 0)
end

-- Wait (bounded) for the user to release the hotkey modifiers before we
-- synthesize a keystroke. Without this, a push's Cmd+C fires while Ctrl+Alt+Cmd
-- is still physically held, so the app sees Ctrl+Alt+Cmd+C (not a clean copy)
-- and nothing is copied - the push then reads stale clipboard contents. (Pull's
-- Cmd+V doesn't need this: it fires ~1s later, after ssh, once the user let go.)
local function waitModifiersReleased(maxMs)
    local waited = 0
    while waited < maxMs do
        local m = hs.eventtap.checkKeyboardModifiers()
        if not (m.cmd or m.ctrl or m.alt or m.shift) then return end
        hs.timer.usleep(15000)
        waited = waited + 15
    end
end

-- Build an scp remote source spec from a Windows path. macOS scp runs a remote
-- glob on the SOURCE and mangles backslashes, so a path that exists still errors
-- "No such file or directory". Forward slashes resolve fine on the Windows
-- OpenSSH sftp server and aren't glob metacharacters. (Destinations aren't
-- globbed, so push paths are left as-is.)
local function scpRemote(winPath)
    return SSH_HOST .. ":" .. (winPath:gsub("\\", "/"))
end

-- === Bridge transport (HTTP via SSH + curl.exe on LOCAL) ===================
-- LOCAL's SSH default shell is PowerShell, so we call curl.exe (not curl) and
-- keep the remote command as a single sh-quoted argument to ssh.
local function sshRun(remoteCmd)
    return runCmd("ssh " .. q(SSH_HOST) .. " " .. q(remoteCmd))
end

-- Base64 of raw bytes (table of 0-255). No external deps.
local B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
local function base64(bytes)
    local out = {}
    for i = 1, #bytes, 3 do
        local b1, b2, b3 = bytes[i], bytes[i + 1], bytes[i + 2]
        local n = b1 * 65536 + (b2 or 0) * 256 + (b3 or 0)
        out[#out + 1] = B64:sub(math.floor(n / 262144) % 64 + 1, math.floor(n / 262144) % 64 + 1)
        out[#out + 1] = B64:sub(math.floor(n / 4096)  % 64 + 1, math.floor(n / 4096)  % 64 + 1)
        out[#out + 1] = b2 and B64:sub(math.floor(n / 64) % 64 + 1, math.floor(n / 64) % 64 + 1) or '='
        out[#out + 1] = b3 and B64:sub(n % 64 + 1, n % 64 + 1) or '='
    end
    return table.concat(out)
end

-- Run a PowerShell command on LOCAL via -EncodedCommand (base64 of UTF-16LE).
-- This is quoting-proof: the payload survives ssh -> sshd -> PowerShell with no
-- shell-metachar hazards. Same rationale as clipsync.ahk's SshPs/-EncodedCommand.
-- (Our commands are ASCII, so one 0x00 high byte per char is a correct UTF-16LE.)
local function sshPwsh(psInner)
    local bytes = {}
    for i = 1, #psInner do
        bytes[#bytes + 1] = psInner:byte(i)
        bytes[#bytes + 1] = 0
    end
    return sshRun("powershell -NoProfile -EncodedCommand " .. base64(bytes))
end

local function sshGet(path, timeout)
    return sshRun("curl.exe -s -m " .. (timeout or HTTP_TIMEOUT) .. " " .. BRIDGE_URL .. path)
end

-- POST the contents of a local file to <bridge><endpoint>.
--
-- We do NOT pipe the body over ssh stdin: LOCAL's default shell is PowerShell,
-- and stdin fed to `ssh host "cmd" < file` is NOT reliably delivered to a
-- child curl.exe under PowerShell - it arrives empty, so POST /text silently
-- clears the clipboard while the bridge still answers "ok". Instead we scp the
-- body up to the LOCAL shared dir and have curl.exe read it as a file (@path),
-- exactly like clipsync.ahk's ScpThenPost. Then we delete the LOCAL temp file.
local function sshPost(bodyFile, endpoint)
    local remotePath = LOCAL_SHARE .. [[\incoming\clipsync_body_]] ..
                       os.date("%Y%m%d-%H%M%S") .. "-" .. nextSeq() .. ".bin"
    local scp = runCmd("scp -q " .. q(bodyFile) .. " " .. q(SSH_HOST .. ":" .. remotePath))
    if scp.exit ~= 0 then return scp end

    -- '@path' single-quoted so remote PowerShell passes it literally to curl.exe.
    local remote = "curl.exe -s -m " .. HTTP_TIMEOUT ..
                   " -X POST --data-binary '@" .. remotePath .. "'" ..
                   " -H 'Content-Type:text/plain;charset=utf-8' " .. BRIDGE_URL .. endpoint
    local res = runCmd("ssh " .. q(SSH_HOST) .. " " .. q(remote))

    -- Best-effort cleanup of the LOCAL temp body file (quoting-proof via sshPwsh).
    sshPwsh("Remove-Item -LiteralPath '" .. remotePath .. "' -Force -ErrorAction SilentlyContinue")
    return res
end

-- The bridge returns "ok" on a successful POST. Treat anything else as failure.
local function responseOk(res)
    return trim(res.stdout) == "ok"
end

-- === Mac clipboard / Finder ================================================
-- Push kind detection. Files come from the Finder selection (most reliable);
-- otherwise we copy the current selection and inspect the pasteboard.
local function finderSelection()
    local script = [[
        set out to ""
        tell application "Finder"
            set sel to selection
            repeat with anItem in sel
                set out to out & POSIX path of (anItem as alias) & linefeed
            end repeat
        end tell
        return out
    ]]
    local ok, result = hs.osascript.applescript(script)
    if not ok or not result then return {} end
    local paths = {}
    for line in tostring(result):gmatch("[^\r\n]+") do
        if trim(line) ~= "" then paths[#paths + 1] = trim(line) end
    end
    return paths
end

local function frontmostIsFinder()
    local app = hs.application.frontmostApplication()
    return app ~= nil and app:bundleID() == "com.apple.finder"
end

-- Percent-encode a POSIX path into a file:// URL for the pasteboard.
local function fileUrl(path)
    local enc = path:gsub("([^%w%-%._~/])", function(c)
        return string.format("%%%02X", string.byte(c))
    end)
    return "file://" .. enc
end

local function setClipboardFiles(paths)
    local objs = {}
    for _, p in ipairs(paths) do
        objs[#objs + 1] = { url = fileUrl(p) }
    end
    -- Writing file URLs registers public.file-url so Finder can paste them.
    hs.pasteboard.writeObjects(objs)
end

local function collectDirItems(dir)
    local items = {}
    for name in hs.fs.dir(dir) do
        if name ~= "." and name ~= ".." then
            items[#items + 1] = dir .. "/" .. name
        end
    end
    return items
end

local function makeStagingDir()
    local ts = os.date("%Y%m%d-%H%M%S") .. "-" .. nextSeq()
    local dir = STAGING_BASE .. "/" .. ts
    ensureDirp(dir)
    return dir
end

-- === Direction 1: LOCAL -> Mac (pull) ======================================
local function pullText()
    local res = sshGet("/text")
    if res.exit ~= 0 then tip("GET /text failed: " .. trim(res.stderr), true); return end
    hs.pasteboard.setContents(res.stdout)
    tip("Pulled " .. #res.stdout .. " chars from LOCAL.")
    hs.timer.usleep(100000)
    sendCmd("v")
end

local function pullFiles()
    local res = sshGet("/files", HTTP_TIMEOUT_FILES)
    if res.exit ~= 0 then tip("GET /files failed: " .. trim(res.stderr), true); return end
    local paths = {}
    for line in res.stdout:gmatch("[^\r\n]+") do
        if trim(line) ~= "" then paths[#paths + 1] = trim(line) end
    end
    if #paths == 0 then tip("Bridge returned no file paths.", true); return end

    local stage = makeStagingDir()
    persistTip("Copying " .. #paths .. " item(s) from LOCAL...")
    local ok, fail = 0, 0
    for _, p in ipairs(paths) do
        local scp = runCmd("scp -r -q " .. q(scpRemote(p)) .. " " .. q(stage))
        if scp.exit == 0 then ok = ok + 1 else fail = fail + 1; log("scp pull failed for " .. p .. ": " .. scp.stderr) end
    end
    hs.alert.closeAll()
    if ok == 0 then tip("All scp pulls failed.", true); return end

    setClipboardFiles(collectDirItems(stage))
    tip("Pulled " .. ok .. " item(s) from LOCAL" .. (fail > 0 and (" (" .. fail .. " failed)") or "") .. ".")
    hs.timer.usleep(100000)
    sendCmd("v")
end

local function pullImage()
    local res = sshGet("/image")
    if res.exit ~= 0 then tip("GET /image failed: " .. trim(res.stderr), true); return end
    local localPath = trim(res.stdout)
    if localPath == "" then tip("Bridge returned empty image path.", true); return end

    local stage = makeStagingDir()
    persistTip("Pulling image from LOCAL...")
    local scp = runCmd("scp -q " .. q(scpRemote(localPath)) .. " " .. q(stage))
    hs.alert.closeAll()
    if scp.exit ~= 0 then tip("scp pull image failed: " .. trim(scp.stderr), true); return end

    local name = localPath:match("[^\\]+$")
    local staged = stage .. "/" .. name
    local img = hs.image.imageFromPath(staged)
    if not img then tip("Staged PNG missing/unreadable at " .. staged, true); return end
    hs.pasteboard.writeObjects(img)
    tip("Pulled image from LOCAL.")
    hs.timer.usleep(100000)
    sendCmd("v")
end

function M.pullFromLocal()
    persistTip("Checking LOCAL clipboard...")
    local res = sshGet("/kind")
    hs.alert.closeAll()
    if res.exit ~= 0 then tip("Bridge unreachable: " .. trim(res.stderr), true); return end
    local kind = trim(res.stdout)
    if kind == "empty" then tip("LOCAL clipboard is empty.", true); return end
    if kind == "text" then pullText()
    elseif kind == "files" then pullFiles()
    elseif kind == "image" then pullImage()
    else tip("Bridge returned unknown kind: " .. kind, true) end
end

-- === Direction 2: Mac -> LOCAL (push) ======================================
local function pushText(text)
    local tmp = "/tmp/clipsync_pushtext_" .. nextSeq() .. ".txt"
    local f = io.open(tmp, "w"); f:write(text); f:close()
    local res = sshPost(tmp, "/text")
    os.remove(tmp)
    if res.exit ~= 0 or not responseOk(res) then
        tip("Push text failed: " .. trim(res.stderr) .. " " .. trim(res.stdout), true); return
    end
    tip("Pushed " .. #text .. " chars to LOCAL.")
end

local function pushFiles(paths)
    if #paths == 0 then tip("No files selected in Finder.", true); return end

    -- Stage under the LOCAL shared dir (not the SSH account's profile) so the
    -- bridge, running as the desktop user, can read them for POST /files.
    local ts = os.date("%Y%m%d-%H%M%S") .. "-" .. nextSeq()
    local stageAbs = LOCAL_SHARE .. [[\incoming\]] .. ts
    local mk = sshPwsh("New-Item -ItemType Directory -Force -Path '" .. stageAbs .. "' | Out-Null")
    if mk.exit ~= 0 then tip("Could not create LOCAL staging: " .. trim(mk.stderr), true); return end

    persistTip("Copying " .. #paths .. " item(s) to LOCAL...")
    local ok, fail, names = 0, 0, {}
    for _, p in ipairs(paths) do
        local scp = runCmd("scp -r -q " .. q(p) .. " " .. q(SSH_HOST .. ":" .. stageAbs))
        if scp.exit == 0 then
            ok = ok + 1
            local leaf = p:gsub("/+$", ""):match("[^/]+$")
            names[#names + 1] = stageAbs .. [[\]] .. leaf
        else
            fail = fail + 1
            log("scp push failed for " .. p .. ": " .. scp.stderr)
        end
    end
    hs.alert.closeAll()
    if ok == 0 then tip("All scp pushes failed.", true); return end

    -- Tell the bridge to set LOCAL's clipboard to the staged paths.
    local tmp = "/tmp/clipsync_pushfiles_" .. nextSeq() .. ".txt"
    local f = io.open(tmp, "w"); f:write(table.concat(names, "\n")); f:close()
    local res = sshPost(tmp, "/files")
    os.remove(tmp)
    if res.exit ~= 0 or not responseOk(res) then
        tip("POST /files failed: " .. trim(res.stderr) .. " " .. trim(res.stdout), true); return
    end
    tip("Pushed " .. ok .. " item(s) to LOCAL" .. (fail > 0 and (" (" .. fail .. " failed)") or "") .. ".")
end

local function pushImage()
    -- Save the Mac pasteboard image to a temp PNG.
    local img = hs.pasteboard.readImage()
    if not img then tip("No image on the Mac clipboard.", true); return end
    local macPng = "/tmp/clipsync_img_" .. nextSeq() .. ".png"
    if not img:saveToFile(macPng) then tip("Could not save clipboard image.", true); return end

    -- scp it into the LOCAL shared dir so the bridge can read it.
    local ts = os.date("%Y%m%d-%H%M%S") .. "-" .. nextSeq()
    local localPng = LOCAL_SHARE .. [[\incoming\clipsync_img_]] .. ts .. ".png"
    sshPwsh("New-Item -ItemType Directory -Force -Path '" .. LOCAL_SHARE .. [[\incoming]] .. "' | Out-Null")
    persistTip("Pushing image to LOCAL...")
    local scp = runCmd("scp -q " .. q(macPng) .. " " .. q(SSH_HOST .. ":" .. localPng))
    os.remove(macPng)
    hs.alert.closeAll()
    if scp.exit ~= 0 then tip("scp push image failed: " .. trim(scp.stderr), true); return end

    -- POST the LOCAL path; the bridge loads it onto the clipboard and deletes it.
    local tmp = "/tmp/clipsync_imgpath_" .. nextSeq() .. ".txt"
    local f = io.open(tmp, "w"); f:write(localPng); f:close()
    local res = sshPost(tmp, "/image")
    os.remove(tmp)
    if res.exit ~= 0 or not responseOk(res) then
        tip("POST /image failed: " .. trim(res.stderr) .. " " .. trim(res.stdout), true); return
    end
    tip("Pushed image to LOCAL.")
end

function M.pushToLocal()
    -- Files: read the Finder selection directly (most reliable on macOS).
    if frontmostIsFinder() then
        local sel = finderSelection()
        if #sel > 0 then pushFiles(sel); return end
    end
    -- Otherwise copy the current selection and inspect the pasteboard.
    -- Wait for the hotkey modifiers to release first, else Cmd+C merges with the
    -- still-held Ctrl+Alt+Cmd and no copy happens (we'd push stale clipboard).
    waitModifiersReleased(600)
    sendCmd("c")
    hs.timer.usleep(300000)
    if hs.pasteboard.readImage() ~= nil then
        pushImage(); return
    end
    local text = hs.pasteboard.readString()
    if text and #text > 0 then
        pushText(text); return
    end
    tip("Nothing to push (no Finder selection, image, or text).", true)
end

-- === Passthrough while a remote-desktop app is frontmost ===================
-- When you're physically at this Mac with Microsoft Remote Desktop focused, the
-- clipsync chord should go INTO the RDP session (macOS Cmd -> Windows key, so
-- Ctrl+Alt+Cmd+V/C arrives in the guest as Ctrl+Alt+Win+V/C -> clipsync.ahk),
-- not be swallowed here. A *disabled* hs.hotkey does not intercept the key, so
-- macOS delivers it straight to the focused app. We toggle the two bindings on
-- focus changes via an application watcher.
--
-- Find your bundle id with:  osascript -e 'id of app "Microsoft Remote Desktop"'
-- (or hs.application.frontmostApplication():bundleID() in the Hammerspoon console
--  while RDP is focused). Add whatever it returns below.
local PASSTHROUGH_BUNDLES = {
    ["com.microsoft.rdc.macos"] = true,   -- Microsoft Remote Desktop v10 / Windows App
    ["com.microsoft.rdc.osx"]   = true,   -- older builds
}

local function updateHotkeyState(app)
    if not (M._hkPull and M._hkPush) then return end
    local bid = app and app:bundleID()
    local passthrough = bid ~= nil and PASSTHROUGH_BUNDLES[bid] == true
    if passthrough then
        M._hkPull:disable(); M._hkPush:disable()
    else
        M._hkPull:enable();  M._hkPush:enable()
    end
    log("hotkeys " .. (passthrough and ("DISABLED (passthrough to " .. bid .. ")") or "enabled")
        .. " frontmost=" .. tostring(bid))
end

-- === Startup ===============================================================
local function clearStaging()
    if hs.fs.attributes(STAGING_BASE) then
        os.execute("/bin/rm -rf " .. q(STAGING_BASE) .. "/*")
    end
end

function M.start()
    ensureDirp(HOME .. "/.clipsync")
    ensureDirp(STAGING_BASE)
    clearStaging()
    M._hkPull = hs.hotkey.bind(MODS, KEY_PULL, M.pullFromLocal)
    M._hkPush = hs.hotkey.bind(MODS, KEY_PUSH, M.pushToLocal)

    -- Disable our hotkeys while a remote-desktop app is frontmost so the chord
    -- passes into the RDP session instead of being captured here.
    M._appWatcher = hs.application.watcher.new(function(_, event, app)
        if event == hs.application.watcher.activated then
            updateHotkeyState(app)
        end
    end)
    M._appWatcher:start()
    updateHotkeyState(hs.application.frontmostApplication())  -- set initial state

    log("=== clipsync started (pull=" .. KEY_PULL .. " push=" .. KEY_PUSH .. ") ===")
    hs.alert.show("clipsync ready", 1.5)
end

M.start()
return M
