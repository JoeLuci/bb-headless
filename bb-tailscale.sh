#!/bin/bash
# bb-tailscale.sh - Tailscale on a VPS box (BB_VM=1): a shell that does not need the desktop.
# Run with: sudo bash bb-tailscale.sh            (install / repair, join the tailnet)
#           sudo bash bb-tailscale.sh update     (upgrade Tailscale, then the same checks)
#           bash bb-tailscale.sh status          (report; no sudo needed, writes nothing)
#
# Why: on 2026-10-16 WindowServer crashed on VPS-01 (HostMyApple M4, SDMM792).
# Every GUI session but one died, 4 of 5 phone lines went down, NoMachine said
# "No available desktops", the provider panel's Reboot and Screen Sharing both
# hung on the stuck session, and from the internet only NoMachine's port is
# reachable. Getting a shell for `sudo reboot` took about an hour and a borrowed
# SSH key on another VPS box. This gives every VPS box Tailscale SSH, served by
# the open-source tailscaled system daemon, which does not depend on the GUI: a
# hung desktop becomes `tailscale ssh joe@<name>` and `sudo reboot`.
#
# It only adds Tailscale. The provider's NoMachine (the way in to the desktop),
# SSH config, firewall, autologin and Screen Sharing are never touched. setup.sh
# runs it in VPS mode; minis get Tailscale from bb-remote-admin.sh instead.
#
# This INTENTIONALLY DIVERGES from bb-remote-admin.sh step 4: Homebrew prefix by
# architecture (never chown /usr/local), KeepAlive in the daemon plist, every
# CLI call pinned to the daemon socket, `tailscale set` instead of `up` on a
# joined box, auth key only from a file, `up --timeout`. Do NOT sync the two in
# either direction without Joe.
#
# What this does (each step logs DONE or SKIPPED (why), summary at the end):
#   1. Preflight. Aborts, changing nothing, when: not root; Tailscale.app (the
#      GUI app) is installed or running (it is not removed - tell Joe); the
#      default route's address or gateway is in 100.64.0.0/10 (the tailnet range
#      could shadow the provider network, and NoMachine with it); the sudo user
#      is not an admin.
#   2. Homebrew for that admin. Apple silicon: /opt/homebrew, installed if
#      missing. Intel: only an existing /usr/local brew (the upstream installer
#      no longer supports Intel). A brew owned by any other account aborts: brew
#      is never run as a provider account.
#   3. `brew install tailscale`, then the system daemon, label
#      com.tailscale.tailscaled (bb-tune.sh and uninstall-tailscale.sh key on
#      it), with KeepAlive on so launchd restarts it if it dies.
#   4. Joins the tailnet with Tailscale SSH on and Tailscale DNS off (the
#      provider's DNS stays in charge), or repairs those settings on a joined box.
#   5. Verifies from the daemon itself before the final DONE.
#
# Never restarts tailscaled under your own feet. Inside a Tailscale SSH session
# a step that would restart it is refused and the run exits non-zero, unless
# BB_TS_ALLOW_DROP=1: then it runs last, detached, and you drop for ~30 s.
# From setup.sh (BB_TS_FROM_SETUP=1) it is always refused inside such a session.
#
# Config via env:
#   BB_TS_HOSTNAME=VPS-01      tailnet machine name (optional)
#   BB_TS_AUTHKEY_FILE=<path>  a 0600 file holding a Tailscale auth key; without
#                              it you get a login URL to approve on your phone.
#                              A key never goes on the command line.
#   BB_TS_ALLOW_DROP=1         allow the tailscaled restart over Tailscale SSH
#   BB_TS_FROM_SETUP=1         set by setup.sh only
# Test seams, for the shim tests ONLY, never on a real box: BREW_PREFIX TS_BIN
# TSD_BIN TS_DAEMON_BIN TS_SOCKET TS_PLIST TS_GUI_APP PLISTBUDDY BB_TS_LOG
# BB_TS_CLI_TIMEOUT BB_TS_SKIP_ROOT_CHECK=1
#
# Exit codes: 0 ok; 1 error (see the log); 3 joined and verified, but a needed
# tailscaled restart was refused because this ran inside a Tailscale SSH session.
#
# Log: /var/log/bb-tailscale.log (install/update only).
# Remove: sudo bash /Users/Shared/bb-headless/uninstall-tailscale.sh
# bash 3.2 compatible. Apple silicon and Intel.

set -euo pipefail
umask 022   # see setup.sh
# Tools are called by name (the tests put shims first); make sure the system
# directories are on PATH whatever the caller had.
export PATH="${PATH:+$PATH:}/usr/bin:/bin:/usr/sbin:/sbin"

SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
REPO_SCRIPT="/Users/Shared/bb-headless/bb-tailscale.sh"   # what messages tell you to run
LABEL="com.tailscale.tailscaled"
LOG="${BB_TS_LOG:-/var/log/bb-tailscale.log}"
LOG_TO_FILE=1
TS_SOCKET="${TS_SOCKET:-/var/run/tailscaled.socket}"
TS_PLIST="${TS_PLIST:-/Library/LaunchDaemons/$LABEL.plist}"
TS_GUI_APP="${TS_GUI_APP:-/Applications/Tailscale.app}"
# Where `tailscaled install-system-daemon` copies the daemon (the plist runs this copy).
TS_DAEMON_BIN="${TS_DAEMON_BIN:-/usr/local/bin/tailscaled}"
PLISTBUDDY="${PLISTBUDDY:-/usr/libexec/PlistBuddy}"
# Seconds a read-only CLI call (status, ip, debug prefs, version) may take, so a
# wedged tailscaled can never hang this script or setup.sh behind it.
CLI_TIMEOUT="${BB_TS_CLI_TIMEOUT:-15}"
HOMEBREW_INSTALL_URL="https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh"

