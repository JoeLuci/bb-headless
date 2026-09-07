#!/bin/bash
# Remove RustDesk from this Mac completely.
# Run: sudo bash /Users/Shared/bb-headless/uninstall-rustdesk.sh
#
# RustDesk leaves a system LaunchDaemon (its service), a LaunchAgent in every
# login (its server/tray), the app bundle, and per-user config/cache. Reports
# only what was actually there; exits 0 on a Mac that never had it.

set -uo pipefail
[ "$(id -u)" -eq 0 ] || { echo "ERROR: must run as root (use sudo)"; exit 1; }

echo "=== Removing RustDesk ==="
FOUND=0

# Per-login agents: bootout from each user's gui domain before deleting.
USERS="$(dscl . -list /Users UniqueID 2>/dev/null | awk '$2 >= 501 && $2 < 4294967294 {print $1}' | grep -v '^_')"
for u in $USERS; do
    uid="$(id -u "$u" 2>/dev/null)" || continue
    for label in com.carriez.RustDesk_server com.carriez.RustDesk_service; do
        if launchctl bootout "gui/$uid/$label" 2>/dev/null; then echo "Stopped $label for $u"; FOUND=1; fi
    done
done
for label in com.carriez.RustDesk_service com.carriez.RustDesk_server; do
    if launchctl bootout "system/$label" 2>/dev/null; then echo "Stopped system $label"; FOUND=1; fi
done

for f in /Library/LaunchDaemons/com.carriez.*.plist /Library/LaunchAgents/com.carriez.*.plist; do
    if [ -f "$f" ]; then rm -f "$f"; echo "Removed $f"; FOUND=1; fi
done

if pgrep -fi rustdesk >/dev/null 2>&1; then
    pkill -fi rustdesk 2>/dev/null || true
    sleep 1
    pkill -9 -fi rustdesk 2>/dev/null || true
    echo "Killed RustDesk processes"
    FOUND=1
fi

if [ -d /Applications/RustDesk.app ]; then
    rm -rf /Applications/RustDesk.app
    echo "Removed /Applications/RustDesk.app"
    FOUND=1
fi

# Per-user leftovers: config, cache, logs.
for u in $USERS; do
    home="$(dscl . -read "/Users/$u" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
    [ -d "$home" ] || continue
    for d in "$home/Library/Preferences/com.carriez.RustDesk" \
             "$home/Library/Preferences/com.carriez.rustdesk" \
             "$home/Library/Caches/com.carriez.rustdesk" \
             "$home/Library/Application Support/com.carriez.rustdesk" \
             "$home/Library/Logs/RustDesk"; do
        if [ -e "$d" ]; then rm -rf "$d"; echo "Removed $d"; FOUND=1; fi
    done
    for f in "$home"/Library/Preferences/com.carriez.rustdesk*.plist "$home"/Library/LaunchAgents/com.carriez.*.plist; do
        if [ -f "$f" ]; then rm -f "$f"; echo "Removed $f"; FOUND=1; fi
    done
done

echo ""
if [ "$FOUND" -eq 1 ]; then
    echo "=== Done. RustDesk fully removed. ==="
else
    echo "=== Nothing to do - RustDesk was not on this Mac. ==="
fi
