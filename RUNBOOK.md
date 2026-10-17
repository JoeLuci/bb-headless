# bb-headless Runbook

## What this is

Runs BlueBubbles Server as a plain Node.js process instead of Electron. Eliminates WindowServer load that was causing crashes (WindowServer bloating to 1GB+ after ~18 days with 5 GUI sessions per Mac, then watchdog killing it).

Repo: https://github.com/JoeLuci/bb-headless (private)

## Install on a new Mac (2 steps)

### Step 1: Build (once per Mac, from any user)

Log into any user (e.g. m01) and run:

```bash
git clone https://github.com/JoeLuci/bb-headless.git /Users/Shared/bb-headless
cd /Users/Shared/bb-headless
sudo bash install.sh --build-only
```

Takes about 3-5 minutes (clones BB source, builds headless server). Only needs to be done once per Mac.

### Step 2: Switch each user (from each login)

Fast User Switch into each user and run:

```bash
bash /Users/Shared/bb-headless/switch-user.sh
```

No sudo needed. It kills Electron BB, starts headless BB, and verifies it's working. Takes 10 seconds per user.

If it fails, it automatically reverts to Electron BB.

This automatically:
- Clones BlueBubbles source to /usr/local/lib/bb-headless/
- Patches in the headless shim (replaces Electron with Node.js stubs)
- Builds with webpack
- Copies Private API dylib from BlueBubbles.app (must be installed)
- Sets file permissions so all users can access the build
- Creates per-user log files at /var/log/bb-headless-USERNAME.log
- For every user with a config.db: creates a LaunchAgent, stops Electron BB, starts headless BB
- Each user's existing config (port, server_address, password, webhooks, Cloudflare tunnel) is preserved — headless reads the same config.db

## Verify after install

```bash
# Check all users are running
for u in m01 m02 m03 m04 m05; do
  PID=$(pgrep -u $u -f "node.*headless" | head -1)
  if [ -n "$PID" ]; then
    PORT=$(lsof -nP -iTCP -sTCP:LISTEN -a -p $PID 2>/dev/null | grep LISTEN | awk '{print $9}' | head -1)
    echo "$u: RUNNING (PID $PID) on $PORT"
  else
    echo "$u: NOT RUNNING — check /var/log/bb-headless-$u.log"
  fi
done
```

## Update

```bash
cd /Users/Shared/bb-headless && git pull && sudo bash install.sh
```

## Tuning (bb-tune)

`install.sh` ends by running `bb-tune.sh install`, which installs a LaunchDaemon
(`com.local.bb-tune`) that re-applies at every boot and every 6 h:

- Spotlight indexing off on `/` and `/System/Volumes/Data` (macOS 26 turns it
  back on after every reboot; with 4-6 logins it alone pushes boot load past 100)
- per account: Photos/media analysis and Siri knowledge indexing disabled
- Bluetooth stays ON, and is turned back on if an older bb-tune disabled it:
  with `com.apple.bluetoothd` disabled, coreaudiod retries its Bluetooth audio
  plugin non-stop, grows ~5 GB/hour after boot (AZ-03 reached 35 GB on a 16 GB
  mini after 10 days), pins launchd and can flood logd until the watchdog
  panics the Mac (AZ-03, 2026-10-16). Turning Bluetooth back on stops the
  growth; the memory already leaked comes back only with a planned restart in a
  quiet hour. Never kill coreaudiod on a bloated Mac.
- bb-headless logs over 1 GB, or belonging to a deleted account, are truncated

It never touches BlueBubbles, Messages/iCloud, RustDesk, Cloudflare, Tailscale
or logins, records which of those are running first, and exits 2 if any stopped.

```bash
cd /Users/Shared/bb-headless && git pull && sudo bash bb-tune.sh install   # update bb-tune only (no rebuild)
sudo bash /Users/Shared/bb-headless/bb-tune.sh status     # what is on/off right now
sudo bash /Users/Shared/bb-headless/bb-tune.sh            # re-apply now
sudo bash /Users/Shared/bb-headless/bb-tune.sh restore    # undo the tuning; daemon then only keeps Bluetooth on and caps logs
tail -f /var/log/bb-tune.log
```

A Mac still running a bb-tune older than 2026-10-16 turns Bluetooth back off every
6 h. Until it is updated, pin it on: `echo DISABLE_BLUETOOTH=0 | sudo tee -a /usr/local/lib/bb-tune/config`.

