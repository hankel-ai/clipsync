#!/usr/bin/env bash
#
# install-mac.sh - set up clipsync on a macOS REMOTE (user-scope, no admin).
#
# The Mac is a REMOTE: it drives hotkeys and reaches a Windows LOCAL machine
# (running clipsync-bridge.ps1) over SSH on the LAN. This installs the
# Hammerspoon hotkey daemon (clipsync.lua), sets up an SSH key + config alias,
# and smoke-tests the bridge.
#
# Usage:
#   ./install-mac.sh --local-host 192.168.1.50 [--local-user clipsync] [--key ~/.ssh/id_ed25519]
#
set -euo pipefail

LOCAL_HOST=""
LOCAL_USER="clipsync"
KEY_PATH="$HOME/.ssh/id_ed25519"

while [ $# -gt 0 ]; do
    case "$1" in
        --local-host) LOCAL_HOST="$2"; shift 2 ;;
        --local-user) LOCAL_USER="$2"; shift 2 ;;
        --key)        KEY_PATH="$2";   shift 2 ;;
        -h|--help)
            grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "[clipsync] unknown arg: $1" >&2; exit 1 ;;
    esac
done

info() { printf '\033[36m[clipsync]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[clipsync]\033[0m %s\n' "$*"; }
fail() { printf '\033[31m[clipsync]\033[0m %s\n' "$*" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LUA_SRC="$SCRIPT_DIR/clipsync.lua"
[ -f "$LUA_SRC" ] || fail "clipsync.lua not found next to install-mac.sh ($LUA_SRC)"

case "$(uname -s)" in
    Darwin) : ;;
    *) fail "This installer is for macOS. Use install.ps1 on a Windows REMOTE." ;;
esac

# ---------------------------------------------------------------------------
# 1. Hammerspoon
# ---------------------------------------------------------------------------
if [ -d "/Applications/Hammerspoon.app" ] || [ -d "$HOME/Applications/Hammerspoon.app" ]; then
    info "Hammerspoon already installed."
elif command -v brew >/dev/null 2>&1; then
    info "Installing Hammerspoon via Homebrew..."
    brew install --cask hammerspoon
else
    warn "Hammerspoon is not installed and Homebrew was not found."
    warn "Download it (notarized, no admin needed) from https://www.hammerspoon.org"
    warn "drag Hammerspoon.app to ~/Applications, then re-run this script."
    fail "Hammerspoon required."
fi

# ---------------------------------------------------------------------------
# 2. Place clipsync.lua and require it from init.lua
# ---------------------------------------------------------------------------
HS_DIR="$HOME/.hammerspoon"
mkdir -p "$HS_DIR"
cp -f "$LUA_SRC" "$HS_DIR/clipsync.lua"
info "Installed $HS_DIR/clipsync.lua"

INIT="$HS_DIR/init.lua"
touch "$INIT"
if ! grep -q 'require("clipsync")' "$INIT" 2>/dev/null; then
    printf '\nrequire("clipsync")\n' >> "$INIT"
    info "Added require(\"clipsync\") to init.lua"
else
    info "init.lua already requires clipsync."
fi

# ---------------------------------------------------------------------------
# 3. SSH key
# ---------------------------------------------------------------------------
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
if [ ! -f "$KEY_PATH" ]; then
    info "Generating SSH key at $KEY_PATH ..."
    ssh-keygen -t ed25519 -f "$KEY_PATH" -N "" -C "clipsync-$(hostname -s)"
fi
PUBKEY="$(cat "${KEY_PATH}.pub")"

# ---------------------------------------------------------------------------
# 4. ssh config 'clipsync-local' alias
# ---------------------------------------------------------------------------
SSH_CONF="$HOME/.ssh/config"
touch "$SSH_CONF"; chmod 600 "$SSH_CONF"
if grep -qiE '^[[:space:]]*Host[[:space:]]+clipsync-local([[:space:]]|$)' "$SSH_CONF"; then
    info "ssh config already has a 'clipsync-local' alias - leaving it alone."
elif [ -z "$LOCAL_HOST" ]; then
    warn "No --local-host given; skipping ssh config."
    warn "Add a 'Host clipsync-local' block to $SSH_CONF pointing at LOCAL's LAN IP,"
    warn "User $LOCAL_USER, IdentityFile $KEY_PATH."
else
    {
        printf '\nHost clipsync-local\n'
        printf '    HostName %s\n' "$LOCAL_HOST"
        printf '    User %s\n' "$LOCAL_USER"
        printf '    IdentityFile %s\n' "$KEY_PATH"
        printf '    IdentitiesOnly yes\n'
    } >> "$SSH_CONF"
    info "Appended 'clipsync-local' alias to $SSH_CONF"
fi

# ---------------------------------------------------------------------------
# 5. Authorize this key on LOCAL (instructions)
# ---------------------------------------------------------------------------
echo ""
info "Authorize THIS Mac's public key on the Windows LOCAL machine. In an"
info "ELEVATED PowerShell on LOCAL, run (from the clipsync folder):"
echo ""
echo "    powershell -File .\\setup-ssh-account.ps1 -AddKeyOnly $PUBKEY"
echo ""

# ---------------------------------------------------------------------------
# 6. Accessibility reminder + reload Hammerspoon config
# ---------------------------------------------------------------------------
warn "Grant Hammerspoon Accessibility permission (required for hotkeys + paste):"
warn "  System Settings -> Privacy & Security -> Accessibility -> enable Hammerspoon."
open -a Hammerspoon >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
# 7. Smoke test the bridge (only meaningful once the key is authorized on LOCAL)
# ---------------------------------------------------------------------------
if grep -qiE '^[[:space:]]*Host[[:space:]]+clipsync-local([[:space:]]|$)' "$SSH_CONF"; then
    info "Testing the bridge via SSH (5s timeout)..."
    if out="$(ssh -o BatchMode=yes -o ConnectTimeout=5 clipsync-local \
              'curl.exe -s -m 5 http://127.0.0.1:8765/ping' 2>/dev/null)" \
       && [ "$out" = "pong" ]; then
        info "Bridge OK - LOCAL is reachable. clipsync is ready."
    else
        warn "Bridge ping failed. This is expected until you:"
        warn "  1. authorize this Mac's key on LOCAL (step 5), and"
        warn "  2. have the bridge running on LOCAL (install-local.ps1)."
    fi
fi

echo ""
info "Done. Hotkeys (adjust in clipsync.lua if Chrome Remote Desktop won't forward them):"
info "  Ctrl+Alt+Cmd+V  pull LOCAL clipboard onto this Mac"
info "  Ctrl+Alt+Cmd+C  push this Mac's clipboard/Finder selection onto LOCAL"