# hw.optional.arm64 says 1 on Apple silicon even under Rosetta, unlike uname -m.
ARM64=0
_arm="$(sysctl -n hw.optional.arm64 2>/dev/null)" || _arm=""
if [ "$_arm" = "1" ]; then ARM64=1; fi
if [ -z "${BREW_PREFIX:-}" ]; then
    if [ "$ARM64" = 1 ]; then BREW_PREFIX="/opt/homebrew"; else BREW_PREFIX="/usr/local"; fi
fi
BREW="$BREW_PREFIX/bin/brew"
TS_BIN="${TS_BIN:-$BREW_PREFIX/bin/tailscale}"
TSD_BIN="${TSD_BIN:-$BREW_PREFIX/bin/tailscaled}"

ADMIN=""
DONE_STEPS=()
SKIPPED_STEPS=()
RESTART_WHY=""       # what a tailscaled restart is needed for (empty = none)
RESTART_REFUSED=""   # set when that restart was refused; the run then exits non-zero
RESTART_DEFERRED=0   # 1 = it runs last, detached (BB_TS_ALLOW_DROP=1)
ST_JSON=""           # last `tailscale status --json` answer

log() {
    local m
    m="$(date '+%Y-%m-%d %H:%M:%S') [bb-tailscale] $*"
    { printf '%s\n' "$m"; } 2>/dev/null || true   # a closed terminal must not stop a restart half way
    if [ "$LOG_TO_FILE" = 1 ]; then { printf '%s\n' "$m" >> "$LOG"; } 2>/dev/null || true; fi
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
    if [ -n "$RESTART_REFUSED" ]; then log "ERROR: also: $RESTART_REFUSED"; fi
    exit 1
}

need_root() {
    if [ "${BB_TS_SKIP_ROOT_CHECK:-0}" = 1 ]; then return 0; fi   # shim tests only
    if [ "$(id -u)" -ne 0 ]; then
        echo "ERROR: run with sudo: sudo bash $REPO_SCRIPT ${1:-}"
        exit 1
    fi
}

# run_limited <seconds> <cmd...>: run cmd; if it is still running after
# <seconds>, TERM it, then KILL it a second later (exit 124). A plain alarm +
# exec is not enough: Go programs such as tailscale catch SIGALRM and carry on.
# stdout, stderr and the exit code pass through. perl ships with macOS.
run_limited() {
    if ! command -v perl >/dev/null 2>&1; then shift; "$@"; return $?; fi
    perl -e 'my $t=shift; my $p=fork; defined $p or exit 127; unless($p){exec @ARGV or exit 127} $SIG{ALRM}=sub{kill "TERM",$p; sleep 1; kill "KILL",$p; waitpid $p,0; exit 124}; alarm $t; waitpid $p,0; exit($? & 127 ? 128+($? & 127) : $? >> 8)' "$@"
}

# Every CLI call goes to OUR daemon's socket, so a Tailscale GUI app can never
# be the one answering. --socket is a root-level flag: it goes first.
# Read-only calls are time-limited. `up` has its own --timeout and `set` comes
# only after the daemon has answered.
ts() {
    case "$1" in
        up|set) "$TS_BIN" --socket="$TS_SOCKET" "$@" ;;
        *)      run_limited "$CLI_TIMEOUT" "$TS_BIN" --socket="$TS_SOCKET" "$@" ;;
    esac
}

first_line() { printf '%s\n' "$1" | sed -n 1p; }

# json_get <json> <keypath>: the value, or empty when absent. plutil reads JSON
# (nulls included) and is on every macOS; jq is not.
json_get() {
    local v
    if [ -z "$1" ]; then return 0; fi
    v="$(printf '%s' "$1" | plutil -extract "$2" raw -o - - 2>/dev/null)" || v=""
    printf '%s' "$v"
}

# Tailnet IPv4 from status JSON. Self.TailscaleIPs.0 is normally the IPv4 one
# (the bare array path would print the element count).
self_ipv4() {
    local a
    a="$(json_get "$1" Self.TailscaleIPs.0)"
    case "$a" in *.*) printf '%s' "$a"; return 0 ;; esac
    a="$(json_get "$1" Self.TailscaleIPs.1)"
    case "$a" in *.*) printf '%s' "$a" ;; esac
    return 0
}

# Absent means key expiry is disabled for this machine (the good state), but
# only when the same JSON says the backend state: callers check that.
key_expiry() {
    local e
    e="$(json_get "$1" Self.KeyExpiry)"
    case "$e" in 0001-*) e="" ;; esac
    printf '%s' "$e"
}

cli_version() {   # first line of `tailscale version`, or empty
    local v
    v="$(ts version 2>/dev/null)" || v=""
    first_line "$v"
}

ts_version() {
    local v
    v="$(cli_version)"
    printf '%s' "${v:-version unknown}"
}

short_version() { printf '%s' "${1%%-*}"; }   # 1.90.0-t123-g456 -> 1.90.0

# "running" = launchd shows a pid for it (loaded is not enough).
daemon_running() {
    local out
    out="$(launchctl print "system/$LABEL" 2>/dev/null)" || out=""
    case "$out" in *"pid = "*) return 0 ;; esac
    return 1
}

