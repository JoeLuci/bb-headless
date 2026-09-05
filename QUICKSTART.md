# bb-headless: Mac Setup

Two steps: one command as admin, then one command inside each user login.
Node.js is **not** required beforehand — the installer puts it in system-wide.

## Before you start

Each user login that should run headless must already have BlueBubbles set up in
the Electron app (so its `config.db` exists). Logins without one are skipped.

## Step 1: Once per Mac, from any admin login

Same command whether the Mac is brand new or already has bb-headless:

```bash
curl -fsSL https://raw.githubusercontent.com/JoeLuci/bb-headless/main/setup.sh | sudo bash
```

Wait 3-5 minutes. It clones/updates `/Users/Shared/bb-headless`, builds the
headless server, installs the health logger, sets up NoMachine and SSH, and
removes Tailscale.

## Step 2: Once per user login

Fast User Switch into each account, open Terminal, and run:

```bash
bb-switch
```

(Short for `bash /Users/Shared/bb-headless/switch-user.sh` — Step 1 puts the
`bb-switch` shortcut on the PATH. Either form works.)

It stops that user's Electron BlueBubbles, starts the headless server, and
installs a LaunchAgent so it comes back on login and reboot. Ten seconds per
user. If it fails it reverts that user to Electron by itself.

> **Never run it with sudo.** As root it reads root's config instead of yours
> and leaves an orphaned server attached to another user's Messages data.

## Step 3: Two clicks macOS will not let a script do

Two Privacy panes open at the end of Step 1. Tick **NoMachine** in both:

- Screen & System Audio Recording
- Accessibility

Then restart, and log the five accounts back in.

## Verify

From any user:
```bash
for u in m01 m02 m03 m04 m05; do
  if pgrep -u $u -f "node.*headless" >/dev/null 2>&1; then
    echo "$u: RUNNING"
  else
    echo "$u: NOT RUNNING"
  fi
done
```

A user shows `NOT RUNNING` if Step 2 has not been run from that login, or if
they had no BlueBubbles config when it was.

## Revert a user

From that user's login:
```bash
pkill -u $(whoami) -f 'node.*headless' && open -a BlueBubbles
```

To also stop it coming back at login:
```bash
launchctl bootout gui/$(id -u)/com.bb-headless.server
```

## Logs

- Install: `/var/log/bb-headless-install.log`
- Remote admin: `/var/log/bb-remote-admin.log`
- LaunchAgent runs: `/var/log/bb-headless-<user>.log`
- `switch-user.sh` runs: `~/Library/Logs/bb-headless.log`

## Full docs

```bash
cat /Users/Shared/bb-headless/RUNBOOK.md
```