Per-Mac toggles live in `/usr/local/lib/bb-tune/config` (1 on / 0 off):
`DISABLE_SPOTLIGHT ERASE_SPOTLIGHT_INDEX DISABLE_PHOTO_ANALYSIS DISABLE_KNOWLEDGE
DISABLE_BLUETOOTH BLUETOOTH_FORCE LOG_CAP_MB`.

## VPS boxes (BB_VM=1)

VPS boxes are set up with `curl -fsSL <url> | sudo BB_VM=1 bash`. The provider's
NoMachine stays the way in to the desktop and is never touched: no RustDesk, SSH
hardening, lockdown, autologin, firewall or Screen Sharing changes. The one thing
added is Tailscale, by `bb-tailscale.sh`: Tailscale SSH, served by the open-source
`tailscaled` system daemon, which keeps working when the desktop does not.

Why: on 2026-10-16 WindowServer crashed on VPS-01. Every GUI session but one died,
4 of 5 phone lines went down, NoMachine showed "No available desktops", the provider
panel's Reboot and Screen Sharing hung, and only NoMachine's port is open to the
internet. Getting a shell for `sudo reboot` took about an hour.

`bb-tailscale.sh` intentionally differs from the Tailscale step in
`bb-remote-admin.sh` (minis). Do not sync the two without Joe.

### Roll out to an existing box

In Terminal on the box (over NoMachine), from the joe account:

```bash
sudo git -c safe.directory=/Users/Shared/bb-headless -C /Users/Shared/bb-headless pull
sudo bash /Users/Shared/bb-headless/bb-tailscale.sh
```

It installs Homebrew for joe if it is missing, `brew install tailscale`, the system
daemon (with KeepAlive, so launchd restarts it if it dies), then prints a login URL.
Open it on your phone (Tailscale app signed in) and tap Approve. It waits 5 minutes;
a URL approved later still finishes the join, then re-run the script to finish the
checks. `sudo BB_TS_HOSTNAME=VPS-01 bash ...` also sets the machine name.

It stops and changes nothing if Tailscale.app (the GUI app) is on the box, if the
box's own address or its gateway is in 100.64.0.0/10 (the range Tailscale uses), or
if it is not run with sudo from an admin account that owns Homebrew.

