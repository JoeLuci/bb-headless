#!/bin/bash
# bb-tune.sh - keep a BlueBubbles relay Mac quiet: Spotlight + Bluetooth off, at every boot
#
# A relay Mac with 4-6 accounts logged in runs every "desktop Mac" background
# job once per account. At boot that stacks up to a load average of 100+ and
# the box freezes (sign-in hangs, RustDesk lags, servers stop answering).
# Measured 2026-10-06 on an M4 mini: load 131 -> 2 after this.
#
# What it turns off (all reversible, all unrelated to iMessage/BlueBubbles):
#   - Spotlight indexing on / and /System/Volumes/Data   (comes back ON after
#     every reboot on macOS 26, which is why this runs as a boot daemon)
#   - per account: Photos/media analysis, Siri knowledge indexing
#   - Bluetooth: the com.apple.bluetoothd system service is disabled at the launchd
#     level (no permission prompt, no Homebrew, works over SSH, persists across
#     reboots); skipped automatically while a Bluetooth keyboard/mouse/trackpad is
#     connected
#
# What it never touches: BlueBubbles servers, Messages/iCloud sign-in, RustDesk,
# Cloudflare, Tailscale, bb-metrics, bb-rustdesk-console, logins. It records
# which resident ones are RUNNING before it starts and exits 2 if any stopped.
#
# Usage (same shape as bb-metrics.sh):
#   sudo bash bb-tune.sh install     install boot daemon + apply now (fully unattended)
#   sudo bash bb-tune.sh             apply now (what the daemon runs)
#   sudo bash bb-tune.sh --dry-run   show what apply would do, change nothing
#   bash bb-tune.sh status           report (run with sudo for the full view)
#   sudo bash bb-tune.sh restore     undo everything and stop re-applying
#
# Daemon: com.local.bb-tune, RunAtLoad + every 6h, log /var/log/bb-tune.log
# Config: /usr/local/lib/bb-tune/config  (1 = on, 0 = off)
#   DISABLE_SPOTLIGHT=1  ERASE_SPOTLIGHT_INDEX=1  DISABLE_PHOTO_ANALYSIS=1
#   DISABLE_KNOWLEDGE=1  DISABLE_BLUETOOTH=1  BLUETOOTH_FORCE=0  LOG_CAP_MB=1024
#
# Exit codes: 0 ok (warnings possible, see log), 1 install/usage error,
#             2 a required service was running before and is not now.
# bash 3.2 compatible. Intel and Apple Silicon.

set -uo pipefail
export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"

INSTALL_DIR="/usr/local/lib/bb-tune"
PLIST_NAME="com.local.bb-tune"
PLIST_DST="/Library/LaunchDaemons/${PLIST_NAME}.plist"
CONF="$INSTALL_DIR/config"
LOG="/var/log/bb-tune.log"
LOCK="/var/run/bb-tune.lock"
DRY_RUN=0
WARNINGS=0

# ── defaults, overridable in $CONF ───────────────────────────────────────────
DISABLE_SPOTLIGHT=1
ERASE_SPOTLIGHT_INDEX=1
DISABLE_PHOTO_ANALYSIS=1
DISABLE_KNOWLEDGE=1
DISABLE_BLUETOOTH=1
BLUETOOTH_FORCE=0
LOG_CAP_MB=1024
[ -f "$CONF" ] && . "$CONF"

VOLUMES="/ /System/Volumes/Data"
PHOTO_AGENTS="com.apple.photoanalysisd com.apple.mediaanalysisd"
KNOWLEDGE_AGENTS="com.apple.spotlightknowledged com.apple.knowledgeconstructiond"
# resident services only: bb-metrics is an hourly job that runs for a second and exits,
# so it must not be here (it tripped the guard once, right after setup.sh reinstalled it)
CRITICAL_SYSTEM="com.carriez.RustDesk_service com.bb.rustdesk-console com.cloudflare.cloudflared com.tailscale.tailscaled"
CRITICAL_USER="com.bb-headless.server com.carriez.RustDesk_server"

# ── helpers ──────────────────────────────────────────────────────────────────
log()  { local m; m="$(date '+%Y-%m-%d %H:%M:%S') [bb-tune] $*"; echo "$m"
         [ "$DRY_RUN" = 1 ] || [ "${BB_TUNE_DAEMON:-0}" = 1 ] || { echo "$m" >> "$LOG"; } 2>/dev/null || true; }
warn() { WARNINGS=$((WARNINGS+1)); log "WARN: $*"; }
run()  { if [ "$DRY_RUN" = 1 ]; then log "would run: $*"; else "$@"; fi; }
is_root() { [ "$(id -u)" -eq 0 ]; }
need_root() { if [ "$DRY_RUN" != 1 ] && ! is_root; then echo "ERROR: run with sudo: sudo bash $0 ${1:-}"; exit 1; fi; }

