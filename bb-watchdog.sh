#!/bin/bash
# bb-watchdog.sh - install, check or remove the Viato Mac Health watchdog
#
# The watchdog (bb-watchdog.js) is a root LaunchDaemon that reports this Mac's
# health to Viato every minute and, when Auto-fix is on in Super Admin >
# Viato Phone > Management > Mac Health, restarts a line server that stopped
# answering and quits a stuck universalaccessd / ControlCenter. It also runs
# the fixed actions a Super Admin clicks there. It never kills coreaudiod or
# WindowServer and never restarts the Mac on its own.
#
# Usage:
#   sudo bash bb-watchdog.sh install [--url https://viato.ai]
#        asks for the one-time Connect code from the Health tab (or reads it
#        from stdin), so the code never lands in the command line or history
#   sudo bash bb-watchdog.sh install --update
#        installs a newer bb-watchdog.js / node on a Mac that is already
#        connected: keeps its key and settings, no Connect code needed
#   bash bb-watchdog.sh status
#   sudo bash bb-watchdog.sh uninstall
#
# Everything the root daemon runs lives in /opt/bb-watchdog, a root-only path,
# including its own copy of node: the shared node on these Macs belongs to a
# regular account, so it is copied only after its Node.js Foundation signature
# checks out (or downloaded from nodejs.org and checked against SHASUMS256).
#
# bash 3.2 compatible. Intel and Apple Silicon.

set -uo pipefail
umask 022   # see setup.sh
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"

HOME_DIR="/opt/bb-watchdog"
PLIST_NAME="com.local.bb-watchdog"
PLIST_DST="/Library/LaunchDaemons/${PLIST_NAME}.plist"
LOG="/var/log/bb-watchdog.log"
STATE_DIR="/var/db/bb-watchdog"
NODE_FALLBACK_VERSION="v24.19.0"
NODE_TEAM="HX7739G8FX"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

die() { echo "ERROR: $*" >&2; exit 1; }
need_root() { [ "$(id -u)" -eq 0 ] || die "run with sudo: sudo bash $0 $1"; }