Then in the admin console (https://login.tailscale.com/admin/machines), on the
machine's ... menu:

1. **Disable key expiry.** Otherwise the box drops off the tailnet in ~180 days,
   probably on the day you need it. `bb-tailscale.sh status` warns while it is on.
2. **Edit machine name**, e.g. `VPS-01`.

Check from your Mac: `tailscale ssh joe@vps-01 hostname`.

New boxes get all of this from setup.sh, right after the clone and before the
BlueBubbles build (`BB_TAILSCALE=0` skips it). The steps it prints at the end
repeat the approve / key expiry / rename list.

### Tailnet SSH policy

Tailscale SSH also needs an `ssh` rule in the tailnet policy file. The default rule
(`src` autogroup:member, `dst` autogroup:self, action `check`) covers a box joined
with the interactive login: the box belongs to Joe's identity, so `autogroup:self`
matches (`check` may ask you to sign in again in a browser now and then).

A box joined with a **tagged auth key** belongs to the tag, not to Joe, so
`autogroup:self` does not match and SSH is refused until the policy has an explicit
rule for that tag, for example:

```json
{"action": "accept", "src": ["autogroup:member"], "dst": ["tag:vps"], "users": ["joe"]}
```

An auth key goes in a file, never on the command line:
`sudo BB_TS_AUTHKEY_FILE=/path/to/keyfile bash /Users/Shared/bb-headless/bb-tailscale.sh`
(the file must be mode 0600; delete it afterwards).

### When the desktop hangs

From your Mac:

```bash
tailscale ssh joe@vps-01        # or plain: ssh joe@vps-01
fdesetup status                 # FileVault On or Off?
sudo reboot                     # FileVault Off
sudo fdesetup authrestart       # FileVault On: comes back without the unlock screen
```

### Check, update, remove

```bash
bash /Users/Shared/bb-headless/bb-tailscale.sh status          # no sudo needed; with sudo it also reads KeepAlive
sudo bash /Users/Shared/bb-headless/bb-tailscale.sh update     # brew upgrade tailscale, new daemon if it changed
sudo bash /Users/Shared/bb-headless/uninstall-tailscale.sh     # remove Tailscale completely (run it from NoMachine)
tail -f /var/log/bb-tailscale.log
```

A step that restarts `tailscaled` (an update that changed the daemon, a repair)
would cut a Tailscale SSH session, so inside one the script skips that step and
exits 3 (joined and verified, only the restart is left). Run it from NoMachine, or over Tailscale SSH with
`sudo BB_TS_ALLOW_DROP=1 bash /Users/Shared/bb-headless/bb-tailscale.sh update`:
the restart then runs last, detached; you drop, reconnect in ~30 s and run `status`.
setup.sh never restarts it from inside a Tailscale SSH session.

## Revert a Mac to Electron

```bash
sudo bash /Users/Shared/bb-headless/uninstall.sh
```

Or revert a single user (run from their login):
```bash
pkill -f 'node.*headless' && open -a BlueBubbles
```

## Prerequisites per Mac

- Node.js installed (`node` in PATH)
- BlueBubbles.app installed (for Private API dylib)
- Each user must have been set up with Electron BB at least once (config.db must exist with port, password, server address, Cloudflare tunnel configured)
- GitHub CLI authenticated (`gh auth login`) or use HTTPS token for cloning

## Logs

Per-user logs:
```bash
tail -f /var/log/bb-headless-m01.log
tail -f /var/log/bb-headless-m02.log
```

Install log:
```bash
cat /var/log/bb-headless-install.log
```

## Check status

```bash
# See all headless BB processes
ps aux | grep 'node.*headless'

# Check a specific user's port
lsof -nP -iTCP -sTCP:LISTEN -a -p $(pgrep -u m01 -f 'node.*headless')

# Test API
curl -s "http://localhost:PORT/api/v1/server/info?password=YOUR_PASSWORD" | python3 -m json.tool
```

## Architecture

Each user's BlueBubbles config lives at:
```
~/Library/Application Support/bluebubbles-server/config.db
```

This contains: socket_port, server_address, password, proxy_service, webhooks, FCM config.

The headless server reads this same database. Cloudflare Zero Trust tunnels point to localhost:PORT per user — no changes needed.

Build lives at:
```
/usr/local/lib/bb-headless/bluebubbles-server/packages/server/dist/headless.js
```

LaunchAgents are installed at:
```
~/Library/LaunchAgents/com.bb-headless.server.plist
```

They auto-start on login and auto-restart on crash (KeepAlive).

## Why this fixes the crashes

- Electron BB = Chromium GUI window + renderer + GPU compositing per user
- 5 users x Electron = WindowServer managing 5 full GUI sessions
- WindowServer bloats to 1GB+ over days -> watchdog kills it -> Mac crashes
- Headless BB = plain Node.js process -> WindowServer manages 0 BB windows
- WindowServer stays at ~50-80 MB -> never crashes

## File structure

```
bb-headless/                        (lives at /Users/Shared/bb-headless)
├── install.sh                      # Main installer — run with sudo
├── uninstall.sh                    # Revert to Electron
├── RUNBOOK.md                      # This file
└── src/
    ├── headless.ts                 # Node.js entry point (replaces Electron main.ts)
    ├── electron-shim.ts            # Build-time Electron API stubs
    ├── electron-runtime-shim.js    # Runtime Electron stubs (for electron-log etc.)
    └── webpack.headless.config.js  # Webpack config targeting Node
```

## Troubleshooting

**Users NOT RUNNING after install**: Run the full install, not --deploy-only. The build must exist at /usr/local/lib/bb-headless/ first. Check the user's log: `cat /var/log/bb-headless-USERNAME.log`

**"Private API Helper is not connected"**: BlueBubbles.app must be installed so the dylib can be copied. Run `sudo bash install.sh` again after installing BB.app.

**Messages not sending**: Check that Messages.app is running for that user. The headless server starts it via AppleScript.

**Port conflict**: Make sure Electron BB is fully stopped before headless starts. `pkill -u USERNAME -f BlueBubbles.app`

**LaunchAgent not starting**: Check `launchctl print gui/UID/com.bb-headless.server` and the user's log at `/var/log/bb-headless-USERNAME.log`

**Permission denied errors**: Run `sudo chmod -R a+rX /usr/local/lib/bb-headless/` then re-run `sudo bash install.sh --deploy-only`
