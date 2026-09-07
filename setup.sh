#!/bin/bash
# setup.sh - one command to set up or update a BlueBubbles Mac mini.
#
#   curl -fsSL https://raw.githubusercontent.com/JoeLuci/bb-headless/main/setup.sh | sudo bash
#
# Same command whether the Mac is brand new or already running bb-headless:
# it clones or updates /Users/Shared/bb-headless, then runs
#   uninstall-autologin - removes the old bb-autologin system if it is present
#   uninstall-rustdesk  - removes RustDesk if it is present
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
# or skip the flag: download the key on the Mac itself (~/Downloads/key.tar.gz),
# or keep all keys in a private repo and pass BB_LICENSE_REPO=owner/repo - see
# the lookup below for every place it looks.
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

step "uninstall-rustdesk.sh (remove RustDesk if present)"
bash "$REPO_DIR/uninstall-rustdesk.sh" || echo "WARNING: RustDesk cleanup failed - carrying on, run it by hand later"

step "install.sh (headless BlueBubbles)"
bash "$REPO_DIR/install.sh"

step "bb-metrics.sh (health logger)"
bash "$REPO_DIR/bb-metrics.sh" install

# NoMachine subscription keys are one-per-Mac and must not live in this public
# repo. If BB_NM_LICENSE is not given, find this Mac's key, in this order:
#   1. bb-licenses/<hostname>.tar.gz|.lic on any mounted drive
#   2. /Users/Shared/bb-licenses/<hostname>.tar.gz|.lic on this Mac
#   3. a PRIVATE GitHub repo: BB_LICENSE_REPO=owner/repo holding
#      <hostname>.tar.gz at its root, fetched with `gh` if it is logged in,
#      else with BB_LICENSE_TOKEN (a read-only fine-grained token)
#   4. the newest key*.tar.gz in the invoking user's ~/Downloads - i.e. you
#      downloaded it from your NoMachine User Area on this Mac just now
# <hostname> is exactly what `scutil --get LocalHostName` prints.
if [ -z "${BB_NM_LICENSE:-}" ] && [ "${BB_NOMACHINE:-1}" = "1" ]; then
    HOSTN="$(scutil --get LocalHostName 2>/dev/null || hostname -s)"
    LIC_TMP="$(mktemp -d)"

    for dir in /Volumes/*/bb-licenses /Users/Shared/bb-licenses; do
        [ -d "$dir" ] || continue
        for f in "$dir/$HOSTN.tar.gz" "$dir/$HOSTN.tgz" "$dir/$HOSTN.lic"; do
            if [ -f "$f" ]; then export BB_NM_LICENSE="$f"; break 2; fi
        done
    done

    if [ -z "${BB_NM_LICENSE:-}" ] && [ -n "${BB_LICENSE_REPO:-}" ]; then
        out="$LIC_TMP/$HOSTN.tar.gz"
        if command -v gh >/dev/null 2>&1 && sudo -u "$CONSOLE_USER" -H gh auth status >/dev/null 2>&1; then
            sudo -u "$CONSOLE_USER" -H gh api "repos/$BB_LICENSE_REPO/contents/$HOSTN.tar.gz" \
                -H "Accept: application/vnd.github.raw" > "$out" 2>/dev/null || rm -f "$out"
        elif [ -n "${BB_LICENSE_TOKEN:-}" ]; then
            curl -fsSL -H "Authorization: token $BB_LICENSE_TOKEN" \
                "https://raw.githubusercontent.com/$BB_LICENSE_REPO/main/$HOSTN.tar.gz" -o "$out" 2>/dev/null || rm -f "$out"
        fi
        if [ -s "$out" ]; then export BB_NM_LICENSE="$out"; echo "Fetched NoMachine key from $BB_LICENSE_REPO"; fi
    fi

    if [ -z "${BB_NM_LICENSE:-}" ]; then
        DL="$(dscl . -read "/Users/$CONSOLE_USER" NFSHomeDirectory 2>/dev/null | awk '{print $2}')/Downloads"
        newest="$(ls -t "$DL"/key*.tar.gz 2>/dev/null | head -1 || true)"
        if [ -n "$newest" ]; then
            export BB_NM_LICENSE="$newest"
            echo "Using the NoMachine key you downloaded: $newest"
            echo "(each key licenses ONE Mac - make sure this is the one you generated for $HOSTN)"
        fi
    fi

    if [ -n "${BB_NM_LICENSE:-}" ]; then
        echo "NoMachine key for $HOSTN: $BB_NM_LICENSE"
    else
        echo "No NoMachine key found for $HOSTN. Without one the server refuses connections."
        echo "Easiest: on this Mac, download the key from your NoMachine User Area (it lands in"
        echo "~/Downloads/key.tar.gz) and re-run this command. Or set BB_LICENSE_REPO=owner/private-repo."
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

