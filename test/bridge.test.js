// Sessions that were open before setup: tabby's hooks through settings.json, for those Claude
// processes only, until they end (lib/bridge.js).
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawn, spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'tabby-bridge-'));
process.env.HOME = tmp;
process.env.TABBY_HOME = path.join(tmp, 'tabby');
process.env.CLAUDE_CONFIG_DIR = path.join(tmp, 'claude');
process.env.TERM_PROGRAM = 'Apple_Terminal';
process.env.TABBY_NO_TERMINAL_PROFILES = '1';
process.env.TABBY_NO_ISLAND = '1';
process.env.TABBY_NO_UPDATE_CHECK = '1';
process.env.CLAUDE_CODE_DISABLE_TERMINAL_TITLE = '1';
for (const k of ['TMUX', 'STY', 'ZELLIJ', 'TABBY_OFF', 'TABBY_INTERNAL', 'CLAUDE_PLUGIN_ROOT']) delete process.env[k];
fs.mkdirSync(process.env.TABBY_HOME, { recursive: true });
fs.mkdirSync(path.join(process.env.CLAUDE_CONFIG_DIR, 'sessions'), { recursive: true });
fs.writeFileSync(path.join(process.env.TABBY_HOME, 'config.json'), JSON.stringify({ namer: 'heuristic', animate: false, termsAccepted: { version: '2026-09-25', by: 'test' } }));

const ROOT = fileURLToPath(new URL('..', import.meta.url));
const settingsFile = path.join(process.env.CLAUDE_CONFIG_DIR, 'settings.json');
const readSettings = () => JSON.parse(fs.readFileSync(settingsFile, 'utf8'));
const MINE = { type: 'command', command: 'echo mine' };

// Stand-ins for Claude processes that were running before setup.
const procs = [];
function claudeProcess(sessionId) {
  const p = spawn('sleep', ['60'], { stdio: 'ignore' });
  procs.push(p);
  fs.writeFileSync(path.join(process.env.CLAUDE_CONFIG_DIR, 'sessions', `${p.pid}.json`), JSON.stringify({ pid: p.pid, sessionId, cwd: '/work/old', kind: 'interactive', status: 'idle', startedAt: Date.now() }));
  return p;
}
// Claude takes its registry file away when it exits.
function exitProcess(p) {
  p.kill('SIGKILL');
  fs.rmSync(path.join(process.env.CLAUDE_CONFIG_DIR, 'sessions', `${p.pid}.json`), { force: true });
}

let B, H, S;
before(async () => {
  B = await import('../lib/bridge.js');
  H = await import('../lib/hooks.js');
  S = await import('../lib/state.js');
});
after(() => procs.forEach((p) => p.kill()));

const tty = path.join(tmp, 'old.tty');
function as(pid, fn) {
  process.env.TABBY_TTY = tty;
  process.env.CLAUDE_PID = String(pid);
  return fn();
}

test('open sessions are bridged: hooks for every plugin event, your own hooks kept', () => {
  fs.writeFileSync(settingsFile, JSON.stringify({ model: 'opus', hooks: { Stop: [{ hooks: [MINE] }], PreToolUse: [{ matcher: 'Bash', hooks: [MINE] }] } }));
  const old = claudeProcess('OLD');
  const res = B.open();
  assert.equal(res.count, 1);
  assert.equal(res.hooks, true);
  assert.deepEqual(B.pids(), [old.pid]);
  assert.equal(fs.readFileSync(path.join(process.env.TABBY_HOME, 'bridge.pids'), 'utf8'), `${old.pid}\n`);
  assert.equal(fs.statSync(path.join(process.env.TABBY_HOME, 'bridge.pids')).mode & 0o777, 0o600);

  const s = readSettings();
  assert.equal(s.model, 'opus');
  const plugin = JSON.parse(fs.readFileSync(path.join(ROOT, 'hooks', 'hooks.json'), 'utf8')).hooks;
  for (const event of Object.keys(plugin)) {
    const ours = s.hooks[event].flatMap((g) => g.hooks).filter((h) => /--bridge$/.test(h.command));
    assert.equal(ours.length, 1, event);
    assert.match(ours[0].command, new RegExp(`^sh ".*/tabby/bin/tabby" hook ${event} --bridge$`));
    assert.equal(!!ours[0].async, !!plugin[event][0].hooks[0].async, `${event} async`);
  }
  assert.deepEqual(s.hooks.Stop[0], { hooks: [MINE] }, 'your Stop hook stays first and unchanged');
  assert.deepEqual(s.hooks.PreToolUse, [{ matcher: 'Bash', hooks: [MINE] }]);

  B.open();
  assert.equal(readSettings().hooks.Stop.length, 2, 'opening again adds nothing');
  assert.match(B.describe(res), /1 Claude session already open is on too/);
});

