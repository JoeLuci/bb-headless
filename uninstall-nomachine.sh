#!/bin/bash
# Remove NoMachine from this Mac completely.
# Run: sudo bash /Users/Shared/bb-headless/uninstall-nomachine.sh
#
# For boxes that had NoMachine installed but now use RustDesk - it frees the
# ~0.7-1.3 GB the nxnode/nxrunner processes hold per box. Reports only what
# was there; exits 0 on a Mac that never had it.
#
# NoMachine's own nxuninstall.sh hands the work to a launchd job and returns
# at once, so we wait for it, then finish the job by hand.
set -uo pipefail
[ "$(id -u)" -eq 0 ] || { echo "ERROR: must run as root (use sudo)"; exit 1; }

NM_APP="/Applications/NoMachine.app"
NM_UNINSTALL="/Library/Application Support/NoMachine/nxuninstall.sh"
nm_here() { [ -d "$NM_APP" ] || [ -x /etc/NX/nxserver ] || [ -f /Library/LaunchDaemons/com.nomachine.server.plist ]; }

echo "=== Removing NoMachine ==="
if ! nm_here; then
    echo "=== Nothing to do - NoMachine was not on this Mac. ==="
    exit 0
fi

[ -x "$NM_UNINSTALL" ] && "$NM_UNINSTALL" >/dev/null 2>&1 || true
for _ in $(seq 1 30); do nm_here || break; sleep 2; done

if nm_here; then
    echo "nxuninstall.sh did not finish - removing the rest by hand"
    for job in com.nomachine.localnxserver com.nomachine.nxlaunchconf com.nomachine.nxnode \
               com.nomachine.nxplayer com.nomachine.nxrunner com.nomachine.nxserver \
               com.nomachine.server com.nomachine.uninstall com.nomachine.uninstallAgent; do
        launchctl bootout "system/$job" 2>/dev/null || true
        rm -f "/Library/LaunchDaemons/$job.plist" "/Library/LaunchAgents/$job.plist"
    done
    pkill -f "NoMachine.app" 2>/dev/null || true
    pkill -x nxd 2>/dev/null || true
    pkill -f "nxserver" 2>/dev/null || true
    sleep 2
    rm -rf "$NM_APP" "/Library/Application Support/NoMachine" /etc/NX
    for r in $(pkgutil --pkgs 2>/dev/null | grep -i nomachine); do pkgutil --forget "$r" >/dev/null 2>&1 || true; done
fi

if nm_here; then
    echo "WARNING: NoMachine still present - remove $NM_APP by hand."
    exit 1
fi
echo "=== Done. NoMachine fully removed. ==="
