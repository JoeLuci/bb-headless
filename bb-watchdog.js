'use strict';
// bb-watchdog.js - phone Mac watchdog for Viato Mac Health.
//
// One resident root process (LaunchDaemon com.local.bb-watchdog, KeepAlive)
// that every 60 s:
//   1. collects the Mac's health (load, memory, swap, WindowServer, coreaudiod,
//      each BlueBubbles account's server) with hard time limits,
//   2. reports it to Viato (POST /api/phone-machines/report),
//   3. when Auto-fix is on, fixes two things itself: a line server that
//      stopped answering (launchctl kickstart) and an allow-listed desktop
//      process stuck at full CPU (universalaccessd, ControlCenter),
//   4. runs the fixed set of actions a Super Admin queued (restart a line
//      server, quit a stuck process, re-run bb-tune, restart the Mac).
//
// It never kills coreaudiod, WindowServer, logd and the other NEVER entries,
// never reboots on its own, and never runs anything Viato sends that is not
// one of those four actions. Every rule is checked here again, whatever Viato
// says.
//
// Installed by bb-watchdog.sh into /opt/bb-watchdog with its own root-owned
// copy of node. Plan (Viato side): MAC_HEALTH_WATCHDOG_PLAN.md, Part G.
//
// Usage (the installer calls the subcommands; the daemon runs with none):
//   node bb-watchdog.js                     run the daemon
//   node bb-watchdog.js enroll --url URL    read a Connect code on stdin, enroll
//   node bb-watchdog.js uninstall-report    tell Viato this Mac is uninstalling
//   node bb-watchdog.js status              print a summary of state.json

const fs = require('fs');
const os = require('os');
const http = require('http');
const https = require('https');
const crypto = require('crypto');
const { execFile } = require('child_process');

const VERSION = '1.0.0';
const SCHEMA_VERSION = 1;

const HOME = '/opt/bb-watchdog';
const KEY_FILE = `${HOME}/key`;
const UUID_FILE = `${HOME}/platform_uuid`;
const CONFIG_FILE = `${HOME}/config.json`;
const STATE_DIR = '/var/db/bb-watchdog';
const STATE_FILE = `${STATE_DIR}/state.json`;
const LOG_FILE = '/var/log/bb-watchdog.log';
const LOG_MAX_BYTES = 5 * 1024 * 1024;
const BB_TUNE = '/usr/local/lib/bb-tune/bb-tune.sh';
const HEADLESS_MATCH = 'bluebubbles-server/packages/server/dist/headless.js';
const LABEL = 'com.bb-headless.server';

const CYCLE_MS = 60_000;
const COLLECT_BUDGET_MS = 25_000;
const REPORT_TIMEOUT_MS = 15_000;
const RESULTS_TIMEOUT_MS = 10_000;
const HANG_MS = 6 * 60_000;
const OFFLINE_RETRY_MS = 10 * 60_000;
const SLOW_EVERY_MS = 10 * 60_000;
const FOOTPRINT_EVERY_MS = 5 * 60_000;
const MAX_CHILDREN = 4;
const MAX_RSS_BYTES = 200 * 1024 * 1024;

const QUIT_ALLOW = [
  '/usr/sbin/universalaccessd',
  '/System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter',
];
const NEVER = [
  'coreaudiod', 'WindowServer', 'logd', 'launchd', 'loginwindow', 'kernel_task',
  'node', 'cloudflared', 'tailscaled', 'RustDesk', 'bluetoothd',
];

const RULES = {
  notAnsweringCyclesToFix: 3,
  notRunningCyclesToFix: 2,
  minAgeS: 600,
  crashLoopPidChanges: 3,
  restartSpacingMs: 15 * 60_000,
  restartCap: 3,
  restartCapWindowMs: 6 * 3600_000,
  remoteCapPerHour: 6,
  hotCpu: 80,
  hotCycles: 3,
  quitCapPerHour: 3,
  quitBackoffMs: 6 * 3600_000,
  audioHotCpu: 90, // a coreaudiod stuck on one thread can read just under 100% in ps (AZ-05 10/23: 103-147%)
  loadHighPerCore: 4,
  loadStarvedPerCore: 8,
  starvedPerCore: 2,
  restartMacSpacingMs: 6 * 3600_000,
  restartMacMinUptimeS: 3600,
};

// ── small helpers ─────────────────────────────────────────────────────────
// The daemon writes its own log (launchd's StandardOutPath would keep writing
// to a rotated-away file), rotating at 5 MB to one .1 copy. `onceKey` lines are
// written only when their text changes, so a watch-only Mac does not log the
// same "would restart" every minute.
const lastLogged = new Map();
function log(msg, onceKey) {
  if (onceKey) {
    if (lastLogged.get(onceKey) === msg) return;
    lastLogged.set(onceKey, msg);
  }
  const line = `${new Date().toISOString()} [bb-watchdog] ${msg}\n`;
  if (require.main !== module || process.argv[2]) { process.stdout.write(line); return; }
  try {
    try { if (fs.statSync(LOG_FILE).size > LOG_MAX_BYTES) fs.renameSync(LOG_FILE, `${LOG_FILE}.1`); } catch { /* no log yet */ }
    fs.appendFileSync(LOG_FILE, line, { mode: 0o644 });
  } catch {
    process.stdout.write(line);
  }
}

function basename(p) {
  const s = String(p || '');
  const i = s.lastIndexOf('/');
  return i >= 0 ? s.slice(i + 1) : s;
}

function isNever(path) {
  const b = basename(path);
  return NEVER.some((n) => b === n || b.startsWith(`${n} `) || String(path).includes(`/${n}.app/`));
}

function isQuitAllowed(path) {
  return QUIT_ALLOW.includes(path) && !isNever(path);
}

function within(list, now, windowMs) {
  return (list || []).filter((t) => now - t < windowMs);
}

function uuidv4() {
  return crypto.randomUUID();
}

// ── child processes with hard limits ─────────────────────────────────────
const tracked = new Set();
let running = 0;
const queue = [];

function pump() {
  while (running < MAX_CHILDREN && queue.length) {
    const job = queue.shift();
    running += 1;
    job();
  }
}

/**
 * execFile with a timeout, SIGKILL, tracking for the deadline, and at most
 * MAX_CHILDREN at once. `priority` jobs (the every-cycle probes) go to the front
 * of the queue so the 10-minute account scan can never hold them up.
 */
function run(cmd, args, timeoutMs, opts = {}) {
  const { priority, input, ...execOpts } = opts;
  return new Promise((resolve) => {
    (priority ? queue.unshift.bind(queue) : queue.push.bind(queue))(() => {
      let child;
      try {
        child = execFile(cmd, args, { timeout: timeoutMs, killSignal: 'SIGKILL', maxBuffer: 8 * 1024 * 1024, ...execOpts },
          (err, stdout, stderr) => {
            tracked.delete(child);
            running -= 1;
            pump();
            resolve({
              ok: !err,
              code: err && typeof err.code === 'number' ? err.code : err ? -1 : 0,
              killed: !!(err && err.killed),
              stdout: String(stdout || ''),
              stderr: String(stderr || ''),
            });
          });
      } catch (e) {
        running -= 1;
        pump();
        resolve({ ok: false, code: -1, killed: false, stdout: '', stderr: String(e && e.message) });
        return;
      }
      tracked.add(child);
      if (input !== undefined && child.stdin) child.stdin.end(input);
    });
    pump();
  });
}

