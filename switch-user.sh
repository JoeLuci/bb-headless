#!/bin/bash
# Switch the CURRENT logged-in user from Electron BB to headless BB.
# Run this from within each user's login session:
#   bash /Users/Shared/bb-headless/switch-user.sh
#
# No sudo needed. No arguments needed. It figures out who you are.

set -euo pipefail

# NEVER run this with sudo. As root it reads root's config.db (not yours) and
# leaves an orphaned server attached to whichever user's Messages data it finds.
if [ "$(id -u)" -eq 0 ]; then
    echo "ERROR: do not run this with sudo."
    echo "Run it as yourself, from your own login:"
    echo "  bash /Users/Shared/bb-headless/switch-user.sh"
    echo "(Only install.sh needs sudo.)"
    exit 1
fi

USER_NAME="$(whoami)"
BB_SERVER="/usr/local/lib/bb-headless/bluebubbles-server/packages/server"
HEADLESS="$BB_SERVER/dist/headless.js"

# Log into the user's own Library — /var/log is root-owned, so writing there is
# what used to make this script look like it needed sudo.
LOG_DIR="$HOME/Library/Logs"
LOG="$LOG_DIR/bb-headless.log"
mkdir -p "$LOG_DIR"

# Prefer the system-wide node the installer places at /usr/local/bin/node.
NODE_BIN=""
for candidate in \
    "/usr/local/bin/node" \
    "/usr/local/lib/nodejs/bin/node" \
    "/opt/homebrew/bin/node" \
    "$(command -v node 2>/dev/null || true)"
do
    if [ -n "$candidate" ] && [ -x "$candidate" ]; then
        NODE_BIN="$candidate"
        break
    fi
done

echo "=== Switching $USER_NAME to headless BlueBubbles ==="

# Check headless.js exists
if [ ! -f "$HEADLESS" ]; then
    echo "ERROR: headless.js not found at $HEADLESS"
    echo "Run 'sudo bash /Users/Shared/bb-headless/install.sh' first from any user."
    exit 1
fi

# Check node exists
if [ -z "$NODE_BIN" ]; then
    echo "ERROR: node not found."
    echo "Run 'sudo bash /Users/Shared/bb-headless/install.sh' — it installs Node system-wide."
    exit 1
fi

# Check config.db exists
CONFIG_DB="$HOME/Library/Application Support/bluebubbles-server/config.db"
if [ ! -f "$CONFIG_DB" ]; then
    echo "ERROR: No BlueBubbles config found for $USER_NAME."
    echo "Set up BlueBubbles with the Electron app first, then run this."
    exit 1
fi

PORT=$(sqlite3 "$CONFIG_DB" "SELECT value FROM config WHERE name='socket_port'" 2>/dev/null || echo "unknown")
SERVER=$(sqlite3 "$CONFIG_DB" "SELECT value FROM config WHERE name='server_address'" 2>/dev/null || echo "unknown")
echo "  Port: $PORT"
echo "  Server: $SERVER"

# Stop Electron BB. This MUST succeed — Electron holds the same port the
# headless server needs to bind, so leaving it running silently breaks the
# switch. Escalate: graceful quit -> TERM -> KILL, verifying after each.
electron_running() {
    pgrep -u "$USER_NAME" -f "BlueBubbles.app" >/dev/null 2>&1
}

wait_for_exit() {
    local tries=$1 i
    for ((i = 0; i < tries; i++)); do
        electron_running || return 0
        sleep 1
    done
    return 1
}

if electron_running; then
    echo "  Stopping Electron BlueBubbles..."

    # 1. Ask it to quit properly, so Electron can shut down its own subprocesses.
    osascript -e 'tell application "BlueBubbles" to quit' >/dev/null 2>&1 || true
    wait_for_exit 10 || {
        # 2. SIGTERM (also catches Electron helper processes).
        echo "  Not responding — sending TERM..."
        pkill -u "$USER_NAME" -f "BlueBubbles.app" 2>/dev/null || true
        wait_for_exit 10 || {
            # 3. SIGKILL.
            echo "  Still running — sending KILL..."
            pkill -9 -u "$USER_NAME" -f "BlueBubbles.app" 2>/dev/null || true
            wait_for_exit 5 || true
        }
    }

    if electron_running; then
        echo ""
        echo "ERROR: could not stop Electron BlueBubbles."
        echo "Quit it manually (BlueBubbles > Quit, or force-quit), then re-run."
        echo "Not starting headless — it would fail to bind port $PORT."
        exit 1
    fi
    echo "  Electron stopped."
fi

# Kill any existing headless
if pgrep -u "$USER_NAME" -f "node.*headless" >/dev/null 2>&1; then
    echo "  Stopping existing headless..."
    pkill -u "$USER_NAME" -f "node.*headless" 2>/dev/null || true
    sleep 1
fi

# Start headless
echo "  Starting headless BlueBubbles..."
cd "$BB_SERVER"
nohup "$NODE_BIN" "$HEADLESS" >> "$LOG" 2>&1 &
BBPID=$!
echo "  PID: $BBPID"

# Verify: the process must be alive AND actually listening on its port.
# A bare liveness check passes even when the server died on a bind conflict.
listening() {
    [ "$PORT" = "unknown" ] && return 0   # can't check; fall back to liveness
    lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1
}

OK=false
for ((i = 0; i < 30; i++)); do
    if ! kill -0 "$BBPID" 2>/dev/null; then
        break                              # died — stop waiting
    fi
    if listening; then
        OK=true
        break
    fi
    sleep 1
done

if $OK; then
    echo ""
    echo "=== SUCCESS ==="
    echo "$USER_NAME is now running headless BlueBubbles (PID $BBPID, port $PORT)"
    echo "Logs: tail -f $LOG"
    echo ""
    echo "To revert: pkill -u \$(whoami) -f 'node.*headless' && open -a BlueBubbles"
    echo ""
    echo "NOTE: this run does not survive logout or reboot."
    echo "For that, use: sudo bash /Users/Shared/bb-headless/install.sh"
else
    echo ""
    echo "=== FAILED — reverting to Electron ==="
    if kill -0 "$BBPID" 2>/dev/null; then
        echo "Server started but never listened on port $PORT — stopping it."
        kill "$BBPID" 2>/dev/null || true
    else
        echo "Server exited on startup."
    fi
    open -a BlueBubbles
    echo "Check log: tail -50 $LOG"
    exit 1
fi
