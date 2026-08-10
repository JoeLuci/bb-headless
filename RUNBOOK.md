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
