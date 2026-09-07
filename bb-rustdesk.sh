#!/bin/bash
# bb-rustdesk.sh - RustDesk for unattended remote access to a BlueBubbles Mac.
# Run with: sudo bash bb-rustdesk.sh            (install / update / re-apply)
#           sudo bash bb-rustdesk.sh status     (ID, password, permissions)
#
# Free (AGPL), no per-machine licence, reaches the Mac through RustDesk's
# public rendezvous/relay - no VPN needed to connect. Tailscale stays for SSH
# and as the Screen Sharing fallback.
#
# What this does:
#   1. Installs RustDesk.app from the GitHub release matching this CPU.
#   2. Writes RustDesk's own launchd daemon + agent plists (byte-for-byte what
#      the app's "Install service" button writes, minus the admin dialog) and
#      starts them: daemon in the system domain, agent in every logged-in
#      user's session and at the login window - so it works after a reboot.
#   3. Sets the permanent password and unattended (password-only) approval.
#      BB_RD_PASSWORD=... to choose it; otherwise one is generated once and
#      kept root-only in /var/root/bb-rustdesk-password. Re-runs reuse it.
#   4. Prints the 9-digit ID to connect to.
#
# Not scriptable, by macOS design: Screen Recording, Accessibility and Input
# Monitoring for RustDesk must be ticked in System Settings on each Mac. The
# status output says which are still missing.
#
# Config via env:
#   BB_RD_PASSWORD        permanent password (else generated + stored)
#   BB_RD_INSTALLER       local .dmg to install from (else GitHub latest)
#   BB_RD_VERSION         pin a release tag, e.g. 1.4.9 (else latest)

set -euo pipefail

RD_APP="/Applications/RustDesk.app"
RD_BIN="$RD_APP/Contents/MacOS/RustDesk"
RD_DAEMON_PLIST="/Library/LaunchDaemons/com.carriez.RustDesk_service.plist"
RD_AGENT_PLIST="/Library/LaunchAgents/com.carriez.RustDesk_server.plist"
RD_PW_FILE="/var/root/bb-rustdesk-password"
LOG_FILE="/var/log/bb-rustdesk.log"
TCC_DB="/Library/Application Support/com.apple.TCC/TCC.db"

log()  { printf '%s [bb-rustdesk] %s\n' "$(date '+%H:%M:%S')" "$*" | tee -a "$LOG_FILE"; }
die()  { log "ERROR: $*"; exit 1; }
[ "$(id -u)" -eq 0 ] || die "Run with sudo: sudo bash $0"

rd_tcc() {  # 0 = granted
    local v
    v="$(sqlite3 "$TCC_DB" "SELECT max(auth_value) FROM access WHERE service='$1' AND client LIKE '%carriez%';" 2>/dev/null || true)"
    [ "$v" = "2" ]
}

rd_id() { "$RD_BIN" --get-id 2>/dev/null | tr -d '[:space:]' || true; }

rd_status() {
    echo "RustDesk"
    if [ -x "$RD_BIN" ]; then
        echo "  installed: $("$RD_BIN" --version 2>/dev/null | head -1 || echo yes)"
    else
        echo "  NOT installed"; return 0
    fi
    if launchctl print system/com.carriez.RustDesk_service >/dev/null 2>&1; then
        echo "  service: running"
    else
        echo "  service: NOT running (sudo bash $0 to repair)"
    fi
    local id; id="$(rd_id)"
    if [ -n "$id" ]; then echo "  ID: $id"; else echo "  ID: (service not answering yet - wait a few seconds and re-run)"; fi
    if [ -s "$RD_PW_FILE" ]; then echo "  password: $(cat "$RD_PW_FILE")"; else echo "  password: (none stored - BB_RD_PASSWORD was given at install, or not set yet)"; fi
    local missing=""
    if sqlite3 "$TCC_DB" "SELECT 1;" >/dev/null 2>&1; then
        rd_tcc kTCCServiceScreenCapture || missing="$missing Screen-Recording"
        rd_tcc kTCCServiceAccessibility || missing="$missing Accessibility"
        rd_tcc kTCCServiceListenEvent   || missing="$missing Input-Monitoring"
        if [ -z "$missing" ]; then echo "  permissions: Screen Recording, Accessibility, Input Monitoring all granted"
        else echo "  permissions MISSING:$missing  -> System Settings > Privacy & Security, tick RustDesk in each"; fi
    else
        echo "  permissions: cannot read TCC (no Full Disk Access)"
    fi
}

