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
#                         and removal of Tailscale
# then installs the `bb-switch` shortcut and opens the two Privacy panes.
#
# This is the once-per-Mac half. Each user login still needs `bb-switch` run
# from inside it - cross-user LaunchAgent bootstrapping was tried and dropped
# as unreliable (see the switch-user.sh commit), so this does not attempt it.
#
# Options are env vars, passed through to the scripts below, e.g.
#   curl -fsSL <url> | sudo BB_DISABLE_SCREENSHARING=1 bash
#   curl -fsSL <url> | sudo BB_NM_LICENSE=/Volumes/DRIVE/server.lic bash
#
# On a Mac that already has its own NoMachine - the VMs - skip that step so the
# existing install and its live sessions are left alone:
#   curl -fsSL <url> | sudo BB_NOMACHINE=0 bash
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
bash "$REPO_DIR/uninstall-autologin.sh"

step "install.sh (headless BlueBubbles)"
bash "$REPO_DIR/install.sh"

step "bb-metrics.sh (health logger)"
bash "$REPO_DIR/bb-metrics.sh" install

step "bb-remote-admin.sh (NoMachine, SSH, lockdown)"
bash "$REPO_DIR/bb-remote-admin.sh"

# Short name so the per-user step is one word instead of a pasted path.
# switch-user.sh uses absolute paths throughout, so a symlink is safe.
mkdir -p /usr/local/bin
ln -sf "$REPO_DIR/switch-user.sh" /usr/local/bin/bb-switch
chmod +x "$REPO_DIR/switch-user.sh"
echo "Installed 'bb-switch' -> $REPO_DIR/switch-user.sh"

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

echo ""
echo "Verify BlueBubbles:"
echo '  for u in m01 m02 m03 m04 m05; do pgrep -u $u -f "node.*headless" >/dev/null && echo "$u ok" || echo "$u DOWN"; done'
echo "Logs: /var/log/bb-headless-install.log  /var/log/bb-remote-admin.log"