# Has launchd applied KeepAlive to the job it has LOADED? The plist on disk can
# say true while the loaded job predates that; launchctl print shows it as
# "properties = keepalive | runatload | ...".
loaded_keepalive() {
    local out props
    out="$(launchctl print "system/$LABEL" 2>/dev/null)" || out=""
    if [ -z "$out" ]; then return 1; fi   # not loaded at all
    props="$(printf '%s\n' "$out" | awk '$1 == "properties" && $2 == "=" {print}')"
    if [ -z "$props" ]; then
        # No properties line in this launchctl's output: trust the plist.
        if [ "$(keepalive_value)" = true ]; then return 0; fi
        return 1
    fi
    case "$props" in *keepalive*) return 0 ;; esac
    return 1
}

# Prints true/false, or nothing when the key or the plist is absent (or
# unreadable). PlistBuddy exits 1 for an absent key: guarded for set -e.
keepalive_value() {
    local v
    v="$("$PLISTBUDDY" -c 'Print :KeepAlive' "$TS_PLIST" 2>/dev/null)" || v=""
    printf '%s' "$v"
}

# Are we inside a Tailscale SSH session? Then tailscaled is one of our
# ancestors. macOS ps prints the full path for comm, so match the basename.
in_tailscale_ssh() {
    local pid="$$" comm n=0
    while [ -n "$pid" ] && [ "$pid" -gt 1 ] && [ "$n" -lt 64 ]; do
        comm="$(ps -o comm= -p "$pid" 2>/dev/null)" || comm=""
        case "${comm##*/}" in tailscaled|tailscaled[[:space:]]*) return 0 ;; esac
        pid="$(ps -o ppid= -p "$pid" 2>/dev/null)" || pid=""
        pid="${pid//[!0-9]/}"
        n=$((n + 1))
    done
    return 1
}

# 100.64.0.0/10 = 100.64.x.x - 100.127.x.x, the range Tailscale hands out.
in_cgnat() {
    local a b rest
    IFS=. read -r a b rest <<EOF
$1
EOF
    case "$a" in ''|*[!0-9]*) return 1 ;; esac
    case "$b" in ''|*[!0-9]*) return 1 ;; esac
    [ "$a" -eq 100 ] && [ "$b" -ge 64 ] && [ "$b" -le 127 ]
}

# ── 1. Preflight (changes nothing) ──────────────────────────────────────────
preflight() {
    local why="" route_out ifc gw addr own mem rc=0

    # The GUI app's network extension and our daemon would fight over the
    # tunnel. It is not ours to remove.
    if [ -e "$TS_GUI_APP" ]; then why="$TS_GUI_APP is installed"
    elif pgrep -x IPNExtension >/dev/null 2>&1; then why="the Tailscale app's IPNExtension is running"
    elif pgrep -f 'io\.tailscale\.ipn\.macsys' >/dev/null 2>&1; then why="the Tailscale app's network extension is running"
    elif pgrep -x Tailscale >/dev/null 2>&1; then why="the Tailscale app is running"
    fi
    [ -z "$why" ] || die "Tailscale GUI app found: $why. This script installs the open-source tailscaled daemon and the two would fight over the network. Nothing was changed and the app was left in place - tell Joe."

    # Only the default route matters: its interface address and its gateway.
    # A tunnel default route (utun*) is skipped, and so is our own tailnet
    # address, so a re-run on a joined box passes.
    route_out="$(route -n get default 2>/dev/null)" || route_out=""
    ifc="$(printf '%s\n' "$route_out" | awk '/interface:/{print $2}')"
    gw="$(printf '%s\n' "$route_out" | awk '/gateway:/{print $2}')"
    [ -n "$ifc" ] || die "No default route - is the network up? Nothing was changed."
    own=""
    if [ -x "$TS_BIN" ]; then
        own="$(ts ip -4 2>/dev/null)" || own=""
        own="$(first_line "$own")"
    fi
    case "$ifc" in
        utun*)
            log "Default route goes through a tunnel ($ifc) - 100.64.0.0/10 check skipped"
            ;;
        *)
            addr="$(ipconfig getifaddr "$ifc" 2>/dev/null)" || addr=""
            if [ -n "$addr" ] && [ "$addr" != "$own" ] && in_cgnat "$addr"; then
                die "This box's address $addr ($ifc) is inside 100.64.0.0/10, the range Tailscale uses. Joining could shadow the provider network and cut NoMachine off. Nothing was changed - tell Joe."
            fi
            if [ -n "$gw" ] && [ "$gw" != "$own" ] && in_cgnat "$gw"; then
                die "The default gateway $gw is inside 100.64.0.0/10, the range Tailscale uses. Joining could shadow the provider network and cut NoMachine off. Nothing was changed - tell Joe."
            fi
            log "Network: default route via $ifc (${addr:-no address}), gateway ${gw:-none} - clear of 100.64.0.0/10"
            ;;
    esac

    # Homebrew belongs to whoever ran sudo, and that must be an admin.
    # dsmemberutil exits 0 either way; only its words say member or not.
    ADMIN="${SUDO_USER:-}"
    if [ -z "$ADMIN" ] || [ "$ADMIN" = root ]; then
        die "Run with sudo from the joe account (the admin), not as root directly. Nothing was changed."
    fi
    mem="$(dsmemberutil checkmembership -U "$ADMIN" -G admin 2>&1)" || rc=$?
    [ "$rc" -ne 7 ] || die "Account '$ADMIN' not found - run with sudo from the joe account. Nothing was changed."
    case "$(printf '%s' "$mem" | tr '[:upper:]' '[:lower:]')" in
        *"is a member"*) ;;
        *) die "'$ADMIN' is not an admin ($mem) - run with sudo from the joe account. Nothing was changed." ;;
    esac
    log "Admin (Homebrew owner): $ADMIN"
}

