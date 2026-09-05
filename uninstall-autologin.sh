#!/bin/bash
# Remove bb-autologin from this Mac completely.
# Run: sudo bash /Users/Shared/bb-headless/uninstall-autologin.sh

set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "ERROR: must run as root (use sudo)"; exit 1; }

echo "=== Removing bb-autologin ==="

# Stop and remove LaunchDaemons. Only report what was actually there - this now
# runs on every Mac from setup.sh, including ones that never had bb-autologin.
FOUND=0
for label in com.local.bb-autologin-watchdog com.local.bb-autologin; do
    if launchctl bootout "system/$label" 2>/dev/null; then
        echo "Stopped $label"
        FOUND=1
    fi
    if [ -f "/Library/LaunchDaemons/${label}.plist" ]; then
        rm -f "/Library/LaunchDaemons/${label}.plist"
        echo "Removed ${label}.plist"
        FOUND=1
    fi
done

# Remove installed files
if [ -d "/usr/local/lib/bb-autologin" ]; then
    rm -rf /usr/local/lib/bb-autologin
    echo "Removed /usr/local/lib/bb-autologin/"
    FOUND=1
fi

# Remove rollout folder if present
if [ -d "/Users/Shared/bb-autologin-rollout" ]; then
    rm -rf /Users/Shared/bb-autologin-rollout
    echo "Removed /Users/Shared/bb-autologin-rollout/"
    FOUND=1
fi

# Remove log
if [ -f /var/log/bb-autologin.log ]; then
    rm -f /var/log/bb-autologin.log
    echo "Removed /var/log/bb-autologin.log"
    FOUND=1
fi

echo ""
if [ "$FOUND" -eq 1 ]; then
    echo "=== Done. bb-autologin fully removed. ==="
else
    echo "=== Nothing to do - bb-autologin was not on this Mac. ==="
fi
