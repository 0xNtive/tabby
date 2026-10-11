// Awake: keep this Mac running with the lid closed for a while, so Claude keeps working.
//
// macOS sleeps when the lid closes whatever caffeinate asks; only `pmset disablesleep` stops it,
// and that needs root. Once, through the macOS admin prompt, tabby adds a sudoers rule that
// allows exactly `/usr/bin/pmset -a disablesleep 1` and `… 0` without a password, nothing else.
// A detached watcher turns sleep back on when the time is up, when every session is done (if
// asked), or when the battery runs low. The island, the SessionStart hook and `tabby awake` check
// on it too, so a crash or a restart never leaves sleep off for good.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import { spawn, spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { paths, readJson, writeJson, readRegistry, listSessions, isAlive, log } from './state.js';

const CLI = fileURLToPath(new URL('../bin/tabby.js', import.meta.url));
export const FILE = path.join(paths.root, 'awake.json');
// Tests point these at stand-ins; the sudoers rule itself only ever names /usr/bin/pmset.
const PMSET = process.env.TABBY_PMSET || '/usr/bin/pmset';
const SUDO = process.env.TABBY_SUDO || '/usr/bin/sudo';
export const RULE = process.env.TABBY_AWAKE_RULE || '/etc/sudoers.d/tabby-awake';

const MIN = 60e3;
const HOUR = 60 * MIN;
export const LIMITS = {
  min: 10 * MIN,
  max: 24 * HOUR,
  // "Until every session is done" still ends by then.
  doneCap: 8 * HOUR,
  // Nothing working for this long counts as done (a turn's tools can pause between steps).
  grace: Number(process.env.TABBY_AWAKE_GRACE_MS) || 5 * MIN,
  // On battery power, sleep comes back at this charge.
  battery: 10,
  tick: Number(process.env.TABBY_AWAKE_TICK_MS) || 20e3,
};

const run = (cmd, args, opts = {}) =>
  spawnSync(cmd, args, { encoding: 'utf8', timeout: 15_000, env: { ...process.env, LC_ALL: 'C', LANG: 'C' }, ...opts });

export function unsupported() {
  if (process.platform !== 'darwin' && !process.env.TABBY_PMSET) return 'Awake is for macOS: it keeps a Mac running with the lid closed.';
  return null;
}

// ---------- reading the Mac ----------

// 1 when sleep is off system-wide (`pmset -a disablesleep 1`), 0 when it isn't, null if unknown.
export function sleepDisabled() {
  const r = run(PMSET, ['-g']);
  if (r.status !== 0) return null;
  const m = /SleepDisabled\s+(\d)/.exec(r.stdout || '');
  return m ? Number(m[1]) : 0;
}

// `pmset -g batt`: on AC power or not, and the charge. A desktop Mac has no battery.
export function parseBattery(text) {
  const s = String(text || '');
  const pct = /(\d+)%/.exec(s);
  return {
    present: /InternalBattery/.test(s),
    ac: /'AC Power'/.test(s),
    pct: pct ? Number(pct[1]) : null,
  };
}

export function battery() {
  const r = run(PMSET, ['-g', 'batt']);
  return parseBattery(r.status === 0 ? r.stdout : '');
}

// The rule is in place and sudo lets this user run both commands without a password.
export function allowed() {
  if (!fs.existsSync(RULE)) return false;
  return run(SUDO, ['-n', '-l', PMSET, '-a', 'disablesleep', '1']).status === 0;
}

function setSleep(off) {
  const r = run(SUDO, ['-n', PMSET, '-a', 'disablesleep', off ? '1' : '0']);
  if (r.status !== 0) {
    log('awake: pmset failed', (r.stderr || r.stdout || '').trim().slice(0, 200));
    return false;
  }
  return sleepDisabled() === (off ? 1 : 0);
}

// ---------- the one-time permission ----------

export function ruleText(user) {
  return [
    `# tabby awake: lets ${user} turn sleep off and back on with the lid closed (tabby awake).`,
    '# Only these two commands, nothing else. Remove it with: tabby awake forget',
    `${user} ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0`,
    '',
  ].join('\n');
}

// What `tabby awake forget` leaves: a rule file with no rules in it (authopen can't delete).
const EMPTY_RULE = '# tabby awake: permission removed (tabby awake forget). This file grants nothing.\n';

