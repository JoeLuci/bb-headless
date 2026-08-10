#!/bin/bash
# Remove bb-autologin from this Mac completely.
# Run: sudo bash /Users/Shared/bb-headless/uninstall-autologin.sh

set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "ERROR: must run as root (use sudo)"; exit 1; }

echo "=== Removing bb-autologin ==="

# Stop and remove LaunchDaemons
for label in com.local.bb-autologin-watchdog com.local.bb-autologin; do
    launchctl bootout "system/$label" 2>/dev/null && echo "Stopped $label" || true
    rm -f "/Library/LaunchDaemons/${label}.plist" && echo "Removed ${label}.plist" || true
done

# Remove installed files
if [ -d "/usr/local/lib/bb-autologin" ]; then
    rm -rf /usr/local/lib/bb-autologin
    echo "Removed /usr/local/lib/bb-autologin/"
fi

# Remove rollout folder if present
if [ -d "/Users/Shared/bb-autologin-rollout" ]; then
    rm -rf /Users/Shared/bb-autologin-rollout
    echo "Removed /Users/Shared/bb-autologin-rollout/"
fi

# Remove log
rm -f /var/log/bb-autologin.log 2>/dev/null && echo "Removed log" || true

echo ""
echo "=== Done. bb-autologin fully removed. ==="
