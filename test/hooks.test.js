// End-to-end hook flows against a throwaway home and fake TTY files.
import { test, before } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'tabby-test-'));
process.env.HOME = tmp; // setup writes ~/.zshrc: keep it inside the sandbox
process.env.TABBY_HOME = path.join(tmp, 'tabby');
process.env.CLAUDE_CONFIG_DIR = path.join(tmp, 'claude');
process.env.TERM_PROGRAM = 'Apple_Terminal';
process.env.TABBY_NO_TERMINAL_PROFILES = '1'; // never switch the real Terminal's profiles
process.env.CLAUDE_CODE_DISABLE_TERMINAL_TITLE = '1';
delete process.env.TMUX;
delete process.env.TABBY_OFF;
delete process.env.TABBY_INTERNAL;
fs.mkdirSync(process.env.TABBY_HOME, { recursive: true });
fs.writeFileSync(path.join(process.env.TABBY_HOME, 'config.json'), JSON.stringify({ namer: 'heuristic', animate: false }));

let H, S, T;
before(async () => {
  H = await import('../lib/hooks.js');
  S = await import('../lib/state.js');
  T = await import('../lib/terms.js');
});

const tty = (name) => path.join(tmp, `${name}.tty`);
const read = (name) => (fs.existsSync(tty(name)) ? fs.readFileSync(tty(name), 'utf8') : '');
const clearTty = (name) => fs.writeFileSync(tty(name), '');
function as(name, pid, fn) {
  process.env.TABBY_TTY = tty(name);
  process.env.CLAUDE_PID = String(pid);
  return fn();
}
const hook = (event, input) => H.handleHook(event, { cwd: '/work/api', transcript_path: '/nope.jsonl', ...input });

test('until the terms are accepted tabby stays off and points at /tabby:setup', () => {
  clearTty('z');
  const start = as('z', process.pid, () => hook('SessionStart', { session_id: 'Z', source: 'startup' }));
  assert.match(start.systemMessage, /\/tabby:setup/);
  assert.equal(S.readSession('Z'), null, 'no record, no colors');
  assert.equal(read('z'), '');
  const again = as('z', process.pid, () => hook('SessionStart', { session_id: 'Z2', source: 'startup' }));
  assert.equal(again, null, 'the nudge is rate-limited');
  const tab = as('z', process.pid, () => hook('UserPromptSubmit', { session_id: 'Z', prompt: '/tab color teal' }));
  assert.equal(tab.decision, 'block');
  assert.match(tab.reason, /off until you accept/);
  assert.equal(as('z', process.pid, () => hook('UserPromptSubmit', { session_id: 'Z', prompt: 'hello' })), null);

  const terms = as('z', process.pid, () => hook('UserPromptSubmit', { session_id: 'Z', prompt: '/tabby:setup' }));
  assert.match(terms.reason, /Terms of Use/);
  assert.match(terms.reason, /sponsored/);
  assert.match(terms.reason, /\/tabby:setup accept/);
  assert.equal(T.termsAccepted(), false);

  const done = as('z', process.pid, () => hook('UserPromptSubmit', { session_id: 'Z', prompt: '/tabby:setup accept' }));
  assert.match(done.reason, /tabby is on/);
  assert.equal(T.termsAccepted(), true);
  const settings = JSON.parse(fs.readFileSync(path.join(process.env.CLAUDE_CONFIG_DIR, 'settings.json'), 'utf8'));
  assert.equal(settings.env.CLAUDE_CODE_DISABLE_TERMINAL_TITLE, '1');
  assert.match(settings.statusLine.command, /tabby\.mjs" statusline$/);
  assert.ok(fs.existsSync(path.join(process.env.TABBY_HOME, 'bin', 'tabby.mjs')), 'launcher');
  assert.ok(fs.existsSync(path.join(process.env.CLAUDE_CONFIG_DIR, 'commands', 'tab.md')), '/tab');
  const rc = path.basename(process.env.SHELL || 'zsh') === 'bash' ? '.bashrc' : '.zshrc';
  assert.match(fs.readFileSync(path.join(tmp, rc), 'utf8'), />>> tabby/);
});

test('session start paints the tab and records identity', () => {
  clearTty('a');
  as('a', process.pid, () => hook('SessionStart', { session_id: 'A', source: 'startup' }));
  const rec = S.readSession('A');
  assert.equal(rec.theme, 'tabby');
  assert.ok(rec.accentKey && rec.accent && rec.bg && rec.fg);
  assert.equal(rec.status, 'new');
  const out = read('a');
  assert.match(out, new RegExp(`\\x1b\\]11;${rec.bg}\\x07`), 'background');
  assert.match(out, new RegExp(`\\x1b\\]10;${rec.fg}\\x07`), 'foreground');
  assert.match(out, /\x1b\]0;\S+ ✳ api\x07/, 'title = marker + status + project');
});