# owner root and no group/other write bit
root_only() {
    local p="$1" owner mode
    owner="$(stat -f '%Su' "$p" 2>/dev/null)" || return 1
    mode="$(stat -f '%Lp' "$p" 2>/dev/null)" || return 1
    [ "$owner" = "root" ] || return 1
    [ $(( 8#$mode & 8#022 )) -eq 0 ]
}

node_signed() {
    local n="$1" info
    codesign --verify --strict "$n" >/dev/null 2>&1 || return 1
    info="$(codesign -dvv "$n" 2>&1)"
    echo "$info" | grep -q "^Authority=Developer ID Application: Node.js Foundation (${NODE_TEAM})$" || return 1
    echo "$info" | grep -q "^TeamIdentifier=${NODE_TEAM}$"
}

node_major() { "$1" -p 'process.versions.node.split(".")[0]' 2>/dev/null; }

# readlink -f exists on macOS 12.3 and later (every phone Mac); never python3,
# which on a Mac without the developer tools opens an install dialog.
real_path() { readlink -f "$1" 2>/dev/null || echo "$1"; }

# The node the BlueBubbles servers run, else the usual shared spots.
node_candidates() {
    local plist
    for plist in /Users/*/Library/LaunchAgents/com.bb-headless.server.plist; do
        [ -f "$plist" ] || continue
        /usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$plist" 2>/dev/null
    done
    echo /usr/local/bin/node
    echo /usr/local/lib/nodejs/bin/node
    echo /opt/homebrew/bin/node
}

pick_node() {
    local c real
    while read -r c; do
        [ -n "$c" ] && [ -x "$c" ] || continue
        real="$(real_path "$c")"
        [ -f "$real" ] || continue
        if node_signed "$real"; then echo "$real"; return 0; fi
        echo "  $real is not the official signed node build; skipping it" >&2
    done < <(node_candidates | awk '!seen[$0]++')
    return 1
}

download_node() {
    local arch tmp name sums want got
    case "$(uname -m)" in arm64) arch=arm64 ;; x86_64) arch=x64 ;; *) die "unknown CPU $(uname -m)" ;; esac
    name="node-${NODE_FALLBACK_VERSION}-darwin-${arch}"
    tmp="$(mktemp -d)" || die "mktemp failed"
    echo "  downloading ${name} from nodejs.org" >&2
    curl -fsSL --max-time 300 -o "$tmp/$name.tar.gz" "https://nodejs.org/dist/${NODE_FALLBACK_VERSION}/${name}.tar.gz" || { rm -rf "$tmp"; die "node download failed"; }
    sums="$(curl -fsSL --max-time 60 "https://nodejs.org/dist/${NODE_FALLBACK_VERSION}/SHASUMS256.txt")" || { rm -rf "$tmp"; die "could not fetch SHASUMS256.txt"; }
    want="$(echo "$sums" | awk -v f="${name}.tar.gz" '$2==f{print $1}')"
    got="$(shasum -a 256 "$tmp/$name.tar.gz" | awk '{print $1}')"
    [ -n "$want" ] && [ "$want" = "$got" ] || { rm -rf "$tmp"; die "node tarball checksum does not match nodejs.org"; }
    tar -xzf "$tmp/$name.tar.gz" -C "$tmp" "$name/bin/node" || { rm -rf "$tmp"; die "could not extract node"; }
    node_signed "$tmp/$name/bin/node" || { rm -rf "$tmp"; die "downloaded node is not signed by the Node.js Foundation"; }
    echo "$tmp/$name/bin/node"
}

do_install() {
    need_root install
    local url="https://viato.ai" code src update=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --url) url="${2:-}"; shift 2 ;;
            --update) update=1; shift ;;
            *) die "unknown option $1" ;;
        esac
    done
    if [ "$update" = 1 ]; then
        [ -s "$HOME_DIR/key" ] && [ -s "$HOME_DIR/platform_uuid" ] || die "--update needs a connected watchdog; run install without --update"
    fi
    case "$url" in https://*) ;; *) die "--url must start with https://" ;; esac
    [ -f "$SCRIPT_DIR/bb-watchdog.js" ] || die "bb-watchdog.js not found next to this script"

    root_only / || die "/ is not root-only on this Mac ($(stat -f '%Su %Lp' /))"
    [ -d /opt ] || { mkdir -p /opt && chown root:wheel /opt && chmod 755 /opt; }
    root_only /opt || die "/opt is not root-only on this Mac ($(stat -f '%Su %Lp' /opt)); fix it before installing"
    mkdir -p "$HOME_DIR" && chown root:wheel "$HOME_DIR" && chmod 755 "$HOME_DIR" || die "could not create $HOME_DIR"

    echo "Node:"
    src="$(pick_node)" || src="$(download_node)" || die "no usable node"
    cp -X "$src" "$HOME_DIR/node.new" && chown root:wheel "$HOME_DIR/node.new" && chmod 755 "$HOME_DIR/node.new" || die "could not copy node"
    # Check the copy, not the source: the source belongs to another account and could change after the first check.
    node_signed "$HOME_DIR/node.new" || { rm -f "$HOME_DIR/node.new"; die "the copied node is not the official signed build"; }
    [ "$("$HOME_DIR/node.new" -e 'process.stdout.write("ok")' 2>/dev/null)" = "ok" ] || die "copied node does not run"
    [ "$(node_major "$HOME_DIR/node.new")" -ge 18 ] 2>/dev/null || die "node 18 or newer is required"
    mv -f "$HOME_DIR/node.new" "$HOME_DIR/node"
    echo "  using a root-owned copy of $src ($("$HOME_DIR/node" -v))"

    cp -X "$SCRIPT_DIR/bb-watchdog.js" "$HOME_DIR/bb-watchdog.js" && chown root:wheel "$HOME_DIR/bb-watchdog.js" && chmod 644 "$HOME_DIR/bb-watchdog.js" || die "could not copy bb-watchdog.js"
    cp -X "$0" "$HOME_DIR/bb-watchdog.sh" 2>/dev/null && chown root:wheel "$HOME_DIR/bb-watchdog.sh" && chmod 755 "$HOME_DIR/bb-watchdog.sh"
    mkdir -p "$STATE_DIR" && chown root:wheel "$STATE_DIR" && chmod 700 "$STATE_DIR"

    # Stop a running watchdog first, so it cannot write state while the new one is set up.
    launchctl bootout "system/$PLIST_NAME" 2>/dev/null || true

    if [ "$update" = 0 ]; then
        if [ -t 0 ]; then
            printf "Paste the Connect code from the Health tab: "
            IFS= read -r -s code; echo
        else
            IFS= read -r code
        fi
        [ -n "$code" ] || { restore_daemon; die "no Connect code"; }
        if ! printf '%s' "$code" | "$HOME_DIR/node" "$HOME_DIR/bb-watchdog.js" enroll --url "$url"; then
            restore_daemon
            die "enroll failed (a watchdog that was already connected keeps running with its old key)"
        fi
        code=""
    fi

    cat > "$PLIST_DST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${PLIST_NAME}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${HOME_DIR}/node</string>
        <string>${HOME_DIR}/bb-watchdog.js</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>30</integer>
    <key>StandardErrorPath</key>
    <string>${LOG}.err</string>
</dict>
</plist>
PLIST
    chmod 644 "$PLIST_DST"; chown root:wheel "$PLIST_DST"
    rotate_log
    launchctl bootstrap system "$PLIST_DST" || die "launchctl bootstrap failed"
    echo "Watchdog installed. It reports every minute; check it with: bash $HOME_DIR/bb-watchdog.sh status"
}

# After a failed Connect, put back the watchdog that was running (its old key still works).
restore_daemon() {
    if [ -f "$PLIST_DST" ] && [ -s "$HOME_DIR/key" ]; then
        launchctl bootstrap system "$PLIST_DST" 2>/dev/null && echo "  the previous watchdog was started again" >&2
    fi
}

rotate_log() {
    local size
    size="$(stat -f '%z' "$LOG" 2>/dev/null || echo 0)"
    if [ "$size" -gt 5242880 ]; then mv -f "$LOG" "$LOG.1"; fi
    size="$(stat -f '%z' "$LOG.err" 2>/dev/null || echo 0)"
    if [ "$size" -gt 1048576 ]; then mv -f "$LOG.err" "$LOG.err.1"; fi
}

do_status() {
    if launchctl print "system/$PLIST_NAME" >/dev/null 2>&1; then
        echo "daemon:   loaded ($(launchctl print "system/$PLIST_NAME" 2>/dev/null | awk '/state =/{print $3; exit}'))"
    else
        echo "daemon:   not loaded"
    fi
    if [ -x "$HOME_DIR/node" ] && [ -r "$STATE_DIR/state.json" ]; then
        "$HOME_DIR/node" "$HOME_DIR/bb-watchdog.js" status
    elif [ -x "$HOME_DIR/node" ]; then
        echo "state:    (run with sudo to read it)"
    fi
    [ -r "$LOG" ] && { echo "last log lines:"; tail -8 "$LOG" | sed 's/^/   /'; }
}

do_uninstall() {
    need_root uninstall
    if [ -x "$HOME_DIR/node" ] && [ -f "$HOME_DIR/bb-watchdog.js" ]; then
        "$HOME_DIR/node" "$HOME_DIR/bb-watchdog.js" uninstall-report 2>/dev/null || true
    fi
    launchctl bootout "system/$PLIST_NAME" 2>/dev/null || true
    rm -f "$PLIST_DST" "$LOG.err" "$LOG.err.1"
    rm -rf "$HOME_DIR" "$STATE_DIR"
    echo "Watchdog removed. Its row in Mac Health now shows Not connected."
}

case "${1:-}" in
    install)   shift; do_install "$@" ;;
    status)    do_status ;;
    uninstall) do_uninstall ;;
    *)         echo "usage: sudo bash $0 install [--url https://viato.ai] [--update] | bash $0 status | sudo bash $0 uninstall"; exit 1 ;;
esac
