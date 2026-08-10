#!/bin/bash
# Switch the CURRENT logged-in user from Electron BB to headless BB.
# Run this from within each user's login session:
#   bash /Users/Shared/bb-headless/switch-user.sh
#
# No sudo needed. No arguments needed. It figures out who you are.

set -euo pipefail

USER_NAME="$(whoami)"
BB_SERVER="/usr/local/lib/bb-headless/bluebubbles-server/packages/server"
HEADLESS="$BB_SERVER/dist/headless.js"
NODE_BIN="$(which node 2>/dev/null || echo "/usr/local/bin/node")"
LOG="/var/log/bb-headless-$USER_NAME.log"

echo "=== Switching $USER_NAME to headless BlueBubbles ==="

# Check headless.js exists
if [ ! -f "$HEADLESS" ]; then
    echo "ERROR: headless.js not found at $HEADLESS"
    echo "Run 'sudo bash /Users/Shared/bb-headless/install.sh --build-only' first from any user."
    exit 1
fi

# Check node exists
if [ ! -x "$NODE_BIN" ]; then
    echo "ERROR: node not found. Install Node.js first."
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

# Kill Electron BB
if pgrep -u "$USER_NAME" -f "BlueBubbles.app" >/dev/null 2>&1; then
    echo "  Stopping Electron BlueBubbles..."
    pkill -f "BlueBubbles.app" 2>/dev/null || true
    sleep 2
fi

# Kill any existing headless
if pgrep -u "$USER_NAME" -f "node.*headless" >/dev/null 2>&1; then
    echo "  Stopping existing headless..."
    pkill -f "node.*headless" 2>/dev/null || true
    sleep 1
fi

# Start headless
echo "  Starting headless BlueBubbles..."
cd "$BB_SERVER"
nohup "$NODE_BIN" "$HEADLESS" >> "$LOG" 2>&1 &
BBPID=$!
echo "  PID: $BBPID"

sleep 5

# Verify
if kill -0 $BBPID 2>/dev/null; then
    echo ""
    echo "=== SUCCESS ==="
    echo "$USER_NAME is now running headless BlueBubbles (PID $BBPID)"
    echo "Logs: tail -f $LOG"
    echo ""
    echo "To revert: pkill -f 'node.*headless' && open -a BlueBubbles"
else
    echo ""
    echo "=== FAILED — reverting to Electron ==="
    open -a BlueBubbles
    echo "Check log: cat $LOG"
fi
