#!/bin/bash
# deploy.sh - one-command Mac setup/update from a thumb drive (or any folder)
#
# Make the drive once:
#   1. Copy this whole repo folder onto the drive
#   2. Create secrets.env next to this script (never committed - gitignored):
#        TS_AUTHKEY=tskey-auth-...
#        BB_ADMIN_PUBKEY="ssh-ed25519 AAAA... joe"
#
# On each Mac:
#   sudo bash "/Volumes/<DRIVE NAME>/bb-headless/deploy.sh"
#
# What it does, in order:
#   1. Copies the repo from the drive to ~/bb-headless of the invoking user
#      (secrets.env stays on the drive, never lands on the Mac)
#   2. install.sh          - install/update headless BB for every configured user
#   3. bb-metrics.sh       - install the hourly health logger
#   4. bb-remote-admin.sh  - remote admin (skipped with a warning if secrets.env
#                            is missing; everything else still runs)
#
# Idempotent - same command updates an already-configured Mac.

set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"

[ "$(id -u)" -eq 0 ] || { echo "ERROR: run with sudo: sudo bash $0"; exit 1; }

TARGET_USER="${SUDO_USER:-}"
[ -n "$TARGET_USER" ] || { echo "ERROR: could not determine invoking user (run via sudo, not as root shell)"; exit 1; }
HOME_DIR="$(dscl . -read "/Users/$TARGET_USER" NFSHomeDirectory | awk '{print $2}')"
DEST="$HOME_DIR/bb-headless"

echo "== Copying repo to $DEST =="
mkdir -p "$DEST"
rsync -a --delete --exclude secrets.env "$SRC/" "$DEST/"
chown -R "$TARGET_USER":staff "$DEST"

if [ -f "$SRC/secrets.env" ]; then
    # shellcheck disable=SC1091
    set -a; . "$SRC/secrets.env"; set +a
    echo "== Loaded secrets.env from drive =="
fi

echo "== install.sh =="
bash "$DEST/install.sh"

echo "== bb-metrics install =="
bash "$DEST/bb-metrics.sh" install

# No secrets required: without TS_AUTHKEY, the Tailscale step prints a login
# URL - open it on a signed-in phone and tap Approve.
echo "== bb-remote-admin =="
bash "$DEST/bb-remote-admin.sh"

echo ""
echo "== deploy.sh done =="
echo "Reminders:"
echo " - Brand-new Mac: each BB account needs its one-time BlueBubbles config"
echo "   (own port + Firebase) before install.sh will deploy for it. Re-run after."
echo " - If the SSH step was skipped: grant Full Disk Access to Terminal"
echo "   (System Settings > Privacy & Security > Full Disk Access), re-run."
