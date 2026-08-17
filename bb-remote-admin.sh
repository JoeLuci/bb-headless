#!/bin/bash
# bb-remote-admin.sh - Remote admin setup for a BlueBubbles Mac mini
# Run with: sudo TS_AUTHKEY=... BB_ADMIN_PUBKEY="ssh-ed25519 ..." bash bb-remote-admin.sh
#       or: sudo bash bb-remote-admin.sh reboot
#
# What this does:
#   1. Enables Screen Sharing, restricted to BB_SCREENSHARING_USERS via the
#      com.apple.access_screensharing group. Legacy VNC password stays OFF,
#      Remote Management/ARD stays OFF.
#   2. Hardens SSH with a drop-in in /etc/ssh/sshd_config.d/ - key auth only,
#      no root login, AllowUsers scoped to BB_ADMIN_USER. Installs the admin
#      public key from $BB_ADMIN_PUBKEY.
#   3. Installs Tailscale (Homebrew standalone build), brings it up with
#      $TS_AUTHKEY, enables Tailscale SSH.
#      NOTE: Tailscale SSH bypasses sshd - the AllowUsers restriction below
#      does NOT govern it. Scope Tailscale SSH in your tailnet ACLs.
#   4. Enables the application firewall, disables automatic login, requires
#      password immediately on wake.
#   5. pmset: never sleep, autorestart after power failure.
#
# Idempotent - safe to re-run. Every step logs DONE or SKIPPED (why), with a
# summary at the end. No secrets live in this repo: credentials come from env
# vars and the script fails loudly if one is needed but unset.
#
# Config via env (defaults shown):
#   BB_ADMIN_USER=m01                admin account for SSH + brew
#   BB_SCREENSHARING_USERS="m01"     space-separated allowlist
#   TS_AUTHKEY                       required only if Tailscale is not up yet
#   BB_ADMIN_PUBKEY                  required only if key not yet installed
#
# Deploy to all Macs:
#   for mac in mac1 mac2 ...; do
#     scp bb-remote-admin.sh m02@${mac}:/tmp/
#     ssh -t m02@${mac} 'sudo TS_AUTHKEY=... BB_ADMIN_PUBKEY="..." bash /tmp/bb-remote-admin.sh'
#   done

set -euo pipefail

BB_ADMIN_USER="${BB_ADMIN_USER:-m01}"
BB_SCREENSHARING_USERS="${BB_SCREENSHARING_USERS:-m01}"
LOG_FILE="/var/log/bb-remote-admin.log"
SSHD_DROPIN="/etc/ssh/sshd_config.d/100-bb-remote-admin.conf"
BREW="/opt/homebrew/bin/brew"
TS_BIN="/opt/homebrew/bin/tailscale"
TSD_BIN="/opt/homebrew/bin/tailscaled"
SFW="/usr/libexec/ApplicationFirewall/socketfilterfw"
SS_GROUP="com.apple.access_screensharing"

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

# ── 1. Screen Sharing, restricted ───────────────────────────────────────────
if ! dseditgroup -o read "$SS_GROUP" >/dev/null 2>&1; then
    dseditgroup -o create -q "$SS_GROUP" >/dev/null
    done_step "Created group $SS_GROUP"
else
    skip_step "Group $SS_GROUP already exists"
fi

for u in $BB_SCREENSHARING_USERS; do
    id "$u" >/dev/null 2>&1 || die "Screen-sharing user '$u' does not exist"
    if dseditgroup -o checkmember -m "$u" "$SS_GROUP" >/dev/null 2>&1; then
        skip_step "$u already in $SS_GROUP"
    else
        dseditgroup -o edit -q -a "$u" -t user "$SS_GROUP"
        done_step "Added $u to $SS_GROUP"
    fi
done

if launchctl print system/com.apple.screensharing >/dev/null 2>&1; then
    skip_step "Screen Sharing already enabled"
else
    launchctl enable system/com.apple.screensharing
    launchctl bootstrap system /System/Library/LaunchDaemons/com.apple.screensharing.plist 2>/dev/null || true
    launchctl kickstart system/com.apple.screensharing 2>/dev/null || true
    done_step "Enabled Screen Sharing (group-restricted; legacy VNC and ARD untouched)"
fi

# ── 2. SSH hardening ────────────────────────────────────────────────────────
ADMIN_HOME="$(dscl . -read "/Users/$BB_ADMIN_USER" NFSHomeDirectory | awk '{print $2}')"
[ -d "$ADMIN_HOME" ] || die "Home directory for $BB_ADMIN_USER not found: $ADMIN_HOME"

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
    else
        systemsetup -setremotelogin on >/dev/null
        done_step "Enabled Remote Login (SSH)"
    fi
    launchctl kickstart -k system/com.openssh.sshd 2>/dev/null || true
else
    skip_step "Remote Login: needs Full Disk Access. Grant it: System Settings > Privacy & Security > Full Disk Access > enable your terminal app (or sshd), then re-run this script."
fi

# ── 3. Tailscale (Homebrew standalone, not App Store) ───────────────────────
[ -x "$BREW" ] || die "Homebrew not found at $BREW"
BREW_OWNER="$(stat -f %Su /opt/homebrew)"

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
else
    [ -n "${TS_AUTHKEY:-}" ] || die "TS_AUTHKEY is not set and Tailscale is not up. Export an auth key from the admin console: TS_AUTHKEY=tskey-auth-..."
    "$TS_BIN" up --authkey "$TS_AUTHKEY" --ssh >>"$LOG_FILE" 2>&1 \
        || die "tailscale up failed - see $LOG_FILE"
    done_step "Tailscale up with Tailscale SSH (remember: scope it in tailnet ACLs)"
fi

# ── 4. Lockdown ─────────────────────────────────────────────────────────────
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

# ── 5. Power ────────────────────────────────────────────────────────────────
pmset -a sleep 0 displaysleep 0 disksleep 0 autorestart 1
done_step "pmset: never sleep, autorestart after power failure"

# ── Summary ─────────────────────────────────────────────────────────────────
log "=== Summary ==="
log "Completed: ${#DONE_STEPS[@]}"
for s in ${DONE_STEPS[@]+"${DONE_STEPS[@]}"}; do log "  + $s"; done
log "Skipped: ${#SKIPPED_STEPS[@]}"
for s in ${SKIPPED_STEPS[@]+"${SKIPPED_STEPS[@]}"}; do log "  - $s"; done
log "Log: $LOG_FILE"
