#!/bin/bash
# setup.sh - one command to set up or update a BlueBubbles Mac mini.
#
#   curl -fsSL https://raw.githubusercontent.com/JoeLuci/bb-headless/main/setup.sh | sudo bash
#
# Same command whether the Mac is brand new or already running bb-headless:
# it clones or updates /Users/Shared/bb-headless, then runs
#   uninstall-autologin - removes the old bb-autologin system if it is present
#   bb-rustdesk.sh      - RustDesk: the remote GUI for the fleet. Free, no
#                         per-machine licence, connect by ID + password from
#                         the RustDesk app anywhere (BB_RUSTDESK=0 to skip)
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
# The shared RustDesk password and any NoMachine keys are fetched from the
# private repo JoeLuci/bb-licenses (one-time `gh` device login per Mac, or
# BB_LICENSE_TOKEN). So a mini needs nothing on the command line:
#   curl -fsSL <url> | sudo bash
#
# Options are env vars, passed through to the scripts below, e.g.
#   curl -fsSL <url> | sudo BB_DISABLE_SCREENSHARING=1 bash
#   curl -fsSL <url> | sudo BB_NM_LICENSE=/Volumes/DRIVE/server.lic bash
# or skip the flag: download the key on the Mac itself (~/Downloads/key.tar.gz),
# or keep all keys in a private repo and pass BB_LICENSE_REPO=owner/repo - see
# the lookup below for every place it looks.
#
# RustDesk is the fleet's remote GUI; any NoMachine on a mini is removed by
# default (BB_NOMACHINE=remove). For the VPS boxes - the hosting provider runs
# NoMachine on those - use VPS mode, which touches none of the remote tools:
#   curl -fsSL <url> | sudo BB_VM=1 bash
# BB_VM=1 forces BB_NOMACHINE=0 BB_TAILSCALE=0 BB_RUSTDESK=0 and cannot be
# overridden from the same command - by design.
#
# Prerequisites, in this order, or the run is wasted:
#   1. Each user login already set up in the BlueBubbles Electron app
#      (its config.db must exist) - logins without one are skipped.
#   2. Terminal has Full Disk Access, or the Remote Login step is skipped.

set -euo pipefail

REPO_URL="https://github.com/JoeLuci/bb-headless.git"
REPO_DIR="/Users/Shared/bb-headless"
BRANCH="${BB_BRANCH:-main}"
# Private repo holding one NoMachine key per Mac, named <hostname>.tar.gz.
# The name is not a secret; access is via gh login or BB_LICENSE_TOKEN.
BB_LICENSE_REPO="${BB_LICENSE_REPO:-JoeLuci/bb-licenses}"

[ "$(id -u)" -eq 0 ] || { echo "ERROR: run with sudo, e.g. curl -fsSL <url> | sudo bash"; exit 1; }
command -v git >/dev/null 2>&1 || {
    echo "ERROR: git is missing. Run 'xcode-select --install', let it finish, then re-run this."
    exit 1
}

CONSOLE_USER="${SUDO_USER:-$(stat -f %Su /dev/console)}"

# VM Macs: they already have NoMachine, and they must not get Tailscale.
# 0 means "leave alone" for both - nothing is installed and nothing removed.
# VPS boxes belong to the hosting provider, who runs NoMachine on every one of
# them. BB_VM=1 is an absolute hands-off guard: it FORCES all three remote
# tools to "leave alone" regardless of any default or explicit value, so a
# VPS can never have RustDesk or Tailscale installed, nor the provider's
# NoMachine removed. Only BlueBubbles, metrics, SSH and lockdown run there.
if [ "${BB_VM:-0}" = "1" ]; then
    export BB_NOMACHINE=0
    export BB_TAILSCALE=0
    export BB_RUSTDESK=0
    echo "BB_VM=1: VPS mode - NoMachine, Tailscale and RustDesk are NOT touched (nothing installed, nothing removed)"
fi

step() { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }

gh_bin() {
    local c
    for c in /opt/homebrew/bin/gh /usr/local/bin/gh; do
        if [ -x "$c" ]; then printf '%s' "$c"; return 0; fi
    done
    return 1
}

