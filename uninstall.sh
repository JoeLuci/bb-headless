#!/bin/bash
# Revert all users back to Electron BlueBubbles
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "ERROR: must run as root (use sudo)"; exit 1; }

echo "=== Reverting to Electron BlueBubbles ==="

while IFS= read -r user; do
    [ -n "$user" ] || continue
    uid=$(id -u "$user" 2>/dev/null) || continue
    home=$(dscl . -read /Users/"$user" NFSHomeDirectory 2>/dev/null | awk '{print $2}')
    [ -d "$home" ] || continue

    plist="$home/Library/LaunchAgents/com.bb-headless.server.plist"
    [ -f "$plist" ] || continue

    echo "Reverting $user..."

    # Stop headless
    launchctl bootout "gui/$uid/com.bb-headless.server" 2>/dev/null || true
    sudo -u "$user" pkill -f "node.*headless" 2>/dev/null || true
    rm -f "$plist"

    # Re-enable Electron LaunchAgent if it was disabled
    electron_agent="$home/Library/LaunchAgents/com.bluebubbles.server.plist.disabled"
    if [ -f "$electron_agent" ]; then
        mv "$electron_agent" "${electron_agent%.disabled}"
        echo "  Re-enabled Electron LaunchAgent"
    fi

    # Start Electron BB
    sudo -u "$user" open -a BlueBubbles 2>/dev/null || true
    echo "  $user: reverted to Electron"

done < <(dscl . -list /Users UniqueID 2>/dev/null | awk '$2 >= 501 && $2 < 4294967294 {print $1}' | grep -v '^_')

echo "=== Done ==="
