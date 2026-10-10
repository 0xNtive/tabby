// Processes left running (tabby procs) and going back to past sessions (tabby history/resume):
// read from made-up `ps`/`lsof` output and session records; nothing is stopped or opened.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'tabby-procs-test-'));
process.env.TABBY_HOME = path.join(tmp, 'tabby');
process.env.CLAUDE_CONFIG_DIR = path.join(tmp, 'claude');

const P = await import('../lib/procs.js');
const H = await import('../lib/history.js');

const NOW = Date.parse('Sat Oct 10 18:00:00 2026');
// As `ps -o lstart` prints it: "Sat Oct 10 18:00:00 2026" (" 3" for a one-digit day).
const at = (hoursAgo) => {
  const [weekday, month, day, year, time] = new Date(NOW - hoursAgo * 3600e3).toString().split(' ');
  return `${weekday} ${month} ${String(Number(day)).padStart(2)} ${time} ${year}`;
};
const UID = 501;
const ME = 9000; // the scan itself

// pid, ppid, uid, cpu, rss (KB), started (hours ago), tty, command [, exe]
const table = [
  [1, 0, 0, 0, 0, 100, '??', '/sbin/launchd'],
  [500, 1, 0, 0, 0, 50, '??', '/usr/bin/login -pf you'],
  [501, 500, UID, 0, 2000, 50, 'ttys001', '-zsh', '/bin/zsh'],
  [502, 501, UID, 4, 500000, 6, 'ttys001', 'claude --dangerously-skip-permissions', 'claude'],
  // A dev server Claude started (live, idle session): its shell, npm, and vite listening.
  [600, 502, UID, 0, 3000, 5, '??', '/bin/zsh -c npm run dev', '/bin/zsh'],
  [601, 600, UID, 0, 60000, 5, '??', 'npm run dev', '/opt/homebrew/bin/npm'],
  [602, 601, UID, 2, 300000, 5, '??', '/opt/homebrew/bin/node /Users/you/billing/node_modules/.bin/vite', '/opt/homebrew/bin/node'],
  // An MCP server Claude runs itself: part of Claude, never offered.
  [610, 502, UID, 1, 90000, 6, '??', '/opt/homebrew/bin/node /Users/you/mcp/server.js', '/opt/homebrew/bin/node'],
  // A leftover from a Claude session that has ended.
  [700, 1, UID, 18, 1200000, 26, '??', 'next-server (v15.1.0)', '/opt/homebrew/bin/node'],
  // A headless Chrome left running from a terminal.
  [710, 1, UID, 9, 160000, 30, '??', '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome --headless=new --remote-debugging-port=9222', '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'],
  // A launchd service (a brew service, an agent of yours): never offered.
  [720, 1, UID, 0, 90000, 90, '??', '/opt/homebrew/opt/postgresql@16/bin/postgres -D /opt/homebrew/var/postgresql@16', '/opt/homebrew/opt/postgresql@16/bin/postgres'],
  [721, 1, UID, 0, 90000, 90, '??', '/opt/homebrew/bin/node /Users/you/bots/nightowl.mjs', '/opt/homebrew/bin/node'],
  // An app, and tabby's own ticker.
  [730, 1, UID, 30, 900000, 2, '??', '/Applications/Slack.app/Contents/MacOS/Slack', '/Applications/Slack.app/Contents/MacOS/Slack'],
  [740, 1, UID, 0, 40000, 3, '??', '/opt/homebrew/bin/node /Users/you/.claude/plugins/tabby/bin/tabby.js _ticker', '/opt/homebrew/bin/node'],
  // A server typed into another terminal tab, still open.
  [800, 500, UID, 0, 2000, 4, 'ttys002', '-zsh', '/bin/zsh'],
  [801, 800, UID, 0, 80000, 1, 'ttys002', 'python3 -m http.server 8000', '/opt/homebrew/bin/python3'],
  // ssh-agent outlives terminals on purpose.
  [810, 1, UID, 0, 3000, 50, '??', '/usr/bin/ssh-agent -l', '/usr/bin/ssh-agent'],
  // Started from a terminal and detached on purpose: a VM, a nohup'd tool. Listed, never stale.
  [820, 1, UID, 0, 600000, 40, '??', '/opt/homebrew/bin/colima daemon start default', '/opt/homebrew/bin/colima'],
  [821, 820, UID, 12, 2000000, 40, '??', '/opt/homebrew/bin/limactl hostagent colima', '/opt/homebrew/bin/limactl'],
  [830, 1, UID, 0, 30000, 20, '??', '/usr/local/bin/backup-watch --dir /Users/you', '/usr/local/bin/backup-watch'],
  // Another user's process.
  [900, 1, 502, 50, 900000, 1, '??', '/usr/local/bin/node /Users/other/app.js', '/usr/local/bin/node'],
  // The scan: run from Claude (502) through a tool shell.
  [8999, 502, UID, 1, 3000, 0.01, '??', '/bin/zsh -c tabby procs', '/bin/zsh'],
  [ME, 8999, UID, 10, 40000, 0.01, '??', 'node tabby.js procs', '/opt/homebrew/bin/node'],
];