# Pull <hostname>.tar.gz from the private repo into $1. Prefers a gh login
# on this Mac (as the invoking user), else BB_LICENSE_TOKEN. Returns 1 when
# neither works or the file is not in the repo.
fetch_from_repo() {   # fetch_from_repo <path-in-repo> <out-file>
    local path="$1" out="$2" GH
    if GH="$(gh_bin)" && sudo -u "$CONSOLE_USER" -H "$GH" auth status >/dev/null 2>&1; then
        sudo -u "$CONSOLE_USER" -H "$GH" api "repos/$BB_LICENSE_REPO/contents/$path" \
            -H "Accept: application/vnd.github.raw" > "$out" 2>/dev/null || rm -f "$out"
    elif [ -n "${BB_LICENSE_TOKEN:-}" ]; then
        curl -fsSL -H "Authorization: token $BB_LICENSE_TOKEN" \
            -H "Accept: application/vnd.github.raw" \
            "https://api.github.com/repos/$BB_LICENSE_REPO/contents/$path" -o "$out" 2>/dev/null || rm -f "$out"
    fi
    [ -s "$out" ]
}
fetch_key_from_repo() { fetch_from_repo "$HOSTN.tar.gz" "$1"; }

# Make sure gh exists and is logged in for the invoking user. Installs it
# with Homebrew (present by now - bb-remote-admin.sh installs Homebrew) and
# runs GitHub's device login: it prints a one-time code and a URL, you enter
# the code on any browser. Needs a terminal; skipped silently without one.
ensure_gh_login() {
    local GH BREW
    if ! GH="$(gh_bin)"; then
        for BREW in /opt/homebrew/bin/brew /usr/local/bin/brew; do [ -x "$BREW" ] && break; done
        [ -x "$BREW" ] || return 1
        # Intel minis: /usr/local is root-owned and brew refuses to run as
        # root - fall back to the owner of the brew binary itself.
        local BREW_OWNER
        BREW_OWNER="$(stat -f %Su "$(dirname "$(dirname "$BREW")")")"
        [ "$BREW_OWNER" = "root" ] && BREW_OWNER="$(stat -f %Su "$BREW")"
        sudo -u "$BREW_OWNER" -H "$BREW" install gh >/dev/null 2>&1 || return 1
        GH="$(gh_bin)" || return 1
    fi
    if sudo -u "$CONSOLE_USER" -H "$GH" auth status >/dev/null 2>&1; then return 0; fi
    [ -w /dev/tty ] || return 1
    echo ""
    echo ">>> One-time GitHub login on this Mac so it can read $BB_LICENSE_REPO (password, keys)."
    echo ">>> A code and a URL will appear below. Open the URL on your phone or laptop,"
    echo ">>> enter the code, approve. This waits until you do (Ctrl-C to skip)."
    # stdin from /dev/null makes gh run NON-interactively: no Y/n survey prompt
    # (which cannot draw inside a piped script), just the device code + URL.
    sudo -u "$CONSOLE_USER" -H env GH_NO_UPDATE_NOTIFIER=1 "$GH" auth login \
        --hostname github.com --git-protocol https --web --skip-ssh-key \
        </dev/null >/dev/tty 2>&1 || return 1
    sudo -u "$CONSOLE_USER" -H "$GH" auth status >/dev/null 2>&1
}

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
# repo. If BB_NM_LICENSE is not given, find this Mac's key, in this order:
#   1. bb-licenses/<hostname>.tar.gz|.lic on any mounted drive
#   2. /Users/Shared/bb-licenses/<hostname>.tar.gz|.lic on this Mac
#   3. a PRIVATE GitHub repo: BB_LICENSE_REPO=owner/repo holding
#      <hostname>.tar.gz at its root, fetched with `gh` if it is logged in,
#      else with BB_LICENSE_TOKEN (a read-only fine-grained token)
#   4. the newest key*.tar.gz in the invoking user's ~/Downloads - i.e. you
#      downloaded it from your NoMachine User Area on this Mac just now
# <hostname> is exactly what `scutil --get LocalHostName` prints.
if [ -z "${BB_NM_LICENSE:-}" ] && [ "${BB_NOMACHINE:-0}" = "1" ]; then
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
        fetch_key_from_repo "$out" && export BB_NM_LICENSE="$out" && echo "Fetched NoMachine key from $BB_LICENSE_REPO"
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

