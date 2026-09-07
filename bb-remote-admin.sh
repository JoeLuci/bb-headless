#!/bin/bash
# bb-remote-admin.sh - Remote admin setup for a BlueBubbles Mac mini
# Run with: sudo BB_ADMIN_PUBKEY="ssh-ed25519 ..." bash bb-remote-admin.sh
#       or: sudo bash bb-remote-admin.sh reboot
#
# What this does:
#   1. Installs NoMachine and configures it for unattended access on
#      BB_NM_PORT (default 4000). This is now the primary remote-GUI path.
#      Screen Recording + Accessibility are TCC-gated and CANNOT be granted
#      from a script - the step reports whether they are still missing.
#   2. Enables Screen Sharing as the fallback/recovery path, restricted to
#      BB_SCREENSHARING_USERS via the com.apple.access_screensharing group.
#      Legacy VNC password stays OFF, Remote Management/ARD stays OFF.
#      Pass BB_DISABLE_SCREENSHARING=1 to turn it off once NoMachine is proven.
#   3. Hardens SSH with a drop-in in /etc/ssh/sshd_config.d/ - key auth only,
#      no root login, AllowUsers scoped to BB_ADMIN_USER. Installs the admin
#      public key from $BB_ADMIN_PUBKEY.
#   4. Installs Tailscale and joins the tailnet. This is what gives each Mac a
#      stable address reachable from outside the LAN - the minis sit on private
#      RFC-1918 addresses, so NoMachine has nothing to dial from the road
#      without it. You still connect with NoMachine; Tailscale is only the
#      address. BB_TAILSCALE=0 leaves it alone; BB_TAILSCALE=remove uninstalls
#      it, at the very end, because removal drops a tailnet SSH session.
#   5. Enables the application firewall, disables automatic login, requires
#      password immediately on wake.
#   6. pmset: never sleep, autorestart after power failure.
#
# Idempotent - safe to re-run. Every step logs DONE or SKIPPED (why), with a
# summary at the end. No secrets live in this repo: credentials come from env
# vars and the script fails loudly if one is needed but unset.
#
# Config via env (defaults shown):
#   BB_ADMIN_USER=m01                admin account for SSH + brew
#   BB_SCREENSHARING_USERS="m01"     space-separated allowlist
#   BB_TAILSCALE=1                   1 = install and join the tailnet
#                                    0 = leave Tailscale alone entirely
#                                    remove = uninstall it
#   TS_AUTHKEY                       only used when Tailscale is not up yet;
#                                    without it you get a login URL to approve
#   BB_ADMIN_PUBKEY                  defaults to Joe's laptop key (public, safe
#                                    in the repo); override to use another key
#   BB_NOMACHINE=0                   1 = install/configure NoMachine; remove =
#                                    uninstall it (for a box switched to
#                                    RustDesk). Off by default - NoMachine is
#                                    licensed per machine, so only a box with a
#                                    paid key runs it.
#   BB_NM_PRODUCT=enterprise-desktop which package to install (or personal-edition)
#   BB_NM_REINSTALL=0                1 = uninstall whatever NoMachine is there and
#                                    install BB_NM_PRODUCT fresh (fixes a PE
#                                    install that refuses an Enterprise key)
#   BB_NM_PORT=4000                  NoMachine NX port
#   BB_NM_INSTALLER                  local .dmg/.pkg to install from (thumb
#                                    drive); otherwise downloaded from nomachine.com
#   BB_NM_DMG_URL                    explicit download URL, overrides discovery
#   BB_NM_LICENSE                    path to server.lic to activate (Enterprise
#                                    Desktop); unset = whatever the package ships
#   BB_DISABLE_SCREENSHARING=0       1 = turn macOS Screen Sharing off
#
# Licensing note: as of NoMachine 10 the old free edition is gone. The public
# download is "Personal Edition" (personal, non-commercial; 14-day trial key).
# Commercial use of this fleet needs Enterprise Desktop licences - put the .dmg
# on the deploy drive as BB_NM_INSTALLER and the key as BB_NM_LICENSE.
#
# Uninstalling NoMachine: sudo bash /Library/Application\ Support/NoMachine/nxuninstall.sh
#
# Deploy to all Macs:
#   for mac in mac1 mac2 ...; do
#     scp bb-remote-admin.sh m02@${mac}:/tmp/
#     ssh -t m02@${mac} 'sudo BB_ADMIN_PUBKEY="..." bash /tmp/bb-remote-admin.sh'
#   done

set -euo pipefail

