# bb-headless Runbook

## What this is

Runs BlueBubbles Server as a plain Node.js process instead of Electron. Eliminates WindowServer load that was causing crashes (WindowServer bloating to 1GB+ after ~18 days with 5 GUI sessions per Mac, then watchdog killing it).

Repo: https://github.com/JoeLuci/bb-headless (private)

## Install on a new Mac

```bash
git clone https://github.com/JoeLuci/bb-headless.git /Users/Shared/bb-headless
cd /Users/Shared/bb-headless
sudo bash install.sh
```

This automatically:
- Clones BlueBubbles source
- Patches in the headless shim (replaces Electron with Node.js stubs)
- Builds with webpack
- Copies Private API dylib from BlueBubbles.app (must be installed)
- For every user with a config.db: creates a LaunchAgent, stops Electron BB, starts headless BB
- Each user's existing config (port, server_address, password, webhooks, Cloudflare tunnel) is preserved — headless reads the same config.db

## Update

```bash
cd /Users/Shared/bb-headless && git pull && sudo bash install.sh
```

## Revert a Mac to Electron

```bash
sudo bash /Users/Shared/bb-headless/uninstall.sh
```

Or revert a single user:
```bash
sudo -u m02 pkill -f 'node.*headless' && sudo -u m02 open -a BlueBubbles
```

## Build only (don't deploy)

```bash
sudo bash install.sh --build-only
```

## Deploy only (skip build)

```bash
sudo bash install.sh --deploy-only
```

## Prerequisites per Mac

- Node.js installed (`node` in PATH)
- BlueBubbles.app installed (for Private API dylib)
- Each user must have been set up with Electron BB at least once (config.db must exist with port, password, server address, Cloudflare tunnel configured)
- `gh auth login` done if cloning from GitHub (or use HTTPS token)

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

LaunchAgents are installed at:
```
~/Library/LaunchAgents/com.bb-headless.server.plist
```

They auto-start on login and auto-restart on crash (KeepAlive).

## Why this fixes the crashes

- Electron BB = Chromium GUI window + renderer + GPU compositing per user
- 5 users × Electron = WindowServer managing 5 full GUI sessions
- WindowServer bloats to 1GB+ over days → watchdog kills it → Mac crashes
- Headless BB = plain Node.js process → WindowServer manages 0 BB windows
- WindowServer stays at ~50-80 MB → never crashes

## File structure

```
bb-headless/
├── install.sh                      # Main installer
├── uninstall.sh                    # Revert to Electron
├── RUNBOOK.md                      # This file
└── src/
    ├── headless.ts                 # Node.js entry point (replaces Electron main.ts)
    ├── electron-shim.ts            # Build-time Electron API stubs
    ├── electron-runtime-shim.js    # Runtime Electron stubs (for electron-log etc.)
    └── webpack.headless.config.js  # Webpack config targeting Node
```

## Troubleshooting

**"Private API Helper is not connected"**: BlueBubbles.app must be installed so the dylib can be copied. Run `sudo bash install.sh` again after installing BB.app.

**Messages not sending**: Check that Messages.app is running for that user. The headless server starts it via AppleScript.

**Port conflict**: Make sure Electron BB is fully stopped before headless starts. `pkill -u USERNAME -f BlueBubbles.app`

**LaunchAgent not starting**: Check `launchctl print gui/UID/com.bb-headless.server` and the user's log at `/var/log/bb-headless-USERNAME.log`.
