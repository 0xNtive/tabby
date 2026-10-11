// Awake, against stand-ins for pmset, sudo and authopen (nothing here touches the real Mac's sleep).
import { test, before } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const ROOT = fileURLToPath(new URL('..', import.meta.url));
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'tabby-awake-'));
process.env.HOME = tmp;
process.env.TABBY_HOME = path.join(tmp, 'tabby');
process.env.CLAUDE_CONFIG_DIR = path.join(tmp, 'claude');
process.env.TABBY_NO_ISLAND = '1';
process.env.TABBY_AWAKE_TICK_MS = '60';
process.env.TABBY_AWAKE_GRACE_MS = '150';
fs.mkdirSync(process.env.TABBY_HOME, { recursive: true });
fs.mkdirSync(path.join(tmp, 'claude', 'sessions'), { recursive: true });

// pmset: "SleepDisabled" lives in a file; `pmset -g batt` prints whatever batt.txt says.
const bin = path.join(tmp, 'bin');
fs.mkdirSync(bin);
const sleepFile = path.join(tmp, 'sleep-disabled');
const battFile = path.join(tmp, 'batt.txt');
fs.writeFileSync(sleepFile, '0');
fs.writeFileSync(battFile, "Now drawing from 'AC Power'\n -InternalBattery-0 (id=1)\t100%; charged; 0:00 remaining present: true\n");
const pmset = path.join(bin, 'pmset');
fs.writeFileSync(pmset, `#!/bin/sh
if [ "$1" = "-g" ] && [ "$2" = "batt" ]; then cat "${battFile}"; exit 0; fi
if [ "$1" = "-g" ]; then echo "System-wide power settings:"; [ "$(cat "${sleepFile}")" = 1 ] && printf ' SleepDisabled\\t\\t1\\n'; echo "Currently in use:"; exit 0; fi
if [ "$1" = "-a" ] && [ "$2" = "disablesleep" ]; then printf '%s' "$3" > "${sleepFile}"; exit 0; fi
exit 1
`, { mode: 0o755 });
// sudo: allows exactly what a rule file with NOPASSWD in it allows; -l only checks.
const rule = path.join(tmp, 'sudoers.d', 'tabby-awake');
fs.mkdirSync(path.dirname(rule));
const sudo = path.join(bin, 'sudo');
fs.writeFileSync(sudo, `#!/bin/sh
[ "$1" = "-n" ] && shift
grep -q NOPASSWD "${rule}" 2>/dev/null || exit 1
if [ "$1" = "-l" ]; then exit 0; fi
exec "$@"
`, { mode: 0o755 });
// authopen: writes stdin to the file (the real one asks for an admin password first).
const authopen = path.join(bin, 'authopen');
const authLog = path.join(tmp, 'authopen.log');
fs.writeFileSync(authopen, `#!/bin/sh
for last; do :; done
echo "$@" >> "${authLog}"
[ -f "${tmp}/deny" ] && { echo "canceled" >&2; exit 1; }
cat > "$last"
`, { mode: 0o755 });
process.env.TABBY_PMSET = pmset;
process.env.TABBY_SUDO = sudo;
process.env.TABBY_AUTHOPEN = authopen;
process.env.TABBY_AWAKE_RULE = rule;

let A;
before(async () => {
  A = await import('../lib/awake.js');
});

const sleepOff = () => fs.readFileSync(sleepFile, 'utf8') === '1';
const waitFor = async (fn, ms = 4000) => {
  const end = Date.now() + ms;
  while (Date.now() < end) {
    if (fn()) return true;
    await new Promise((r) => setTimeout(r, 40));
  }
  return false;
};

test('durations read the way people type them', () => {
  const H = 3600e3;
  assert.equal(A.parseDuration('4h'), 4 * H);
  assert.equal(A.parseDuration('4'), 4 * H);
  assert.equal(A.parseDuration('90m'), 1.5 * H);
  assert.equal(A.parseDuration('1.5h'), 1.5 * H);
  assert.equal(A.parseDuration('4h30m'), 4.5 * H);
  assert.equal(A.parseDuration('2 hours'), 2 * H);
  assert.equal(A.parseDuration('45 min'), 0.75 * H);
  assert.equal(A.parseDuration('done'), null);
  assert.equal(A.parseDuration(''), null);
  assert.equal(A.humanize(3 * H + 12 * 60e3), '3h 12m');
  assert.equal(A.humanize(40 * 60e3), '40m');
});

test('battery text from pmset', () => {
  assert.deepEqual(A.parseBattery("Now drawing from 'Battery Power'\n -InternalBattery-0 (id=1)\t8%; discharging; 0:31 remaining present: true"), { present: true, ac: false, pct: 8 });
  assert.deepEqual(A.parseBattery("Now drawing from 'AC Power'"), { present: false, ac: true, pct: null });
});

test('the rule allows exactly two pmset commands and passes visudo', () => {
  const text = A.ruleText('someone');
  assert.match(text, /^someone ALL=\(root\) NOPASSWD: \/usr\/bin\/pmset -a disablesleep 1, \/usr\/bin\/pmset -a disablesleep 0$/m);
  assert.equal(text.split('\n').filter((l) => l && !l.startsWith('#')).length, 1);
  if (process.platform === 'darwin' && fs.existsSync('/usr/sbin/visudo')) {
    const f = path.join(tmp, 'rule-check');
    fs.writeFileSync(f, text);
    assert.equal(spawnSync('/usr/sbin/visudo', ['-cqf', f]).status, 0);
  }
});