BB_ADMIN_USER="${BB_ADMIN_USER:-m01}"
BB_SCREENSHARING_USERS="${BB_SCREENSHARING_USERS:-m01}"
# Public half of the admin keypair - safe to commit; the private half never
# leaves Joe's laptop.
BB_ADMIN_PUBKEY="${BB_ADMIN_PUBKEY:-ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHmuQ3rHXmKVJuJXRwEy6+heabNN075idY2RlVxRCZy4 joe-laptop}"
LOG_FILE="/var/log/bb-remote-admin.log"
SSHD_DROPIN="/etc/ssh/sshd_config.d/100-bb-remote-admin.conf"
# Apple silicon puts Homebrew in /opt/homebrew, the two Intel minis in /usr/local.
BREW_PREFIX="/usr/local"
if [ -x /opt/homebrew/bin/brew ]; then BREW_PREFIX="/opt/homebrew"; fi
BREW="$BREW_PREFIX/bin/brew"
TS_BIN="$BREW_PREFIX/bin/tailscale"
TSD_BIN="$BREW_PREFIX/bin/tailscaled"
SFW="/usr/libexec/ApplicationFirewall/socketfilterfw"
SS_GROUP="com.apple.access_screensharing"
TCC_DB="/Library/Application Support/com.apple.TCC/TCC.db"

# NoMachine
NM_APP="/Applications/NoMachine.app"
NM_ETC="$NM_APP/Contents/Frameworks/etc"
NM_CFG="$NM_ETC/server.cfg"
# Which product to install. The subscription keys are Enterprise Desktop
# (server type EDSS) and a Personal Edition install (PE) refuses them outright:
#   "NX> 650 ERROR: The installed server type PE is not suitable for the
#    subscription type EDSS."
# Both packages are public downloads; only the licence differs.
BB_NM_PRODUCT="${BB_NM_PRODUCT:-enterprise-desktop}"
case "$BB_NM_PRODUCT" in
    enterprise-desktop) NM_MAC_DOWNLOAD_PAGE="https://download.nomachine.com/download/?id=37&platform=mac" ;;
    personal-edition)   NM_MAC_DOWNLOAD_PAGE="https://download.nomachine.com/download/?id=117&platform=mac" ;;
    *) echo "ERROR: BB_NM_PRODUCT must be enterprise-desktop or personal-edition"; exit 1 ;;
esac
NM_UNINSTALL="/Library/Application Support/NoMachine/nxuninstall.sh"
BB_NM_PORT="${BB_NM_PORT:-4000}"
NM_READY=0
NM_TCC_MISSING=""
NM_CHANGED=0

DONE_STEPS=()
SKIPPED_STEPS=()

log() {
    printf '%s [bb-remote-admin] %s\n' "$(date '+%H:%M:%S')" "$*" | tee -a "$LOG_FILE"
}

done_step() {
    DONE_STEPS+=("$1")
    log "DONE: $1"
}

skip_step() {
    SKIPPED_STEPS+=("$1")
    log "SKIPPED: $1"
}

die() {
    log "ERROR: $*"
    exit 1
}

# ── Reboot helper ───────────────────────────────────────────────────────────
# fdesetup authrestart skips the FileVault pre-boot unlock so the machine
# comes back to the login window unattended; plain reboot otherwise.
if [ "${1:-install}" = "reboot" ]; then
    [ "$(id -u)" -eq 0 ] || die "Run with sudo: sudo bash $0 reboot"
    if fdesetup status | grep -q "FileVault is On"; then
        log "FileVault on - using authrestart"
        exec fdesetup authrestart
    else
        log "FileVault off - plain restart"
        exec shutdown -r now
    fi
fi

# ── Preflight ───────────────────────────────────────────────────────────────
[ "$(id -u)" -eq 0 ] || die "Run with sudo: sudo bash $0"

id "$BB_ADMIN_USER" >/dev/null 2>&1 || die "Admin user '$BB_ADMIN_USER' does not exist"
# `id` resolves account names case-insensitively; dscl record paths do not.
# A box whose account is really "M01" passes the check above and then dies
# in `dscl . -read /Users/m01` with eDSRecordNotFound. Use the canonical
# spelling from here on, for the admin and the screen-sharing users alike.
BB_ADMIN_USER="$(id -un "$BB_ADMIN_USER")"
_ss=""
for u in $BB_SCREENSHARING_USERS; do
    id "$u" >/dev/null 2>&1 || die "Screen-sharing user '$u' does not exist"
    _ss="$_ss $(id -un "$u")"
done
BB_SCREENSHARING_USERS="${_ss# }"
log "Accounts: admin=$BB_ADMIN_USER screen-sharing=[$BB_SCREENSHARING_USERS]"

GATEWAY="$(route -n get default 2>/dev/null | awk '/gateway:/{print $2}')"
[ -n "$GATEWAY" ] || die "No default gateway - is the network up?"
ping -c 1 -t 3 "$GATEWAY" >/dev/null 2>&1 || die "Cannot reach gateway $GATEWAY"
ping -c 1 -t 5 1.1.1.1 >/dev/null 2>&1 || die "Gateway reachable but no internet (1.1.1.1 unreachable)"
log "Network OK (gateway $GATEWAY, internet reachable)"

# Full Disk Access probe: reading the TCC database requires FDA even as root.
# systemsetup -setremotelogin silently no-ops without it, so detect up front.
HAVE_FDA=0
if sqlite3 "/Library/Application Support/com.apple.TCC/TCC.db" "SELECT 1;" >/dev/null 2>&1; then
    HAVE_FDA=1
    log "Full Disk Access: present"
else
    log "Full Disk Access: NOT present (Remote Login step will be skipped)"
fi