const ps = table.map(([pid, ppid, uid, cpu, rss, h, tty, cmd]) => `${String(pid).padStart(5)} ${String(ppid).padStart(5)} ${String(uid).padStart(5)} ${String(cpu).padStart(5)} ${String(rss).padStart(8)} ${at(h)}     ${tty.padEnd(8)} ${cmd}`).join('\n');
const comm = table.map(([pid, , , , , , , cmd, exe]) => `${String(pid).padStart(5)} ${exe || cmd.split(' ')[0]}`).join('\n');
const terminal = 'TERM_PROGRAM=Apple_Terminal TERM_SESSION_ID=AAA XPC_SERVICE_NAME=0';
const envs = {
  600: `${terminal} CLAUDECODE=1 CLAUDE_CODE_SESSION_ID=live-1 CLAUDE_PID=502`,
  610: `${terminal} CLAUDECODE=1 CLAUDE_PID=502`,
  700: `${terminal} CLAUDECODE=1 CLAUDE_CODE_SESSION_ID=ended-1 CLAUDE_PID=444`,
  710: `${terminal}`,
  720: 'XPC_SERVICE_NAME=homebrew.mxcl.postgresql@16',
  721: 'XPC_SERVICE_NAME=com.you.nightowl',
  730: 'XPC_SERVICE_NAME=application.com.tinyspeck.slackmacgap',
  740: `${terminal} CLAUDECODE=1`,
  801: 'TERM_PROGRAM=Apple_Terminal TERM_SESSION_ID=BBB XPC_SERVICE_NAME=0',
  810: '',
  820: 'TERM_PROGRAM=Apple_Terminal TERM_SESSION_ID=CCC XPC_SERVICE_NAME=0',
  830: 'TERM_PROGRAM=Apple_Terminal TERM_SESSION_ID=DDD XPC_SERVICE_NAME=0',
};
const listening = ['p602', 'f20', 'n127.0.0.1:5173', 'p700', 'f21', 'n*:3000', 'n*:3000', 'p710', 'n127.0.0.1:9222', 'p720', 'n127.0.0.1:5432', 'p801', 'n*:8000', 'p610', 'n127.0.0.1:7777'].join('\n');
const records = [
  { sessionId: 'live-1', pid: 502, title: 'Stripe Webhook Retries', project: 'billing', status: 'idle', statusAt: NOW - 4 * 3600e3, cwd: '/Users/you/billing' },
  { sessionId: 'ended-1', pid: 444, title: 'Dark Mode Settings', project: 'web', status: 'ended', cwd: '/Users/you/web' },
];

const system = (overrides = {}) => ({
  uid: UID,
  ps: () => ps,
  comm: () => comm,
  listening: () => listening,
  env: (pids) => pids.map((pid) => `${pid} cmd ${envs[pid] ?? ''}`).join('\n'),
  cwd: (pids) => pids.map((pid) => `p${pid}\nfcwd\nn${pid === 801 ? '/Users/you/site' : pid === 710 ? '/Users/you/docs' : '/Users/you/proj'}`).join('\n'),
  registry: () => new Map([[502, { pid: 502, sessionId: 'live-1', status: 'idle', statusUpdatedAt: NOW - 4 * 3600e3 }]]),
  sessions: () => records,
  ...overrides,
});

