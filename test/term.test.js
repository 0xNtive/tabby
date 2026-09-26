import { test } from 'node:test';
import assert from 'node:assert/strict';

process.env.TABBY_NO_TERMINAL_PROFILES = '1';
const { sequences } = await import('../lib/term.js');
const { isTwin, useTwin, restoreProfile, twins, SUFFIX } = await import('../lib/terminal-prefs.js');

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