# ── 1. NoMachine (primary remote GUI) ───────────────────────────────────────
# NoMachine on macOS drives the *physical* console display; it has no per-user
# virtual desktops on this platform. You land in whichever session is on the
# console and Fast-User-Switch from there to reach m01..m05 - the other
# sessions keep running in the background, exactly as they do today.
#
# Screen Recording and Accessibility are TCC-gated. Nothing here can grant them
# (that needs MDM or a human in a GUI session), so the step installs, configures
# and starts NoMachine, then reports which permissions are still outstanding.
# Grant them over Screen Sharing, THEN re-run with BB_DISABLE_SCREENSHARING=1.

if [ "${BB_NOMACHINE:-0}" = "remove" ]; then
    NM_RM="$(cd "$(dirname "$0")" && pwd)/uninstall-nomachine.sh"
    if [ -f "$NM_RM" ]; then
        bash "$NM_RM" 2>&1 | tee -a "$LOG_FILE"
        done_step "Removed NoMachine (BB_NOMACHINE=remove)"
    else
        log "WARNING: $NM_RM missing - cannot remove NoMachine"
    fi
elif [ "${BB_NOMACHINE:-0}" != "1" ]; then
    skip_step "NoMachine step skipped (BB_NOMACHINE=0) - leaving the existing install untouched"
else

# nxserver lives inside the app bundle on macOS; /etc/NX is the documented
# symlink and older builds used /usr/NX. Take whichever exists.
nm_bin() {
    local c
    for c in "$NM_APP/Contents/Frameworks/bin/nxserver" /etc/NX/nxserver /usr/NX/bin/nxserver; do
        if [ -x "$c" ]; then printf '%s' "$c"; return 0; fi
    done
    return 1
}

# Screen Recording / Accessibility state for NoMachine, read from the system TCC
# database. Column name changed across macOS versions (allowed -> auth_value),
# and the client is sometimes a bundle id, sometimes a binary path - hence LIKE.
# Returns 0 = granted, 1 = not granted / unknown.
nm_tcc_granted() {
    local service="$1" col v
    for col in auth_value allowed; do
        v="$(sqlite3 "$TCC_DB" \
            "SELECT max($col) FROM access WHERE service='$service' AND client LIKE '%nomachine%';" 2>/dev/null || true)"
        case "$v" in
            2|1) return 0 ;;
            0)   return 1 ;;
        esac
    done
    return 1
}

# Set a key in server.cfg. Existing *active* lines for the key are dropped and
# the new value appended; the commented-out defaults NoMachine ships are left
# alone so the file still documents itself.
nm_set_cfg() {
    local key="$1" val="$2"
    if grep -qE "^[[:space:]]*${key}[[:space:]]+${val}[[:space:]]*$" "$NM_CFG"; then
        skip_step "server.cfg: $key already $val"
        return
    fi
    sed -i '' -E "/^[[:space:]]*${key}[[:space:]]/d" "$NM_CFG"
    printf '%s %s\n' "$key" "$val" >> "$NM_CFG"
    NM_CHANGED=1
    done_step "server.cfg: set $key $val"
}

# Where to get the package: explicit URL, then the official Mac download page,
# then the Homebrew cask metadata as a last resort.
nm_resolve_url() {
    local u
    if [ -n "${BB_NM_DMG_URL:-}" ]; then printf '%s' "$BB_NM_DMG_URL"; return 0; fi
    u="$(curl -fsSL --max-time 20 "$NM_MAC_DOWNLOAD_PAGE" 2>/dev/null \
        | grep -oE 'https://[^"[:space:]]+/MacOSX/[^"[:space:]]+\.dmg' | head -1 || true)"
    if [ -n "$u" ]; then printf '%s' "$u"; return 0; fi
    u="$(curl -fsSL --max-time 20 https://formulae.brew.sh/api/cask/nomachine.json 2>/dev/null \
        | /usr/bin/python3 -c "import json,sys; print(json.load(sys.stdin)[\"url\"])" 2>/dev/null || true)"
    if [ -n "$u" ]; then printf '%s' "$u"; return 0; fi
    return 1
}

nm_install() {
    NM_SRC="${BB_NM_INSTALLER:-}"
    NM_TMP=""
    if [ -n "$NM_SRC" ]; then
        [ -f "$NM_SRC" ] || die "BB_NM_INSTALLER=$NM_SRC does not exist"
        log "Installing NoMachine from $NM_SRC"
    else
        NM_URL="$(nm_resolve_url)" || die "Could not work out the NoMachine download URL. Set BB_NM_DMG_URL=... or put the package on the drive and set BB_NM_INSTALLER=/Volumes/<DRIVE>/nomachine.dmg"
        NM_TMP="$(mktemp -d)"
        NM_SRC="$NM_TMP/nomachine.dmg"
        log "Downloading NoMachine: $NM_URL"
        curl -fsSL --retry 3 --max-time 900 -o "$NM_SRC" "$NM_URL" \
            || die "NoMachine download failed: $NM_URL"
    fi

    case "$NM_SRC" in
        *.pkg)
            installer -pkg "$NM_SRC" -target / >>"$LOG_FILE" 2>&1 \
                || die "installer failed for $NM_SRC - see $LOG_FILE"
            ;;
        *.dmg)
            # nomachine.com answers a stale/removed file with a 200 redirect to
            # its home page, so an HTML "dmg" is the normal failure here.
            hdiutil imageinfo "$NM_SRC" >/dev/null 2>&1 \
                || die "$NM_SRC is not a disk image - the download URL probably redirected to the NoMachine home page. Grab the Mac package from $NM_MAC_DOWNLOAD_PAGE and re-run with BB_NM_INSTALLER=/path/to.dmg"
            NM_MNT="$(mktemp -d)"
            hdiutil attach -nobrowse -readonly -mountpoint "$NM_MNT" "$NM_SRC" >>"$LOG_FILE" 2>&1 \
                || die "Could not mount $NM_SRC"
            NM_PKG="$(find "$NM_MNT" -maxdepth 2 -name '*.pkg' | head -1 || true)"
            if [ -z "$NM_PKG" ]; then
                hdiutil detach "$NM_MNT" >/dev/null 2>&1 || true
                die "No .pkg inside $NM_SRC"
            fi
            installer -pkg "$NM_PKG" -target / >>"$LOG_FILE" 2>&1 || {
                hdiutil detach "$NM_MNT" >/dev/null 2>&1 || true
                die "installer failed for $NM_PKG - see $LOG_FILE"
            }
            hdiutil detach "$NM_MNT" >/dev/null 2>&1 || true
            rmdir "$NM_MNT" 2>/dev/null || true
            ;;
        *)
            die "Unsupported NoMachine package type: $NM_SRC (want .dmg or .pkg)"
            ;;
    esac
    if [ -n "$NM_TMP" ]; then rm -rf "$NM_TMP"; fi
    nm_bin >/dev/null || die "NoMachine installed but no nxserver binary found under $NM_APP"
    NM_CHANGED=1
    done_step "Installed NoMachine ($BB_NM_PRODUCT)"
}

