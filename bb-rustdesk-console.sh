#!/bin/bash
# bb-rustdesk-console.sh - keep exactly ONE RustDesk session agent running: the
# one belonging to whoever owns the physical console. Runs as a root
# LaunchDaemon (installed by bb-rustdesk.sh) and re-checks every 3 seconds.
#
# Why: RustDesk assumes one logged-in user. On these Macs five users are logged
# in at once, each session auto-starts `RustDesk --server`, all five register
# the same ID, and the relay hands a connection to whichever registered last -
# usually a background session, whose desktop you then see and cannot control.
# With only the console user's agent alive, a connection always lands on the
# session that is actually on screen, and Fast User Switching is followed
# within a few seconds.
#
#   bb-rustdesk-console.sh          run the loop (what the daemon does)
#   bb-rustdesk-console.sh once     one pass, then exit (used after setup)
set -uo pipefail

AGENT_PLIST="/Library/LaunchAgents/com.carriez.RustDesk_server.plist"
LABEL="com.carriez.RustDesk_server"
LOG="/var/log/bb-rustdesk-console.log"
log() { printf '%s %s\n' "$(date '+%H:%M:%S')" "$*" >> "$LOG"; }

agent_running_for() { pgrep -u "$1" -f "RustDesk --server" >/dev/null 2>&1; }

start_agent() {  # as the user, into their own gui domain
    local u="$1" uid; uid="$(id -u "$u" 2>/dev/null)" || return 1
    sudo -u "$u" launchctl bootstrap "gui/$uid" "$AGENT_PLIST" 2>/dev/null \
        || sudo -u "$u" launchctl kickstart -k "gui/$uid/$LABEL" 2>/dev/null || true
}

stop_agent() {
    local u="$1" uid; uid="$(id -u "$u" 2>/dev/null)" || return 1
    sudo -u "$u" launchctl bootout "gui/$uid/$LABEL" 2>/dev/null || true
    pkill -u "$u" -f "RustDesk --server" 2>/dev/null || true
}

pass() {
    local console u
    console="$(stat -f %Su /dev/console 2>/dev/null)"
    [ -n "$console" ] || return 0
    # At the login window /dev/console is root: the LoginWindow agent handles it.
    for u in $(who | awk '/console/ {print $1}' | sort -u); do
        if [ "$u" = "$console" ]; then
            agent_running_for "$u" || { start_agent "$u"; log "console=$console: started agent for $u"; }
        else
            agent_running_for "$u" && { stop_agent "$u"; log "console=$console: stopped background agent for $u"; }
        fi
    done
}

if [ "${1:-}" = "once" ]; then pass; exit 0; fi
log "watcher started"
while :; do pass; sleep 3; done