# ── 2. Homebrew ─────────────────────────────────────────────────────────────
# brew refuses to run as root; run it as the admin, from / (root's cwd may be
# unreadable to that user).
brew_run() {
    ( cd / && sudo -u "$ADMIN" -H "$BREW" "$@" ) >>"$LOG" 2>&1
}

ensure_brew() {
    local owner
    if [ -x "$BREW" ]; then
        # Apple silicon: the prefix itself is Homebrew's. Intel: /usr/local stays
        # root's, so the brew binary says who owns Homebrew.
        if [ "$ARM64" = 1 ]; then owner="$(stat -f %Su "$BREW_PREFIX" 2>/dev/null)" || owner=""
        else owner="$(stat -f %Su "$BREW" 2>/dev/null)" || owner=""; fi
        [ "$owner" = "$ADMIN" ] || die "Homebrew at $BREW_PREFIX belongs to '${owner:-unknown}', not '$ADMIN'. brew is never run as another account (it could be a provider account). Nothing was changed - tell Joe."
        skip_step "Homebrew already installed ($BREW, owner $ADMIN)"
        return 0
    fi
    if [ "$ARM64" != 1 ]; then
        die "No Homebrew at $BREW and this is an Intel Mac: Homebrew's installer no longer supports Intel, and /usr/local is never chown'd. Nothing was changed. Install Homebrew by hand as $ADMIN, then re-run."
    fi
    xcode-select -p >/dev/null 2>&1 || die "Xcode Command Line Tools are missing (Homebrew needs them). Run: xcode-select --install, let it finish, then re-run. Nothing was changed."
    # Pre-owning the prefix (the prefix only, never -R) means the installer needs
    # no sudo of its own, so it runs clean under NONINTERACTIVE=1.
    log "Homebrew not found - installing it for $ADMIN in $BREW_PREFIX (takes a few minutes)"
    mkdir -p "$BREW_PREFIX"
    chown "$ADMIN:admin" "$BREW_PREFIX"
    ( cd / && sudo -u "$ADMIN" -H env NONINTERACTIVE=1 \
        bash -c "$(curl -fsSL "$HOMEBREW_INSTALL_URL")" ) >>"$LOG" 2>&1 \
        || die "Homebrew install failed - see $LOG"
    # A failed download runs `bash -c ""`, which exits 0: check the result.
    [ -x "$BREW" ] || die "The Homebrew installer finished but $BREW is missing (download failed?) - see $LOG"
    done_step "Installed Homebrew for $ADMIN ($BREW_PREFIX)"
}

# ── 3. Tailscale and the system daemon ──────────────────────────────────────
ensure_tailscale() {
    if [ -x "$TS_BIN" ] && [ -x "$TSD_BIN" ]; then
        skip_step "Tailscale already installed ($(ts_version))"
        return 0
    fi
    log "Installing Tailscale with Homebrew (as $ADMIN)"
    brew_run install tailscale || die "brew install tailscale failed - see $LOG"
    [ -x "$TS_BIN" ] && [ -x "$TSD_BIN" ] || die "brew install tailscale finished but $TS_BIN or $TSD_BIN is missing - see $LOG"
    done_step "Installed Tailscale with Homebrew ($(ts_version), user $ADMIN)"
}

upgrade_tailscale() {
    local before after
    [ -x "$TS_BIN" ] && [ -x "$TSD_BIN" ] || die "Tailscale is not installed yet - run: sudo bash $REPO_SCRIPT"
    before="$(ts_version)"
    brew_run upgrade tailscale || die "brew upgrade tailscale failed - see $LOG"
    after="$(ts_version)"
    if [ "$before" = "$after" ]; then
        skip_step "Tailscale already the newest Homebrew version ($after)"
    else
        done_step "Upgraded Tailscale $before -> $after"
    fi
}

# What the daemon needs, read from the box: a (re)install (plist or daemon copy
# missing, or on update a running daemon older than the CLI), KeepAlive in the
# plist, a (re)load (not running, or launchd has not applied KeepAlive).
compute_needs() {
    local mode="$1" have want st w=""
    NEED_REINSTALL=""; NEED_KEEPALIVE=0; NEED_RELOAD=0; RELOAD_WHY=""
    if [ ! -f "$TS_PLIST" ]; then
        NEED_REINSTALL="$TS_PLIST missing"
    elif [ ! -x "$TS_DAEMON_BIN" ]; then
        NEED_REINSTALL="$TS_DAEMON_BIN missing"
    elif [ "$mode" = update ]; then
        # Compare what is RUNNING with the CLI brew just installed. On Intel
        # /usr/local/bin/tailscaled is brew's own symlink, so the two binaries
        # always match after an upgrade while the old daemon keeps running.
        want="$(short_version "$(cli_version)")"
        st="$(ts status --json --peers=false 2>/dev/null)" || st=""
        have="$(short_version "$(json_get "$st" Version)")"
        if [ -z "$have" ]; then   # daemon not answering: fall back to the binaries
            have="$("$TS_DAEMON_BIN" --version 2>/dev/null)" || have=""
            want="$("$TSD_BIN" --version 2>/dev/null)" || want=""
            have="$(short_version "$(first_line "$have")")"; want="$(short_version "$(first_line "$want")")"
        fi
        if [ -n "$want" ] && [ "$have" != "$want" ]; then NEED_REINSTALL="daemon ${have:-unknown} -> $want"; fi
    fi
    if [ "$(keepalive_value)" != true ]; then NEED_KEEPALIVE=1; fi
    if ! daemon_running; then NEED_RELOAD=1; RELOAD_WHY="start tailscaled (not running)"
    elif ! loaded_keepalive; then NEED_RELOAD=1; RELOAD_WHY="reload tailscaled (launchd has not applied KeepAlive)"; fi
    if [ -n "$NEED_REINSTALL" ]; then w="install the system daemon ($NEED_REINSTALL)"; fi
    if [ "$NEED_KEEPALIVE" = 1 ]; then w="${w:+$w, }turn KeepAlive on"; fi
    if [ "$NEED_RELOAD" = 1 ]; then w="${w:+$w, }$RELOAD_WHY"; fi
    RESTART_WHY="$w"
}