if [ "${1:-install}" = "status" ]; then rd_status; exit 0; fi

# ── 1. Install ───────────────────────────────────────────────────────────────
if [ -x "$RD_BIN" ]; then
    log "RustDesk already installed ($("$RD_BIN" --version 2>/dev/null | head -1 || true))"
else
    case "$(uname -m)" in
        arm64)  RD_ARCH="aarch64" ;;
        x86_64) RD_ARCH="x86_64" ;;
        *) die "unsupported CPU $(uname -m)" ;;
    esac
    SRC="${BB_RD_INSTALLER:-}"; TMP=""
    if [ -z "$SRC" ]; then
        TAG="${BB_RD_VERSION:-}"
        [ -n "$TAG" ] || TAG="$(curl -fsSL --max-time 20 https://api.github.com/repos/rustdesk/rustdesk/releases/latest 2>/dev/null \
            | /usr/bin/python3 -c "import json,sys; print(json.load(sys.stdin)[\"tag_name\"])" 2>/dev/null || true)"
        [ -n "$TAG" ] || TAG="1.4.9"
        URL="https://github.com/rustdesk/rustdesk/releases/download/$TAG/rustdesk-$TAG-$RD_ARCH.dmg"
        TMP="$(mktemp -d)"; SRC="$TMP/rustdesk.dmg"
        log "Downloading RustDesk $TAG ($RD_ARCH)"
        curl -fsSL --retry 3 --max-time 600 -o "$SRC" "$URL" || die "download failed: $URL"
    fi
    [ -f "$SRC" ] || die "installer not found: $SRC"
    hdiutil imageinfo "$SRC" >/dev/null 2>&1 || die "$SRC is not a disk image"
    MNT="$(mktemp -d)"
    hdiutil attach -nobrowse -readonly -mountpoint "$MNT" "$SRC" >>"$LOG_FILE" 2>&1 || die "could not mount $SRC"
    if [ -d "$MNT/RustDesk.app" ]; then
        rm -rf "$RD_APP"
        cp -R "$MNT/RustDesk.app" /Applications/
    else
        hdiutil detach "$MNT" >/dev/null 2>&1 || true
        die "no RustDesk.app inside $SRC"
    fi
    hdiutil detach "$MNT" >/dev/null 2>&1 || true
    if [ -n "$TMP" ]; then rm -rf "$TMP"; fi
    xattr -dr com.apple.quarantine "$RD_APP" 2>/dev/null || true
    chown -R root:wheel "$RD_APP"; chmod -R a+rX "$RD_APP"
    [ -x "$RD_BIN" ] || die "install finished but $RD_BIN is missing"
    log "Installed RustDesk ($("$RD_BIN" --version 2>/dev/null | head -1 || true))"
fi

# ── 2. Service ───────────────────────────────────────────────────────────────
# These are RustDesk's own templates (src/platform/privileges_scripts).
cat > "$RD_DAEMON_PLIST" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
    <dict>
        <key>Label</key>
        <string>com.carriez.RustDesk_service</string>
        <key>AssociatedBundleIdentifiers</key>
        <string>com.carriez.rustdesk</string>
        <key>KeepAlive</key>
        <true/>
        <key>ThrottleInterval</key>
        <integer>1</integer>
        <key>ProgramArguments</key>
        <array>
        <string>/bin/sh</string>
        <string>-c</string>
        <string>/Applications/RustDesk.app/Contents/MacOS/service</string>
        </array>
        <key>RunAtLoad</key>
        <true/>
        <key>WorkingDirectory</key>
        <string>/Applications/RustDesk.app/Contents/MacOS/</string>
        <key>StandardErrorPath</key>
        <string>/var/log/rustdesk_service.err</string>
        <key>StandardOutPath</key>
        <string>/var/log/rustdesk_service.out</string>
    </dict>
</plist>
PLIST
cat > "$RD_AGENT_PLIST" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
    <dict>
        <key>Label</key>
        <string>com.carriez.RustDesk_server</string>
        <key>AssociatedBundleIdentifiers</key>
        <string>com.carriez.rustdesk</string>
        <key>LimitLoadToSessionType</key>
        <array>
          <string>LoginWindow</string>
          <string>Aqua</string>
        </array>
        <key>KeepAlive</key>
        <dict>
            <key>SuccessfulExit</key>
            <false />
            <key>AfterInitialDemand</key>
            <false />
        </dict>
        <key>ThrottleInterval</key>
        <integer>1</integer>
        <key>RunAtLoad</key>
        <true />
        <key>ProgramArguments</key>
        <array>
            <string>/Applications/RustDesk.app/Contents/MacOS/RustDesk</string>
            <string>--server</string>
        </array>
        <key>WorkingDirectory</key>
        <string>/Applications/RustDesk.app/Contents/MacOS/</string>
        <key>ProcessType</key>
        <string>Interactive</string>
    </dict>
</plist>
PLIST
chown root:wheel "$RD_DAEMON_PLIST" "$RD_AGENT_PLIST"; chmod 644 "$RD_DAEMON_PLIST" "$RD_AGENT_PLIST"
mkdir -p /var/root/Library/Preferences/com.carriez.RustDesk

launchctl bootout system/com.carriez.RustDesk_service 2>/dev/null || true
launchctl bootstrap system "$RD_DAEMON_PLIST" 2>>"$LOG_FILE" || launchctl load -w "$RD_DAEMON_PLIST" 2>>"$LOG_FILE" || true
# Agent: every session that is on the console now, plus the login window so a
# rebooted Mac is reachable before anyone logs in.
for uid in $(who | awk '/console/ {print $1}' | sort -u | xargs -n1 id -u 2>/dev/null); do
    launchctl bootout "gui/$uid/com.carriez.RustDesk_server" 2>/dev/null || true
    launchctl bootstrap "gui/$uid" "$RD_AGENT_PLIST" 2>>"$LOG_FILE" || true
done
launchctl load -w -S LoginWindow "$RD_AGENT_PLIST" 2>/dev/null || true
log "Service installed and started"

# ── 3. Password + unattended mode ───────────────────────────────────────────
PW="${BB_RD_PASSWORD:-}"
if [ -z "$PW" ] && [ -s "$RD_PW_FILE" ]; then PW="$(cat "$RD_PW_FILE")"; fi
if [ -z "$PW" ]; then
    PW="$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 16)"
    log "Generated a permanent password (kept root-only in $RD_PW_FILE)"
fi
umask 077; printf '%s\n' "$PW" > "$RD_PW_FILE"; chmod 600 "$RD_PW_FILE"; umask 022

# The CLI talks to the running service over IPC; give it a moment to come up.
ID=""
for _ in $(seq 1 15); do
    ID="$(rd_id)"
    [ -n "$ID" ] && break
    sleep 2
done
[ -n "$ID" ] || die "RustDesk service is not answering (no ID after 30s) - see /var/log/rustdesk_service.err"

"$RD_BIN" --password "$PW" >>"$LOG_FILE" 2>&1 || die "could not set the permanent password - see $LOG_FILE"
"$RD_BIN" --option verification-method use-permanent-password >>"$LOG_FILE" 2>&1 || true
"$RD_BIN" --option approve-mode password >>"$LOG_FILE" 2>&1 || true
log "Permanent password set; unattended (password-only) approval on"

# ── Summary ─────────────────────────────────────────────────────────────────
echo ""
rd_status
echo ""
echo "Connect: open RustDesk on your laptop/phone, enter ID $ID, then the password above."
