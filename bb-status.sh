#!/bin/bash
# bb-status.sh - what is actually true on this Mac right now.
#
#   sudo bash /Users/Shared/bb-headless/bb-status.sh     (or: sudo bb-status)
#
# Reads live state rather than trusting what an installer said. Run it with
# sudo to see every user; without sudo you only get your own login's detail.
# setup.sh calls it at the end of a run.
#
# No set -e on purpose: a failed probe should print a question mark, not abort
# the report.
set -uo pipefail

GREEN=$'\033[32m'; RED=$'\033[31m'; YELL=$'\033[33m'; DIM=$'\033[2m'; OFF=$'\033[0m'
ok()   { printf '  %s✓%s %s\n' "$GREEN" "$OFF" "$*"; }
bad()  { printf '  %s✗%s %s\n' "$RED" "$OFF" "$*"; }
warn() { printf '  %s!%s %s\n' "$YELL" "$OFF" "$*"; }
head_() { printf '\n%s\n' "$*"; }

IS_ROOT=0; [ "$(id -u)" -eq 0 ] && IS_ROOT=1
[ "$IS_ROOT" -eq 1 ] || printf '%s(not root - other users show limited detail; re-run with sudo)%s\n' "$DIM" "$OFF"

head_ "BlueBubbles, per user"
USERS="$(dscl . -list /Users UniqueID 2>/dev/null | awk '$2 >= 501 && $2 < 4294967294 {print $1}' | grep -v '^_')"
for u in $USERS; do
    home="$(dscl . -read "/Users/$u" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
    db="$home/Library/Application Support/bluebubbles-server/config.db"
    [ -e "$db" ] || continue

    port="$(sqlite3 "$db" "SELECT value FROM config WHERE name='socket_port'" 2>/dev/null)"
    findmy="$(sqlite3 "$db" "SELECT value FROM config WHERE name='open_findmy_on_startup'" 2>/dev/null)"
    pid="$(pgrep -u "$u" -f 'node.*headless' 2>/dev/null | head -1)"
    electron="$(pgrep -u "$u" -f 'BlueBubbles.app' 2>/dev/null | head -1)"
    plist="$home/Library/LaunchAgents/com.bb-headless.server.plist"

    printf '\n %s%s%s\n' "$DIM" "$u" "$OFF"
    if [ -n "$pid" ]; then ok "headless server running (pid $pid, port ${port:-?})"
    else bad "headless server NOT running - run 'bb-switch' from this login"; fi

    if [ -n "$electron" ]; then bad "Electron BlueBubbles still running (pid $electron) - it will fight for the port"
    else ok "Electron BlueBubbles quit"; fi

    case "$findmy" in
        0) ok "Find My on startup: off" ;;
        1) warn "Find My on startup: ON (costs ~200 MB) - BB_KEEP_FINDMY unset should have cleared this" ;;
        "") warn "Find My on startup: could not read (need sudo?)" ;;
        *) warn "Find My on startup: unexpected value '$findmy'" ;;
    esac

    if [ -e "$plist" ]; then ok "LaunchAgent installed (survives reboot)"
    elif [ "$IS_ROOT" -eq 1 ]; then bad "no LaunchAgent - will NOT come back after reboot"
    else warn "LaunchAgent: cannot read (need sudo)"; fi
done

head_ "Remote access"
NX="/Applications/NoMachine.app/Contents/Frameworks/bin/nxserver"
if [ -x "$NX" ]; then
    ok "NoMachine installed ($("$NX" --version 2>/dev/null | grep -i version | head -1 || echo version unknown))"
    SUB="$("$NX" --subscriptioninfo 2>&1)"
    if printf '%s' "$SUB" | grep -q "No subscription found"; then
        bad "NoMachine has NO subscription - it refuses every connection. Deploy this Mac's key.tar.gz"
    else
        ok "NoMachine subscription: $(printf '%s' "$SUB" | grep -vi warning | head -1)"
    fi
    if nc -z -w 2 localhost "${BB_NM_PORT:-4000}" >/dev/null 2>&1; then
        ok "NoMachine listening on ${BB_NM_PORT:-4000}"
    else
        bad "nothing listening on ${BB_NM_PORT:-4000} - reboot, or nxserver --restart"
    fi
    TCC="/Library/Application Support/com.apple.TCC/TCC.db"
    for pair in "kTCCServiceScreenCapture:Screen Recording" "kTCCServiceAccessibility:Accessibility"; do
        svc="${pair%%:*}"; label="${pair#*:}"
        v="$(sqlite3 "$TCC" "SELECT max(auth_value) FROM access WHERE service='$svc' AND client LIKE '%nomachine%';" 2>/dev/null)"
        case "$v" in
            2) ok "NoMachine has $label" ;;
            "") warn "NoMachine $label: cannot read TCC (needs Full Disk Access)" ;;
            *) bad "NoMachine missing $label - tick it in System Settings > Privacy & Security" ;;
        esac
    done
else
    warn "NoMachine not installed (expected if this Mac was set up with BB_NOMACHINE=0)"
fi

if launchctl print-disabled system 2>/dev/null | grep -q '"com.apple.screensharing" => enabled'; then
    ok "Screen Sharing on (fallback). BB_DISABLE_SCREENSHARING=1 turns it off"
else
    warn "Screen Sharing off - NoMachine and SSH are the only ways in"
fi

nc -z -w 2 localhost 22 >/dev/null 2>&1 && ok "SSH listening on 22" || bad "SSH not listening"

head_ "How to reach this Mac"
IFACE="$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')"
LAN_IP="$(ipconfig getifaddr "$IFACE" 2>/dev/null)"
echo "  On this LAN:  ${LAN_IP:-?}:${BB_NM_PORT:-4000}   or   $(scutil --get LocalHostName 2>/dev/null).local:${BB_NM_PORT:-4000}"

TS=""
for c in /usr/local/bin/tailscale /opt/homebrew/bin/tailscale; do
    if [ -x "$c" ]; then TS="$c"; break; fi
done
if [ -n "$TS" ]; then
    TS_IP="$("$TS" ip -4 2>/dev/null | head -1)"
    if [ -n "$TS_IP" ]; then
        ok "From anywhere:  $TS_IP:${BB_NM_PORT:-4000}  (Tailscale) - put this in NoMachine"
    else
        bad "Tailscale installed but not joined - run: sudo $TS up --ssh, then approve the URL"
    fi
else
    warn "No Tailscale - this Mac is reachable on the LAN ONLY. Fine for a VM with its own public address; on a mini it means no access while travelling."
fi

head_ "Old systems"
if [ -d /Applications/RustDesk.app ] || ls /Library/LaunchDaemons/com.carriez.*.plist >/dev/null 2>&1 || pgrep -fi rustdesk >/dev/null 2>&1; then
    warn "RustDesk still present - run uninstall-rustdesk.sh"
else
    ok "RustDesk gone"
fi
if [ -d /usr/local/lib/bb-autologin ] || [ -f /Library/LaunchDaemons/com.local.bb-autologin.plist ]; then
    warn "bb-autologin still present - run uninstall-autologin.sh"
else
    ok "bb-autologin gone"
fi

head_ "Logs"
echo "  /var/log/bb-headless-install.log   /var/log/bb-remote-admin.log"
echo "  /var/log/bb-headless-<user>.log    ~/Library/Logs/bb-headless.log"