detect_users() { dscl . -list /Users UniqueID 2>/dev/null | awk '$2 >= 501 && $2 < 4294967294 {print $1}' | grep -v '^_'; }
uid_of() { id -u "$1" 2>/dev/null; }

# "running" = launchd shows a pid for it (not merely loaded)
sys_running()  { launchctl print "system/$1" 2>/dev/null | grep -q 'pid = '; }
user_running() { launchctl print "gui/$1/$2" 2>/dev/null | grep -q 'pid = '; }

snapshot_critical() {
    local s u uid
    for s in $CRITICAL_SYSTEM; do sys_running "$s" && echo "system/$s"; done
    for u in $(detect_users); do
        uid="$(uid_of "$u")" || continue
        for s in $CRITICAL_USER; do user_running "$uid" "$s" && echo "gui/$uid/$s ($u)"; done
    done
    return 0
}

disable_agent() { run launchctl disable "gui/$1/$2" 2>/dev/null || run launchctl disable "user/$1/$2" 2>/dev/null || true
                  run launchctl bootout "gui/$1/$2" >/dev/null 2>&1 || true; }
enable_agent()  { run launchctl enable  "gui/$1/$2" 2>/dev/null || run launchctl enable  "user/$1/$2" 2>/dev/null || true; }

BT_SVC="com.apple.bluetoothd"
bt_running()  { pgrep -x bluetoothd >/dev/null 2>&1; }
bt_disabled() { launchctl print-disabled system 2>/dev/null | grep -q "\"$BT_SVC\" => disabled"; }
bt_hid_connected() {   # any Bluetooth keyboard/mouse/trackpad attached right now? (ioreg: fast, never hangs)
    ioreg -r -c IOBluetoothHIDDriver -d 1 2>/dev/null | grep -q '"Product"' ; }
bt_off() { run launchctl disable "system/$BT_SVC" 2>/dev/null || true; run launchctl bootout "system/$BT_SVC" >/dev/null 2>&1 || true; }
bt_on()  { run launchctl enable "system/$BT_SVC" 2>/dev/null || true
           run launchctl bootstrap system "/System/Library/LaunchDaemons/$BT_SVC.plist" >/dev/null 2>&1 || run launchctl kickstart "system/$BT_SVC" >/dev/null 2>&1 || true; }

arch_of() { file "$1" 2>/dev/null | grep -oE 'x86_64|arm64' | sort -u | tr '\n' ' '; }

