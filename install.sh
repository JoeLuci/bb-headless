#!/bin/bash
# bb-headless installer
# Clones BlueBubbles, patches for headless, builds, and deploys per-user.
#
# Usage:
#   sudo bash install.sh              # Install/update on this Mac
#   sudo bash install.sh --build-only # Just rebuild, don't deploy
#   sudo bash install.sh --deploy-only # Just deploy (skip build)
#
# Each user's existing config.db (port, server_address, webhooks, password)
# is preserved — headless reads the same config as Electron.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_DIR="/usr/local/lib/bb-headless"
BB_REPO="$INSTALL_DIR/bluebubbles-server"
BB_SERVER="$BB_REPO/packages/server"
LOG="/var/log/bb-headless-install.log"
NODE_BIN="$(which node 2>/dev/null || echo "/usr/local/bin/node")"

BUILD_ONLY=false
DEPLOY_ONLY=false
for arg in "$@"; do
    case "$arg" in
        --build-only) BUILD_ONLY=true ;;
        --deploy-only) DEPLOY_ONLY=true ;;
    esac
done

log() { echo "$(date '+%H:%M:%S') $*" | tee -a "$LOG"; }

[ "$(id -u)" -eq 0 ] || { echo "ERROR: must run as root (use sudo)"; exit 1; }
[ -x "$NODE_BIN" ] || { echo "ERROR: node not found. Install Node.js first."; exit 1; }

log "=== bb-headless installer ==="
log "Node: $($NODE_BIN --version)"
mkdir -p "$INSTALL_DIR"

# ── 1. Clone or update BlueBubbles ────────────────────────────────────────────
clone_or_update() {
    if [ -d "$BB_REPO/.git" ]; then
        log "[1/5] Updating BlueBubbles source..."
        cd "$BB_REPO" && git pull --ff-only 2>&1 | tail -3 | tee -a "$LOG"
    else
        log "[1/5] Cloning BlueBubbles source..."
        git clone https://github.com/BlueBubblesApp/bluebubbles-server.git "$BB_REPO" 2>&1 | tail -3 | tee -a "$LOG"
    fi
}

# ── 2. Patch for headless ─────────────────────────────────────────────────────
apply_patches() {
    log "[2/5] Applying headless patches..."

    # Copy our headless files into the BB source
    cp "$SCRIPT_DIR/src/headless.ts" "$BB_SERVER/src/headless.ts"
    cp "$SCRIPT_DIR/src/electron-shim.ts" "$BB_SERVER/src/electron-shim.ts"
    cp "$SCRIPT_DIR/src/webpack.headless.config.js" "$BB_SERVER/scripts/webpack.headless.config.js"

    # Remove devEngines (breaks npm on newer Node)
    cd "$BB_REPO"
    if grep -q '"devEngines"' package.json; then
        "$NODE_BIN" -e "
            const fs = require('fs');
            const pkg = JSON.parse(fs.readFileSync('package.json', 'utf8'));
            delete pkg.devEngines;
            fs.writeFileSync('package.json', JSON.stringify(pkg, null, 4) + '\n');
        "
        log "  Removed devEngines from root package.json"
    fi

    log "  Patches applied"
}

# ── 3. Build ──────────────────────────────────────────────────────────────────
build_headless() {
    log "[3/5] Building headless server..."
    cd "$BB_SERVER"

    # Install deps without electron-rebuild
    log "  Installing dependencies..."
    npm install --ignore-scripts >> "$LOG" 2>&1
    (cd "$BB_REPO" && npm install --ignore-scripts >> "$LOG" 2>&1)

    # Rebuild native modules for system Node
    log "  Rebuilding native modules for Node.js..."
    npm install better-sqlite3@latest --no-save >> "$LOG" 2>&1
    npm rebuild node-mac-contacts >> "$LOG" 2>&1 || true
    npm rebuild node-mac-permissions >> "$LOG" 2>&1 || true

    # Create runtime electron shim (for electron-log and other runtime requires)
    for SHIM_LOC in "$BB_REPO/node_modules/electron" "$BB_SERVER/node_modules/electron"; do
        mkdir -p "$SHIM_LOC"
        cp "$SCRIPT_DIR/src/electron-runtime-shim.js" "$SHIM_LOC/index.js"
        echo '{"name":"electron","version":"0.0.0-headless-shim","main":"index.js"}' > "$SHIM_LOC/package.json"
    done

    # Build with webpack
    log "  Running webpack..."
    npx webpack --config ./scripts/webpack.headless.config.js >> "$LOG" 2>&1

    # Copy Private API dylib from installed Electron app
    if [ -d "/Applications/BlueBubbles.app/Contents/Resources/appResources" ]; then
        cp -R /Applications/BlueBubbles.app/Contents/Resources/appResources "$BB_SERVER/dist/"
        log "  Copied Private API resources from BlueBubbles.app"
    else
        log "  WARNING: BlueBubbles.app not found — Private API will not work"
    fi

    log "  Build complete: $BB_SERVER/dist/headless.js"
}