function killTracked() {
  for (const c of tracked) {
    try { c.kill('SIGKILL'); } catch { /* gone */ }
  }
}

/** Resolve to the value, or to `fallback` once ms pass. */
function withDeadline(promise, ms, fallback) {
  let t;
  return Promise.race([
    promise.finally(() => clearTimeout(t)),
    new Promise((resolve) => { t = setTimeout(() => resolve(fallback), ms); }),
  ]);
}

// ── parsers (pure) ──────────────────────────────────────────────────────
/** ps etime "[[dd-]hh:]mm:ss" -> seconds */
function parseEtime(s) {
  const m = /^(?:(\d+)-)?(?:(\d+):)?(\d+):(\d+)$/.exec(String(s).trim());
  if (!m) return null;
  return (Number(m[1] || 0) * 86400) + (Number(m[2] || 0) * 3600) + (Number(m[3]) * 60) + Number(m[4]);
}

/** `ps -axo pid=,uid=,pcpu=,rss=,etime=,comm=` -> rows */
function parsePs(text) {
  const out = [];
  for (const line of String(text).split('\n')) {
    const m = /^\s*(\d+)\s+(\d+)\s+([\d.]+)\s+(\d+)\s+(\S+)\s+(.+?)\s*$/.exec(line);
    if (!m) continue;
    out.push({ pid: Number(m[1]), uid: Number(m[2]), cpu: Number(m[3]), rssKb: Number(m[4]), ageS: parseEtime(m[5]), path: m[6] });
  }
  return out;
}

/** `lsof -F pun` -> [{pid, uid, port}] for LISTEN sockets */
function parseLsof(text) {
  const out = [];
  let pid = null;
  let uid = null;
  for (const line of String(text).split('\n')) {
    if (!line) continue;
    const tag = line[0];
    const v = line.slice(1);
    if (tag === 'p') { pid = Number(v); uid = null; }
    else if (tag === 'u') uid = Number(v);
    else if (tag === 'n' && pid !== null) {
      const m = /:(\d+)$/.exec(v);
      if (m) out.push({ pid, uid, port: Number(m[1]) });
    }
  }
  return out;
}

/** "total = 2048.00M  used = 483.62M  free = ..." -> MB */
function parseSwap(line) {
  const num = (k) => {
    const m = new RegExp(`${k} = ([\\d.]+)([MG])`).exec(String(line));
    if (!m) return null;
    return Math.round(Number(m[1]) * (m[2] === 'G' ? 1024 : 1));
  };
  return { total: num('total'), used: num('used') };
}

function parseFileVault(raw) {
  const s = String(raw || '').trim();
  if (s === 'FileVault is Off.') return 'off';
  if (/^FileVault is On/.test(s)) return 'on';
  return 'unknown';
}

/** `launchctl print-disabled gui/<uid>` -> is com.bb-headless.server disabled */
function parseDisabled(text) {
  const m = new RegExp(`"${LABEL.replace(/\./g, '\\.')}" => (\\w+)`).exec(String(text));
  if (!m) return false;
  return m[1] === 'disabled' || m[1] === 'true';
}

/** `footprint -f bytes` output -> MB */
function parseFootprint(text) {
  const m = /Footprint:\s*([\d,]+)\s*B/.exec(String(text)) || /Footprint:\s*([\d,]+)/.exec(String(text));
  if (!m) return null;
  return Math.round(Number(m[1].replace(/,/g, '')) / 1048576);
}

// ── decisions (pure; tests drive these) ─────────────────────────────────
/**
 * Updates one account's streaks from this cycle's probe. Mutates and returns u.
 * `alive` is null when the process scan failed this cycle: unknown never moves
 * a streak, the same as an unknown probe.
 */
function updateLineStreaks(u, probe, alive, pid, now, dtS) {
  u.pidHistory = (u.pidHistory || []).filter((h) => now - h.at < 600_000);
  if (pid && (!u.pidHistory.length || u.pidHistory[u.pidHistory.length - 1].pid !== pid)) {
    u.pidHistory.push({ pid, at: now });
  }
  if (probe === 'answering') {
    u.notAnsweringS = 0;
    u.notAnsweringCycles = 0;
    u.cyclesSinceRestart = null;
  } else if (probe === 'not_answering') {
    u.notAnsweringS = (u.notAnsweringS || 0) + dtS;
    u.notAnsweringCycles = (u.notAnsweringCycles || 0) + 1;
    if (u.cyclesSinceRestart !== null && u.cyclesSinceRestart !== undefined) u.cyclesSinceRestart += 1;
  }
  if (alive === true) u.notRunningCycles = 0;
  else if (alive === false) u.notRunningCycles = (u.notRunningCycles || 0) + 1;
  return u;
}

function pidChanges10m(u) {
  return Math.max(0, (u.pidHistory || []).length - 1);
}

/**
 * Should this account's line server be restarted now?
 * ctx: { now, autofix, managed, starved, restartedThisCycle }
 * info: { alive, probe, guiSession, guiAgeS, serverAgeS, electron, disabled }
 *   alive / guiSession are null when the process scan failed this cycle.
 * -> { state: ok|would_fix|fixed|skipped|capped, reason, action: null|'kickstart_k'|'kickstart' }
 */
function decideLineFix(u, info, ctx) {
  const crashLoop = pidChanges10m(u) >= RULES.crashLoopPidChanges;
  const triggerAlive = info.alive === true && (u.notAnsweringCycles || 0) >= RULES.notAnsweringCyclesToFix;
  // "Not running" only counts when the scan really saw no server AND the line is not answering.
  const triggerDead = info.alive === false && info.probe !== 'answering' && (u.notRunningCycles || 0) >= RULES.notRunningCyclesToFix;
  if (!ctx.managed || (!triggerAlive && !triggerDead)) return { state: 'ok', reason: null, action: null };

  // Unknown session (scan failed): judge it next cycle. Grace: an account or a
  // server that just started is not judged yet.
  if (info.guiSession === null || info.guiSession === undefined) return { state: 'ok', reason: null, action: null };
  if (info.guiSession && (info.guiAgeS ?? 0) < RULES.minAgeS) return { state: 'ok', reason: null, action: null };
  if (triggerAlive && (info.serverAgeS ?? 0) < RULES.minAgeS && !crashLoop) return { state: 'ok', reason: null, action: null };

  if (u.needsPerson) return { state: 'capped', reason: null, action: null };
  const recent = within(u.restarts, ctx.now, RULES.restartCapWindowMs);
  if (recent.length >= RULES.restartCap) return { state: 'capped', reason: null, action: null, capHit: 'limit' };
  // A crash-looping server gets one restart; if it keeps crashing after that, a person looks at it.
  if (crashLoop && within(u.restarts, ctx.now, 600_000).length >= 1) return { state: 'capped', reason: null, action: null, capHit: 'crash' };
  // Its server was found not loaded on the last try: nothing to restart until bb-switch is run (re-checked every 10 min).
  if (u.notLoadedAt && ctx.now - u.notLoadedAt < 600_000) return { state: 'skipped', reason: 'not_loaded', action: null };
  if (recent.length && ctx.now - recent[recent.length - 1] < RULES.restartSpacingMs) return { state: 'ok', reason: null, action: null };

  let reason = null;
  if (ctx.starved) reason = 'starved';
  else if (info.electron) reason = 'electron';
  else if (!info.guiSession) reason = 'no_session';
  else if (info.disabled) reason = 'disabled';
  if (reason) return { state: 'skipped', reason, action: null };

  if (!ctx.autofix) return { state: 'would_fix', reason: null, action: null };
  if (ctx.restartedThisCycle) return { state: 'ok', reason: null, action: null };
  return { state: 'fixed', reason: null, action: triggerAlive ? 'kickstart_k' : 'kickstart' };
}