test('a canceled password prompt changes nothing', () => {
  fs.writeFileSync(path.join(tmp, 'deny'), '');
  const r = A.command(['4h']);
  fs.rmSync(path.join(tmp, 'deny'));
  assert.equal(r.ok, false);
  assert.match(r.message, /Nothing changed/);
  assert.equal(sleepOff(), false);
  assert.equal(A.readState(), null);
});

test('the first start asks once, turns sleep off, and a watcher keeps time', async () => {
  const r = A.command(['4h']);
  assert.equal(r.ok, true, r.message);
  assert.match(r.message, /Close the lid any time/);
  assert.equal(sleepOff(), true);
  assert.equal(fs.readFileSync(authLog, 'utf8').trim().split('\n').length, 2, 'one prompt for the cancel, one for the grant');
  const s = A.readState();
  assert.equal(s.on, true);
  assert.equal(s.prior, 0);
  assert.ok(Math.abs(s.until - Date.now() - 4 * 3600e3) < 5000);
  assert.ok(s.watcherPid > 0);
  // Asked again: no second prompt.
  const again = A.command(['2h']);
  assert.equal(again.ok, true);
  assert.equal(fs.readFileSync(authLog, 'utf8').trim().split('\n').length, 2);
  const ext = A.command(['+1h']);
  assert.ok(ext.state.until - Date.now() > 2.9 * 3600e3);
  // The old watcher steps aside for the new one.
  assert.ok(await waitFor(() => { try { process.kill(s.watcherPid, 0); return false; } catch { return true; } }), 'superseded watcher exits');
});

test('off turns sleep back on and says so', () => {
  const r = A.command(['off']);
  assert.equal(r.ok, true);
  assert.match(r.message, /sleeps as usual/);
  assert.equal(sleepOff(), false);
  assert.equal(A.readState().on, false);
  assert.equal(A.readState().reason, 'off');
});

test('until done: the watcher ends it once nothing has worked for a while', async () => {
  const r = A.command(['done']);
  assert.equal(r.ok, true, r.message);
  assert.equal(A.readState().untilDone, true);
  assert.ok(A.readState().until - Date.now() > 7.9 * 3600e3, 'eight hours at most');
  assert.ok(await waitFor(() => A.readState()?.on === false), 'watcher stopped it');
  assert.equal(A.readState().reason, 'done');
  assert.equal(sleepOff(), false);
});

test('a session at work keeps it awake', async () => {
  const reg = path.join(tmp, 'claude', 'sessions', `${process.pid}.json`);
  fs.writeFileSync(reg, JSON.stringify({ pid: process.pid, sessionId: 'S-busy', status: 'busy', kind: 'interactive' }));
  A.command(['done', '2h']);
  await new Promise((r) => setTimeout(r, 500));
  assert.equal(A.readState().on, true, 'still awake while a session works');
  fs.writeFileSync(reg, JSON.stringify({ pid: process.pid, sessionId: 'S-busy', status: 'idle', kind: 'interactive' }));
  assert.ok(await waitFor(() => A.readState()?.on === false));
  assert.equal(A.readState().reason, 'done');
  assert.equal(A.readState().worked, 1);
  fs.rmSync(reg);
});

test('low battery on battery power ends it', async () => {
  A.command(['4h']);
  fs.writeFileSync(battFile, "Now drawing from 'Battery Power'\n -InternalBattery-0 (id=1)\t9%; discharging; 0:20 remaining present: true\n");
  assert.ok(await waitFor(() => A.readState()?.on === false));
  assert.equal(A.readState().reason, 'battery');
  assert.equal(sleepOff(), false);
  fs.writeFileSync(battFile, "Now drawing from 'AC Power'\n");
});

test('a missed end is caught by the next check, and a dead watcher is replaced', () => {
  A.command(['4h']);
  const s = A.readState();
  process.kill(s.watcherPid, 'SIGKILL');
  spawnSync('sleep', ['0.2']);
  const checked = A.check();
  assert.equal(checked.on, true);
  assert.notEqual(checked.watcherPid, s.watcherPid);
  // The time ran out while nobody was watching (a restart, say).
  fs.writeFileSync(A.FILE, JSON.stringify({ ...A.readState(), until: Date.now() - 1000 }));
  assert.equal(A.check().on, false);
  assert.equal(A.readState().reason, 'time');
  assert.equal(sleepOff(), false);
});

test('sleep that was already off before tabby stays off', () => {
  fs.writeFileSync(sleepFile, '1');
  const r = A.command(['1h']);
  assert.equal(r.ok, true);
  assert.equal(A.readState().prior, 1);
  const off = A.command(['off']);
  assert.match(off.message, /already off before tabby/);
  assert.equal(sleepOff(), true);
  fs.writeFileSync(sleepFile, '0');
});

test('forget leaves a rule file that grants nothing', () => {
  const r = A.command(['forget']);
  assert.equal(r.ok, true, r.message);
  assert.doesNotMatch(fs.readFileSync(rule, 'utf8'), /NOPASSWD/);
  assert.equal(A.allowed(), false);
});

test('the CLI speaks it too', () => {
  const cli = path.join(ROOT, 'bin', 'tabby.js');
  fs.writeFileSync(path.join(process.env.TABBY_HOME, 'config.json'), JSON.stringify({ termsAccepted: { version: '2026-09-25', at: new Date().toISOString(), by: 'test' } }));
  const r = spawnSync(process.execPath, [cli, 'awake', 'help'], { encoding: 'utf8', env: process.env });
  assert.match(r.stdout, /tabby awake 4h/);
  const j = spawnSync(process.execPath, [cli, 'awake', '--json'], { encoding: 'utf8', env: process.env });
  assert.equal(JSON.parse(j.stdout).on, false);
});

test.after?.(() => {
  try {
    A?.stop('off');
  } catch {}
});