test('prompt → working + instant name; /tab commands are blocked and never reach the model', () => {
  clearTty('a');
  as('a', process.pid, () => {
    const out = hook('UserPromptSubmit', { session_id: 'A', prompt: 'okay so can you fix the flaky login tests in the auth module' });
    assert.equal(out, null, 'heuristic names are not pushed to Claude');
  });
  let rec = S.readSession('A');
  assert.equal(rec.status, 'busy');
  assert.equal(rec.title, 'Fix Flaky Login Tests');
  assert.match(read('a'), /◐ Fix Flaky Login Tests/);

  const out = as('a', process.pid, () => hook('UserPromptSubmit', { session_id: 'A', prompt: '/tab Auth refactor' }));
  assert.equal(out.decision, 'block');
  assert.match(out.reason, /Renamed → Auth refactor/);
  assert.equal(out.hookSpecificOutput.sessionTitle, 'Auth refactor');
  assert.equal(out.hookSpecificOutput.suppressOriginalPrompt, true);
  rec = S.readSession('A');
  assert.equal(rec.titleSource, 'manual');
  assert.equal(rec.promptCount, 1, '/tab is not recorded as a prompt');

  const before = rec.bg;
  as('a', process.pid, () => hook('UserPromptSubmit', { session_id: 'A', prompt: '/tab color teal' }));
  rec = S.readSession('A');
  assert.equal(rec.accentKey, 'teal');
  assert.notEqual(rec.bg, before);

  as('a', process.pid, () => hook('UserPromptSubmit', { session_id: 'A', prompt: '/tabby:tab theme nord' }));
  assert.equal(S.readSession('A').theme, 'nord');

  const help = as('a', process.pid, () => hook('UserPromptSubmit', { session_id: 'A', prompt: '/tab' }));
  assert.match(help.reason, /\/tab color/);
});

test('waiting → working → your turn status markers', () => {
  clearTty('a');
  as('a', process.pid, () => hook('Notification', { session_id: 'A', notification_type: 'permission_prompt' }));
  assert.equal(S.readSession('A').status, 'waiting');
  assert.match(read('a'), /🔔 Auth refactor/);
  as('a', process.pid, () => hook('PostToolUse', { session_id: 'A', tool_name: 'Bash' }));
  assert.equal(S.readSession('A').status, 'busy');
  as('a', process.pid, () => hook('Stop', { session_id: 'A' }));
  assert.equal(S.readSession('A').status, 'idle');
  assert.match(read('a'), /✳ Auth refactor\x07$/);
});

test('turns are timed without the time spent waiting on you', () => {
  as('a', process.pid, () => hook('UserPromptSubmit', { session_id: 'A', prompt: 'add retries to the webhook handler' }));
  const started = S.readSession('A');
  assert.equal(started.status, 'busy');
  assert.ok(Math.abs(started.turnStartedAt - Date.now()) < 2000, 'turn start recorded');
  // Pretend the turn began 5 minutes ago and spent 2 of them on a permission prompt.
  S.patchSession('A', { status: 'waiting', turnStartedAt: Date.now() - 300_000, turnWaitMs: 60_000, waitingSince: Date.now() - 60_000 });
  as('a', process.pid, () => hook('PostToolUse', { session_id: 'A', tool_name: 'Bash' })); // prompt answered
  assert.ok(!S.readSession('A').waitingSince, 'waiting over');
  assert.ok(S.readSession('A').turnWaitMs >= 119_000, 'both waits counted');
  as('a', process.pid, () => hook('Stop', { session_id: 'A' }));
  const done = S.readSession('A');
  assert.equal(done.turnStartedAt, null);
  assert.ok(done.lastTurnMs > 175_000 && done.lastTurnMs < 185_000, `about 3 minutes of work, got ${done.lastTurnMs}`);
  assert.equal(done.turns.at(-1), done.lastTurnMs);
  // A turn with no recorded start (tabby installed mid-turn) adds nothing.
  as('a', process.pid, () => hook('Stop', { session_id: 'A' }));
  assert.equal(S.readSession('A').turns.length, done.turns.length);
  assert.equal(H.turnDuration({ turnStartedAt: Date.now() - 800 }), null, 'trivial turns are ignored');
});

test('a second live session gets a different color and marker', () => {
  clearTty('b');
  as('b', process.ppid, () => hook('SessionStart', { session_id: 'B', source: 'startup', cwd: '/work/web' }));
  const a = S.readSession('A');
  const b = S.readSession('B');
  assert.notEqual(`${a.theme}/${a.accentKey}`, `${b.theme}/${b.accentKey}`);
  assert.notEqual(a.marker, b.marker);
});

