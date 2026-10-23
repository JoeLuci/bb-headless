'use strict';
// node --test test/bb-watchdog.test.js  (no dependencies). ps/lsof/sysctl/footprint fixtures are
// trimmed real output from a phone Mac (AZ-05, macOS 26.3, 10/23).
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const w = require('../bb-watchdog.js');

const fx = (name) => fs.readFileSync(path.join(__dirname, 'fixtures', name), 'utf8');

// Viato (viato-crm src/lib/phoneMachineHealth.test.ts) asserts the same two hashes.
const EXPECTED_REPORT_FIXTURE_SHA256 = '5ce7545e52c0b6b534b87a8b54a1369714c14a84644af5ceee43922c6341e0bf';
const EXPECTED_RESULTS_FIXTURE_SHA256 = '7dd32ad1f6c5b24d88748f90b6a2296ee3621ecf6a8a35626240ff8d1f42657b';

test('report fixtures match the copies Viato validates', () => {
  const sha = (n) => crypto.createHash('sha256').update(fx(n)).digest('hex');
  assert.equal(sha('report.full.json'), EXPECTED_REPORT_FIXTURE_SHA256);
  assert.equal(sha('report.results_only.json'), EXPECTED_RESULTS_FIXTURE_SHA256);
});

test('parses real ps, lsof, sysctl and footprint output', () => {
  const ps = w.parsePs(fx('ps.txt'));
  const ca = ps.find((p) => p.path === '/usr/sbin/coreaudiod');
  assert.ok(ca && ca.pid > 0 && ca.ageS > 0);
  assert.ok(ps.some((p) => p.path.endsWith('/WindowServer')));
  assert.ok(ps.filter((p) => p.path.endsWith('/loginwindow')).length >= 5);

  const ls = w.parseLsof(fx('lsof.txt'));
  const m01 = ls.filter((l) => l.uid === 501).map((l) => l.port);
  assert.ok(m01.includes(1254), 'socket port');
  assert.ok(m01.includes(45670), 'private API port is also listed; only socket_port counts');

  const [level, swap] = fx('sysctl.txt').trim().split('\n');
  assert.equal(Number(level), 75);
  assert.deepEqual(w.parseSwap(swap), { total: 0, used: 0 });
  assert.equal(w.parseFootprint(fx('footprint.txt')), 16);
});

test('parseEtime handles every ps format', () => {
  assert.equal(w.parseEtime('51:48'), 3108);
  assert.equal(w.parseEtime('06:42:16'), 24136);
  assert.equal(w.parseEtime('10-02:33:02'), 873182);
  assert.equal(w.parseEtime('bogus'), null);
});

test('FileVault: only the exact Off line counts as off', () => {
  assert.equal(w.parseFileVault('FileVault is Off.\n'), 'off');
  assert.equal(w.parseFileVault('FileVault is On.'), 'on');
  assert.equal(w.parseFileVault(''), 'unknown');
  assert.equal(w.parseFileVault('FileVault is Off, but will be enabled after the next restart.'), 'unknown');
});

test('NEVER list wins over everything, quit list is full paths only', () => {
  assert.equal(w.isQuitAllowed('/usr/sbin/universalaccessd'), true);
  assert.equal(w.isQuitAllowed('universalaccessd'), false);
  assert.equal(w.isQuitAllowed('/usr/sbin/coreaudiod'), false);
  assert.equal(w.isNever('/usr/sbin/coreaudiod'), true);
  assert.equal(w.isNever('/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer'), true);
  assert.equal(w.isNever('/Applications/RustDesk.app/Contents/MacOS/RustDesk'), true);
});

const NOW = 1_800_000_000_000;
const aged = { alive: true, guiSession: true, guiAgeS: 7200, serverAgeS: 7200, electron: false, disabled: false };
const ctx = (over = {}) => ({ now: NOW, autofix: true, managed: true, starved: false, restartedThisCycle: false, ...over });

