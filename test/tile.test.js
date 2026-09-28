// Screens, layouts, choosing sessions to tile, recent folders and `tabby new` (no windows move).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'tabby-tile-test-'));
process.env.TABBY_HOME = path.join(tmp, 'tabby');
process.env.CLAUDE_CONFIG_DIR = path.join(tmp, 'claude');

const S = await import('../lib/screens.js');
const T = await import('../lib/tile.js');
const R = await import('../lib/recent.js');
const L = await import('../lib/launch.js');

// A laptop (left, notch), a landscape main screen, and a portrait monitor on the right.
const screens = S.sortScreens(
  [
    { uuid: 'MAIN', name: 'HP E273q', primary: true, current: true, full: { x: 0, y: 0, w: 2560, h: 1440 }, frame: { x: 0, y: 30, w: 2560, h: 1328 } },
    { uuid: 'LAPTOP', name: 'Built-in Retina Display', builtin: true, notch: 32, full: { x: -1512, y: 458, w: 1512, h: 982 }, frame: { x: -1512, y: 490, w: 1512, h: 950 } },
    { uuid: null, name: 'DELL U2720Q', full: { x: 2560, y: -600, w: 1440, h: 2560 }, frame: { x: 2560, y: -575, w: 1440, h: 2535 } },
  ].map((s) => ({ ...s, key: S.screenKey(s), portrait: s.full.h > s.full.w })),
);

test('screens are keyed by display UUID, or name and size when macOS has none', () => {
  assert.deepEqual(screens.map((s) => s.key), ['LAPTOP', 'MAIN', 'DELL U2720Q@1440x2560']);
  assert.ok(screens[2].portrait);
  assert.match(S.describe(screens[1]), /HP E273q {2}2560×1440 {2}\(main, current\)/);
});

test('picking screens by number, name or key; "all" and "current"', () => {
  assert.deepEqual(S.parseSelection('3', screens), { value: ['DELL U2720Q@1440x2560'] });
  assert.deepEqual(S.parseSelection('dell, 1', screens), { value: ['DELL U2720Q@1440x2560', 'LAPTOP'] });
  assert.deepEqual(S.parseSelection('all', screens), { value: 'all' });
  assert.deepEqual(S.parseSelection('', screens), { value: 'current' });
  assert.match(S.parseSelection('7', screens).error, /No screen "7"/);
});