# ── 4. Detect users and deploy ────────────────────────────────────────────────
deploy_per_user() {
    log "[4/5] Deploying per-user LaunchAgents..."

    # Find all real users (UID >= 501)
    local users=()
    while IFS= read -r u; do
        [ -n "$u" ] && users+=("$u")
    done < <(dscl . -list /Users UniqueID 2>/dev/null | awk '$2 >= 501 && $2 < 4294967294 {print $1}' | grep -v '^_')

    log "  Found users: ${users[*]}"

    for user in "${users[@]}"; do
        local uid
        uid=$(id -u "$user" 2>/dev/null) || continue
        local home
        home=$(dscl . -read /Users/"$user" NFSHomeDirectory 2>/dev/null | awk '{print $2}')
        [ -d "$home" ] || continue

        local config_db="$home/Library/Application Support/bluebubbles-server/config.db"
        if [ ! -f "$config_db" ]; then
            log "  $user: no config.db found, skipping (BB not set up for this user)"
            continue
        fi

        # Read port from config
        local port
        port=$(sqlite3 "$config_db" "SELECT value FROM config WHERE name='socket_port'" 2>/dev/null || echo "unknown")
        local server_addr
        server_addr=$(sqlite3 "$config_db" "SELECT value FROM config WHERE name='server_address'" 2>/dev/null || echo "unknown")

        log "  $user: port=$port, server=$server_addr"

        # Create LaunchAgent
        local agent_dir="$home/Library/LaunchAgents"
        local plist_path="$agent_dir/com.bb-headless.server.plist"
        mkdir -p "$agent_dir"

        cat > "$plist_path" << PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.bb-headless.server</string>
    <key>ProgramArguments</key>
    <array>
        <string>$NODE_BIN</string>
        <string>$BB_SERVER/dist/headless.js</string>
    </array>
    <key>WorkingDirectory</key>
    <string>$BB_SERVER</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
        <key>Crashed</key>
        <true/>
    </dict>
    <key>StandardOutPath</key>
    <string>/var/log/bb-headless-$user.log</string>
    <key>StandardErrorPath</key>
    <string>/var/log/bb-headless-$user.log</string>
    <key>ProcessType</key>
    <string>Background</string>
    <key>ThrottleInterval</key>
    <integer>10</integer>
</dict>
</plist>
PLISTEOF

        chown "$user:staff" "$plist_path"
        chmod 644 "$plist_path"
        log "  $user: LaunchAgent installed"
    done
}

# ── 5. Switch from Electron to headless ───────────────────────────────────────
activate_headless() {
    log "[5/5] Activating headless for all configured users..."

    local users=()
    while IFS= read -r u; do
        [ -n "$u" ] && users+=("$u")
    done < <(dscl . -list /Users UniqueID 2>/dev/null | awk '$2 >= 501 && $2 < 4294967294 {print $1}' | grep -v '^_')

    for user in "${users[@]}"; do
        local uid
        uid=$(id -u "$user" 2>/dev/null) || continue
        local home
        home=$(dscl . -read /Users/"$user" NFSHomeDirectory 2>/dev/null | awk '{print $2}')
        local plist_path="$home/Library/LaunchAgents/com.bb-headless.server.plist"
        [ -f "$plist_path" ] || continue

        # Stop Electron BlueBubbles for this user
        local electron_pids
        electron_pids=$(pgrep -u "$user" -f "BlueBubbles.app" 2>/dev/null || true)
        if [ -n "$electron_pids" ]; then
            log "  $user: stopping Electron BlueBubbles..."
            sudo -u "$user" pkill -f "BlueBubbles.app" 2>/dev/null || true
            sleep 2
        fi

        # Disable Electron auto-start (LoginItem)
        # Remove Electron LaunchAgent if present
        local electron_agent="$home/Library/LaunchAgents/com.bluebubbles.server.plist"
        if [ -f "$electron_agent" ]; then
            launchctl bootout "gui/$uid/com.bluebubbles.server" 2>/dev/null || true
            mv "$electron_agent" "$electron_agent.disabled" 2>/dev/null || true
            log "  $user: disabled Electron LaunchAgent"
        fi

        # Load headless LaunchAgent
        launchctl bootout "gui/$uid/com.bb-headless.server" 2>/dev/null || true
        if launchctl bootstrap "gui/$uid" "$plist_path" 2>/dev/null; then
            log "  $user: headless server STARTED"
        else
            launchctl load -w "$plist_path" 2>/dev/null && log "  $user: headless server STARTED (legacy)" || \
                log "  $user: WARNING — failed to start LaunchAgent"
        fi

        # Verify it's running
        sleep 3
        if pgrep -u "$user" -f "node.*headless" >/dev/null 2>&1; then
            local pid
            pid=$(pgrep -u "$user" -f "node.*headless" | head -1)
            log "  $user: RUNNING (PID $pid)"
        else
            log "  $user: NOT RUNNING — check /var/log/bb-headless-$user.log"
        fi
    done
}

# ── Main ──────────────────────────────────────────────────────────────────────
if ! $DEPLOY_ONLY; then
    clone_or_update
    apply_patches
    build_headless
fi

if ! $BUILD_ONLY; then
    deploy_per_user
    activate_headless
fi

log ""
log "=== Done ==="
log "Logs per user: /var/log/bb-headless-<user>.log"
log "To revert a user to Electron: sudo -u <user> pkill -f 'node.*headless' && sudo -u <user> open -a BlueBubbles"
log "To update: cd $(pwd) && git pull && sudo bash install.sh"