function streaked(cycles, alive = true) {
  const u = { restarts: [] };
  for (let i = 0; i < cycles; i++) w.updateLineStreaks(u, alive ? 'not_answering' : 'unknown', alive, alive ? 700 : null, NOW - (cycles - i) * 60_000, 60);
  return u;
}

test('a line is restarted after 3 not-answering checks, not before', () => {
  assert.equal(w.decideLineFix(streaked(2), aged, ctx()).action, null);
  assert.equal(w.decideLineFix(streaked(3), aged, ctx()).action, 'kickstart_k');
});

test('a dead server is started after 2 checks; grace is on the GUI session only', () => {
  const u = streaked(2, false);
  const dead = { ...aged, alive: false, serverAgeS: null };
  assert.equal(w.decideLineFix(u, dead, ctx()).action, 'kickstart');
  assert.equal(w.decideLineFix(u, { ...dead, guiAgeS: 60 }, ctx()).action, null);
});

test('unknown probes never advance the streak (starved box)', () => {
  const u = { restarts: [] };
  for (let i = 0; i < 10; i++) w.updateLineStreaks(u, 'unknown', true, 700, NOW + i * 60_000, 60);
  assert.equal(u.notAnsweringCycles || 0, 0);
  assert.equal(u.notAnsweringS || 0, 0);
  w.updateLineStreaks(u, 'not_answering', true, 700, NOW, 60);
  w.updateLineStreaks(u, 'answering', true, 700, NOW, 60);
  assert.equal(u.notAnsweringS, 0);
});

test('guards: starved, Electron, signed out, disabled, watch only, unmanaged', () => {
  const u = streaked(3);
  assert.deepEqual(w.decideLineFix(u, aged, ctx({ starved: true })), { state: 'skipped', reason: 'starved', action: null });
  assert.equal(w.decideLineFix(u, { ...aged, electron: true }, ctx()).reason, 'electron');
  assert.equal(w.decideLineFix(u, { ...aged, guiSession: false }, ctx()).reason, 'no_session');
  assert.equal(w.decideLineFix(u, { ...aged, disabled: true }, ctx()).reason, 'disabled');
  assert.equal(w.decideLineFix(u, aged, ctx({ autofix: false })).state, 'would_fix');
  assert.equal(w.decideLineFix(u, aged, ctx({ managed: false })).state, 'ok');
});

test('one auto restart per Mac per cycle', () => {
  assert.equal(w.decideLineFix(streaked(3), aged, ctx({ restartedThisCycle: true })).action, null);
});

test('a young server is not restarted unless it is crash-looping', () => {
  const young = { ...aged, serverAgeS: 120 };
  assert.equal(w.decideLineFix(streaked(3), young, ctx()).action, null);
  const loop = streaked(3);
  loop.pidHistory = [{ pid: 1, at: NOW - 500_000 }, { pid: 2, at: NOW - 300_000 }, { pid: 3, at: NOW - 200_000 }, { pid: 4, at: NOW - 100_000 }];
  assert.equal(w.decideLineFix(loop, young, ctx()).action, 'kickstart_k');
});

test('restart caps: 15 min spacing, 3 per 6 h then needs a person', () => {
  const u = streaked(3);
  u.restarts = [NOW - 5 * 60_000];
  assert.equal(w.decideLineFix(u, aged, ctx()).action, null);
  u.restarts = [NOW - 3 * 3600_000, NOW - 2 * 3600_000, NOW - 3600_000];
  const d = w.decideLineFix(u, aged, ctx());
  assert.equal(d.state, 'capped');
  assert.equal(d.capHit, 'limit');
});