/**
 * Stuck desktop process. p = state entry for uid:path ({pid, hotCycles, kills, backoffUntil}).
 * -> { state: null|would_fix|fixed|skipped_audio|capped, kill: bool }
 */
function decideProcessFix(p, ctx) {
  if (p.backoffUntil && ctx.now < p.backoffUntil) return { state: 'capped', kill: false };
  if ((p.hotCycles || 0) < RULES.hotCycles) return { state: null, kill: false };
  if (ctx.audioHot) return { state: 'skipped_audio', kill: false };
  if (within(p.kills, ctx.now, 3600_000).length >= RULES.quitCapPerHour) {
    p.backoffUntil = ctx.now + RULES.quitBackoffMs;
    return { state: 'capped', kill: false };
  }
  if (!ctx.autofix) return { state: 'would_fix', kill: false };
  return { state: 'fixed', kill: true };
}

/** Rules for a queued Super Admin action, checked on the Mac. -> null (allowed) or the refusal reason. */
function validateCommand(cmd, ctx) {
  const t = cmd && cmd.target && typeof cmd.target === 'object' ? cmd.target : {};
  switch (cmd && cmd.action) {
    case 'restart_line_server': {
      if (!Number.isInteger(t.uid) || t.uid < 501) return 'Not a valid account.';
      if (!(ctx.commandUids || []).includes(t.uid)) return 'That account is not a line Viato can restart here.';
      const u = ctx.users[t.uid];
      if (!u) return 'That account has no BlueBubbles server here.';
      if (u.electron === true) return 'The BlueBubbles app is open in that account.';
      if (u.electron !== false) return 'Could not check whether the BlueBubbles app is open in that account. Try again in a minute.';
      if (within(ctx.remoteRestarts[t.uid], ctx.now, 3600_000).length >= RULES.remoteCapPerHour) return 'Restarted from Viato too many times in the last hour.';
      return null;
    }
    case 'quit_process': {
      if (!Number.isInteger(t.pid) || t.pid < 2) return 'Not a valid process.';
      if (typeof t.path !== 'string' || !isQuitAllowed(t.path)) return 'That process is not on the list the watchdog may quit.';
      const p = ctx.procs.find((x) => x.pid === t.pid);
      if (!p || p.path !== t.path) return 'That process is no longer running.';
      if (within(ctx.remoteQuits[`${p.uid}:${p.path}`], ctx.now, 3600_000).length >= RULES.remoteCapPerHour) return 'Quit from Viato too many times in the last hour.';
      return null;
    }
    case 'run_bb_tune':
      return null;
    case 'restart_mac':
      return null; // checked at run time (fdesetup is re-read right before acting)
    default:
      return 'Unknown action.';
  }
}

