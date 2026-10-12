import { test } from 'node:test';
import assert from 'node:assert/strict';

process.env.TABBY_NO_TERMINAL_PROFILES = '1';
const { sequences, detectTerminal, caps, tmuxArgs, envOfPid } = await import('../lib/term.js');
const { targetOf } = await import('../lib/apply.js');
const { isTwin, useTwin, restoreProfile, twins, SUFFIX } = await import('../lib/terminal-prefs.js');
const { spawn } = await import('node:child_process');

test('titles are OSC 0, stripped of control characters', () => {
  // Terminal.app too: an OSC 1 tab title would show twice in a window with one tab.
  assert.equal(sequences('apple-terminal', { title: '🟢 ✳ Auth' }), '\x1b]0;🟢 ✳ Auth\x07');
  assert.equal(sequences('apple-terminal', { title: '' }), '\x1b]0;\x07', 'clearing');
  assert.equal(sequences('ghostty', { title: 'a\x07b' }), '\x1b]0;a b\x07', 'control characters never reach the terminal');
  assert.equal(sequences('apple-terminal', {}), '', 'no title, nothing written');
});

test('Terminal.app profile twins: naming, and no AppleScript when disabled', () => {
  assert.equal(SUFFIX, ' · tabby');
  assert.ok(isTwin('Man Page · tabby'));
  assert.ok(!isTwin('Man Page'));
  assert.ok(!isTwin(undefined));
  assert.equal(useTwin('/dev/ttys999'), null);
  assert.equal(restoreProfile('*'), 0);
  assert.deepEqual(twins(), []);
});

test('TERM_PROGRAM decides; marker variables only count without it', () => {
  // `code .` from an iTerm2 shell: VS Code inherits LC_TERMINAL but sets its own TERM_PROGRAM.
  assert.equal(detectTerminal({ TERM_PROGRAM: 'vscode', LC_TERMINAL: 'iTerm2' }), 'vscode');
  assert.equal(detectTerminal({ TERM_PROGRAM: 'Apple_Terminal', GHOSTTY_RESOURCES_DIR: '/x', WEZTERM_PANE: '0', KITTY_WINDOW_ID: '1' }), 'apple-terminal');
  assert.equal(detectTerminal({ TERM_PROGRAM: 'ghostty', LC_TERMINAL: 'iTerm2' }), 'ghostty');
  assert.equal(detectTerminal({ TERM_PROGRAM: 'iTerm.app' }), 'iterm2');
  assert.equal(detectTerminal({ LC_TERMINAL: 'iTerm2', TERM: 'xterm-256color' }), 'iterm2', 'over SSH: only LC_TERMINAL comes along');
  assert.equal(detectTerminal({ TERM: 'xterm-ghostty' }), 'ghostty');
  assert.equal(detectTerminal({ TERM: 'xterm-kitty', GHOSTTY_RESOURCES_DIR: '/x' }), 'kitty', "the tab's own TERM beats a leaked marker");
  assert.equal(detectTerminal({ TERM_PROGRAM: 'Hyper' }), 'hyper');
  assert.equal(caps('hyper').label, 'Hyper');
  for (const tp of ['zed', 'rio', 'SomethingNew']) assert.equal(detectTerminal({ TERM_PROGRAM: tp, LC_TERMINAL: 'iTerm2' }), 'generic', tp);
  assert.equal(detectTerminal({ TERM_PROGRAM: 'tmux' }), 'generic', 'a tmux the session is no longer in');
  assert.equal(detectTerminal({}), 'generic');
});

test('multiplexers come before the terminal around them', () => {
  assert.equal(detectTerminal({ TMUX: '/tmp/tmux-1000/default,123,0', TERM_PROGRAM: 'tmux', LC_TERMINAL: 'iTerm2' }), 'tmux');
  assert.equal(detectTerminal({ STY: '123.ttys001.host', TERM_PROGRAM: 'iTerm.app' }), 'screen');
  assert.equal(detectTerminal({ ZELLIJ: '0', TERM_PROGRAM: 'iTerm.app' }), 'zellij');
  assert.deepEqual([caps('screen').colors, caps('screen').tabColor, caps('screen').focus, caps('screen').marker], [false, false, false, true]);
  assert.deepEqual([caps('zellij').colors, caps('zellij').tabColor, caps('zellij').focus, caps('zellij').marker], [true, false, false, true]);
});

test('screen and Zellij never get iTerm2 tab colors; screen gets no color codes at all', () => {
  const look = { bg: '#1b1e23', fg: '#d1d4da', cursor: '#77b7f4', accent: '#77b7f4' };
  const all = { title: 'Auth', look, reset: true, tabColor: '#77b7f4' };
  assert.equal(sequences('screen', all), '\x1b]0;Auth\x07');
  const z = sequences('zellij', all);
  assert.ok(!z.includes('\x1b]6;'), 'no OSC 6');
  assert.match(z, /\x1b\]11;#1b1e23\x07/);
  assert.match(sequences('iterm2', all), /\x1b\]6;1;bg;red;brightness;119\x07/, 'iTerm2 still gets its tab color');
});

test('tmux commands name the server by its socket, when it is a clean absolute path', () => {
  const args = ['rename-window', '-t', '%3', 'x'];
  assert.deepEqual(tmuxArgs({ tmuxSocket: '/tmp/tmux-1000/default' }, args), ['-S', '/tmp/tmux-1000/default', ...args]);
  for (const bad of [undefined, null, '', 'default', '-L evil', '/tmp/a\nb', '/tmp/\x1b]0;x', 42]) assert.deepEqual(tmuxArgs({ tmuxSocket: bad }, args), args, String(bad));
  assert.deepEqual(tmuxArgs(null, args), args);
  const rec = { tty: '/dev/ttys001', term: 'tmux', tmuxPane: '%3', tmuxSocket: '/tmp/s', title: 'x' };
  assert.deepEqual(targetOf(rec), { tty: '/dev/ttys001', term: 'tmux', tmuxPane: '%3', tmuxSocket: '/tmp/s' });
});

test('envOfPid reads the environment, not KEY=val arguments', async () => {
  const env = { PATH: process.env.PATH, TERM_PROGRAM: 'Apple_Terminal', __CFBundleIdentifier: 'com.apple.Terminal', COLORTERM: 'truecolor' };
  const child = spawn(process.execPath, ['-e', 'setTimeout(() => {}, 20000)', 'TERM_PROGRAM=WezTerm', 'STY=1.fake', 'ZELLIJ=0'], { env, stdio: 'ignore' });
  try {
    await new Promise((resolve) => setTimeout(resolve, 150));
    const got = envOfPid(child.pid);
    assert.equal(got.TERM_PROGRAM, 'Apple_Terminal');
    assert.equal(got.__CFBundleIdentifier, 'com.apple.Terminal');
    assert.equal(got.COLORTERM, 'truecolor');
    assert.equal(got.STY, undefined, 'an argument is not the environment');
    assert.equal(got.ZELLIJ, undefined);
    assert.equal(detectTerminal(got), 'apple-terminal');
  } finally {
    child.kill();
  }
  assert.deepEqual(envOfPid(0), {});
});