test('stuck process: 3 hot checks, never while audio is stuck, capped then 6 h back-off', () => {
  assert.deepEqual(w.decideProcessFix({ hotCycles: 2, kills: [] }, { now: NOW, audioHot: false, autofix: true }), { state: null, kill: false });
  assert.deepEqual(w.decideProcessFix({ hotCycles: 3, kills: [] }, { now: NOW, audioHot: false, autofix: true }), { state: 'fixed', kill: true });
  assert.equal(w.decideProcessFix({ hotCycles: 3, kills: [] }, { now: NOW, audioHot: true, autofix: true }).state, 'skipped_audio');
  const p = { hotCycles: 3, kills: [NOW - 50 * 60_000, NOW - 30 * 60_000, NOW - 10 * 60_000] };
  assert.equal(w.decideProcessFix(p, { now: NOW, audioHot: false, autofix: true }).state, 'capped');
  assert.ok(p.backoffUntil > NOW);
  assert.equal(w.decideProcessFix({ ...p, kills: [] }, { now: NOW + 3600_000, audioHot: false, autofix: true }).state, 'capped');
});

test('commands are checked on the Mac whatever Viato sends', () => {
  const c = { now: NOW, users: { 503: { electron: false } }, procs: [{ pid: 2124, uid: 504, path: '/usr/sbin/universalaccessd' }], commandUids: [503], remoteRestarts: {}, remoteQuits: {} };
  assert.equal(w.validateCommand({ action: 'restart_line_server', target: { uid: 503 } }, c), null);
  assert.match(w.validateCommand({ action: 'restart_line_server', target: { uid: 501 } }, c), /not a line/);
  assert.match(w.validateCommand({ action: 'restart_line_server', target: { uid: '503' } }, c), /valid/);
  assert.equal(w.validateCommand({ action: 'quit_process', target: { pid: 2124, path: '/usr/sbin/universalaccessd' } }, c), null);
  assert.match(w.validateCommand({ action: 'quit_process', target: { pid: 203, path: '/usr/sbin/coreaudiod' } }, c), /not on the list/);
  assert.match(w.validateCommand({ action: 'quit_process', target: { pid: 9999, path: '/usr/sbin/universalaccessd' } }, c), /no longer/);
  assert.match(w.validateCommand({ action: 'rm -rf /', target: {} }, c), /Unknown/);
  const busy = { ...c, remoteRestarts: { 503: Array.from({ length: 6 }, (_, i) => NOW - i * 60_000) } };
  assert.match(w.validateCommand({ action: 'restart_line_server', target: { uid: 503 } }, busy), /too many/);
});

test('analyze + buildFullReport from real output produce the Part I shape', () => {
  const state = w.emptyState();
  state.cores = 10;
  state.accounts = {
    501: { name: 'm01', uid: 501, socket_port: 1254, server_address: 'https://user-test-line-one.example.com', disabled: false },
    502: { name: 'm02', uid: 502, socket_port: 1284, server_address: 'https://user-test-line-two.example.com', disabled: false },
  };
  const procs = w.parsePs(fx('ps.txt'));
  const snap = {
    at: NOW, procs, psOk: true, headless: procs.filter((p) => p.path.endsWith('/node')).map((p) => p.pid), pgOk: true,
    listen: w.parseLsof(fx('lsof.txt')), lsOk: true, memlevel: 75, swap: { total: 0, used: 0 },
    probes: { 1254: 'answering', 1284: 'refused' }, load: { load1: 1.5, load5: 2, load15: 3, cores: 10, starved: false },
  };
  const analysis = w.analyze(state, snap);
  const report = w.buildFullReport(state, snap, analysis, 'TEST-UUID', []);
  assert.equal(report.schema_version, 1);
  assert.equal(report.type, 'full');
  const [m01, m02] = report.users;
  assert.equal(m01.probe, 'answering');
  assert.equal(m01.gui_session, true);
  assert.equal(m01.server_listening, true);
  assert.equal(m02.probe, 'not_answering');
  assert.equal(m02.not_answering_s, 60);
  assert.ok(report.top.length <= 10);
  assert.equal(report.coreaudiod.pid, procs.find((p) => p.path === '/usr/sbin/coreaudiod').pid);
  for (const k of ['host', 'coreaudiod', 'windowserver', 'top', 'users', 'process_fixes', 'fixes', 'command_results']) assert.ok(k in report, k);
});