function hostKey(url) {
  if (!url) return null;
  const h = String(url).trim().toLowerCase().replace(/^[a-z][a-z0-9+.-]*:\/\//, '').split(/[/?#]/)[0].replace(/:\d+$/, '').replace(/_/g, '-');
  return h || null;
}

// ── state ───────────────────────────────────────────────────────────────
function emptyState() {
  return {
    users: {}, accounts: {}, procs: {}, remoteRestarts: {}, remoteQuits: {},
    pendingFixes: [], commands: {}, doneCommandIds: [],
    server: { autofix: false, managedUids: [], commandUids: [], audioHot: true },
    coreaudiodHotSince: null, loadHighSince: null, loadStarvedSince: null,
    footprint: {}, filevault: null, cores: null, lastSlowAt: 0, lastFootprintAt: 0,
    lastCycleAt: 0, lastRestartMacAt: 0, mode: 'connected', lastReportAttemptAt: 0,
  };
}

function loadState() {
  try {
    return { ...emptyState(), ...JSON.parse(fs.readFileSync(STATE_FILE, 'utf8')) };
  } catch {
    return emptyState();
  }
}

function saveState(state) {
  try {
    fs.mkdirSync(STATE_DIR, { recursive: true, mode: 0o700 });
    const tmp = `${STATE_FILE}.tmp`;
    fs.writeFileSync(tmp, JSON.stringify(state), { mode: 0o600 });
    fs.renameSync(tmp, STATE_FILE);
  } catch (e) {
    log(`could not save state: ${e.message}`);
  }
}

// ── HTTP ────────────────────────────────────────────────────────────────
function postJson(url, body, key, timeoutMs) {
  return new Promise((resolve) => {
    let u;
    try { u = new URL(url); } catch { resolve({ status: 0, body: null, error: 'bad url' }); return; }
    if (u.protocol !== 'https:') { resolve({ status: 0, body: null, error: 'https only' }); return; }
    const data = Buffer.from(JSON.stringify(body));
    const headers = { 'Content-Type': 'application/json', 'Content-Length': data.length, 'User-Agent': `bb-watchdog/${VERSION}` };
    if (key) headers.Authorization = `Bearer ${key}`;
    const req = https.request(u, { method: 'POST', headers, timeout: timeoutMs }, (res) => {
      const chunks = [];
      let size = 0;
      res.on('data', (c) => { size += c.length; if (size < 1024 * 1024) chunks.push(c); });
      res.on('end', () => {
        let parsed = null;
        try { parsed = JSON.parse(Buffer.concat(chunks).toString('utf8')); } catch { /* not json */ }
        resolve({ status: res.statusCode || 0, body: parsed });
      });
    });
    req.on('timeout', () => req.destroy(new Error('timeout')));
    req.on('error', (e) => resolve({ status: 0, body: null, error: e.message }));
    req.end(data);
  });
}

/** GET 127.0.0.1:port/api/v1/server/info. any HTTP status = answering. */
function probePort(port, timeoutMs) {
  return new Promise((resolve) => {
    const req = http.get({ host: '127.0.0.1', port, path: '/api/v1/server/info', timeout: timeoutMs }, (res) => {
      res.resume();
      resolve('answering');
    });
    req.on('timeout', () => { req.destroy(); resolve('timeout'); });
    req.on('error', (e) => resolve(e && e.code === 'ECONNREFUSED' ? 'refused' : 'error'));
  });
}

// ── collection ──────────────────────────────────────────────────────────
/**
 * Every 10 min: the BlueBubbles accounts (uid >= 501 with config.db + the
 * LaunchAgent plist) and their socket_port / server_address, FileVault, cores.
 * Runs beside the every-cycle probes, never ahead of them. A read that fails,
 * or a scan cut short by the deadline, keeps the last known values.
 */
async function collectSlow(state, token) {
  const [ids, homes] = await Promise.all([
    run('/usr/bin/dscl', ['.', '-list', '/Users', 'UniqueID'], 5000),
    run('/usr/bin/dscl', ['.', '-list', '/Users', 'NFSHomeDirectory'], 5000),
  ]);
  if (token.aborted) return;
  if (ids.ok && homes.ok) {
    const homeOf = new Map();
    for (const line of homes.stdout.split('\n')) {
      const m = /^(\S+)\s+(\/.+?)\s*$/.exec(line);
      if (m) homeOf.set(m[1], m[2]);
    }
    const next = {};
    for (const line of ids.stdout.split('\n')) {
      if (token.aborted) return;
      const m = /^(\S+)\s+(\d+)$/.exec(line.trim());
      if (!m || m[1].startsWith('_')) continue;
      const uid = Number(m[2]);
      if (uid < 501 || uid > 65533) continue;
      const home = homeOf.get(m[1]);
      if (!home) continue;
      const db = `${home}/Library/Application Support/bluebubbles-server/config.db`;
      const plist = `${home}/Library/LaunchAgents/${LABEL}.plist`;
      if (!fs.existsSync(db) || !fs.existsSync(plist)) continue;
      const prev = state.accounts[uid] || {};
      const [q, dis] = await Promise.all([
        run('/usr/bin/sqlite3', ['-readonly', db, "SELECT name || '=' || value FROM config WHERE name IN ('socket_port','server_address')"], 5000),
        run('/bin/launchctl', ['print-disabled', `gui/${uid}`], 5000),
      ]);
      if (token.aborted) return;
      let port = prev.socket_port ?? null;
      let address = prev.server_address ?? null;
      if (q.ok) {
        for (const row of q.stdout.split('\n')) {
          const [k, ...rest] = row.split('=');
          const v = rest.join('=').trim();
          if (k === 'socket_port' && /^\d+$/.test(v)) port = Number(v);
          if (k === 'server_address' && v) address = v.slice(0, 256);
        }
      }
      next[uid] = { name: m[1], uid, socket_port: port, server_address: address, disabled: dis.ok ? parseDisabled(dis.stdout) : prev.disabled ?? null };
    }
    state.accounts = next;
  }
  const [fv, cores] = await Promise.all([
    run('/usr/bin/fdesetup', ['status'], 5000),
    run('/usr/sbin/sysctl', ['-n', 'hw.physicalcpu'], 3000),
  ]);
  if (token.aborted) return;
  if (fv.ok) state.filevault = { raw: fv.stdout.trim().slice(0, 128), state: parseFileVault(fv.stdout), at: Date.now() };
  if (cores.ok && /^\d+/.test(cores.stdout.trim())) state.cores = Number(cores.stdout.trim());
}

async function collectFootprint(state, pids, token) {
  for (const [name, pid] of Object.entries(pids)) {
    if (!pid) continue;
    const r = await run('/usr/bin/footprint', ['--pid', String(pid), '--noCategories', '-f', 'bytes'], 10_000);
    if (token.aborted) return;
    const mb = r.ok ? parseFootprint(r.stdout) : null;
    if (mb !== null) state.footprint[name] = { mb, at: Date.now() };
  }
}

/**
 * One cycle's data. Each probe records whether it really succeeded (`psOk`,
 * `pgOk`, `lsOk`): a failed or killed probe is unknown, never "nothing there".
 * pgrep exits 1 when nothing matches; lsof exits 1 with no output the same way.
 */
async function collect(state) {
  const now = Date.now();
  const snap = {
    at: now, procs: [], psOk: false, headless: [], pgOk: false, listen: [], lsOk: false,
    memlevel: null, swap: { total: null, used: null }, probes: {},
  };
  const [load1, load5, load15] = os.loadavg();
  const cores = state.cores || os.cpus().length;
  const starved = load1 >= RULES.starvedPerCore * cores;
  snap.load = { load1, load5, load15, cores, starved };
  const token = { aborted: false };

  // The account scan starts beside the probes; the probes use the accounts the
  // last finished scan found (ports almost never change).
  let slow = Promise.resolve();
  if (now - (state.lastSlowAt || 0) >= SLOW_EVERY_MS || !Object.keys(state.accounts || {}).length) {
    state.lastSlowAt = now; // set up front: a scan cut short is retried in 10 min, not every cycle
    slow = collectSlow(state, token);
  }

  const fast = (async () => {
    const ports = Object.values(state.accounts || {}).map((a) => a.socket_port).filter((p) => p);
    const probes = Promise.all(ports.map((p) => probePort(p, 5000).then((r) => [p, r])));
    const [ps, pg, ls, sc] = await Promise.all([
      run('/bin/ps', ['-axo', 'pid=,uid=,pcpu=,rss=,etime=,comm='], 8000, { priority: true }),
      run('/usr/bin/pgrep', ['-f', HEADLESS_MATCH], 5000, { priority: true }),
      run('/usr/sbin/lsof', ['-a', '-b', '-nP', '-c', 'node', '-iTCP', '-sTCP:LISTEN', '-F', 'pun'], 8000, { priority: true }),
      run('/usr/sbin/sysctl', ['-n', 'kern.memorystatus_level', 'vm.swapusage'], 3000, { priority: true }),
    ]);
    const results = await probes;
    if (token.aborted) return;
    snap.psOk = ps.ok && !ps.killed;
    if (snap.psOk) snap.procs = parsePs(ps.stdout);
    snap.pgOk = !pg.killed && (pg.code === 0 || pg.code === 1);
    if (snap.pgOk) snap.headless = pg.stdout.split('\n').map((x) => Number(x.trim())).filter((n) => n > 0);
    snap.lsOk = !ls.killed && (ls.code === 0 || (ls.code === 1 && !ls.stdout.trim()));
    if (snap.lsOk) snap.listen = parseLsof(ls.stdout);
    if (sc.ok) {
      const lines = sc.stdout.split('\n');
      if (/^\d+$/.test((lines[0] || '').trim())) snap.memlevel = Number(lines[0].trim());
      snap.swap = parseSwap(lines.slice(1).join(' '));
    }
    for (const [p, r] of results) snap.probes[p] = r;
    if (!starved && now - (state.lastFootprintAt || 0) >= FOOTPRINT_EVERY_MS && snap.psOk) {
      state.lastFootprintAt = now;
      const ca = snap.procs.find((p) => p.path === '/usr/sbin/coreaudiod');
      const ws = snap.procs.find((p) => basename(p.path) === 'WindowServer');
      await collectFootprint(state, { coreaudiod: ca && ca.pid, windowserver: ws && ws.pid }, token);
    }
  })();

  const finished = await withDeadline(Promise.all([fast, slow]).then(() => true), COLLECT_BUDGET_MS, false);
  if (!finished) {
    token.aborted = true;
    log('collection hit its 25 s budget; unfinished checks are reported as unknown');
    killTracked();
  }
  return snap;
}

// ── analysis: snapshot + state -> report users, streaks ─────────────────
function analyze(state, snap) {
  const now = snap.at;
  const dtS = state.lastCycleAt ? Math.min(300, Math.max(1, Math.round((now - state.lastCycleAt) / 1000))) : 60;
  const procs = snap.procs;
  const byUid = (uid, pred) => procs.find((p) => p.uid === uid && pred(p));
  const users = [];
  const infoByUid = {};
  for (const acct of Object.values(state.accounts || {})) {
    const uid = acct.uid;
    const login = snap.psOk ? byUid(uid, (p) => p.path === '/System/Library/CoreServices/loginwindow.app/Contents/MacOS/loginwindow') : null;
    const serverProc = snap.psOk && snap.pgOk ? procs.find((p) => p.uid === uid && snap.headless.includes(p.pid)) || null : null;
    const alive = snap.psOk && snap.pgOk ? !!serverProc : null;
    const listening = serverProc && snap.lsOk ? snap.listen.some((l) => l.pid === serverProc.pid && l.port === acct.socket_port) : null;
    const electron = snap.psOk ? !!byUid(uid, (p) => p.path.includes('/BlueBubbles.app/')) : null;
    const raw = acct.socket_port ? snap.probes[acct.socket_port] : undefined;
    let probe = 'unknown';
    if (raw === 'answering') probe = 'answering';
    else if (raw === 'refused' || raw === 'error') probe = 'not_answering';
    else if (raw === 'timeout') probe = snap.load.starved ? 'unknown' : 'not_answering';
    // An HTTP answer from a process that is not this account's server listening on its port is not this line.
    if (probe === 'answering' && listening === false) probe = 'not_answering';

    const u = state.users[uid] || (state.users[uid] = { restarts: [] });
    updateLineStreaks(u, probe, alive, serverProc ? serverProc.pid : null, now, dtS);
    const info = {
      alive,
      probe,
      guiSession: snap.psOk ? !!login : null,
      guiAgeS: login ? login.ageS : null,
      serverAgeS: serverProc ? serverProc.ageS : null,
      electron: electron === true,
      disabled: acct.disabled === true,
    };
    infoByUid[uid] = info;
    users.push({
      name: acct.name, uid, socket_port: acct.socket_port ?? null, server_address: acct.server_address ?? null,
      gui_session: info.guiSession, gui_session_age_s: info.guiAgeS,
      server_pid: serverProc ? serverProc.pid : null, server_age_s: info.serverAgeS, server_listening: listening,
      pid_changes_10m: pidChanges10m(u), job_disabled: acct.disabled ?? null, electron_running: electron,
      probe, not_answering_s: u.notAnsweringS || 0,
      still_failing_after_restart: (u.cyclesSinceRestart ?? 0) >= 2,
      needs_person: !!u.needsPerson, fix_state: 'ok', fix_skip_reason: null,
    });
  }

  // machine-level streaks: a failed process scan leaves them as they were
  const ca = snap.psOk ? procs.find((p) => p.path === '/usr/sbin/coreaudiod') || null : undefined;
  if (snap.psOk) {
    const caHot = !!ca && ca.cpu >= RULES.audioHotCpu;
    state.coreaudiodHotSince = caHot ? state.coreaudiodHotSince || now : null;
  }
  const { load1, cores } = snap.load;
  const high = load1 >= RULES.loadHighPerCore * cores;
  const starvedLoad = load1 >= RULES.loadStarvedPerCore * cores;
  state.loadHighSince = high ? state.loadHighSince || now : null;
  state.loadStarvedSince = starvedLoad ? state.loadStarvedSince || now : null;

  // stuck-process streaks (only from a scan that worked)
  if (snap.psOk) {
    const seen = new Set();
    for (const p of procs) {
      if (!QUIT_ALLOW.includes(p.path)) continue;
      const key = `${p.uid}:${p.path}`;
      seen.add(key);
      const e = state.procs[key] || (state.procs[key] = { kills: [] });
      e.hotCycles = p.cpu >= RULES.hotCpu ? (e.pid === p.pid ? (e.hotCycles || 0) + 1 : 1) : 0;
      e.pid = p.pid;
      e.uid = p.uid;
      e.path = p.path;
    }
    for (const key of Object.keys(state.procs)) {
      const e = state.procs[key];
      if (!seen.has(key)) e.hotCycles = 0;
      if (!seen.has(key) && !(e.backoffUntil > now) && !within(e.kills, now, 3600_000).length) delete state.procs[key];
    }
  }

  // The Mac's own view of a stuck audio service, so quitting its clients is
  // blocked from the first minute, before Viato's 5-minute yellow arrives.
  const audioHotLocal = !snap.psOk || !ca || ca.cpu >= RULES.audioHotCpu || !!state.coreaudiodHotSince;
  return { users, infoByUid, ca: ca || null, dtS, audioHotLocal };
}

function buildFullReport(state, snap, analysis, platformUuid, commandResults) {
  const now = snap.at;
  const ws = snap.procs.find((p) => basename(p.path) === 'WindowServer');
  const fp = state.footprint || {};
  const fpAge = (k) => (fp[k] ? Math.round((now - fp[k].at) / 1000) : null);
  const top = [...snap.procs].sort((a, b) => b.cpu - a.cpu).slice(0, 10)
    .map((p) => ({ pid: p.pid, uid: p.uid, cpu: p.cpu, rss_mb: Math.round(p.rssKb / 1024), path: p.path.slice(0, 256) }));
  const processFixes = Object.values(state.procs)
    .filter((e) => e.lastState)
    .map((e) => ({ uid: e.uid, path: e.path, state: e.lastState }))
    .slice(0, 20);
  return {
    schema_version: SCHEMA_VERSION,
    type: 'full',
    agent_version: VERSION,
    platform_uuid: platformUuid,
    command_results: commandResults,
    host: {
      hostname: os.hostname().slice(0, 64),
      arch: process.arch === 'x64' ? 'x86_64' : process.arch,
      macos: state.macos || null,
      uptime_s: Math.round(os.uptime()),
      cores_physical: state.cores || null,
      load1: snap.load.load1, load5: snap.load.load5, load15: snap.load.load15,
      load_high_s: state.loadHighSince ? Math.round((now - state.loadHighSince) / 1000) : 0,
      load_starved_s: state.loadStarvedSince ? Math.round((now - state.loadStarvedSince) / 1000) : 0,
      memlevel: snap.memlevel,
      swap_used_mb: snap.swap.used, swap_total_mb: snap.swap.total,
      bluetooth: snap.psOk ? snap.procs.some((p) => p.path === '/usr/sbin/bluetoothd') : null,
      filevault: state.filevault ? state.filevault.state : 'unknown',
      filevault_checked_s: state.filevault ? Math.round((now - state.filevault.at) / 1000) : null,
      filevault_raw: state.filevault ? state.filevault.raw : null,
    },
    coreaudiod: {
      pid: analysis.ca ? analysis.ca.pid : null,
      cpu: analysis.ca ? analysis.ca.cpu : null,
      cpu_hot_s: state.coreaudiodHotSince ? Math.round((now - state.coreaudiodHotSince) / 1000) : 0,
      footprint_mb: fp.coreaudiod ? fp.coreaudiod.mb : null,
      footprint_age_s: fpAge('coreaudiod'),
    },
    windowserver: {
      pid: ws ? ws.pid : null,
      cpu: ws ? ws.cpu : null,
      footprint_mb: fp.windowserver ? fp.windowserver.mb : null,
      footprint_age_s: fpAge('windowserver'),
    },
    top,
    users: analysis.users,
    process_fixes: processFixes,
    fixes: state.pendingFixes.slice(0, 50).map((f) => ({ ...f, at_s_ago: Math.max(0, Math.round((now - f.at) / 1000)), at: undefined })),
  };
}

function pendingResults(state) {
  return Object.entries(state.commands)
    .filter(([, c]) => c.state === 'done')
    .slice(0, 10)
    .map(([id, c]) => ({ id, result: c.result, output: (c.output || '').slice(0, 2000) }));
}

function applyAccepted(state, body) {
  const fixIds = new Set((body && body.accepted_fix_ids) || []);
  if (fixIds.size) state.pendingFixes = state.pendingFixes.filter((f) => !fixIds.has(f.mac_event_id));
  for (const id of (body && body.accepted_result_ids) || []) {
    if (state.commands[id]) {
      delete state.commands[id];
      state.doneCommandIds = [id, ...state.doneCommandIds.filter((x) => x !== id)].slice(0, 200);
    }
  }
}

// ── actions ─────────────────────────────────────────────────────────────
async function jobLoaded(uid) {
  const r = await run('/bin/launchctl', ['print', `gui/${uid}/${LABEL}`], 10_000);
  return r.ok;
}

async function kickstart(uid, kill) {
  const args = kill ? ['kickstart', '-k', `gui/${uid}/${LABEL}`] : ['kickstart', `gui/${uid}/${LABEL}`];
  const r = await run('/bin/launchctl', args, 20_000);
  return { ok: r.ok, output: `launchctl ${args.join(' ')}${r.ok ? '' : `: ${(r.stderr || r.stdout).trim().slice(0, 300)}`}` };
}

async function currentPath(pid) {
  const r = await run('/bin/ps', ['-p', String(pid), '-o', 'comm='], 5000);
  return r.ok ? r.stdout.trim() : null;
}

async function quit(pid, path) {
  if (!isQuitAllowed(path)) return { ok: false, output: 'Not on the quit list.' };
  const now = await currentPath(pid);
  if (now !== path) return { ok: false, output: 'That process is no longer the one reported.' };
  try {
    process.kill(pid, 'SIGTERM');
    return { ok: true, output: `Sent TERM to ${basename(path)} (${pid}).` };
  } catch (e) {
    return { ok: false, output: e.message };
  }
}

function rootOwned(path) {
  try {
    const st = fs.statSync(path);
    return st.uid === 0 && (st.mode & 0o022) === 0;
  } catch {
    return false;
  }
}

/**
 * Decides this cycle's fixes before the report (pure decisions, so users[] and
 * process_fixes[] carry their state), without acting. Returns the actions for
 * executeFixes, which runs after the report has gone out.
 */
function planFixes(state, snap, analysis) {
  const now = snap.at;
  const managed = new Set(state.server.managedUids || []);
  const autofix = state.server.autofix === true;
  const plan = [];
  let restartPlanned = false;
  for (const ru of analysis.users) {
    const u = state.users[ru.uid];
    const info = analysis.infoByUid[ru.uid];
    // "Needs a person" ends when a person restarts the line from Viato, or 6 h
    // after the limit was hit once its restarts have aged out of the window.
    if (u.needsPerson && now - (u.cappedAt || 0) >= RULES.restartCapWindowMs
        && within(u.restarts, now, RULES.restartCapWindowMs).length < RULES.restartCap) {
      u.needsPerson = false;
      u.cappedAt = null;
    }
    const d = decideLineFix(u, info, { now, autofix, managed: managed.has(ru.uid), starved: snap.load.starved, restartedThisCycle: restartPlanned });
    if (d.capHit && !u.needsPerson) {
      u.needsPerson = true;
      u.cappedAt = now;
      log(`line ${ru.name} (${ru.uid}) ${d.capHit === 'crash' ? 'keeps crashing after a restart' : 'hit its restart limit'}: needs a person`, `cap:${ru.uid}`);
    }
    ru.fix_state = d.state;
    ru.fix_skip_reason = d.reason;
    ru.needs_person = !!u.needsPerson;
    log(d.state === 'would_fix' ? `would restart ${ru.name}'s server (watch only)` : `line ${ru.name}: ${d.state}`, `line:${ru.uid}`);
    if (d.action) {
      restartPlanned = true;
      plan.push({ kind: 'line', uid: ru.uid, name: ru.name, action: d.action });
    }
  }
  const audioHot = state.server.audioHot !== false || analysis.audioHotLocal;
  for (const e of Object.values(state.procs)) {
    const d = decideProcessFix(e, { now, audioHot, autofix });
    e.lastState = d.state;
    if (d.kill) plan.push({ kind: 'proc', key: `${e.uid}:${e.path}`, pid: e.pid, path: e.path, uid: e.uid });
  }
  return plan;
}

async function executeFixes(state, plan, analysis) {
  const now = Date.now();
  // The plan was made from the previous response; the fresh one may have turned
  // Auto-fix off, dropped an account from managed_uids or flagged the audio service.
  const fresh = state.server;
  const allowed = plan.filter((step) =>
    fresh.autofix === true && (step.kind === 'line'
      ? (fresh.managedUids || []).includes(step.uid)
      : fresh.audioHot === false && !analysis.audioHotLocal));
  for (const step of allowed) {
    if (step.kind === 'line') {
      const u = state.users[step.uid];
      if (!(await jobLoaded(step.uid))) {
        u.notLoadedAt = now;
        log(`could not restart ${step.name}'s server: it is not loaded (run bb-switch from that login)`, `notloaded:${step.uid}`);
        continue;
      }
      u.notLoadedAt = null;
      const r = await kickstart(step.uid, step.action === 'kickstart_k');
      u.restarts = [...within(u.restarts, now, RULES.restartCapWindowMs), now];
      u.cyclesSinceRestart = 0;
      log(`restarted ${step.name}'s server: ${r.output}`);
      state.pendingFixes.push({
        mac_event_id: uuidv4(), at: now, code: 'restart_line', target: { uid: step.uid, path: null }, result: r.ok ? 'ok' : 'failed',
        note: step.action === 'kickstart_k' ? `not answering ${u.notAnsweringCycles} checks` : `not running ${u.notRunningCycles} checks`,
      });
    } else {
      const e = state.procs[step.key];
      const r = await quit(step.pid, step.path);
      if (e) {
        e.kills = [...within(e.kills, now, 3600_000), now];
        e.hotCycles = 0;
      }
      log(`quit stuck ${basename(step.path)} for uid ${step.uid}: ${r.output}`);
      state.pendingFixes.push({
        mac_event_id: uuidv4(), at: now, code: 'quit_process', target: { uid: step.uid, path: step.path }, result: r.ok ? 'ok' : 'failed',
        note: `${RULES.hotCycles} checks at >= ${RULES.hotCpu}% CPU`,
      });
    }
    saveState(state);
  }
  state.pendingFixes = state.pendingFixes.slice(-200);
}

/** Returns { restartMac: bool } so the caller can send results and then reboot. */
async function runCommands(state, snap, analysis, commands) {
  const now = snap.at;
  let long = false;
  let restartMac = false;
  const users = {};
  for (const ru of analysis.users) users[ru.uid] = { electron: ru.electron_running };
  const ctx = {
    now, users, procs: snap.procs, commandUids: state.server.commandUids || [],
    remoteRestarts: state.remoteRestarts, remoteQuits: state.remoteQuits,
  };
  for (const cmd of (commands || []).slice(0, 3)) {
    if (!cmd || typeof cmd.id !== 'string') continue;
    if (state.commands[cmd.id] || state.doneCommandIds.includes(cmd.id)) continue;
    const finish = (result, output) => {
      state.commands[cmd.id] = { state: 'done', result, output: String(output || '').slice(0, 2000), at: Date.now() };
      saveState(state);
      log(`command ${cmd.action} ${cmd.id}: ${result} ${output || ''}`);
    };
    const refusal = validateCommand(cmd, ctx);
    if (refusal) { finish('refused', refusal); continue; }
    const isLong = cmd.action === 'run_bb_tune' || cmd.action === 'restart_mac';
    if (isLong && long) { finish('refused', 'Only one long action per minute.'); continue; }
    if (isLong) long = true;

    state.commands[cmd.id] = { state: 'started', at: Date.now() };
    saveState(state);
    if (cmd.action === 'restart_line_server') {
      const uid = cmd.target.uid;
      if (!(await jobLoaded(uid))) { finish('refused', "That account's server is not loaded. Run bb-switch from that login."); continue; }
      const r = await kickstart(uid, true);
      state.remoteRestarts[uid] = [...within(state.remoteRestarts[uid], now, 3600_000), now];
      if (r.ok && state.users[uid]) Object.assign(state.users[uid], { needsPerson: false, cappedAt: null, notLoadedAt: null });
      finish(r.ok ? 'ok' : 'failed', r.output);
    } else if (cmd.action === 'quit_process') {
      const p = snap.procs.find((x) => x.pid === cmd.target.pid);
      const key = `${p ? p.uid : '?'}:${cmd.target.path}`;
      const r = await quit(cmd.target.pid, cmd.target.path);
      state.remoteQuits[key] = [...within(state.remoteQuits[key], now, 3600_000), now];
      finish(r.ok ? 'ok' : 'failed', r.output);
    } else if (cmd.action === 'run_bb_tune') {
      if (!rootOwned(BB_TUNE) || !rootOwned('/usr/local/lib/bb-tune')) { finish('refused', 'bb-tune is missing or not root-owned on this Mac.'); continue; }
      const r = await run('/bin/bash', [BB_TUNE], 180_000);
      const tail = (r.stdout || r.stderr).trim().split('\n').slice(-6).join('\n');
      finish(r.ok ? 'ok' : 'failed', tail || (r.killed ? 'Timed out after 3 minutes.' : ''));
    } else if (cmd.action === 'restart_mac') {
      const fv = await run('/usr/bin/fdesetup', ['status'], 10_000);
      const raw = fv.stdout.trim();
      if (raw !== 'FileVault is Off.') { finish('refused', `FileVault check: ${raw || 'could not read it'}`); continue; }
      if (os.uptime() < RULES.restartMacMinUptimeS) { finish('refused', 'This Mac started less than an hour ago.'); continue; }
      if (now - (state.lastRestartMacAt || 0) < RULES.restartMacSpacingMs) { finish('refused', 'This Mac was restarted from Viato in the last 6 hours.'); continue; }
      state.lastRestartMacAt = now;
      finish('ok', 'Restart started.');
      restartMac = true;
      break;
    }
  }
  return { restartMac };
}

// ── daemon ──────────────────────────────────────────────────────────────
function readFile(path) {
  try { return fs.readFileSync(path, 'utf8').trim(); } catch { return null; }
}

function readConfig() {
  try { return JSON.parse(fs.readFileSync(CONFIG_FILE, 'utf8')); } catch { return {}; }
}

async function readPlatformUuid() {
  const r = await run('/usr/sbin/ioreg', ['-rd1', '-c', 'IOPlatformExpertDevice'], 10_000);
  const m = /"IOPlatformUUID"\s*=\s*"([^"]+)"/.exec(r.stdout);
  return m ? m[1] : null;
}