# ── apply ────────────────────────────────────────────────────────────────────
do_apply() {
    if [ "$DRY_RUN" != 1 ]; then
        if ! mkdir "$LOCK" 2>/dev/null; then
            # stale lock (> 30 min) is removed; otherwise another apply is running
            if [ -n "$(find "$LOCK" -maxdepth 0 -mmin +30 2>/dev/null)" ]; then rmdir "$LOCK" 2>/dev/null; mkdir "$LOCK" 2>/dev/null || { log "another apply is running, skipping"; return 0; }
            else log "another apply is running, skipping"; return 0; fi
        fi
        trap 'rmdir "$LOCK" 2>/dev/null' EXIT
    fi
    log "=== apply start (arch=$(uname -m), macOS $(sw_vers -productVersion), host=$(hostname -s), load=$(sysctl -n vm.loadavg | awk '{print $2}')) ==="
    local before after u uid lbl v lost
    before="$(snapshot_critical)"
    log "required services running before: $(printf '%s\n' "$before" | grep -c .)"

    # 1. Spotlight
    if [ "$DISABLE_SPOTLIGHT" = 1 ]; then
        for v in $VOLUMES; do
            [ -d "$v" ] || continue
            [ "$DRY_RUN" = 1 ] && log "would run: mdutil -i off $v$([ "$ERASE_SPOTLIGHT_INDEX" = 1 ] && echo " ; mdutil -E $v")"
            run mdutil -i off "$v" >/dev/null 2>&1 || warn "mdutil -i off $v failed"
            if [ "$ERASE_SPOTLIGHT_INDEX" = 1 ]; then run mdutil -E "$v" >/dev/null 2>&1 || true; run mdutil -i off "$v" >/dev/null 2>&1 || true; fi
            if [ "$DRY_RUN" != 1 ]; then
                mdutil -s "$v" 2>/dev/null | grep -q -i 'disabled' && log "Spotlight: $v indexing disabled" || warn "Spotlight: could not confirm $v disabled: $(mdutil -s "$v" 2>&1 | tail -1 | tr -d '\t')"
            fi
        done
        # stop any indexer still chewing
        run pkill -x mds_stores 2>/dev/null || true; run pkill -f mdworker 2>/dev/null || true
    else log "Spotlight: left as-is (DISABLE_SPOTLIGHT=0)"; fi

    # 2. per-account agents
    for u in $(detect_users); do
        uid="$(uid_of "$u")" || { warn "no uid for $u"; continue; }
        if [ "$DISABLE_PHOTO_ANALYSIS" = 1 ]; then for lbl in $PHOTO_AGENTS; do disable_agent "$uid" "$lbl"; done; fi
        if [ "$DISABLE_KNOWLEDGE" = 1 ];      then for lbl in $KNOWLEDGE_AGENTS; do disable_agent "$uid" "$lbl"; done; fi
        log "user $u ($uid): photo analysis=$([ "$DISABLE_PHOTO_ANALYSIS" = 1 ] && echo off || echo kept), knowledge indexing=$([ "$DISABLE_KNOWLEDGE" = 1 ] && echo off || echo kept)"
    done

    # 3. Bluetooth (service-level, no permission prompt)
    if [ "$DISABLE_BLUETOOTH" = 1 ]; then
        if bt_hid_connected && [ "$BLUETOOTH_FORCE" != 1 ]; then
            warn "Bluetooth: a Bluetooth keyboard/mouse/trackpad is connected - leaving ON (BLUETOOTH_FORCE=1 overrides)"
        elif bt_disabled && ! bt_running; then
            log "Bluetooth: already off (bluetoothd disabled)"
        else
            [ "$DRY_RUN" = 1 ] && log "would run: launchctl disable system/$BT_SVC ; launchctl bootout system/$BT_SVC"
            bt_off
            if [ "$DRY_RUN" != 1 ]; then
                sleep 2
                if bt_disabled && ! bt_running; then log "Bluetooth: off (bluetoothd disabled, persists across reboots)"
                else warn "Bluetooth: could not disable bluetoothd (disabled=$(bt_disabled && echo yes || echo no), running=$(bt_running && echo yes || echo no))"; fi
            fi
        fi
    else log "Bluetooth: left as-is (DISABLE_BLUETOOTH=0)"; fi

    # 4. runaway / orphaned bb-headless logs (a deleted account's stale session wrote 3.7 GB in one hour)
    local f lu sz
    for f in /var/log/bb-headless-*.log; do
        [ -f "$f" ] || continue
        lu="${f##*/bb-headless-}"; lu="${lu%.log}"
        [ "$lu" = install ] && continue
        sz=$(( $(stat -f %z "$f" 2>/dev/null || echo 0) / 1048576 ))
        if ! id "$lu" >/dev/null 2>&1; then
            warn "log $f belongs to account '$lu' which no longer exists (${sz} MB)"
            if [ "$sz" -gt 0 ] && ! pgrep -u "$lu" -f headless.js >/dev/null 2>&1; then run truncate -s 0 "$f" 2>/dev/null && log "  truncated orphaned log $f"; fi
        elif [ "$sz" -gt "$LOG_CAP_MB" ]; then
            warn "log $f is ${sz} MB (> LOG_CAP_MB=$LOG_CAP_MB), truncating"; run truncate -s 0 "$f" 2>/dev/null || true
        fi
    done

    # 5. RustDesk build check (report only)
    local bin="/Applications/RustDesk.app/Contents/MacOS/RustDesk"
    if [ -x "$bin" ]; then
        if [ "$(uname -m)" = arm64 ] && ! arch_of "$bin" | grep -q arm64; then
            warn "RustDesk is the Intel build running under Rosetta on this Apple Silicon Mac; install the aarch64 build (over SSH/Tailscale, not through RustDesk)"
        else log "RustDesk build: $(arch_of "$bin")- OK for $(uname -m)"; fi
    fi

    # 6. integrity - a service mid-restart (installer just reloaded it, console
    # watcher flipping a RustDesk agent) must not read as lost: re-check 3x over ~15 s
    if [ "$DRY_RUN" != 1 ]; then
        local try
        for try in 1 2 3; do
            sleep 5
            after="$(snapshot_critical)"
            lost="$(comm -23 <(printf '%s\n' "$before" | sort) <(printf '%s\n' "$after" | sort) | grep .)"
            [ -z "$lost" ] && break
            log "integrity: $(printf '%s\n' "$lost" | grep -c .) service(s) not seen on check $try/3, re-checking"
        done
        if [ -n "$lost" ]; then
            log "ERROR: required services running before but NOT now:"; printf '%s\n' "$lost" | while read -r l; do log "   LOST: $l"; done
            log "ERROR: run 'sudo bash $0 restore' and report this"; log "=== apply FAILED ==="; return 2
        fi
        log "integrity: all $(printf '%s\n' "$before" | grep -c .) required services still running"
    fi
    log "=== apply done (warnings: $WARNINGS) ==="
    return 0
}