test('exactly one side answers for a bridged session: the bridge, not the plugin', () => {
  const pid = B.pids()[0];
  assert.equal(as(pid, () => H.handleHook('UserPromptSubmit', { session_id: 'OLD', cwd: '/work/old', prompt: '/tab color teal' })), null, 'plugin stands back');
  const out = as(pid, () => H.handleHook('UserPromptSubmit', { session_id: 'OLD', cwd: '/work/old', prompt: '/tab color teal' }, { via: 'bridge' }));
  assert.equal(out.decision, 'block');
  assert.equal(S.readSession('OLD').accentKey, 'teal');

  as(pid, () => H.handleHook('UserPromptSubmit', { session_id: 'OLD', cwd: '/work/old', prompt: 'fix the login flow' }, { via: 'bridge' }));
  const rec = S.readSession('OLD');
  assert.equal(rec.status, 'busy');
  assert.equal(rec.ownsTitle, false, 'Claude still draws the title in a session that started before setup');
  assert.equal(rec.title, 'Fix Login Flow');

  // Any other session: the bridge's hooks do nothing, the plugin's answer.
  assert.equal(as(process.pid, () => H.handleHook('UserPromptSubmit', { session_id: 'NEW', cwd: '/work/new', prompt: '/tab' }, { via: 'bridge' })), null);
  assert.equal(as(process.pid, () => H.handleHook('UserPromptSubmit', { session_id: 'NEW', cwd: '/work/new', prompt: '/tab' })).decision, 'block');
});

test('bin/tabby.sh only starts Node for a bridged session', () => {
  const marker = path.join(tmp, 'node-ran');
  const fakeNode = path.join(tmp, 'fake-node.sh');
  fs.writeFileSync(fakeNode, `#!/bin/sh\ntouch "${marker}"\n`, { mode: 0o755 });
  const run = (pid) => {
    try { fs.unlinkSync(marker); } catch {}
    spawnSync('sh', [path.join(ROOT, 'bin', 'tabby.sh'), 'hook', 'UserPromptSubmit', '--bridge'], { input: '{}', env: { ...process.env, TABBY_NODE: fakeNode, CLAUDE_PID: String(pid) } });
    return fs.existsSync(marker);
  };
  assert.equal(run(process.pid), false, 'another session: no Node');
  assert.equal(run(B.pids()[0]), true, 'the bridged one: Node');
});

test('the hooks come out when the last bridged session ends, and only they do', () => {
  const pid = B.pids()[0];
  assert.equal(B.tidy(), false, 'still running');
  as(pid, () => H.handleHook('SessionEnd', { session_id: 'OLD', cwd: '/work/old', reason: 'clear' }, { via: 'bridge' }));
  assert.equal(B.installed(), true, '/clear keeps the process: the bridge stays');
  as(pid, () => H.handleHook('SessionEnd', { session_id: 'OLD', cwd: '/work/old', reason: 'prompt_input_exit' }, { via: 'bridge' }));
  exitProcess(procs.find((p) => p.pid === pid));
  assert.equal(B.installed(), false);
  assert.deepEqual(B.pids(), []);
  assert.equal(fs.existsSync(path.join(process.env.TABBY_HOME, 'bridge.pids')), false);
  const s = readSettings();
  assert.deepEqual(s.hooks, { Stop: [{ hooks: [MINE] }], PreToolUse: [{ matcher: 'Bash', hooks: [MINE] }] });
  assert.equal(s.model, 'opus');
});

test('a bridge whose sessions are gone is taken down by the next hook from anywhere', async () => {
  fs.writeFileSync(settingsFile, JSON.stringify({}));
  const p = claudeProcess('GONE');
  B.open();
  assert.equal(B.installed(), true);
  const gone = new Promise((r) => p.once('exit', r));
  p.kill('SIGKILL'); // a crash: its registry file stays behind
  await gone;
  as(process.pid, () => H.handleHook('Stop', { session_id: 'OTHER', cwd: '/w' }, { via: 'bridge' }));
  assert.equal(B.installed(), false);
  assert.equal(readSettings().hooks, undefined, 'an empty hooks block it made is gone too');
});

test('no bridge when settings.json is broken or hooks are turned off; colors still come', () => {
  fs.writeFileSync(settingsFile, '{ not json');
  claudeProcess('BROKEN');
  const res = B.open();
  assert.equal(res.hooks, false);
  assert.match(res.why, /isn't valid JSON/);
  assert.equal(fs.readFileSync(settingsFile, 'utf8'), '{ not json', 'never rewritten');
  assert.match(B.describe(res), /\/reload-plugins/);

  fs.writeFileSync(settingsFile, JSON.stringify({ disableAllHooks: true }));
  assert.match(B.open().why, /disableAllHooks/);
  assert.equal(readSettings().hooks, undefined);
});

test('setup run from a plugin hook leaves its own session to the plugin', () => {
  fs.writeFileSync(settingsFile, JSON.stringify({}));
  for (const f of ['bridge.json', 'bridge.pids']) try { fs.unlinkSync(path.join(process.env.TABBY_HOME, f)); } catch {}
  const self = claudeProcess('SELF');
  process.env.CLAUDE_PLUGIN_ROOT = ROOT;
  process.env.CLAUDE_PID = String(self.pid);
  try {
    B.open();
    assert.equal(B.pids().includes(self.pid), false);
  } finally {
    delete process.env.CLAUDE_PLUGIN_ROOT;
  }
});
