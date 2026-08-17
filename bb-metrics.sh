#!/bin/bash
# bb-metrics.sh - hourly health metrics for a BlueBubbles Mac mini
#
# Purpose: decide how many logins a box can hold by watching the two signals
# that precede a WindowServer watchdog kill: memory pressure and WindowServer
# CPU/footprint growth. Add a session, watch a week, compare.
#
# Usage:
#   sudo bash bb-metrics.sh install   # install LaunchDaemon (hourly sample)
#   sudo bash bb-metrics.sh           # take one sample now (what the daemon runs)
#   bash bb-metrics.sh show           # print the last 24 samples
#
# Output: /var/log/bb-metrics.csv, one row per sample:
#   ts                sample time
#   up_days           machine uptime in days (WindowServer bloat tracks this)
#   sessions          console sessions logged in
#   memlevel          kern.memorystatus_level (100=plenty free, <15=jetsam near)
#   comp_mb           compressed memory, MB (relief valve #1)
#   swap_mb           swap used, MB (relief valve #2; nonzero = RAM truly full)
#   load1             1-minute load average
#   ws_cpu_min        WindowServer cumulative CPU minutes (rate of growth matters)
#   ws_foot_mb        WindowServer footprint, MB (1600 MB = the Aug 16 kill)

set -euo pipefail

CSV="/var/log/bb-metrics.csv"
INSTALL_DIR="/usr/local/lib/bb-metrics"
PLIST_NAME="com.local.bb-metrics"
PLIST_DST="/Library/LaunchDaemons/${PLIST_NAME}.plist"

# ── show ──────────────────────────────────────────────────────────────────────
if [ "${1:-}" = "show" ]; then
    [ -f "$CSV" ] || { echo "No data yet at $CSV"; exit 1; }
    head -1 "$CSV"
    tail -24 "$CSV"
    exit 0
fi

[ "$(id -u)" -eq 0 ] || { echo "ERROR: run with sudo"; exit 1; }

# ── install ───────────────────────────────────────────────────────────────────
if [ "${1:-}" = "install" ]; then
    SCRIPT_PATH="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
    mkdir -p "$INSTALL_DIR"
    cp "$SCRIPT_PATH" "$INSTALL_DIR/bb-metrics.sh"
    chmod 755 "$INSTALL_DIR/bb-metrics.sh"
    cat > "$PLIST_DST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${PLIST_NAME}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>${INSTALL_DIR}/bb-metrics.sh</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>StartInterval</key>
    <integer>3600</integer>
    <key>ProcessType</key>
    <string>Background</string>
    <key>LowPriorityIO</key>
    <true/>
</dict>
</plist>
EOF
    chmod 644 "$PLIST_DST"
    chown root:wheel "$PLIST_DST"
    launchctl bootout system/"$PLIST_NAME" 2>/dev/null || true
    launchctl bootstrap system "$PLIST_DST"
    echo "Installed. Hourly samples -> $CSV"
    echo "View: bash $INSTALL_DIR/bb-metrics.sh show"
    exit 0
fi

# ── sample ────────────────────────────────────────────────────────────────────
[ -f "$CSV" ] || echo "ts,up_days,sessions,memlevel,comp_mb,swap_mb,load1,ws_cpu_min,ws_foot_mb" > "$CSV"

TS="$(date '+%Y-%m-%d %H:%M')"

BOOT_EPOCH="$(sysctl -n kern.boottime | sed 's/.*{ sec = \([0-9]*\),.*/\1/')"
UP_DAYS="$(( ($(date +%s) - BOOT_EPOCH) / 86400 ))"

SESSIONS="$(who | awk '$2=="console"' | wc -l | tr -d ' ')"

MEMLEVEL="$(sysctl -n kern.memorystatus_level)"

COMP_MB="$(vm_stat | awk '/occupied by compressor/{gsub(/\./,"",$NF); printf "%d", $NF*16384/1048576}')"

SWAP_MB="$(sysctl -n vm.swapusage | awk '{print $6}' | sed 's/M//' | cut -d. -f1)"

LOAD1="$(sysctl -n vm.loadavg | awk '{print $2}')"

WS_PID="$(pgrep -x WindowServer | head -1 || true)"
WS_CPU_MIN=0
WS_FOOT_MB=0
if [ -n "$WS_PID" ]; then
    # cumulative CPU as minutes (ps time format: [[dd-]hh:]mm:ss.cs)
    WS_CPU_MIN="$(ps -o time= -p "$WS_PID" | awk -F'[:.]' '{
        n=NF; s=$(n-1); m=$(n-2); h=0; d=0
        if (n>=4) h=$(n-3)
        if (h ~ /-/) { split(h,a,"-"); d=a[1]; h=a[2] }
        printf "%d", ((d*24+h)*60+m) + (s>=30 ? 1 : 0)
    }')"
    WS_FOOT_MB="$(footprint --pid "$WS_PID" --noCategories -f bytes 2>/dev/null \
        | awk '/Footprint:/{for(i=1;i<NF;i++) if($i=="Footprint:"){printf "%d", $(i+1)/1048576; exit}}')"
    [ -n "$WS_FOOT_MB" ] || WS_FOOT_MB="$(ps -o rss= -p "$WS_PID" | awk '{printf "%d", $1/1024}')"
fi

echo "$TS,$UP_DAYS,$SESSIONS,$MEMLEVEL,$COMP_MB,$SWAP_MB,$LOAD1,$WS_CPU_MIN,$WS_FOOT_MB" >> "$CSV"