async function startupUuid() {
  const stored = readFile(UUID_FILE);
  for (let i = 0; i < 3; i += 1) {
    const fresh = await readPlatformUuid();
    if (fresh) {
      if (stored && fresh !== stored) log('this Mac\'s hardware UUID differs from the one it was connected with; reporting the new one');
      return fresh;
    }
  }
  return stored;
}

let lastCycleDone = Date.now();

async function cycle(state, ctx) {
  const snap = await collect(state);
  const analysis = analyze(state, snap);
  state.lastCycleAt = snap.at;

  const key = readFile(KEY_FILE);
  const url = `${ctx.url.replace(/\/+$/, '')}/api/phone-machines/report`;
  const canReport = key && ctx.uuid && (state.mode === 'connected' || Date.now() - state.lastReportAttemptAt >= OFFLINE_RETRY_MS);
  let response = null;
  let fixPlan = [];
  if (canReport) {
    state.lastReportAttemptAt = Date.now();
    // Fixes are decided before the report (so it carries their state) and run after it.
    if (state.mode === 'connected') fixPlan = planFixes(state, snap, analysis);
    const report = buildFullReport(state, snap, analysis, ctx.uuid, pendingResults(state));
    const res = await withDeadline(postJson(url, report, key, REPORT_TIMEOUT_MS), REPORT_TIMEOUT_MS + 2000, { status: 0, body: null, error: 'deadline' });
    if (res.status === 200 && res.body) {
      if (state.mode !== 'connected') log('connected again');
      state.mode = 'connected';
      applyAccepted(state, res.body);
      state.server = {
        autofix: res.body.autofix === true,
        managedUids: Array.isArray(res.body.managed_uids) ? res.body.managed_uids.filter(Number.isInteger) : [],
        commandUids: Array.isArray(res.body.command_uids) ? res.body.command_uids.filter(Number.isInteger) : [],
        audioHot: res.body.audio_hot !== false,
      };
      response = res.body;
    } else if (res.status === 401) {
      if (state.mode !== 'disconnected') log('Viato says this Mac is not connected; no fixes or actions until it is connected again');
      state.mode = 'disconnected';
      state.server.autofix = false;
    } else if (res.status === 409) {
      if (state.mode !== 'reconnect') log('Viato says this key belongs to another Mac; no fixes or actions until it is connected again');
      state.mode = 'reconnect';
      state.server.autofix = false;
    } else if (res.status === 429 && res.body) {
      applyAccepted(state, res.body);
    } else if (res.status !== 429) {
      log(`report failed: ${res.status || res.error}`);
    }
  }

  // Only fixes planned while connected, and only if Viato did not just disconnect this Mac.
  if (fixPlan.length && state.mode === 'connected') await executeFixes(state, fixPlan, analysis);

  let restartMac = false;
  if (response && state.mode === 'connected' && Array.isArray(response.commands) && response.commands.length) {
    ({ restartMac } = await runCommands(state, snap, analysis, response.commands));
    const results = pendingResults(state);
    if (results.length) {
      const res = await withDeadline(
        postJson(url, { schema_version: SCHEMA_VERSION, type: 'results_only', agent_version: VERSION, platform_uuid: ctx.uuid, command_results: results }, key, RESULTS_TIMEOUT_MS),
        RESULTS_TIMEOUT_MS + 2000, { status: 0, body: null });
      if (res.status === 200 && res.body) applyAccepted(state, res.body);
    }
  }
  saveState(state);
  if (restartMac) {
    log('restarting this Mac (Super Admin action)');
    await run('/sbin/shutdown', ['-r', 'now'], 30_000);
  }
}