# ── restore ──────────────────────────────────────────────────────────────────
do_restore() {
    log "=== restore start ==="
    local u uid lbl v
    for v in $VOLUMES; do [ -d "$v" ] && { run mdutil -i on "$v" >/dev/null 2>&1 || true; }; done
    for u in $(detect_users); do uid="$(uid_of "$u")" || continue; for lbl in $PHOTO_AGENTS $KNOWLEDGE_AGENTS; do enable_agent "$uid" "$lbl"; done; done
    bt_on
    # make the daemon a no-op so it cannot undo this
    if [ "$DRY_RUN" != 1 ] && [ -d "$INSTALL_DIR" ]; then
        printf '# written by restore on %s - daemon is now a no-op\nDISABLE_SPOTLIGHT=0\nERASE_SPOTLIGHT_INDEX=0\nDISABLE_PHOTO_ANALYSIS=0\nDISABLE_KNOWLEDGE=0\nDISABLE_BLUETOOTH=0\n' "$(date)" > "$CONF"
    fi
    warn "Spotlight is re-indexing every account now; expect high load for a while"
    log "restored. To re-enable tuning: delete $CONF and run 'sudo bash $0'. To remove the daemon: sudo launchctl bootout system/$PLIST_NAME; sudo rm $PLIST_DST"
}

# ── status ───────────────────────────────────────────────────────────────────
do_status() {
    local v
    echo "host:       $(hostname -s)   $(uname -m)   macOS $(sw_vers -productVersion)   load $(sysctl -n vm.loadavg | awk '{print $2}')"
    for v in $VOLUMES; do [ -d "$v" ] && echo "spotlight:  $v -> $(mdutil -s "$v" 2>/dev/null | tail -1 | tr -d '\t')"; done
    echo "bluetooth:  bluetoothd $(bt_running && echo running || echo 'not running'), $(bt_disabled && echo disabled || echo enabled)$(bt_hid_connected && echo '  (BT keyboard/mouse connected)')"
    echo "daemon:     $(sys_running "$PLIST_NAME" >/dev/null 2>&1 || launchctl print "system/$PLIST_NAME" >/dev/null 2>&1 && echo installed || echo 'not installed')"
    echo "accounts:   $(detect_users | tr '\n' ' ')"
    echo "required services running:"; snapshot_critical | sed 's/^/   /'
    is_root || echo "(run with sudo to see other accounts' services)"
}

# ── install ──────────────────────────────────────────────────────────────────
do_install() {
    [ -f "$0" ] || { echo "ERROR: run from a file: sudo bash /path/to/bb-tune.sh install"; return 1; }
    log "installing to $INSTALL_DIR"
    mkdir -p "$INSTALL_DIR" && cp "$0" "$INSTALL_DIR/bb-tune.sh" && chmod 755 "$INSTALL_DIR/bb-tune.sh" || { log "ERROR: could not copy script"; return 1; }
    if [ ! -f "$CONF" ]; then
        printf '# bb-tune machine config (1 on, 0 off). Re-applied at boot + every 6h.\n#DISABLE_SPOTLIGHT=1\n#ERASE_SPOTLIGHT_INDEX=1\n#DISABLE_PHOTO_ANALYSIS=1\n#DISABLE_KNOWLEDGE=1\n#DISABLE_BLUETOOTH=1\n#BLUETOOTH_FORCE=0\n#LOG_CAP_MB=1024\n' > "$CONF"
    fi
    chown -R root:wheel "$INSTALL_DIR"

    cat > "$PLIST_DST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${PLIST_NAME}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>${INSTALL_DIR}/bb-tune.sh</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>BB_TUNE_DAEMON</key>
        <string>1</string>
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>StartInterval</key>
    <integer>21600</integer>
    <key>StandardOutPath</key>
    <string>${LOG}</string>
    <key>StandardErrorPath</key>
    <string>${LOG}</string>
    <key>ProcessType</key>
    <string>Background</string>
    <key>LowPriorityIO</key>
    <true/>
</dict>
</plist>
PLIST
    chmod 644 "$PLIST_DST"; chown root:wheel "$PLIST_DST"
    # apply first (holds the lock), then load the daemon; its immediate run is a cheap idempotent re-apply
    do_apply; local rc=$?
    launchctl bootout "system/$PLIST_NAME" 2>/dev/null || true
    launchctl bootstrap system "$PLIST_DST" 2>/dev/null || warn "launchctl bootstrap failed; daemon will load at next boot"
    log "daemon $PLIST_NAME installed (boot + every 6h). Log: $LOG"
    return $rc
}

# ── main ─────────────────────────────────────────────────────────────────────
case "${1:-}" in
    install)   need_root install; do_install ;;
    "")        need_root; do_apply ;;
    --dry-run) DRY_RUN=1; do_apply ;;
    status)    do_status ;;
    restore)   need_root restore; do_restore ;;
    *)         echo "usage: sudo bash $0 [install|status|restore|--dry-run]"; exit 1 ;;
esac
