#!/bin/bash
# Remove Tailscale from this Mac completely.
# Run: sudo bash /Users/Shared/bb-headless/uninstall-tailscale.sh
#
# Removes, in order: the tailnet registration, the system daemon and its plist,
# the binary `tailscaled install-system-daemon` copied into /usr/local/bin, the
# Homebrew keg, the state directory, and the App Store app if one is present.
#
# WARNING: if you are reaching this Mac over the tailnet, this cuts the
# connection you are using. Have another way in first (LAN IP, NoMachine).
#
# The node also stays listed in the Tailscale admin console until you delete it
# there - logout deregisters the machine but does not remove the record.

set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "ERROR: must run as root (use sudo)"; exit 1; }

echo "=== Removing Tailscale ==="

# Homebrew symlinks the CLI into its own prefix; install-system-daemon copies
# the daemon to /usr/local/bin. Look in both places for both binaries.
find_bin() {
    local name="$1" c
    for c in "/usr/local/bin/$name" "/opt/homebrew/bin/$name"; do
        if [ -x "$c" ]; then printf '%s' "$c"; return 0; fi
    done
    return 1
}

TS_CLI="$(find_bin tailscale || true)"
TS_DAEMON="$(find_bin tailscaled || true)"

if [ -n "$TS_CLI" ]; then
    "$TS_CLI" down >/dev/null 2>&1 || true
    if "$TS_CLI" logout >/dev/null 2>&1; then
        echo "Logged out of the tailnet"
    else
        echo "Not logged in (or already gone)"
    fi
else
    echo "No tailscale CLI found"
fi

if [ -n "$TS_DAEMON" ]; then
    if "$TS_DAEMON" uninstall-system-daemon >/dev/null 2>&1; then
        echo "Uninstalled the system daemon"
    fi
fi
launchctl bootout system/com.tailscale.tailscaled 2>/dev/null || true
if [ -f /Library/LaunchDaemons/com.tailscale.tailscaled.plist ]; then
    rm -f /Library/LaunchDaemons/com.tailscale.tailscaled.plist
    echo "Removed com.tailscale.tailscaled.plist"
fi

# brew refuses to run as root; run it as whoever owns the prefix.
BREW_PREFIX="/usr/local"
if [ -x /opt/homebrew/bin/brew ]; then BREW_PREFIX="/opt/homebrew"; fi
BREW="$BREW_PREFIX/bin/brew"
if [ -x "$BREW" ]; then
    BREW_OWNER="$(stat -f %Su "$BREW_PREFIX")"
    if sudo -u "$BREW_OWNER" -H "$BREW" list tailscale >/dev/null 2>&1; then
        sudo -u "$BREW_OWNER" -H "$BREW" uninstall --force tailscale >/dev/null 2>&1 \
            && echo "Uninstalled the Homebrew keg" \
            || echo "WARNING: brew uninstall tailscale failed - remove it by hand"
    else
        echo "No Homebrew tailscale keg"
    fi
fi

# Leftovers: the daemon copy install-system-daemon made, the Homebrew symlinks
# if the keg removal above did not get to them, the control socket.
for f in /usr/local/bin/tailscaled /usr/local/bin/tailscale \
         /opt/homebrew/bin/tailscaled /opt/homebrew/bin/tailscale \
         /var/run/tailscaled.socket; do
    if [ -e "$f" ]; then rm -f "$f" && echo "Removed $f"; fi
done
if [ -d /Library/Tailscale ]; then
    rm -rf /Library/Tailscale
    echo "Removed /Library/Tailscale (state)"
fi
if [ -d /Applications/Tailscale.app ]; then
    rm -rf /Applications/Tailscale.app
    echo "Removed /Applications/Tailscale.app"
fi

echo ""
if pgrep -x tailscaled >/dev/null 2>&1; then
    echo "WARNING: a tailscaled process is still running - reboot to be sure."
else
    echo "=== Done. Tailscale fully removed. ==="
fi
if [ -n "$TS_CLI" ]; then
    echo "Remember to delete this machine in the Tailscale admin console."
fi