# Shared RustDesk password lives in the private repo as `rustdesk-password`,
# so no box needs it on the command line. Homebrew (hence gh) exists by now.
# Falls back to a generated password (shown by bb-status) if it cannot be
# fetched - never a stopper.
if [ "${BB_RUSTDESK:-1}" = "1" ] && [ -z "${BB_RD_PASSWORD:-}" ]; then
    step "RustDesk password from $BB_LICENSE_REPO"
    pwf="$(mktemp)"
    if ensure_gh_login && fetch_from_repo rustdesk-password "$pwf"; then
        BB_RD_PASSWORD="$(tr -d '\r\n' < "$pwf")"; export BB_RD_PASSWORD
        echo "Fetched the shared RustDesk password"
    else
        echo "Could not fetch it (no GitHub login on this Mac yet?) - a password will be generated; sudo bb-status shows it"
    fi
    rm -f "$pwf"
fi

if [ "${BB_RUSTDESK:-1}" = "1" ]; then
    step "bb-rustdesk.sh (remote GUI)"
    bash "$REPO_DIR/bb-rustdesk.sh" || echo "WARNING: RustDesk setup failed - see /var/log/bb-rustdesk.log; Screen Sharing over Tailscale still works"
fi

# The key lookup above runs before Homebrew (and so gh) exists on a fresh
# Mac. If NoMachine is still unlicensed, try the private repo now that the
# tools are here, then deploy with a quick second pass.
NX=/Applications/NoMachine.app/Contents/Frameworks/bin/nxserver
if [ "${BB_NOMACHINE:-0}" = "1" ] && [ -z "${BB_NM_LICENSE:-}" ] && [ -x "$NX" ] \
   && "$NX" --subscriptioninfo 2>&1 | grep -q "No subscription found"; then
    step "NoMachine key from $BB_LICENSE_REPO"
    out="${LIC_TMP:-$(mktemp -d)}/$HOSTN.tar.gz"
    if ensure_gh_login && fetch_key_from_repo "$out"; then
        echo "Fetched $HOSTN.tar.gz - deploying"
        BB_NM_LICENSE="$out" bash "$REPO_DIR/bb-remote-admin.sh" >/dev/null 2>&1 \
            && echo "Deployed. NoMachine: $("$NX" --subscriptioninfo 2>&1 | grep -vi warning | head -1)" \
            || echo "WARNING: deploy failed - see /var/log/bb-remote-admin.log"
    else
        echo "No key for this Mac yet. NoMachine will refuse connections until one is deployed."
        echo "  1. Buy an Enterprise Desktop subscription for this Mac (one per machine)."
        echo "  2. Upload the emailed key.tar.gz to https://github.com/$BB_LICENSE_REPO as: $HOSTN.tar.gz"
        echo "  3. Re-run this command. (Or drop key.tar.gz in ~/Downloads on this Mac and re-run.)"
    fi
fi

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

2. Tick RustDesk in the Privacy panes (they are opening now):
     Screen & System Audio Recording
     Accessibility
     Input Monitoring (if keyboard/mouse do not work remotely)
   Nothing can grant these from a script - macOS does not allow it.

3. Restart the Mac, then log all five accounts back in.
TXT

# Only useful if someone is looking at a screen; harmless over SSH.
for pane in Privacy_ScreenCapture Privacy_Accessibility Privacy_ListenEvent; do
    sudo -u "$CONSOLE_USER" open "x-apple.systempreferences:com.apple.preference.security?$pane" >/dev/null 2>&1 || true
    sleep 1
done

step "Checking what actually took"
bash "$REPO_DIR/bb-status.sh" || true
echo ""
echo "Re-run this check any time with:  sudo bb-status"