const scanned = (o) => P.scan({ system: system(o), now: NOW, self: ME });
const byPid = (r) => Object.fromEntries(r.items.map((i) => [i.pid, i]));

test('ps, lsof and environment output parse', () => {
  const rows = P.parsePs(ps);
  assert.equal(rows.get(602).memMB, 293);
  assert.equal(rows.get(602).tty, '??');
  assert.equal(rows.get(700).command, 'next-server (v15.1.0)');
  assert.equal(rows.get(700).startedAt, NOW - 26 * 3600e3);
  assert.deepEqual(P.parseLsof(listening).get(700), ['*:3000', '*:3000']);
  assert.equal(P.portOf('[::1]:5432'), 5432);
  const env = P.parseEnv('42 node a.js TERM=xterm CLAUDE_CODE_SESSION_ID=abc XPC_SERVICE_NAME=0');
  assert.deepEqual(env.get(42), { CLAUDE_CODE_SESSION_ID: 'abc', XPC_SERVICE_NAME: '0' });
  assert.ok(P.fromTerminal({ TERM_SESSION_ID: 'x', XPC_SERVICE_NAME: '0' }));
  assert.ok(!P.fromTerminal({ XPC_SERVICE_NAME: 'homebrew.mxcl.postgresql@16', TERM_PROGRAM: 'x' }), 'a launchd job, whatever else it says');
  assert.ok(!P.fromTerminal({}), 'nothing known: left alone');
});

test('only what a terminal or Claude started: launchd services, apps, agents, Claude, tabby and other users are never listed', () => {
  const pids = Object.keys(byPid(scanned())).map(Number).sort((a, b) => a - b);
  assert.deepEqual(pids, [600, 700, 710, 801, 820, 830]);
});

test("what was detached on purpose (a VM, a database, a nohup'd tool) is listed but never stale", () => {
  const r = byPid(scanned());
  assert.equal(r[820].label, 'limactl', 'named after what uses the most');
  assert.deepEqual(r[820].pids, [820, 821]);
  assert.ok(!r[820].stale);
  assert.equal(r[820].why, 'in the background');
  assert.ok(!r[830].stale, 'not a dev server or script: not ours to call stale');
  assert.equal(r[830].why, 'in the background');
});

test('a leftover from an ended Claude session is stale, and says whose it was', () => {
  const next = byPid(scanned())[700];
  assert.equal(next.label, 'next-server');
  assert.deepEqual(next.ports, [3000]);
  assert.ok(next.stale && next.leftover);
  assert.equal(next.why, 'session ended');
  assert.equal(next.owner.title, 'Dark Mode Settings');
  assert.equal(next.project, 'web');
  assert.equal(next.id, `700-${Math.round((NOW - 26 * 3600e3) / 1000)}`, 'the id carries the start time');
});

test("a server in an open session is grouped with its shell and npm, named after what listens, stale only once the session has idled for hours", () => {
  const vite = byPid(scanned())[600];
  assert.deepEqual(vite.pids, [600, 601, 602]);
  assert.equal(vite.label, 'vite');
  assert.deepEqual(vite.ports, [5173]);
  assert.equal(vite.memMB, 3 + 59 + 293);
  assert.equal(vite.owner.title, 'Stripe Webhook Retries');
  assert.ok(vite.owner.live);
  assert.ok(vite.stale, 'idle 4 h');
  assert.equal(vite.why, 'session idle 4 h');

  const busy = byPid(scanned({ registry: () => new Map([[502, { pid: 502, sessionId: 'live-1', status: 'busy', statusUpdatedAt: NOW - 60e3 }]]) }))[600];
  assert.ok(!busy.stale);
  assert.equal(busy.why, 'session working');
  const fresh = byPid(scanned({ registry: () => new Map([[502, { pid: 502, sessionId: 'live-1', status: 'idle', statusUpdatedAt: NOW - 600e3 }]]) }))[600];
  assert.ok(!fresh.stale, 'idle ten minutes: still yours');
  assert.equal(fresh.why, 'session open');
});