test('/tab theme <t> all recolors every live tab and becomes the default', () => {
  clearTty('a');
  clearTty('b');
  const out = as('a', process.pid, () => hook('UserPromptSubmit', { session_id: 'A', prompt: '/tab theme everforest all' }));
  assert.match(out.reason, /Everforest for all 2 tabs/);
  assert.equal(S.readSession('A').theme, 'everforest');
  assert.equal(S.readSession('B').theme, 'everforest');
  assert.equal(S.readConfig().theme, 'everforest');
  assert.match(read('b'), /\x1b\]11;#/);
});

test('/tab watermark turns the island watermark on and off', () => {
  const run = (prompt) => as('a', process.pid, () => hook('UserPromptSubmit', { session_id: 'A', prompt })).reason;
  assert.match(run('/tab watermark off'), /Watermark off/);
  assert.equal(S.readConfig().watermark, false);
  assert.match(run('/tab watermark'), /Watermark on.*⌃⌥W toggles it/);
  assert.equal(S.readConfig().watermark, true);
  S.writeConfig({ islandShortcuts: { watermark: 'cmd+shift+w' } });
  assert.match(run('/tab watermark off'), /or ⇧⌘W/);
  assert.match(run('/tab watermark maybe'), /Watermark: on \| off \(now off\)/);
  S.writeConfig({ watermark: true, islandShortcuts: {} });
});

test('/clear keeps the tab identity; exit restores the terminal', () => {
  const b = S.readSession('B');
  clearTty('b');
  as('b', process.ppid, () => hook('SessionEnd', { session_id: 'B', reason: 'clear' }));
  assert.equal(read('b'), '', 'no reset on /clear');
  as('b', process.ppid, () => hook('SessionStart', { session_id: 'C', source: 'clear', cwd: '/work/web' }));
  const c = S.readSession('C');
  assert.equal(c.theme, b.theme);
  assert.equal(c.accentKey, b.accentKey);
  assert.equal(S.readSession('B').status, 'ended');

  clearTty('b');
  as('b', process.ppid, () => hook('SessionEnd', { session_id: 'C', reason: 'prompt_input_exit' }));
  assert.match(read('b'), /\x1b\]111\x07/, 'background reset');
  assert.match(read('b'), /\x1b\]0;\x07/, 'title cleared');
  assert.equal(S.readSession('C').status, 'ended');
});

test('launch flags via environment', () => {
  process.env.TABBY_COLOR = 'pink';
  process.env.TABBY_THEME = 'kanagawa';
  process.env.TABBY_NAME = 'Release prep';
  clearTty('d');
  try {
    as('d', process.ppid, () => hook('SessionStart', { session_id: 'D', source: 'startup', cwd: '/work/rel' }));
  } finally {
    delete process.env.TABBY_COLOR;
    delete process.env.TABBY_THEME;
    delete process.env.TABBY_NAME;
  }
  const d = S.readSession('D');
  assert.equal(d.theme, 'kanagawa');
  assert.equal(d.accentKey, 'pink');
  assert.equal(d.title, 'Release prep');
  assert.equal(d.titleSource, 'manual');
  assert.match(read('d'), /Release prep/);
});

test('adopted sessions only take over the title once Claude stops drawing it', () => {
  S.patchSession('F', { sessionId: 'F', pid: process.ppid, tty: tty('f'), term: 'apple-terminal', cwd: '/work/old', project: 'old', theme: 'tabby', accentKey: 'green', accent: '#7fc489', bg: '#0f2317', fg: '#d1d4da', ownsTitle: false, status: 'idle', title: 'Old Claude Title', titleSource: 'claude', adopted: true });
  clearTty('f');
  delete process.env.CLAUDE_CODE_DISABLE_TERMINAL_TITLE;
  try {
    as('f', process.ppid, () => hook('UserPromptSubmit', { session_id: 'F', prompt: 'keep going' }));
  } finally {
    process.env.CLAUDE_CODE_DISABLE_TERMINAL_TITLE = '1';
  }
  assert.doesNotMatch(read('f'), /\x1b\]0;/, 'Claude still owns the title: no title written');
  assert.match(read('f'), /\x1b\]11;#0f2317\x07/, 'colors still applied');
  clearTty('f');
  as('f', process.ppid, () => hook('UserPromptSubmit', { session_id: 'F', prompt: 'and now?' }));
  assert.equal(S.readSession('F').ownsTitle, true);
  assert.match(read('f'), /\x1b\]0;🟢 ◐ Old Claude Title\x07/, 'title taken over after /reload-plugins, Claude\'s name kept');
});

test('hooks stay silent when disabled or internal', () => {
  process.env.TABBY_INTERNAL = '1';
  try {
    assert.equal(hook('SessionStart', { session_id: 'E' }), null);
    assert.equal(S.readSession('E'), null);
  } finally {
    delete process.env.TABBY_INTERNAL;
  }
});