async function daemon() {
  const cfg = readConfig();
  const ctx = { url: typeof cfg.url === 'string' && cfg.url.startsWith('https://') ? cfg.url : 'https://viato.ai', uuid: null };
  const state = loadState();
  for (const [id, c] of Object.entries(state.commands)) {
    if (c.state === 'started') state.commands[id] = { state: 'done', result: 'failed', output: 'Interrupted (watchdog restarted).', at: Date.now() };
  }
  const sw = await run('/usr/bin/sw_vers', ['-productVersion'], 5000);
  if (sw.ok) state.macos = sw.stdout.trim().slice(0, 32);
  ctx.uuid = await startupUuid();
  if (!ctx.uuid) log('no hardware UUID on record; reports are paused until the watchdog is reinstalled');
  log(`started v${VERSION}, reporting to ${ctx.url}`);

  setInterval(() => {
    if (Date.now() - lastCycleDone > HANG_MS) {
      log('no cycle finished in 6 minutes; restarting the watchdog');
      killTracked();
      process.exit(3);
    }
    if (process.memoryUsage().rss > MAX_RSS_BYTES) {
      log('watchdog memory over 200 MB; restarting it');
      process.exit(4);
    }
  }, 30_000).unref();

  const loop = async () => {
    const started = Date.now();
    try {
      await cycle(state, ctx);
    } catch (e) {
      log(`cycle error: ${e && e.stack ? e.stack.split('\n')[0] : e}`);
    }
    lastCycleDone = Date.now();
    setTimeout(loop, Math.max(5_000, CYCLE_MS - (Date.now() - started)));
  };
  loop();
}