# Returns 0 when it changed the plist, 1 when KeepAlive was already true.
# Set when the key is there, Add when it is not.
ensure_keepalive() {
    local v
    [ -f "$TS_PLIST" ] || die "$TS_PLIST is missing - re-run sudo bash $REPO_SCRIPT"
    v="$(keepalive_value)"
    if [ "$v" = true ]; then return 1; fi
    if [ -n "$v" ]; then
        "$PLISTBUDDY" -c 'Set :KeepAlive true' "$TS_PLIST" >>"$LOG" 2>&1 || true
    else
        "$PLISTBUDDY" -c 'Add :KeepAlive bool true' "$TS_PLIST" >>"$LOG" 2>&1 || true
    fi
    [ "$(keepalive_value)" = true ] || die "Could not set KeepAlive in $TS_PLIST - see $LOG"
    return 0
}

# bootout, wait until launchd has let go, enable, bootstrap (retry once, then
# load -w). The outcome is read from launchd's state, never from return codes:
# "already loaded" is not a failure, not running is. Never leave it unloaded.
reload_daemon() {
    local i
    log "Reloading tailscaled (launchctl bootout + bootstrap)"
    launchctl bootout "system/$LABEL" >>"$LOG" 2>&1 || true
    i=0
    while launchctl print "system/$LABEL" >/dev/null 2>&1 && [ "$i" -lt 10 ]; do sleep 1; i=$((i + 1)); done
    launchctl enable "system/$LABEL" >>"$LOG" 2>&1 || true
    if ! launchctl bootstrap system "$TS_PLIST" >>"$LOG" 2>&1; then
        sleep 2
        if ! launchctl bootstrap system "$TS_PLIST" >>"$LOG" 2>&1; then
            log "bootstrap refused twice - trying launchctl load -w"
            launchctl load -w "$TS_PLIST" >>"$LOG" 2>&1 || true
        fi
    fi
    i=0
    while { ! daemon_running || ! loaded_keepalive; } && [ "$i" -lt 10 ]; do sleep 1; i=$((i + 1)); done
    if daemon_running && loaded_keepalive && [ "$(keepalive_value)" = true ]; then
        done_step "tailscaled loaded and running, KeepAlive on (applied by launchd)"
        return 0
    fi
    not_loaded_banner
    if daemon_running; then
        die "tailscaled is running but WITHOUT KeepAlive (a crash would leave it down) - fix before leaving this box"
    fi
    die "tailscaled NOT LOADED - fix before leaving this box"
}

not_loaded_banner() {
    local run=no ka=no
    if daemon_running; then run=yes; fi
    if loaded_keepalive; then ka=yes; fi
    log "ERROR: ************************************************************"
    if [ "$run" = yes ]; then
        log "ERROR: tailscaled running WITHOUT KeepAlive - fix before leaving this box"
    else
        log "ERROR: tailscaled NOT LOADED - fix before leaving this box"
    fi
    log "ERROR: (launchd: running=$run, KeepAlive applied=$ka; plist: ${TS_PLIST})"
    log "ERROR: look: sudo launchctl print system/$LABEL"
    log "ERROR: load: sudo launchctl enable system/$LABEL; sudo launchctl bootstrap system $TS_PLIST"
    log "ERROR: ************************************************************"
}

# Install, KeepAlive, reload: every step here can restart tailscaled, so the
# caller has already decided that is allowed.
restart_steps() {
    local err
    compute_needs "$1"
    if [ -n "$NEED_REINSTALL" ]; then
        # install-system-daemon unloads the job, rewrites the plist, then runs a
        # plain `launchctl load` + `start`. A disabled label (load without -w
        # refuses it) or an unload/load race ("Load failed: 5") fails that and
        # leaves tailscaled unloaded. So enable the label first, and if it still
        # fails, load it ourselves before stopping.
        launchctl enable "system/$LABEL" >>"$LOG" 2>&1 || true
        if ! "$TSD_BIN" install-system-daemon >>"$LOG" 2>&1; then
            err="tailscaled install-system-daemon failed ($NEED_REINSTALL) - see $LOG"
            log "ERROR: $err"
            if [ -f "$TS_PLIST" ]; then
                log "Loading tailscaled by hand so it is not left unloaded"
                # KeepAlive edit is best effort here: nothing may stop the reload.
                "$PLISTBUDDY" -c 'Set :KeepAlive true' "$TS_PLIST" >>"$LOG" 2>&1 \
                    || "$PLISTBUDDY" -c 'Add :KeepAlive bool true' "$TS_PLIST" >>"$LOG" 2>&1 || true
                reload_daemon
                die "$err (tailscaled itself was loaded by hand and is running)"
            fi
            not_loaded_banner
            die "$err, and $TS_PLIST is gone"
        fi
        [ -f "$TS_PLIST" ] || { not_loaded_banner; die "install-system-daemon ran but $TS_PLIST is missing - see $LOG"; }
        done_step "Installed the tailscaled system daemon ($NEED_REINSTALL)"
        NEED_RELOAD=1
    fi
    if ensure_keepalive; then
        done_step "KeepAlive on in $TS_PLIST (launchd restarts tailscaled if it dies)"
        NEED_RELOAD=1
    fi
    if [ "$NEED_RELOAD" = 1 ]; then reload_daemon; fi
}