// Writes the rule through macOS's own admin prompt (authopen: setuid root, asks for an
// administrator's password or Touch ID, then writes stdin to the file as root). The text is
// checked with visudo first: a broken file in sudoers.d would stop sudo from working at all.
function writeRule(text) {
  const tmp = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'tabby-awake-')), 'rule');
  try {
    fs.writeFileSync(tmp, text, { mode: 0o600 });
    const check = run('/usr/sbin/visudo', ['-cqf', tmp]);
    if (check.status !== 0) return { ok: false, error: `the rule did not pass visudo (${(check.stderr || check.stdout || '').trim().slice(0, 120)})` };
  } finally {
    fs.rmSync(path.dirname(tmp), { recursive: true, force: true });
  }
  const r = run(AUTHOPEN, ['-c', '-m', '0440', '-w', RULE], { input: text, timeout: 10 * MIN });
  if (r.status !== 0) {
    const err = (r.stderr || r.stdout || '').trim();
    return { ok: false, canceled: /cancel|denied|-60006|-128/i.test(err) || !err, error: err.slice(0, 200) || 'the admin prompt was closed' };
  }
  try {
    const st = fs.statSync(RULE);
    if (!process.env.TABBY_AUTHOPEN && (st.uid !== 0 || st.mode & 0o022)) return { ok: false, error: `${RULE} came out with the wrong owner or mode` };
  } catch (e) {
    return { ok: false, error: e.message };
  }
  return { ok: true };
}
const AUTHOPEN = process.env.TABBY_AUTHOPEN || '/usr/libexec/authopen';

// The admin prompt, once. Returns { ok, canceled, error }.
export function grant() {
  const user = os.userInfo().username;
  if (!/^[A-Za-z0-9_][A-Za-z0-9_.-]*$/.test(user)) return { ok: false, error: `unusual user name "${user}"` };
  const w = writeRule(ruleText(user));
  if (!w.ok) return w;
  if (!allowed()) return { ok: false, error: 'sudo still asks for a password (is /etc/sudoers.d read by your sudoers?)' };
  log('awake: permission granted');
  return { ok: true };
}

// Takes the permission away again (the admin prompt once more).
export function revoke() {
  if (!fs.existsSync(RULE) || !allowed()) return { ok: true, message: 'Nothing to remove: tabby has no permission to turn sleep off.' };
  const off = readState()?.on ? stop('off') : null;
  const w = writeRule(EMPTY_RULE);
  if (!w.ok) return { ok: false, message: w.canceled ? 'Nothing changed: the admin prompt was canceled.' : `Could not remove it: ${w.error}` };
  log('awake: permission removed');
  return { ok: true, message: `${off ? off.message + '\n' : ''}Removed: tabby can no longer turn sleep off.` };
}

// ---------- state ----------

export function readState() {
  const s = readJson(FILE);
  return s && typeof s === 'object' ? s : null;
}

const clock = (ms) => new Date(ms).toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' });

export function humanize(ms) {
  const m = Math.max(0, Math.round(ms / MIN));
  if (m < 60) return `${m}m`;
  const h = Math.floor(m / 60);
  const r = m % 60;
  return r ? `${h}h ${r}m` : `${h}h`;
}

// "4h", "90m", "1.5h", "4h30m", "2 hours", "45 min", "3" (hours). Null when it isn't one.
export function parseDuration(text) {
  const s = String(text ?? '').trim().toLowerCase().replace(/\s+/g, '');
  if (!s) return null;
  if (/^\d+(\.\d+)?$/.test(s)) return Number(s) * HOUR;
  const m = /^(?:(\d+(?:\.\d+)?)(?:h|hr|hrs|hour|hours))?(?:(\d+)(?:m|min|mins|minute|minutes))?$/.exec(s);
  if (!m || (!m[1] && !m[2])) return null;
  return (Number(m[1] || 0) * HOUR) + (Number(m[2] || 0) * MIN);
}

const clamp = (ms) => Math.min(LIMITS.max, Math.max(LIMITS.min, Math.round(ms)));

// Sessions in the middle of a turn: Claude's own registry, and tabby's records.
export function busySessions() {
  const busy = new Set();
  for (const r of readRegistry().values()) if (r.status === 'busy') busy.add(r.sessionId || String(r.pid));
  for (const s of listSessions()) {
    if (s.status === 'busy' && s.pid && isAlive(s.pid)) busy.add(s.sessionId);
  }
  return busy;
}

// ---------- on and off ----------

