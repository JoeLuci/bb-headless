# bb-headless: New Mac Setup

Node.js is **not** required beforehand — `install.sh` installs it system-wide if missing.

## Before you start

Each user login that should run headless must already have BlueBubbles set up in
the Electron app (so its `config.db` exists). Logins without one are skipped.

## Step 1: Install (once, from any user)

```bash
git clone https://github.com/JoeLuci/bb-headless.git /Users/Shared/bb-headless
cd /Users/Shared/bb-headless
sudo bash install.sh
```

Wait 3-5 minutes. This builds the server, then installs and starts a LaunchAgent
for every user that has a BlueBubbles config — including users who are not
currently logged in. **It survives logout and reboot.**

That's it. No per-user step needed.

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

A user shows `NOT RUNNING` if they had no BlueBubbles config at install time.
Set BlueBubbles up in the Electron app under that login, then re-run
`sudo bash install.sh --deploy-only`.

---

## Manual fallback: switch one user by hand

Only needed if you want to start headless for a single login without the
LaunchAgent. From **that user's own login**, and **without sudo**:

```bash
bash /Users/Shared/bb-headless/switch-user.sh
```

> **Never run `switch-user.sh` with sudo.** As root it reads root's config
> instead of yours and leaves an orphaned server attached to another user's
> Messages data. Only `install.sh` needs sudo.

A run started this way does **not** survive logout or reboot.

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
- LaunchAgent runs: `/var/log/bb-headless-<user>.log`
- `switch-user.sh` runs: `~/Library/Logs/bb-headless.log`

## Full docs

```bash
cat /Users/Shared/bb-headless/RUNBOOK.md
```