# Nothing may stop a restart half way and leave tailscaled unloaded: a closed
# terminal (HUP, or PIPE on a dead pipe), Ctrl-C or TERM are ignored for exactly
# this span, and log() never fails on a dead terminal.
guarded_restart_steps() {
    trap '' HUP INT TERM PIPE
    restart_steps "$1"
    trap - HUP INT TERM PIPE
}

# Decide whether a needed restart may happen now, later (detached) or not at all.
restart_phase() {
    local mode="$1" again=""
    if [ "$mode" = update ]; then again=" update"; fi
    compute_needs "$mode"
    if [ -z "$RESTART_WHY" ]; then
        skip_step "tailscaled system daemon already installed, running, KeepAlive on (applied by launchd)"
        return 0
    fi
    if ! in_tailscale_ssh; then
        log "tailscaled needs: $RESTART_WHY"
        guarded_restart_steps "$mode"
        return 0
    fi
    if [ "${BB_TS_FROM_SETUP:-0}" = 1 ]; then
        RESTART_REFUSED="tailscaled needs a restart ($RESTART_WHY), not done: setup.sh is running inside a Tailscale SSH session. Run sudo bash $REPO_SCRIPT standalone afterwards, from NoMachine or with sudo BB_TS_ALLOW_DROP=1 bash $REPO_SCRIPT"
        skip_step "tailscaled restart refused: inside a Tailscale SSH session, from setup.sh"
    elif [ "${BB_TS_ALLOW_DROP:-0}" = 1 ]; then
        RESTART_DEFERRED=1
        log "Inside a Tailscale SSH session: the tailscaled restart ($RESTART_WHY) runs as the very last step (BB_TS_ALLOW_DROP=1)"
    else
        RESTART_REFUSED="tailscaled needs a restart ($RESTART_WHY), not done: it would cut this Tailscale SSH session. Run it from NoMachine, or here with: sudo BB_TS_ALLOW_DROP=1 bash $REPO_SCRIPT$again (you drop for ~30 s)"
        skip_step "tailscaled restart refused: inside a Tailscale SSH session (BB_TS_ALLOW_DROP=1 allows it)"
    fi
}

# Ready = `tailscale status --json` exits 0 (it does in every backend state).
# A freshly started daemon gets up to 30 s to settle past NoState/Starting, so
# a joined box is not mistaken for a new one.
wait_ready() {
    local i=0 answered=0 st state end=$((SECONDS + 30))
    while [ "$i" -lt 30 ] && [ "$SECONDS" -lt "$end" ]; do
        if st="$(ts status --json --peers=false 2>/dev/null)"; then
            answered=1
            ST_JSON="$st"
            state="$(json_get "$st" BackendState)"
            case "$state" in ''|NoState|Starting) ;; *) return 0 ;; esac
        fi
        sleep 1
        i=$((i + 1))
    done
    [ "$answered" = 1 ]
}

# ── 4. Join / repair ────────────────────────────────────────────────────────
check_authkey_file() {
    local f="$BB_TS_AUTHKEY_FILE" mode
    [ -f "$f" ] || die "BB_TS_AUTHKEY_FILE=$f is not a file"
    mode="$(stat -f %Lp "$f" 2>/dev/null)" || mode=""
    [ "$mode" = 600 ] || [ "$mode" = 400 ] || die "BB_TS_AUTHKEY_FILE=$f must be mode 0600 (it is ${mode:-unknown}): chmod 600 $f"
}

up_failed() {
    local st state url
    st="$(ts status --json --peers=false 2>/dev/null)" || st=""
    state="$(json_get "$st" BackendState)"
    url="$(json_get "$st" AuthURL)"
    if [ "$state" = NeedsMachineAuth ]; then
        log "This machine is waiting for approval: approve this device in the Tailscale admin console (Machines)."
    fi
    # Only an interactive login that is still waiting is "approve it later".
    if [ -z "${BB_TS_AUTHKEY_FILE:-}" ] && { [ "$state" = NeedsLogin ] || [ "$state" = NeedsMachineAuth ]; }; then
        if [ -n "$url" ]; then
            log "Not approved yet. This URL stays valid; approve it any time and the join finishes by itself:"
            log "    $url"
        fi
        die "Tailscale is not joined yet (state $state) - approve the URL later, then re-run sudo bash $REPO_SCRIPT to finish the checks"
    fi
    die "tailscale up failed (state ${state:-unknown}) - see the output above (also in $LOG)"
}