# The wrong product installed is worse than none: it holds the port and
# refuses the key. BB_NM_REINSTALL=1 tears it out and installs BB_NM_PRODUCT.
if nm_bin >/dev/null && [ "${BB_NM_REINSTALL:-0}" = "1" ]; then
    # NoMachine's own uninstaller hands the real work to a launchd job and
    # returns immediately, so the bundle can still be there seconds later.
    # Give it a minute, then finish the job ourselves: stop every NoMachine
    # launchd job, remove the bundle, support dir and receipts.
    if [ -x "$NM_UNINSTALL" ]; then
        "$NM_UNINSTALL" >>"$LOG_FILE" 2>&1 || log "WARNING: nxuninstall.sh returned non-zero - continuing"
    fi
    for _ in $(seq 1 30); do
        nm_bin >/dev/null 2>&1 || break
        sleep 2
    done
    if nm_bin >/dev/null 2>&1; then
        log "nxuninstall.sh did not finish - removing the rest by hand"
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
    if nm_bin >/dev/null 2>&1; then die "NoMachine still present after uninstall - remove $NM_APP by hand and re-run"; fi
    done_step "Uninstalled the previous NoMachine (BB_NM_REINSTALL=1)"
fi

if nm_bin >/dev/null; then
    skip_step "NoMachine already installed ($("$(nm_bin)" --version 2>/dev/null | grep -i version | head -1 | tr -d '\n' || true))"
else
    nm_install
fi

NXSERVER="$(nm_bin)"

# NoMachine 10 renamed --activate to --subscriptionset; try the new name and
# fall back. BB_NM_LICENSE may be a .lic file or the key.tar.gz NoMachine
# issues from the User Area, which holds server.lic (and node.lic) - every .lic
# inside gets deployed. Until one is in place the server answers every
# connection with "No subscription found on this server".
nm_set_licence() {
    "$NXSERVER" --subscriptionset "$1" >>"$LOG_FILE" 2>&1 \
        || "$NXSERVER" --activate "$1" >>"$LOG_FILE" 2>&1
}

if [ -n "${BB_NM_LICENSE:-}" ]; then
    [ -f "$BB_NM_LICENSE" ] || die "BB_NM_LICENSE=$BB_NM_LICENSE does not exist"
    NM_SUB="$("$NXSERVER" --subscriptioninfo 2>&1 || true)"
    if ! printf '%s' "$NM_SUB" | grep -q "No subscription found"; then
        skip_step "NoMachine already has a subscription: $(printf '%s' "$NM_SUB" | grep -vi warning | head -1 | tr -d '\n')"
    else
        NM_LIC_TMP=""
        case "$BB_NM_LICENSE" in
            *.tar.gz|*.tgz)
                NM_LIC_TMP="$(mktemp -d)"
                tar -xzf "$BB_NM_LICENSE" -C "$NM_LIC_TMP" || die "Could not extract $BB_NM_LICENSE"
                LIC_FILES="$(find "$NM_LIC_TMP" -name '*.lic' | sort || true)"
                ;;
            *) LIC_FILES="$BB_NM_LICENSE" ;;
        esac
        [ -n "$LIC_FILES" ] || die "No .lic file found in $BB_NM_LICENSE"
        for f in $LIC_FILES; do
            if ! nm_set_licence "$f"; then
                if grep -q "not suitable for the subscription type" "$LOG_FILE"; then
                    die "The installed NoMachine product does not match this key ($(grep -o 'server type [A-Z]* is not suitable for the subscription type [A-Z]*' "$LOG_FILE" | tail -1)). Re-run with BB_NM_REINSTALL=1 to replace it with $BB_NM_PRODUCT."
                fi
                die "nxserver could not deploy $(basename "$f") - see $LOG_FILE"
            fi
        done
        if [ -n "$NM_LIC_TMP" ]; then rm -rf "$NM_LIC_TMP"; fi
        NM_CHANGED=1
        done_step "Deployed NoMachine subscription ($(for f in $LIC_FILES; do basename "$f"; done | tr '\n' ' '))"
    fi