test('only the chosen screens are used, and an unplugged one falls back', () => {
  assert.deepEqual(S.chooseScreens(screens, 'current').screens.map((s) => s.key), ['MAIN']);
  assert.equal(S.chooseScreens(screens, 'all').screens.length, 3);
  const vertical = S.chooseScreens(screens, ['DELL U2720Q@1440x2560']);
  assert.deepEqual(vertical.screens.map((s) => s.name), ['DELL U2720Q'], 'the main screen stays free');
  const half = S.chooseScreens(screens, ['DELL U2720Q@1440x2560', 'GONE']);
  assert.equal(half.screens.length, 1);
  assert.match(half.note, /isn't connected/);
  const none = S.chooseScreens(screens, ['GONE']);
  assert.deepEqual(none.screens.map((s) => s.key), ['MAIN']);
  assert.match(none.note, /None of your chosen screens/);
});

test('a portrait screen stacks rows; a landscape one lines up columns', () => {
  assert.deepEqual(S.grid(3), [3, 1]);
  assert.deepEqual(S.grid(3, 1440 / 2560), [1, 3]);
  assert.deepEqual(S.grid(8, 0.5), [2, 4]);
  const rows = S.cells(3, screens[2].frame, 6);
  assert.equal(new Set(rows.map((r) => r[0])).size, 1, 'one column');
  assert.ok(rows.every((r) => r[2] - r[0] > r[3] - r[1]), 'each cell wider than tall');
  assert.ok(rows.every((r) => r[1] >= screens[2].frame.y && r[3] <= screens[2].frame.y + screens[2].frame.h));
});

test('windows spread over screens by area, the biggest first when there are few', () => {
  assert.deepEqual(S.distribute(1, screens), [0, 0, 1], 'the portrait 4K has the most room');
  assert.deepEqual(S.distribute(6, screens).reduce((a, b) => a + b), 6);
  const placed = S.layout(6, screens);
  assert.equal(placed.length, 6);
  for (const { rect, screen } of placed) {
    const f = screen.frame;
    assert.ok(rect[0] >= f.x && rect[2] <= f.x + f.w && rect[1] >= f.y && rect[3] <= f.y + f.h, `inside ${screen.name}`);
  }
  assert.equal(T.gridSummary(S.layout(4, [screens[1]]), [screens[1]]), 'a 2×2 grid');
  assert.match(T.gridSummary(S.layout(4, screens), screens), / on .* and /);
});

test('full screen is spotted on any display', () => {
  assert.ok(S.fullScreenOn('-1512,490,0,1440', screens), 'the laptop, below its notch');
  assert.ok(S.fullScreenOn('2560,-600,4000,1960', screens));
  assert.ok(!S.fullScreenOn('2566,-569,3994,1954', screens), 'a window filling the visible frame is not full screen');
});

test('"only active" means working or needs you', () => {
  const list = [{ status: 'busy' }, { status: 'waiting' }, { status: 'idle' }, { status: 'new' }, { status: 'error' }, { status: 'shell' }];
  assert.deepEqual(list.filter(T.isActive).map((s) => s.status), ['busy', 'waiting']);
});

test('--only picks by number, id, tty, title or project', () => {
  const list = [
    { sessionId: 'aaaaaaaa-1', title: 'Auth refactor', project: 'api', tty: '/dev/ttys001' },
    { sessionId: 'bbbbbbbb-2', title: 'Landing page', project: 'site', tty: '/dev/ttys002' },
    { sessionId: 'cccccccc-3', claudeName: 'Fix flaky test', project: 'api', tty: '/dev/ttys003' },
  ];
  const ids = (spec) => T.pickSessions(list, spec).picked.map((s) => s.sessionId);
  assert.deepEqual(ids('2'), ['bbbbbbbb-2']);
  assert.deepEqual(ids('1, 3'), ['aaaaaaaa-1', 'cccccccc-3']);
  assert.deepEqual(ids('cccccccc'), ['cccccccc-3']);
  assert.deepEqual(ids('ttys002'), ['bbbbbbbb-2']);
  assert.deepEqual(ids('landing'), ['bbbbbbbb-2']);
  assert.deepEqual(ids('flaky,auth,1'), ['cccccccc-3', 'aaaaaaaa-1'], 'no duplicates');
  assert.deepEqual(ids('api'), ['aaaaaaaa-1'], 'a project matches its first session');
  assert.deepEqual(T.pickSessions(list, 'nope,9').missing, ['nope', '9']);
});

test('frecency: recent and frequent folders first, gone and temporary ones never', () => {
  const now = Date.UTC(2026, 8, 28, 12);
  const h = 3600e3;
  const visits = [
    ...Array.from({ length: 12 }, (_, i) => ({ path: '/w/old-favorite', at: now - (20 + i) * 24 * h })),
    { path: '/w/today', at: now - 2 * h },
    { path: '/w/today', at: now - 3 * h },
    { path: '/w/running', at: now, live: true },
    { path: '/w/gone', at: now - h },
    { path: '/tmp/scratch', at: now - h },
    { path: os.tmpdir() + '/x', at: now - h },
    { path: 'relative/path', at: now },
    { path: '/w/Today/', at: now - 30 * 24 * h },
  ];
  const resolve = (p) => (p.includes('gone') ? null : p.replace(/\/+$/, '').replace('/w/Today', '/w/today'));
  const ranked = R.rankFolders(visits, { now, resolve });
  assert.deepEqual(ranked.map((f) => f.path), ['/w/today', '/w/old-favorite', '/w/running']);
  const today = ranked[0];
  assert.equal(today.sessions, 3, 'one folder, however it was spelled');
  assert.equal(today.lastUsed, now - 2 * h);
  assert.equal(ranked.find((f) => f.path === '/w/running').live, 1);
  assert.ok(R.weight(h) > R.weight(2 * 24 * h) && R.weight(2 * 24 * h) > R.weight(60 * 24 * h));
});

test('tabby new: the command, the terminal and where the window goes', () => {
  assert.equal(L.claudeCommand('/w/my app', { name: "Bob's fix", dangerous: true }), `cd '/w/my app' && claude --name 'Bob'\\''s fix' --dangerously-skip-permissions`);
  assert.equal(L.claudeCommand('/w', {}), `cd '/w' && claude`);
  assert.equal(L.pickTerminal('iterm'), 'iterm2');
  assert.equal(L.pickTerminal(undefined, 'apple-terminal'), 'apple-terminal');
  assert.equal(L.pickTerminal(undefined, 'vscode', [{ term: 'iterm2' }, { term: 'iterm2' }, { term: 'apple-terminal' }]), 'iterm2', 'from an editor: the terminal your sessions use');
  assert.equal(L.pickTerminal(undefined, 'generic', []), 'apple-terminal');
  assert.equal(L.placement(undefined, { tileScreens: 'current' }, screens), null, 'default: wherever the terminal opens it');
  const vertical = L.placement(undefined, { tileScreens: ['DELL U2720Q@1440x2560'] }, screens);
  assert.equal(vertical.screen.name, 'DELL U2720Q');
  const [l, t, r, b] = vertical.rect;
  assert.ok(l > 2560 && r < 4000 && t > -575 && b < 1960, 'centered on the vertical monitor');
  assert.equal(L.placement('1', {}, screens).screen.key, 'LAPTOP');
  assert.match(L.placement('9', {}, screens).error, /No screen/);
  assert.match(L.launchScript('apple-terminal', 'claude', [1, 2, 3, 4]), /set bounds of front window to \{1, 2, 3, 4\}/);
  assert.match(L.launchScript('iterm2', 'say "hi"', null), /write text "say \\"hi\\""/);
  const folders = [{ name: 'tabby', path: '/w/tabby' }, { name: 'levercat', path: '/w/levercat' }];
  assert.deepEqual(L.resolveFolder('lever', folders), { dir: '/w/levercat', loose: true });
  assert.match(L.newSession({ dir: 'lever', dangerous: true, dryRun: true, folders }), /only partly matches/, 'no skipping permissions on a guess');
  assert.deepEqual(L.resolveFolder(tmp, folders), { dir: tmp });
  assert.match(L.resolveFolder('nothing-like-it', folders).error, /No folder/);
  assert.match(L.resolveFolder('/no/such/dir', folders).error, /No such folder/);
});