join_tailnet() {
    local state host prefs how args
    state="$(json_get "$ST_JSON" BackendState)"
    if [ "$state" = Running ]; then
        # Joined already. `set` changes only what it names; `up` would refuse
        # unless every non-default setting were repeated.
        args=(set --ssh --accept-dns=false)
        if [ -n "${BB_TS_HOSTNAME:-}" ]; then args+=("--hostname=$BB_TS_HOSTNAME"); fi
        ts "${args[@]}" >>"$LOG" 2>&1 || die "tailscale set failed - see $LOG"
        done_step "Tailscale already joined: Tailscale SSH on, Tailscale DNS off${BB_TS_HOSTNAME:+, name $BB_TS_HOSTNAME} (tailscale set)"
        return 0
    fi

    # Not running. Pass the current name (or BB_TS_HOSTNAME) so `up` never
    # trips over a name set earlier.
    host="${BB_TS_HOSTNAME:-}"
    if [ -z "$host" ]; then
        prefs="$(ts debug prefs 2>/dev/null)" || prefs=""
        host="$(json_get "$prefs" Hostname)"
    fi
    args=(up --ssh --accept-dns=false --timeout=5m)
    if [ -n "$host" ]; then args+=("--hostname=$host"); fi
    if [ -n "${BB_TS_AUTHKEY_FILE:-}" ]; then
        check_authkey_file
        args+=("--auth-key=file:$BB_TS_AUTHKEY_FILE")
        how="auth key file"
        log "Joining the tailnet with the auth key in $BB_TS_AUTHKEY_FILE (state was ${state:-unknown})"
    else
        how="interactive approval"
        log ">>> Tailscale needs a one-time approval. A login URL will appear below."
        log ">>> Open it on your phone (Tailscale app signed in) and tap Approve. This waits up to 5 minutes."
        if [ "${BB_TS_FROM_SETUP:-0}" = 1 ]; then log ">>> Ctrl-C skips Tailscale only"; fi
    fi
    # The login URL must reach the terminal, not only the log.
    if ts "${args[@]}" 2>&1 | tee -a "$LOG"; then
        done_step "Joined the tailnet ($how): Tailscale SSH on, Tailscale DNS off"
    else
        up_failed
    fi
}

# ── 5. Verify ───────────────────────────────────────────────────────────────
verify() {
    local prefs st state ssh corp ip4 dns exp name
    prefs="$(ts debug prefs 2>/dev/null)" || prefs=""
    ssh="$(json_get "$prefs" RunSSH)"
    corp="$(json_get "$prefs" CorpDNS)"
    st="$(ts status --json --peers=false 2>/dev/null)" || st=""
    state="$(json_get "$st" BackendState)"
    dns="$(json_get "$st" Self.DNSName)"; dns="${dns%.}"
    ip4="$(self_ipv4 "$st")"
    exp="$(key_expiry "$st")"
    [ "$state" = Running ] || die "Tailscale is not Running (state ${state:-unknown}) - re-run sudo bash $REPO_SCRIPT"
    [ "$ssh" = true ] || die "Tailscale SSH is not on (RunSSH=${ssh:-unknown}) - re-run sudo bash $REPO_SCRIPT"
    [ "$corp" = false ] || die "Tailscale DNS is still on (CorpDNS=${corp:-unknown}) - re-run sudo bash $REPO_SCRIPT"
    done_step "Verified: Running, Tailscale SSH on, Tailscale DNS off"
    log "Tailnet address: ${ip4:-unknown}   name: ${dns:-unknown}"
    if [ -n "$exp" ]; then
        log "WARNING: this machine's key expires $exp - disable key expiry for this machine in the admin console"
    fi
    name="${dns%%.*}"
    log "When the desktop hangs, from a Mac on the tailnet: tailscale ssh ${ADMIN:-${SUDO_USER:-joe}}@${name:-<machine name>} then sudo reboot (sudo fdesetup authrestart if FileVault is On)"
}

summary() {
    local s
    log "=== Summary ==="
    log "Completed: ${#DONE_STEPS[@]}"
    for s in ${DONE_STEPS[@]+"${DONE_STEPS[@]}"}; do log "  + $s"; done
    log "Skipped: ${#SKIPPED_STEPS[@]}"
    for s in ${SKIPPED_STEPS[@]+"${SKIPPED_STEPS[@]}"}; do log "  - $s"; done
    log "Log: $LOG"
}