test('only accepted fixes and results are dropped', () => {
  const state = w.emptyState();
  state.pendingFixes = [{ mac_event_id: 'a' }, { mac_event_id: 'b' }];
  state.commands = { x: { state: 'done', result: 'ok' }, y: { state: 'done', result: 'ok' } };
  w.applyAccepted(state, { accepted_fix_ids: ['a'], accepted_result_ids: ['x'] });
  assert.deepEqual(state.pendingFixes.map((f) => f.mac_event_id), ['b']);
  assert.deepEqual(Object.keys(state.commands), ['y']);
  assert.ok(state.doneCommandIds.includes('x'));
});

test('hostKey matches Viato: no scheme, port, path, case, and _ equals -', () => {
  assert.equal(w.hostKey('HTTPS://User_X.example.com:443/api/'), 'user-x.example.com');
});

// ── a failed or killed probe is unknown, never "nothing there" (build review blocker) ──
function snapFrom(over = {}) {
  const procs = w.parsePs(fx('ps.txt'));
  return {
    at: NOW, procs, psOk: true, headless: procs.filter((p) => p.path.endsWith('/node')).map((p) => p.pid), pgOk: true,
    listen: w.parseLsof(fx('lsof.txt')), lsOk: true, memlevel: 75, swap: { total: 0, used: 0 },
    probes: { 1254: 'answering' }, load: { load1: 1.5, load5: 2, load15: 3, cores: 10, starved: false }, ...over,
  };
}
function stateWithM01() {
  const state = w.emptyState();
  state.cores = 10;
  state.accounts = { 501: { name: 'm01', uid: 501, socket_port: 1254, server_address: null, disabled: false } };
  return state;
}

test('lsof failing never turns an answering line into not answering', () => {
  const state = stateWithM01();
  for (let i = 0; i < 12; i++) {
    const a = w.analyze(state, snapFrom({ at: NOW + i * 60_000, lsOk: false, listen: [] }));
    assert.equal(a.users[0].probe, 'answering');
    assert.equal(a.users[0].server_listening, null);
  }
  assert.equal(state.users[501].notAnsweringCycles || 0, 0);
});

test('pgrep failing leaves the not-running streak alone', () => {
  const state = stateWithM01();
  for (let i = 0; i < 5; i++) w.analyze(state, snapFrom({ at: NOW + i * 60_000, pgOk: false, headless: [] }));
  assert.equal(state.users[501].notRunningCycles || 0, 0);
});

test('ps failing: session unknown (no false "not signed in"), audio streak kept', () => {
  const state = stateWithM01();
  state.coreaudiodHotSince = NOW - 400_000;
  const a = w.analyze(state, snapFrom({ psOk: false, procs: [] }));
  assert.equal(a.users[0].gui_session, null);
  assert.equal(state.coreaudiodHotSince, NOW - 400_000);
  assert.equal(a.audioHotLocal, true);
  const u = streaked(3);
  assert.deepEqual(w.decideLineFix(u, { ...aged, guiSession: null }, ctx()), { state: 'ok', reason: null, action: null });
});

test('a server the scan misses is not "dead" while its line still answers', () => {
  const u = streaked(5, false);
  assert.equal(w.decideLineFix(u, { ...aged, alive: false, probe: 'answering', serverAgeS: null }, ctx()).action, null);
  assert.equal(w.decideLineFix(u, { ...aged, alive: false, probe: 'not_answering', serverAgeS: null }, ctx()).action, 'kickstart');
});

test('a crash-looping server gets one restart, then needs a person', () => {
  const loop = streaked(3);
  loop.pidHistory = [{ pid: 1, at: NOW - 500_000 }, { pid: 2, at: NOW - 300_000 }, { pid: 3, at: NOW - 200_000 }, { pid: 4, at: NOW - 100_000 }];
  loop.restarts = [NOW - 120_000];
  const d = w.decideLineFix(loop, { ...aged, serverAgeS: 60 }, ctx());
  assert.equal(d.state, 'capped');
  assert.equal(d.capHit, 'crash');
});