test('a headless browser left behind counts; a server in an open terminal tab is listed but not stale', () => {
  const r = byPid(scanned());
  assert.equal(r[710].label, 'Chrome (headless)');
  assert.ok(r[710].stale);
  assert.equal(r[710].why, 'left running');
  assert.equal(r[801].label, 'python http.server');
  assert.ok(!r[801].stale);
  assert.equal(r[801].why, 'in a terminal');
  assert.equal(r[801].project, 'site');
});

test('stale ones come first, with their totals', () => {
  const r = scanned();
  assert.deepEqual(r.items.map((i) => i.stale), [true, true, true, false, false, false]);
  assert.equal(r.stale.count, 3);
  assert.equal(r.stale.memMB, r.items.filter((i) => i.stale).reduce((s, i) => s + i.memMB, 0));
});

test('labels say what a process is', () => {
  const cases = [
    ['/opt/homebrew/bin/node /x/node_modules/vite/bin/vite.js', 'vite'],
    ['node /x/node_modules/.bin/next dev', 'next dev'],
    ['node /x/node_modules/@astrojs/cli/bin.js', 'cli'],
    ['node server.js --port 3000', 'server.js'],
    ['node -e require("http").createServer()', 'node -e'],
    ['node --require ts-node/register app.ts', 'app.ts'],
    ['npm run dev', 'npm run dev'],
    ['pnpm dev', 'pnpm dev'],
    ['python3 -m http.server 8000', 'python http.server'],
    ['python manage.py runserver', 'django runserver'],
    ['/usr/bin/ruby bin/rails server', 'ruby rails'],
    ['next-server (v15.1.0)', 'next-server'],
    ['/x/Google Chrome --headless=new', 'Chrome (headless)'],
    ['/usr/local/bin/redis-server *:6379', 'redis-server'],
  ];
  for (const [cmd, label] of cases) assert.equal(P.describe(cmd), label, cmd);
});

test('stop: SIGTERM to the group (children first), SIGKILL for whatever stays, and only what the list showed', () => {
  const list = scanned();
  const alive = new Set([600, 601, 602, 700, 710, 801]);
  const stubborn = new Set([602]);
  const sent = [];
  const kill = (pid, sig) => {
    sent.push([pid, sig]);
    if (!alive.has(pid)) throw Object.assign(new Error('gone'), { code: 'ESRCH' });
    if (sig === 'SIGKILL' || !stubborn.has(pid)) alive.delete(pid);
  };
  const res = P.stop([list.items.find((i) => i.pid === 600).id], { scanned: list, kill, isAlive: (p) => alive.has(p), wait: () => {} });
  assert.deepEqual(sent.filter(([, s]) => s === 'SIGTERM').map(([p]) => p), [602, 601, 600]);
  assert.deepEqual(sent.filter(([, s]) => s === 'SIGKILL').map(([p]) => p), [602]);
  assert.deepEqual(res.stopped.map((s) => s.label), ['vite']);
  assert.ok(alive.has(700) && alive.has(801), 'nothing else touched');

  const stale = P.stop('stale', { scanned: scanned(), kill, isAlive: (p) => alive.has(p), wait: () => {} });
  assert.deepEqual(stale.stopped.map((s) => s.pid).sort(), [600, 700, 710]);
  assert.ok(alive.has(801), 'not stale: still running');
  assert.match(P.stopReport(stale), /^Stopped 3: /);

  const stale2 = P.stop(['801-1'], { scanned: scanned(), kill, isAlive: (p) => alive.has(p), wait: () => {} });
  assert.deepEqual(stale2.stopped, [], 'a pid that started at another time (reused) is never hit');
  assert.deepEqual(stale2.unknown, ['801-1']);
});

