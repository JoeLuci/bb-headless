#!/bin/bash
# setup.sh - one command to set up or update a BlueBubbles Mac mini.
#
#   curl -fsSL https://raw.githubusercontent.com/JoeLuci/bb-headless/main/setup.sh | sudo bash
#
# Same command whether the Mac is brand new or already running bb-headless:
# it clones or updates /Users/Shared/bb-headless, then runs
#   uninstall-autologin - removes the old bb-autologin system if it is present
#   install.sh          - headless BlueBubbles for every user with a config.db
#   bb-metrics.sh       - hourly health logger
#   bb-remote-admin.sh  - NoMachine, Screen Sharing fallback, SSH, lockdown,
#                         and Tailscale (the address that makes NoMachine
#                         reachable from outside the LAN)
# then installs the `bb-switch` and `bb-status` shortcuts, opens the two Privacy
# panes, and prints a per-user check of what actually took (`sudo bb-status`).
#
# This is the once-per-Mac half. Each user login still needs `bb-switch` run
# from inside it - cross-user LaunchAgent bootstrapping was tried and dropped
# as unreliable (see the switch-user.sh commit), so this does not attempt it.
#
# Options are env vars, passed through to the scripts below, e.g.
#   curl -fsSL <url> | sudo BB_DISABLE_SCREENSHARING=1 bash
#   curl -fsSL <url> | sudo BB_NM_LICENSE=/Volumes/DRIVE/server.lic bash
# or skip the flag entirely: put each Mac's key on the drive as
# bb-licenses/<hostname>.tar.gz and it is picked up by name - see below.
#
# For the VM Macs, which already have their own NoMachine and must not get
# Tailscale, one flag covers both:
#   curl -fsSL <url> | sudo BB_VM=1 bash
# It is shorthand for BB_NOMACHINE=0 BB_TAILSCALE=0 - neither is installed, and
# nothing already on the box is touched or removed. Set either explicitly to
# override.
#
# Prerequisites, in this order, or the run is wasted:
#   1. Each user login already set up in the BlueBubbles Electron app
#      (its config.db must exist) - logins without one are skipped.
#   2. Terminal has Full Disk Access, or the Remote Login step is skipped.

set -euo pipefail

REPO_URL="https://github.com/JoeLuci/bb-headless.git"
REPO_DIR="/Users/Shared/bb-headless"
BRANCH="${BB_BRANCH:-main}"

[ "$(id -u)" -eq 0 ] || { echo "ERROR: run with sudo, e.g. curl -fsSL <url> | sudo bash"; exit 1; }
command -v git >/dev/null 2>&1 || {
    echo "ERROR: git is missing. Run 'xcode-select --install', let it finish, then re-run this."
    exit 1
}

CONSOLE_USER="${SUDO_USER:-$(stat -f %Su /dev/console)}"

# VM Macs: they already have NoMachine, and they must not get Tailscale.
# 0 means "leave alone" for both - nothing is installed and nothing removed.
if [ "${BB_VM:-0}" = "1" ]; then
    export BB_NOMACHINE="${BB_NOMACHINE:-0}"
    export BB_TAILSCALE="${BB_TAILSCALE:-0}"
    echo "BB_VM=1: NoMachine and Tailscale steps disabled (nothing installed, nothing removed)"
fi

step() { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }

step "Repo -> $REPO_DIR"
# Always take a fresh clone rather than updating in place. The existing copy is
# owned by whichever admin made it, and a root `git fetch` into someone else's
# directory hits both "dubious ownership" and write-permission errors. It is a
# deploy copy - nothing here is worth preserving. Clone beside it first so a
# network failure cannot leave the Mac with no copy at all.
rm -rf "$REPO_DIR.new"
git clone --quiet --branch "$BRANCH" "$REPO_URL" "$REPO_DIR.new" \
    || { echo "ERROR: could not clone $REPO_URL - is the network up?"; exit 1; }