// ── installer subcommands ───────────────────────────────────────────────
async function enroll(url) {
  const code = (await new Promise((resolve) => {
    let s = '';
    process.stdin.setEncoding('utf8');
    process.stdin.on('data', (c) => { s += c; });
    process.stdin.on('end', () => resolve(s));
  })).trim();
  if (!code) { console.error('No Connect code was given.'); process.exit(1); }
  const uuid = await readPlatformUuid();
  if (!uuid) { console.error('Could not read this Mac\'s hardware UUID.'); process.exit(1); }
  const res = await postJson(`${url.replace(/\/+$/, '')}/api/phone-machines/enroll`,
    { code, hostname: os.hostname().slice(0, 64), agent_version: VERSION, platform_uuid: uuid }, null, 30_000);
  if (res.status !== 200 || !res.body || typeof res.body.key !== 'string') {
    console.error(`Viato did not accept the code: ${(res.body && res.body.error) || res.status || res.error}`);
    process.exit(1);
  }
  const old = process.umask(0o077);
  fs.writeFileSync(KEY_FILE, `${res.body.key}\n`, { mode: 0o600 });
  fs.writeFileSync(UUID_FILE, `${uuid}\n`, { mode: 0o600 });
  process.umask(old);
  fs.writeFileSync(CONFIG_FILE, JSON.stringify({ url }), { mode: 0o644 });
  try { fs.unlinkSync(STATE_FILE); } catch { /* none */ }
  console.log(`Connected as ${res.body.label || res.body.machine_id}.`);
}