test('stuck processes are not quit while the audio service is hot on this Mac, even before Viato says so', () => {
  const state = stateWithM01();
  state.server = { autofix: true, managedUids: [501], commandUids: [501], audioHot: false };
  const procs = w.parsePs(fx('ps.txt')).map((p) =>
    p.path === '/usr/sbin/universalaccessd' ? { ...p, cpu: 99 } : p.path === '/usr/sbin/coreaudiod' ? { ...p, cpu: 140 } : p);
  let plan = [];
  for (let i = 0; i < 4; i++) {
    const snap = snapFrom({ at: NOW + i * 60_000, procs });
    plan = w.planFixes(state, snap, w.analyze(state, snap));
  }
  assert.equal(plan.filter((s) => s.kind === 'proc').length, 0);
  assert.ok(Object.values(state.procs).some((e) => e.lastState === 'skipped_audio'));
});

test('with a calm audio service a stuck universalaccessd is planned for a quit after 3 hot checks', () => {
  const state = stateWithM01();
  state.server = { autofix: true, managedUids: [501], commandUids: [501], audioHot: false };
  const procs = w.parsePs(fx('ps.txt')).map((p) => (p.path === '/usr/sbin/universalaccessd' && p.uid === 501 ? { ...p, cpu: 99 } : p));
  let plan = [];
  for (let i = 0; i < 3; i++) {
    const snap = snapFrom({ at: NOW + i * 60_000, procs });
    plan = w.planFixes(state, snap, w.analyze(state, snap));
  }
  assert.equal(plan.filter((s) => s.kind === 'proc').length, 1);
});

// ── round 2 regressions ──
test('a line whose server is not loaded is skipped, and never blocks the next line', () => {
  const state = w.emptyState();
  state.cores = 10;
  state.server = { autofix: true, managedUids: [501, 502], commandUids: [501, 502], audioHot: false };
  state.accounts = {
    501: { name: 'm01', uid: 501, socket_port: 1254, server_address: null, disabled: false },
    502: { name: 'm02', uid: 502, socket_port: 1284, server_address: null, disabled: false },
  };
  let plan = [];
  for (let i = 0; i < 3; i++) {
    const snap = snapFrom({ at: NOW + i * 60_000, probes: { 1254: 'refused', 1284: 'refused' } });
    plan = w.planFixes(state, snap, w.analyze(state, snap));
  }
  assert.deepEqual(plan.filter((s) => s.kind === 'line').map((s) => s.uid), [501]);
  // executeFixes found 501 not loaded:
  state.users[501].notLoadedAt = NOW + 3 * 60_000;
  const snap = snapFrom({ at: NOW + 4 * 60_000, probes: { 1254: 'refused', 1284: 'refused' } });
  const analysis = w.analyze(state, snap);
  plan = w.planFixes(state, snap, analysis);
  assert.equal(analysis.users.find((u) => u.uid === 501).fix_skip_reason, 'not_loaded');
  assert.deepEqual(plan.filter((s) => s.kind === 'line').map((s) => s.uid), [502]);
});

test('a crash-loop cap holds until a person acts, it does not reopen after 10 minutes', () => {
  const state = w.emptyState();
  state.cores = 10;
  state.server = { autofix: true, managedUids: [501], commandUids: [501], audioHot: false };
  state.accounts = { 501: { name: 'm01', uid: 501, socket_port: 1254, server_address: null, disabled: false } };
  state.users[501] = { restarts: [NOW - 120_000], needsPerson: false };
  for (let i = 0; i < 20; i++) {
    const snap = snapFrom({ at: NOW + i * 60_000, probes: { 1254: 'refused' }, headless: [700 + i] , procs: w.parsePs(fx('ps.txt')).map((p) => (p.uid === 501 && p.path.endsWith('/node') ? { ...p, pid: 700 + i, ageS: 30 } : p)) });
    const plan = w.planFixes(state, snap, w.analyze(state, snap));
    assert.equal(plan.filter((s) => s.kind === 'line').length, 0, `cycle ${i}`);
  }
  assert.equal(state.users[501].needsPerson, true);
});