else
    if "$NXSERVER" --subscriptioninfo 2>&1 | grep -q "No subscription found"; then
        log "WARNING: NoMachine has NO subscription - it will refuse every connection until one is deployed."
        log "         Get a 14-day trial from your nomachine.com User Area, then re-run with BB_NM_LICENSE=/path/to/key.tar.gz"
        skip_step "NoMachine subscription (none deployed, BB_NM_LICENSE unset)"
    else
        skip_step "NoMachine subscription already present"
    fi
fi

if [ -f "$NM_CFG" ]; then
    # 0 = connect without the console user having to click Accept. Unattended
    # boxes have nobody to click it.
    nm_set_cfg PhysicalDesktopAuthorization 0
    nm_set_cfg NXPort "$BB_NM_PORT"
else
    log "WARNING: $NM_CFG not found - skipping NoMachine configuration"
fi

# Application firewall: allow the listener explicitly rather than relying on the
# signed-app default, which a stealth/block-all policy would override.
NM_FW=0
for b in "$NM_APP/Contents/Frameworks/bin/nxd" "$NM_APP/Contents/Frameworks/bin/nxserver.bin" "$NM_APP"; do
    [ -e "$b" ] || continue
    "$SFW" --add "$b" >/dev/null 2>&1 || true
    "$SFW" --unblockapp "$b" >/dev/null 2>&1 || true
    NM_FW=1
done
if [ "$NM_FW" -eq 1 ]; then
    done_step "Application firewall: allowed NoMachine"
else
    skip_step "Application firewall: no NoMachine binary to allow"
fi

# Restarting nxserver drops every live NoMachine session - including the one
# you are probably running this from. Only do it when this run actually changed
# something, or when the server is not answering at all.
NM_WAS_UP=0
if nc -z -w 3 localhost "$BB_NM_PORT" >/dev/null 2>&1; then NM_WAS_UP=1; fi

if [ "$NM_CHANGED" -eq 1 ]; then
    if "$NXSERVER" --restart >>"$LOG_FILE" 2>&1 || "$NXSERVER" --startup >>"$LOG_FILE" 2>&1; then
        done_step "Restarted NoMachine server (this run changed its config)"
    else
        log "WARNING: could not restart nxserver - see $LOG_FILE"
    fi
elif [ "$NM_WAS_UP" -eq 1 ]; then
    skip_step "NoMachine already running as configured - not restarting (that would drop your session)"
else
    if "$NXSERVER" --startup >>"$LOG_FILE" 2>&1; then
        done_step "Started NoMachine server"
    else
        log "WARNING: could not start nxserver - see $LOG_FILE"
    fi
fi

sleep 3
if nc -z -w 3 localhost "$BB_NM_PORT" >/dev/null 2>&1; then
    done_step "NoMachine listening on port $BB_NM_PORT"
    NM_READY=1
else
    log "WARNING: nothing listening on port $BB_NM_PORT yet. A fresh NoMachine install usually needs one reboot: sudo bash $0 reboot"
fi

if [ "$HAVE_FDA" -eq 1 ]; then
    nm_tcc_granted kTCCServiceScreenCapture || NM_TCC_MISSING="$NM_TCC_MISSING Screen-Recording"
    nm_tcc_granted kTCCServiceAccessibility || NM_TCC_MISSING="$NM_TCC_MISSING Accessibility"
    if [ -z "$NM_TCC_MISSING" ]; then
        done_step "NoMachine has Screen Recording + Accessibility"
    else
        NM_READY=0
        log "WARNING: NoMachine is missing TCC permissions:$NM_TCC_MISSING"
    fi
else
    NM_READY=0
    NM_TCC_MISSING=" (unknown - no Full Disk Access to read TCC.db)"
    skip_step "NoMachine permission check: needs Full Disk Access"
fi

fi

# ── 2. Screen Sharing (fallback / recovery path) ────────────────────────────
# This is the fallback, not the primary path. A hiccup here must not abort
# the run and skip SSH, Tailscale and lockdown behind it - warn and move on.
if ! dseditgroup -o read "$SS_GROUP" >/dev/null 2>&1; then
    if dseditgroup -o create -q "$SS_GROUP" >/dev/null 2>&1; then
        done_step "Created group $SS_GROUP"
    else
        log "WARNING: could not create group $SS_GROUP - Screen Sharing stays unrestricted-by-group"
    fi