async function uninstallReport() {
  const key = readFile(KEY_FILE);
  const uuid = readFile(UUID_FILE);
  const cfg = readConfig();
  if (!key || !uuid || typeof cfg.url !== 'string') return;
  await postJson(`${cfg.url.replace(/\/+$/, '')}/api/phone-machines/report`,
    { schema_version: SCHEMA_VERSION, type: 'results_only', agent_version: VERSION, platform_uuid: uuid, uninstalling: true, command_results: [] },
    key, 10_000);
}

function status() {
  const s = loadState();
  const cfg = readConfig();
  console.log(`watchdog v${VERSION}  url ${cfg.url || '-'}  mode ${s.mode}  auto-fix ${s.server.autofix ? 'on' : 'off (watch only)'}`);
  console.log(`last cycle ${s.lastCycleAt ? `${Math.round((Date.now() - s.lastCycleAt) / 1000)} s ago` : 'never'}`);
  console.log(`accounts: ${Object.values(s.accounts).map((a) => `${a.name}:${a.socket_port ?? '?'}`).join(' ') || '-'}`);
  console.log(`pending fixes ${s.pendingFixes.length}, open command results ${Object.keys(s.commands).length}`);
}

if (require.main === module) {
  const [cmd, ...rest] = process.argv.slice(2);
  if (!cmd) daemon();
  else if (cmd === 'enroll') {
    const i = rest.indexOf('--url');
    const url = i >= 0 ? rest[i + 1] : 'https://viato.ai';
    if (!url || !url.startsWith('https://')) { console.error('--url must start with https://'); process.exit(1); }
    enroll(url).catch((e) => { console.error(e.message); process.exit(1); });
  } else if (cmd === 'uninstall-report') uninstallReport().catch(() => undefined);
  else if (cmd === 'status') status();
  else { console.error('usage: node bb-watchdog.js [enroll --url URL | uninstall-report | status]'); process.exit(1); }
} else {
  module.exports = {
    RULES, QUIT_ALLOW, NEVER, isNever, isQuitAllowed, parseEtime, parsePs, parseLsof, parseSwap, parseFileVault,
    parseDisabled, parseFootprint, updateLineStreaks, pidChanges10m, decideLineFix, decideProcessFix, validateCommand,
    hostKey, analyze, buildFullReport, applyAccepted, emptyState, pendingResults, planFixes,
  };
}