// Keeps the Mac awake for `ms` (or until every session is done, `ms` at most). `prompt: false`
// never shows the admin prompt (the hook, the island's background checks).
export function start({ ms, untilDone = false, by = process.env.TABBY_SOURCE || 'cli', prompt = true } = {}) {
  const why = unsupported();
  if (why) return { ok: false, message: why };
  const span = clamp(ms || (untilDone ? LIMITS.doneCap : 4 * HOUR));
  const cur = readState();
  const now = Date.now();
  const was = sleepDisabled();
  // Restarting keeps what sleep was like before tabby first turned it off.
  const prior = cur?.on ? cur.prior : was;
  if (!allowed()) {
    if (!prompt) return { ok: false, needsGrant: true, message: 'Awake needs your OK once. Run: tabby awake 4h' };
    const g = grant();
    if (!g.ok) {
      return { ok: false, canceled: !!g.canceled, message: g.canceled ? 'Nothing changed: the macOS password prompt was canceled.' : `Could not keep the Mac awake: ${g.error}` };
    }
  }
  if (was !== 1 && !setSleep(true)) {
    return { ok: false, message: 'Could not keep the Mac awake: pmset refused. Run `tabby awake` for the details.' };
  }
  if (sleepDisabled() !== 1) return { ok: false, message: 'Could not keep the Mac awake: sleep is still on.' };
  const state = {
    v: 1,
    on: true,
    token: crypto.randomBytes(8).toString('hex'),
    startedAt: cur?.on ? cur.startedAt : now,
    until: now + span,
    untilDone: !!untilDone,
    minBattery: LIMITS.battery,
    prior: prior === 1 ? 1 : 0,
    by: String(by).slice(0, 16),
  };
  writeJson(FILE, state);
  const watcher = spawnWatcher(state.token);
  if (watcher) writeJson(FILE, { ...state, watcherPid: watcher });
  log('awake: on', { until: state.until, untilDone: state.untilDone, by: state.by });
  return { ok: true, state: readState(), message: describe(readState()) };
}

// More time on the clock (from now when it has already run out).
export function extend(ms) {
  const cur = readState();
  if (!cur?.on) return start({ ms });
  const until = Math.min(Date.now() + LIMITS.max, Math.max(cur.until, Date.now()) + clamp(ms));
  writeJson(FILE, { ...cur, until });
  check();
  return { ok: true, state: readState(), message: describe(readState()) };
}

// Sleep back on. `reason`: off (asked), time, done, battery, external (someone else turned it on).
export function stop(reason = 'off', extra = {}) {
  const cur = readState();
  if (!cur?.on) return { ok: true, state: cur, message: 'Awake is already off: the Mac sleeps as usual.' };
  let restored = true;
  if (cur.prior !== 1 && reason !== 'external') {
    restored = sleepDisabled() === 0 || setSleep(false);
  }
  const next = { ...cur, ...extra, on: false, endedAt: Date.now(), reason, restored };
  delete next.watcherPid;
  writeJson(FILE, next);
  log('awake: off', { reason, restored });
  if (!restored) return { ok: false, state: next, message: 'Sleep is still off: tabby could not turn it back on. Run: sudo pmset -a disablesleep 0' };
  const why = { off: '', time: " (time's up)", done: ' (every session is done)', battery: ' (battery low)', external: ' (turned on elsewhere)' }[reason] ?? '';
  return { ok: true, state: next, message: cur.prior === 1 ? `Awake is off${why}. Sleep was already off before tabby, so it stays that way.` : `Awake is off${why}: the Mac sleeps as usual again.` };
}

// After a crash, a restart or a missed end: puts things right without asking anything.
export function check() {
  const cur = readState();
  if (!cur) return null;
  if (!cur.on) {
    // A restore that failed earlier: try again now (the rule may be back).
    if (cur.restored === false && cur.prior !== 1 && sleepDisabled() === 1 && allowed()) {
      if (setSleep(false)) writeJson(FILE, { ...cur, restored: true });
    }
    return readState();
  }
  if (Date.now() >= cur.until) return stop('time').state;
  if (!cur.watcherPid || !isAlive(cur.watcherPid) || !isWatcher(cur.watcherPid)) {
    const pid = spawnWatcher(cur.token);
    if (pid) writeJson(FILE, { ...readState(), watcherPid: pid });
  }
  return readState();
}

function isWatcher(pid) {
  const r = run('/bin/ps', ['-o', 'command=', '-p', String(pid)]);
  return /tabby\.(?:js|mjs)\b.*\bawake\b.*_watch/.test(r.stdout || '');
}

function spawnWatcher(token) {
  try {
    const child = spawn(process.execPath, [CLI, 'awake', '_watch', token], {
      detached: true,
      stdio: 'ignore',
      env: { ...process.env, TABBY_INTERNAL: '1' },
    });
    child.unref();
    return child.pid || null;
  } catch (e) {
    log('awake: watcher failed to start', e.message);
    return null;
  }
}