else
    skip_step "Group $SS_GROUP already exists"
fi

for u in $BB_SCREENSHARING_USERS; do
    if dseditgroup -o checkmember -m "$u" "$SS_GROUP" >/dev/null 2>&1; then
        skip_step "$u already in $SS_GROUP"
    elif dseditgroup -o edit -q -a "$u" -t user "$SS_GROUP" >>"$LOG_FILE" 2>&1; then
        done_step "Added $u to $SS_GROUP"
    else
        log "WARNING: could not add $u to $SS_GROUP - see $LOG_FILE"
    fi
done

# IMPORTANT: "service is loaded" (launchctl print) is NOT "sharing is enabled".
# macOS loads screensharingd on-demand either way; clients then get
# "Screen sharing is not permitted" until the launchd override DB says enabled.
# The authoritative check is print-disabled. (Found the hard way on box 1.)
if [ "${BB_DISABLE_SCREENSHARING:-0}" = "1" ]; then
    # Deliberate one-way step: after this, NoMachine and SSH are the only ways
    # in. Do not run it until NoMachine has actually been used to log in once.
    if launchctl print-disabled system | grep -q '"com.apple.screensharing" => disabled'; then
        skip_step "Screen Sharing already disabled"
    else
        [ "$NM_READY" -eq 1 ] || log "WARNING: disabling Screen Sharing while NoMachine is not verified ready -$NM_TCC_MISSING"
        launchctl bootout system/com.apple.screensharing 2>/dev/null || true
        launchctl disable system/com.apple.screensharing
        done_step "Disabled Screen Sharing (BB_DISABLE_SCREENSHARING=1) - NoMachine is now the only GUI path"
    fi
elif launchctl print-disabled system | grep -q '"com.apple.screensharing" => enabled'; then
    skip_step "Screen Sharing already enabled (fallback path)"
else
    launchctl enable system/com.apple.screensharing
    launchctl bootstrap system /System/Library/LaunchDaemons/com.apple.screensharing.plist 2>/dev/null || true
    launchctl kickstart -k system/com.apple.screensharing 2>/dev/null || true
    done_step "Enabled Screen Sharing as fallback (group-restricted; legacy VNC and ARD untouched)"
fi

# ── 3. SSH hardening ────────────────────────────────────────────────────────
# Home dir: the local DS node first, then the full search path, then plain
# getpwnam via ~user - an account that `id` can see is resolvable by one of
# them even when `dscl .` answers eDSRecordNotFound.
ADMIN_HOME="$(dscl . -read "/Users/$BB_ADMIN_USER" NFSHomeDirectory 2>/dev/null | awk '{print $2}' || true)"
[ -n "$ADMIN_HOME" ] || ADMIN_HOME="$(dscl /Search -read "/Users/$BB_ADMIN_USER" NFSHomeDirectory 2>/dev/null | awk '{print $2}' || true)"
[ -n "$ADMIN_HOME" ] || ADMIN_HOME="$(eval echo "~$BB_ADMIN_USER" 2>/dev/null || true)"
[ -n "$ADMIN_HOME" ] && [ -d "$ADMIN_HOME" ] || die "Home directory for $BB_ADMIN_USER not found (dscl: $(dscl . -read "/Users/$BB_ADMIN_USER" NFSHomeDirectory 2>&1 | head -1))"

AUTH_KEYS="$ADMIN_HOME/.ssh/authorized_keys"
if [ -f "$AUTH_KEYS" ] && [ -n "${BB_ADMIN_PUBKEY:-}" ] && grep -qxF "$BB_ADMIN_PUBKEY" "$AUTH_KEYS"; then
    skip_step "Admin public key already installed"
elif [ -z "${BB_ADMIN_PUBKEY:-}" ]; then
    if [ -s "$AUTH_KEYS" ]; then
        skip_step "BB_ADMIN_PUBKEY unset but $AUTH_KEYS already has keys - leaving as-is"
    else
        die "BB_ADMIN_PUBKEY is not set and $AUTH_KEYS is empty. Export your public key: BB_ADMIN_PUBKEY=\"ssh-ed25519 AAAA... you@host\""
    fi
else
    mkdir -p "$ADMIN_HOME/.ssh"
    printf '%s\n' "$BB_ADMIN_PUBKEY" >> "$AUTH_KEYS"
    chown -R "$BB_ADMIN_USER":staff "$ADMIN_HOME/.ssh"
    chmod 700 "$ADMIN_HOME/.ssh"
    chmod 600 "$AUTH_KEYS"
    done_step "Installed admin public key for $BB_ADMIN_USER"
fi

grep -q '^Include /etc/ssh/sshd_config.d/\*' /etc/ssh/sshd_config \
    || die "/etc/ssh/sshd_config has no Include for sshd_config.d - unexpected macOS config"

# A box that has never had Remote Login on has no host keys, and sshd -t
# refuses to validate anything without them. Generate the missing ones.
if [ ! -f /etc/ssh/ssh_host_ed25519_key ]; then
    ssh-keygen -A >/dev/null 2>&1
    done_step "Generated SSH host keys"