rm -rf "$REPO_DIR"
mv "$REPO_DIR.new" "$REPO_DIR"
echo "At $(git -C "$REPO_DIR" log --oneline -1)"
chmod -R a+rX "$REPO_DIR"

step "uninstall-autologin.sh (remove the old bb-autologin system)"
# Never a stopper: this is cleanup of a dead system, and failing it must not
# cost you the actual install below.
bash "$REPO_DIR/uninstall-autologin.sh" || echo "WARNING: bb-autologin cleanup failed - carrying on, run it by hand later"

step "install.sh (headless BlueBubbles)"
bash "$REPO_DIR/install.sh"

step "bb-metrics.sh (health logger)"
bash "$REPO_DIR/bb-metrics.sh" install

# NoMachine subscription keys are one-per-Mac and must not live in this public
# repo. If BB_NM_LICENSE is not given, look for a key named after this Mac on
# any plugged-in drive, then in /Users/Shared/bb-licenses. Name the file after
# the hostname exactly as `scutil --get LocalHostName` prints it:
#   bb-licenses/Viato-Phone-MM-AZ-08.tar.gz    (the key.tar.gz NoMachine issues)
#   bb-licenses/Viato-Phone-MM-AZ-08.lic       (a bare server.lic also works)
if [ -z "${BB_NM_LICENSE:-}" ] && [ "${BB_NOMACHINE:-1}" = "1" ]; then
    HOSTN="$(scutil --get LocalHostName 2>/dev/null || hostname -s)"
    for dir in /Volumes/*/bb-licenses /Users/Shared/bb-licenses; do
        [ -d "$dir" ] || continue
        for f in "$dir/$HOSTN.tar.gz" "$dir/$HOSTN.tgz" "$dir/$HOSTN.lic"; do
            if [ -f "$f" ]; then export BB_NM_LICENSE="$f"; break 2; fi
        done
    done
    if [ -n "${BB_NM_LICENSE:-}" ]; then
        echo "NoMachine key for $HOSTN: $BB_NM_LICENSE"
    else
        echo "No NoMachine key found for $HOSTN (looked in /Volumes/*/bb-licenses and /Users/Shared/bb-licenses)."
        echo "Without one the server refuses connections. Add bb-licenses/$HOSTN.tar.gz to the drive and re-run."
    fi
fi

step "bb-remote-admin.sh (NoMachine, SSH, lockdown)"
bash "$REPO_DIR/bb-remote-admin.sh"

# Short name so the per-user step is one word instead of a pasted path.
# switch-user.sh uses absolute paths throughout, so a symlink is safe.
mkdir -p /usr/local/bin
ln -sf "$REPO_DIR/switch-user.sh" /usr/local/bin/bb-switch
ln -sf "$REPO_DIR/bb-status.sh"   /usr/local/bin/bb-status
chmod +x "$REPO_DIR/switch-user.sh" "$REPO_DIR/bb-status.sh"
echo "Installed 'bb-switch' and 'bb-status'"

step "What is left to do by hand"
cat <<'TXT'
1. Fast User Switch into EACH user login, open Terminal, and run:

     bb-switch

   Ten seconds each. Run it as that user - never with sudo.

2. Tick NoMachine in BOTH Privacy panes (they are opening now):
     Screen & System Audio Recording
     Accessibility
   Nothing can grant these from a script - macOS does not allow it.

3. Restart the Mac, then log all five accounts back in.
TXT

# Only useful if someone is looking at a screen; harmless over SSH.
for pane in Privacy_ScreenCapture Privacy_Accessibility; do
    sudo -u "$CONSOLE_USER" open "x-apple.systempreferences:com.apple.preference.security?$pane" >/dev/null 2>&1 || true
    sleep 1
done

step "Checking what actually took"
bash "$REPO_DIR/bb-status.sh" || true
echo ""
echo "Re-run this check any time with:  sudo bb-status"