// The detached watcher: one look every tick until it's time to sleep again, or someone else ends it.
export async function watch(token) {
  let lastBusy = Date.now();
  const worked = new Set();
  for (;;) {
    const cur = readState();
    if (!cur?.on || cur.token !== token) return;
    const now = Date.now();
    const extra = () => ({ worked: worked.size });
    if (now >= cur.until) return void stop('time', extra());
    const busy = busySessions();
    for (const id of busy) worked.add(id);
    if (busy.size) lastBusy = now;
    else if (cur.untilDone && now - lastBusy >= LIMITS.grace) return void stop('done', extra());
    const b = battery();
    if (b.present && !b.ac && b.pct != null && b.pct <= (cur.minBattery ?? LIMITS.battery)) return void stop('battery', extra());
    if (sleepDisabled() === 0 && cur.prior !== 1) return void stop('external', extra());
    await new Promise((r) => setTimeout(r, LIMITS.tick));
  }
}

// ---------- words ----------

export function describe(s = readState()) {
  if (!s?.on) {
    if (s?.endedAt && Date.now() - s.endedAt < 12 * HOUR) {
      const why = { time: "time's up", done: 'every session was done', battery: 'the battery ran low', external: 'sleep was turned on elsewhere', off: 'turned off' }[s.reason] || 'ended';
      return `Awake is off (ended at ${clock(s.endedAt)}: ${why}${s.worked ? `, ${s.worked} session${s.worked === 1 ? '' : 's'} worked meanwhile` : ''}).`;
    }
    return 'Awake is off: the Mac sleeps when the lid closes.';
  }
  const left = s.until - Date.now();
  const lines = [
    `Awake until ${clock(s.until)} (${humanize(left)} left)${s.untilDone ? ', or once every session is done' : ''}.`,
    'Close the lid any time: Claude keeps working.',
    `Sleep comes back on by itself${s.untilDone ? ' when the work is done,' : ''} at ${clock(s.until)} at the latest, or below ${s.minBattery ?? LIMITS.battery}% battery. Stop it early: tabby awake off`,
  ];
  if (s.prior === 1) lines.push('(Sleep was already off before tabby; it stays off afterwards.)');
  return lines.join('\n');
}

export function status() {
  const s = check();
  return {
    supported: !unsupported(),
    allowed: !unsupported() && allowed(),
    on: !!s?.on,
    until: s?.on ? s.until : null,
    left: s?.on ? Math.max(0, s.until - Date.now()) : null,
    untilDone: !!s?.untilDone,
    startedAt: s?.startedAt ?? null,
    endedAt: s?.on ? null : s?.endedAt ?? null,
    reason: s?.on ? null : s?.reason ?? null,
    worked: s?.worked ?? null,
    sleepDisabled: unsupported() ? null : sleepDisabled(),
    battery: unsupported() ? null : battery(),
  };
}

export const USAGE = [
  'tabby awake 4h              keep the Mac running with the lid closed for 4 hours (90m, 1.5h, 8h…)',
  'tabby awake done [8h]       until every Claude session is done (8 h at most)',
  'tabby awake 2h --until-done the same, 2 h at most',
  'tabby awake +1h             more time       tabby awake off   sleep as usual again',
  'tabby awake                 how long it has left',
  'The first time, macOS asks for your password once: tabby may then turn sleep off and back on, nothing else.',
  'Undo that permission: tabby awake forget',
].join('\n');

// `tabby awake …` and `/tab awake …`: the words after "awake". Returns { ok, message, state? }.
export function command(words, { untilDone = false, prompt = true } = {}) {
  const w = words.map((x) => String(x).toLowerCase()).filter(Boolean);
  const first = w[0] || '';
  if (!first || first === 'status') return { ok: true, message: unsupported() || describe(check()) };
  if (['help', '-h', '--help'].includes(first)) return { ok: true, message: USAGE };
  if (['off', 'stop', 'sleep', 'end', 'cancel'].includes(first)) return stop('off');
  if (['forget', 'revoke', 'uninstall'].includes(first)) return revoke();
  if (first === 'allow' || first === 'setup') {
    if (allowed()) return { ok: true, message: 'Already allowed: tabby awake 4h keeps the Mac running with the lid closed.' };
    const g = grant();
    return { ok: g.ok, message: g.ok ? 'Allowed. Now: tabby awake 4h' : g.canceled ? 'Nothing changed: the prompt was canceled.' : `Could not allow it: ${g.error}` };
  }
  if (first.startsWith('+') || first === 'more' || first === 'extend') {
    const ms = parseDuration(first.startsWith('+') ? first.slice(1) : w[1] || '1h');
    if (!ms) return { ok: false, message: USAGE };
    return extend(ms);
  }
  const done = untilDone || w.some((x) => ['done', 'finish', 'finished', 'until-done', '--until-done'].includes(x));
  const spec = w.find((x) => parseDuration(x));
  const ms = spec ? parseDuration(spec) : done ? LIMITS.doneCap : ['on', 'start'].includes(first) ? 4 * HOUR : null;
  if (!ms) return { ok: false, message: `Not a length of time: "${words.join(' ')}".\n${USAGE}` };
  return start({ ms, untilDone: done, prompt });
}