# ── status (no root needed, writes nothing) ─────────────────────────────────
do_status() {
    set +e
    local out pid ka st prefs state ssh corp host dns ip4 exp name who fv
    echo "Tailscale on $(hostname -s) (bb-tailscale status)"
    if [ -e "$TS_GUI_APP" ]; then
        echo "  note:        $TS_GUI_APP (the GUI app) is on this box - bb-tailscale.sh does not use or manage it"
    fi
    if [ ! -x "$TS_BIN" ] && [ ! -x "$TS_DAEMON_BIN" ] && [ ! -f "$TS_PLIST" ]; then
        echo "  Tailscale:   not installed. Set it up with: sudo bash $REPO_SCRIPT"
        exit 0
    fi
    if [ -x "$TS_BIN" ]; then echo "  installed:   yes ($(ts_version), $TS_BIN)"
    else echo "  installed:   CLI MISSING ($TS_BIN) - run: sudo bash $REPO_SCRIPT"; fi

    out="$(launchctl print "system/$LABEL" 2>/dev/null)"
    if [ -n "$out" ]; then
        pid="$(printf '%s\n' "$out" | awk '$1 == "pid" && $2 == "=" {print $3}' | sed -n 1p)"
        if [ -n "$pid" ]; then echo "  daemon:      loaded, running (pid $pid)"
        else echo "  daemon:      loaded, NOT running - run: sudo bash $REPO_SCRIPT"; fi
    elif [ -f "$TS_PLIST" ]; then
        echo "  daemon:      NOT loaded - run: sudo bash $REPO_SCRIPT"
    else
        echo "  daemon:      NOT installed ($TS_PLIST missing) - run: sudo bash $REPO_SCRIPT"
    fi

    if [ ! -f "$TS_PLIST" ]; then ka="no plist"
    elif [ ! -r "$TS_PLIST" ]; then ka="? (run with sudo to read the plist)"
    else
        case "$(keepalive_value)" in
            true) ka="on" ;;
            *)    ka="OFF - run: sudo bash $REPO_SCRIPT" ;;
        esac
    fi
    # What launchd has loaded can lag the plist; print works without root.
    if [ -n "$out" ]; then
        if loaded_keepalive; then ka="$ka (applied by launchd)"
        else ka="$ka (NOT applied by launchd - run: sudo bash $REPO_SCRIPT)"; fi
    fi
    echo "  KeepAlive:   $ka"

    if [ ! -x "$TS_BIN" ]; then exit 0; fi
    st="$(ts status --json --peers=false 2>/dev/null)"
    if [ -z "$st" ]; then
        echo "  state:       daemon not answering on $TS_SOCKET"
        exit 0
    fi
    prefs="$(ts debug prefs 2>/dev/null)"
    state="$(json_get "$st" BackendState)"
    ssh="$(json_get "$prefs" RunSSH)"
    corp="$(json_get "$prefs" CorpDNS)"
    host="$(json_get "$prefs" Hostname)"
    dns="$(json_get "$st" Self.DNSName)"; dns="${dns%.}"
    ip4="$(self_ipv4 "$st")"
    exp="$(key_expiry "$st")"
    echo "  state:       ${state:-unknown}"
    case "$ssh" in
        true)  echo "  SSH:         Tailscale SSH on" ;;
        false) echo "  SSH:         Tailscale SSH OFF - run: sudo bash $REPO_SCRIPT" ;;
        *)     echo "  SSH:         ? (could not read prefs)" ;;
    esac
    case "$corp" in
        false) echo "  DNS:         Tailscale DNS off (provider DNS in charge)" ;;
        true)  echo "  DNS:         Tailscale DNS ON - run: sudo bash $REPO_SCRIPT" ;;
        *)     echo "  DNS:         ? (could not read prefs)" ;;
    esac
    echo "  hostname:    ${host:-(OS hostname)}"
    echo "  DNS name:    ${dns:-unknown}"
    echo "  IPv4:        ${ip4:-unknown}"
    # "off" only when this same JSON answered with a joined backend state.
    case "$state" in
        "") echo "  key expiry:  ? (could not read the backend state)" ;;
        NoState|NeedsLogin|NeedsMachineAuth) echo "  key expiry:  n/a (not joined yet)" ;;
        *)
            if [ -n "$exp" ]; then echo "  key expiry:  $exp  <- disable key expiry for this machine in the admin console"
            else echo "  key expiry:  off"; fi
            ;;
    esac

    name="${dns%%.*}"; name="${name:-<machine name>}"
    who="${SUDO_USER:-joe}"; [ "$who" = root ] && who=joe
    fv="$(fdesetup status 2>/dev/null)"
    echo "How to get in when the desktop hangs, from a Mac on the tailnet:"
    echo "  tailscale ssh $who@$name"
    case "$fv" in
        *"FileVault is On"*) echo "  sudo fdesetup authrestart    (FileVault is On: comes back without the unlock screen)" ;;
        *"FileVault is Off"*) echo "  sudo reboot                  (FileVault is Off)" ;;
        *) echo "  sudo reboot   (or sudo fdesetup authrestart if fdesetup status says FileVault is On)" ;;
    esac
    exit 0
}

# ── main ────────────────────────────────────────────────────────────────────
run_main() {   # run_main install|update
    local mode="$1" again=""
    if [ "$mode" = update ]; then again="update"; fi
    need_root "$again"
    log "=== bb-tailscale $mode start (host $(hostname -s), $(uname -m), macOS $(sw_vers -productVersion 2>/dev/null)) ==="
    preflight
    if [ "$mode" = update ] && { [ ! -x "$TS_BIN" ] || [ ! -x "$TSD_BIN" ]; }; then
        die "Tailscale is not installed yet - run: sudo bash $REPO_SCRIPT"
    fi
    ensure_brew
    if [ "$mode" = update ]; then upgrade_tailscale; else ensure_tailscale; fi
    restart_phase "$mode"
    wait_ready || die "tailscaled is not answering on $TS_SOCKET after 30 s - look: sudo launchctl print system/$LABEL"
    if [ "$mode" = install ]; then join_tailnet; fi
    verify
    summary
    if [ -n "$RESTART_REFUSED" ]; then
        log "ERROR: $RESTART_REFUSED"
        exit 3   # joined and verified; only the restart is left (setup.sh reads this)
    fi
    if [ "$RESTART_DEFERRED" = 1 ]; then
        log "Restarting tailscaled now, detached ($RESTART_WHY)."
        log "You will drop; reconnect in ~30 s and run: sudo bash $REPO_SCRIPT status"
        nohup /bin/bash "$SELF" __restart "$mode" </dev/null >>"$LOG" 2>&1 &
    fi
    exit 0
}

case "${1:-}" in
    ""|install) run_main install ;;
    update)     run_main update ;;
    status)     do_status ;;
    __restart)
        # Internal: the detached restart started above. Root check only, no
        # preflight and no Tailscale SSH check (that is why it exists).
        need_root
        LOG_TO_FILE=0   # stdout is already the log (see the nohup line)
        case "${2:-install}" in update) RMODE=update ;; *) RMODE=install ;; esac
        sleep 3
        log "=== detached tailscaled restart ($RMODE) ==="
        guarded_restart_steps "$RMODE"
        wait_ready || die "tailscaled is not answering on $TS_SOCKET after 30 s - look: sudo launchctl print system/$LABEL"
        verify
        summary
        exit 0
        ;;
    *) echo "usage: sudo bash $0 [update|status]"; exit 1 ;;
esac