test('report: stale first with how to stop them, the rest after', () => {
  const text = P.report(scanned(), { now: NOW });
  assert.match(text, /^Stale \(3\)/);
  assert.match(text, /tabby procs stop/);
  assert.match(text, /next-server :3000/);
  assert.match(text, /Running \(3\)/);
  assert.match(P.report({ items: [], stale: { count: 0, memMB: 0, cpu: 0 } }), /^Nothing to clean up/);
});

// ---------- history & resume ----------

const transcripts = path.join(tmp, 'claude', 'projects');
fs.mkdirSync(path.join(transcripts, 'p'), { recursive: true });
const tfile = (id, mode) => {
  const file = path.join(transcripts, 'p', `${id}.jsonl`);
  fs.writeFileSync(file, `{"type":"user","permissionMode":"default"}\n{"type":"user","permissionMode":"${mode}"}\n`);
  return file;
};
const dir = fs.mkdtempSync(path.join(tmp, 'proj-'));
const past = [
  { sessionId: 'aaaa-1', title: 'Stripe Webhook Retries', project: 'billing', cwd: dir, status: 'ended', promptCount: 4, updatedAt: NOW - 3600e3, summary: 'Retrying webhooks.', transcriptPath: tfile('aaaa-1', 'bypassPermissions'), term: 'apple-terminal' },
  { sessionId: 'bbbb-2', title: '', titleSource: 'project', project: 'web', cwd: dir, status: 'ended', prompts: ['can you fix the flaky checkout test please'], promptCount: 1, updatedAt: NOW - 7200e3, transcriptPath: tfile('bbbb-2', 'default') },
  { sessionId: 'cccc-3', title: 'Open One', project: 'api', cwd: dir, status: 'idle', promptCount: 2, updatedAt: NOW, transcriptPath: tfile('cccc-3', 'default') },
  { sessionId: 'dddd-4', title: '', project: 'empty', cwd: dir, status: 'ended', updatedAt: NOW - 60e3 }, // opened and closed
  { sessionId: 'tty-ttys009', bare: true, title: 'Shell', cwd: dir, updatedAt: NOW },
];

test('history: newest first, named from what was asked when tabby never named it, open ones marked', () => {
  const rows = H.history({ records: past, live: new Set(['cccc-3']) });
  assert.deepEqual(rows.map((r) => r.sessionId), ['cccc-3', 'aaaa-1', 'bbbb-2']);
  assert.equal(rows[2].title, 'Fix Flaky Checkout Test', 'never "web-4f" or blank');
  assert.ok(rows[0].live && !rows[1].live);
  assert.ok(rows[1].resumable);
  assert.equal(H.findPast('2', rows).sessionId, 'aaaa-1', 'the number tabby history shows');
  assert.equal(H.findPast('stripe', rows).sessionId, 'aaaa-1');
  assert.equal(H.findPast('aaaa', rows).sessionId, 'aaaa-1');
  assert.equal(H.findPast('nope', rows), null);
});

test('resume opens claude --resume in its folder, the way it ran before', () => {
  const rows = H.history({ records: past, live: new Set(['cccc-3']) });
  const bypass = H.resume('aaaa-1', { rows, records: past, dryRun: true });
  assert.ok(bypass.ok);
  assert.match(bypass.message, new RegExp(`cd '${dir}' && claude --resume 'aaaa-1' --dangerously-skip-permissions`));
  const normal = H.resume('bbbb-2', { rows, records: past, dryRun: true });
  assert.doesNotMatch(normal.message, /dangerously/);
  const open = H.resume('Open One', { rows, records: past, dryRun: true });
  assert.ok(open.live);
  assert.match(open.message, /still open/);
  assert.equal(H.transcriptMode(past[0].transcriptPath), 'bypassPermissions', 'the last mode wins');
  const gone = H.resume('aaaa-1', { rows: rows.map((r) => ({ ...r, cwd: path.join(dir, 'gone') })), records: past, dryRun: true });
  assert.ok(!gone.ok);
  assert.match(gone.message, /folder is gone/);
});