fi

DROPIN_CONTENT="# Managed by bb-remote-admin.sh - do not edit by hand
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
PermitRootLogin no
AllowUsers $BB_ADMIN_USER"

if [ -f "$SSHD_DROPIN" ] && [ "$(cat "$SSHD_DROPIN")" = "$DROPIN_CONTENT" ]; then
    skip_step "sshd drop-in already in place"
else
    printf '%s\n' "$DROPIN_CONTENT" > "$SSHD_DROPIN"
    chmod 644 "$SSHD_DROPIN"
    # Validate before letting it take effect; a broken sshd on a remote box
    # locks you out. Roll back on failure.
    if /usr/sbin/sshd -t 2>&1 | tee -a "$LOG_FILE"; then
        done_step "Wrote sshd hardening drop-in ($SSHD_DROPIN)"
    else
        rm -f "$SSHD_DROPIN"
        die "sshd -t rejected the drop-in; removed it. Fix and re-run."
    fi
fi

if [ "$HAVE_FDA" -eq 1 ]; then
    if systemsetup -getremotelogin 2>/dev/null | grep -qi ": on"; then
        skip_step "Remote Login already on"
    elif systemsetup -setremotelogin on >>"$LOG_FILE" 2>&1; then
        done_step "Enabled Remote Login (SSH) via systemsetup"
    else
        # systemsetup is TCC-fussy in some invocation contexts; the launchd
        # service (ssh.plist -> com.openssh.sshd) is the same thing.
        launchctl enable system/com.openssh.sshd
        launchctl bootstrap system /System/Library/LaunchDaemons/ssh.plist 2>/dev/null || true
        done_step "Enabled Remote Login (SSH) via launchctl (systemsetup refused)"
    fi
    launchctl kickstart -k system/com.openssh.sshd 2>/dev/null || true
    sleep 2
    if nc -z -w 3 localhost 22 >/dev/null 2>&1; then
        done_step "sshd verified listening on port 22"
    else
        log "WARNING: port 22 still not answering - check 'launchctl print system/com.openssh.sshd'"
    fi
else
    skip_step "Remote Login: needs Full Disk Access. Grant it: System Settings > Privacy & Security > Full Disk Access > enable your terminal app (or sshd), then re-run this script."
fi

# ── 4. Tailscale (Homebrew standalone, not App Store) ───────────────────────
# The address layer. NoMachine is the thing you actually use; this just makes
# the Mac reachable from outside the LAN.
if [ "${BB_TAILSCALE:-1}" != "1" ]; then
    skip_step "Tailscale install skipped (BB_TAILSCALE=${BB_TAILSCALE:-1})"
else

# A fresh mini has no Homebrew. Install it for the invoking admin rather than
# dying here - everything after this step (lockdown, pmset) would be skipped.
# Pre-owning the prefix means Homebrew's installer needs no sudo of its own,
# so it runs clean under NONINTERACTIVE=1 from this root script. It still
# needs the Xcode Command Line Tools, which setup.sh already requires for git.
if [ ! -x "$BREW" ]; then
    BREW_USER="${SUDO_USER:-$(stat -f %Su /dev/console)}"
    [ -n "$BREW_USER" ] && [ "$BREW_USER" != "root" ] || die "Homebrew not found and no admin user to install it for - install it by hand: https://brew.sh"
    log "Homebrew not found - installing it for $BREW_USER (this takes a few minutes)"
    mkdir -p "$BREW_PREFIX"
    chown -R "$BREW_USER":admin "$BREW_PREFIX"
    sudo -u "$BREW_USER" -H env NONINTERACTIVE=1 \
        bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" >>"$LOG_FILE" 2>&1 \
        || die "Homebrew install failed - see $LOG_FILE (is Xcode Command Line Tools installed? xcode-select --install)"
    [ -x "$BREW" ] || die "Homebrew installer finished but $BREW is missing"
    done_step "Installed Homebrew for $BREW_USER"
fi
BREW_OWNER="$(stat -f %Su "$BREW_PREFIX")"

if [ -x "$TS_BIN" ]; then
    skip_step "Tailscale already installed"
else
    # brew refuses to run as root; run as the user who owns /opt/homebrew.
    sudo -u "$BREW_OWNER" -H "$BREW" install tailscale >>"$LOG_FILE" 2>&1 \
        || die "brew install tailscale failed - see $LOG_FILE"
    done_step "Installed Tailscale via Homebrew (user $BREW_OWNER)"
fi

if [ -f /Library/LaunchDaemons/com.tailscale.tailscaled.plist ]; then
    skip_step "tailscaled system daemon already installed"
else
    "$TSD_BIN" install-system-daemon >>"$LOG_FILE" 2>&1 \
        || die "tailscaled install-system-daemon failed - see $LOG_FILE"
    done_step "Installed tailscaled system daemon"
fi

if "$TS_BIN" status >/dev/null 2>&1; then
    skip_step "Tailscale already up"
