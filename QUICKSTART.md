# bb-headless: New Mac Setup

## Step 1: Build (once, from any user — e.g. m01)

```bash
git clone https://github.com/JoeLuci/bb-headless.git /Users/Shared/bb-headless
cd /Users/Shared/bb-headless
sudo bash install.sh --build-only
```

Wait 3-5 minutes for it to finish.

## Step 2: Switch each user

Fast User Switch into EACH user login. Open Terminal. Run:

```bash
bash /Users/Shared/bb-headless/switch-user.sh
```

Repeat for every user (m01, m02, m03, m04, m05).

## That's it.

## Verify

From any user:
```bash
for u in m01 m02 m03 m04 m05; do
  PID=$(pgrep -u $u -f "node.*headless" | head -1)
  if [ -n "$PID" ]; then
    echo "$u: RUNNING"
  else
    echo "$u: NOT RUNNING"
  fi
done
```

## Revert a user (if needed)

From that user's login:
```bash
pkill -f 'node.*headless' && open -a BlueBubbles
```

## Full docs

```bash
cat /Users/Shared/RUNBOOK-bb-headless.md
```