elif [ -n "${TS_AUTHKEY:-}" ]; then
    "$TS_BIN" up --authkey "$TS_AUTHKEY" --ssh >>"$LOG_FILE" 2>&1 \
        || die "tailscale up failed - see $LOG_FILE"
    done_step "Tailscale up via auth key, with Tailscale SSH"
else
    # No key: interactive join. tailscale prints a login URL - open it on any
    # signed-in device (the operator's phone) and tap approve. No secrets.
    log ">>> Tailscale needs a one-time approval. A login URL will appear below."
    log ">>> Open it on your phone (Tailscale app signed in) and tap Approve."
    "$TS_BIN" up --ssh \
        || die "tailscale interactive login failed or was not approved"
    done_step "Tailscale up via interactive approval, with Tailscale SSH"
fi

fi

# ── 5. Lockdown ─────────────────────────────────────────────────────────────
if "$SFW" --getglobalstate | grep -qi enabled; then
    skip_step "Application firewall already on"
else
    "$SFW" --setglobalstate on >/dev/null
    done_step "Enabled application firewall"
fi

if defaults read /Library/Preferences/com.apple.loginwindow autoLoginUser >/dev/null 2>&1; then
    defaults delete /Library/Preferences/com.apple.loginwindow autoLoginUser
    rm -f /etc/kcpassword
    done_step "Disabled automatic login (removed autoLoginUser + kcpassword)"
else
    rm -f /etc/kcpassword
    skip_step "Automatic login already off"
fi

PW_USERS="$(dscl . -list /Users UniqueID 2>/dev/null | awk '$2 >= 501 && $2 < 4294967294 {print $1}' | grep -v '^_' || true)"
for u in $PW_USERS; do
    sudo -u "$u" defaults write com.apple.screensaver askForPassword -int 1 2>/dev/null || true
    sudo -u "$u" defaults write com.apple.screensaver askForPasswordDelay -int 0 2>/dev/null || true
done
done_step "Require password immediately on wake (users: $(echo "$PW_USERS" | tr '\n' ' '))"

# ── 6. Power ────────────────────────────────────────────────────────────────
pmset -a sleep 0 displaysleep 0 disksleep 0 autorestart 1
done_step "pmset: never sleep, autorestart after power failure"

# ── Summary ─────────────────────────────────────────────────────────────────
log "=== Summary ==="
log "Completed: ${#DONE_STEPS[@]}"
for s in ${DONE_STEPS[@]+"${DONE_STEPS[@]}"}; do log "  + $s"; done
log "Skipped: ${#SKIPPED_STEPS[@]}"
for s in ${SKIPPED_STEPS[@]+"${SKIPPED_STEPS[@]}"}; do log "  - $s"; done
log "Log: $LOG_FILE"

log "=== Remote GUI ==="
if [ "${BB_NOMACHINE:-0}" != "1" ]; then
    log "Remote GUI: Screen Sharing over Tailscale. From a device on the tailnet: vnc://$("$TS_BIN" ip -4 2>/dev/null | head -1 || echo '<tailscale-ip>')  (NoMachine not enabled; BB_NOMACHINE=1 for a box with a paid key)"
elif [ "$NM_READY" -eq 1 ]; then
    log "NoMachine ready on port $BB_NM_PORT. Connect to nx://<tailscale-name>:$BB_NM_PORT"
    if [ "${BB_DISABLE_SCREENSHARING:-0}" != "1" ]; then
        log "Screen Sharing is still on as fallback. Once you have logged in over"
        log "NoMachine at least once, turn it off:  sudo BB_DISABLE_SCREENSHARING=1 bash $0"
    fi
else
    log "NoMachine NOT ready yet.$NM_TCC_MISSING"
    log "Finish it from a GUI session (Screen Sharing still works):"
    log "  System Settings > Privacy & Security > Screen & System Audio Recording -> enable NoMachine"
    log "  System Settings > Privacy & Security > Accessibility                    -> enable NoMachine"
    log "  then: sudo \"$NM_APP/Contents/Frameworks/bin/nxserver\" --restart   (reboot if it still will not bind)"
    log "Leave Screen Sharing on until NoMachine works."
fi

# ── Tailscale removal (last, on purpose) ──────────────────────────────────
# Dead last because it kills a tailnet SSH session - everything above has
# already run and been logged by the time this fires.
if [ "${BB_TAILSCALE:-1}" = "remove" ]; then
    if [ -x "$TS_BIN" ] || [ -x /usr/local/bin/tailscaled ] \
        || [ -f /Library/LaunchDaemons/com.tailscale.tailscaled.plist ]; then
        TS_UNINSTALL="$(cd "$(dirname "$0")" && pwd)/uninstall-tailscale.sh"
        if [ -f "$TS_UNINSTALL" ]; then
            log "=== Removing Tailscale (BB_TAILSCALE=remove was set) ==="
            log "If you are connected over the tailnet, this is where you get dropped."
            bash "$TS_UNINSTALL" 2>&1 | tee -a "$LOG_FILE"
        else
            log "WARNING: Tailscale is installed but $TS_UNINSTALL is missing - run it by hand"
        fi
    else
        log "Tailscale: not installed, nothing to remove"
    fi
fi
