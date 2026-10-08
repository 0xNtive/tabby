// Colors after tiling (spreadLooks) and the tile lock that carries progress (no windows move).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'tabby-spread-test-'));
process.env.TABBY_HOME = path.join(tmp, 'tabby');
process.env.CLAUDE_CONFIG_DIR = path.join(tmp, 'claude');

const A = await import('../lib/assign.js');
const T = await import('../lib/tile.js');
const { getTheme, accentHex, ACCENT_KEYS } = await import('../lib/themes.js');
const { hexToOklch, hueDistance } = await import('../lib/color.js');

const frame = { x: 0, y: 33, w: 1512, h: 949 };
const grid = (n, looks = []) =>
  T.cells(n, frame).map((rect, i) => ({ rect, rec: { sessionId: `s${i}`, theme: 'midnight', accentKey: 'blue', ...looks[i] } }));
const apply = (items, looks) =>
  items.map((it) => ({ ...it, rec: { ...it.rec, ...looks.find((l) => l.sessionId === it.rec.sessionId) } }));
const hue = (rec) => hexToOklch(accentHex(getTheme(rec.theme), rec.accentKey)).h;

test('windows that share an edge are neighbors; diagonal ones are not', () => {
  assert.deepEqual(A.neighbors(T.cells(4, frame)), [[0, 1], [0, 2], [1, 3], [2, 3]]);
  assert.deepEqual(A.neighbors(T.cells(3, frame)), [[0, 1], [1, 2]]);
  assert.deepEqual(A.neighbors([[0, 0, 100, 100], [500, 0, 600, 100]]), [], 'far apart');
});

test('a tiled grid gets one color per window, windows side by side far apart', () => {
  for (const n of [2, 3, 4, 6, 8]) {
    const items = grid(n);
    const done = apply(items, A.spreadLooks(items, { theme: 'midnight', auto: 'tint' }));
    const keys = done.map((it) => it.rec.accentKey);
    assert.equal(new Set(keys).size, n, `${n} windows, ${n} colors: ${keys}`);
    for (const [a, b] of A.neighbors(done.map((it) => it.rect))) {
      assert.ok(hueDistance(hue(done[a].rec), hue(done[b].rec)) >= 60, `${n}: ${keys[a]} next to ${keys[b]}`);
    }
    assert.ok(done.every((it) => it.rec.theme === 'midnight'), 'tint mode keeps the theme');
  }
});

test('tiling again changes nothing: the colors are already the best set', () => {
  const items = grid(4);
  const first = A.spreadLooks(items, { theme: 'midnight' });
  assert.equal(first.length >= 3, true);
  assert.deepEqual(A.spreadLooks(apply(items, first), { theme: 'midnight' }), []);
});

test('a window keeps its color when it is already part of a good set', () => {
  const items = grid(2, [{ accentKey: 'blue' }, { accentKey: 'orange' }]);
  assert.deepEqual(A.spreadLooks(items, { theme: 'midnight' }), []);
});

test('hand-picked colors stay, and the rest steer clear of them', () => {
  const items = grid(4, [{ accentKey: 'teal', lookSource: 'manual' }]);
  const looks = A.spreadLooks(items, { theme: 'midnight' });
  assert.ok(!looks.some((l) => l.sessionId === 's0'), 'the hand-picked one is left alone');
  const keys = apply(items, looks).map((it) => it.rec.accentKey);
  assert.equal(keys[0], 'teal');
  assert.equal(new Set(keys).size, 4, keys.join());
});

test('colors of sessions outside the grid are avoided while there is room', () => {
  const items = grid(2);
  const looks = A.spreadLooks(items, { theme: 'midnight' }, [{ accentKey: 'orange' }, { accentKey: 'blue' }]);
  const keys = apply(items, looks).map((it) => it.rec.accentKey);
  assert.ok(!keys.includes('orange') && !keys.includes('blue'), keys.join());
});

test('in themes mode every window also gets its own theme, with a hue the theme has', () => {
  const items = grid(4);
  const done = apply(items, A.spreadLooks(items, { theme: 'midnight', auto: 'themes' }));
  assert.equal(new Set(done.map((it) => it.rec.theme)).size, 4);
  for (const it of done) assert.ok(getTheme(it.rec.theme).accents[it.rec.accentKey], `${it.rec.theme} has ${it.rec.accentKey}`);
});

test('more windows than colors: every color once before any comes back', () => {
  const items = grid(10);
  const keys = apply(items, A.spreadLooks(items, { theme: 'midnight' })).map((it) => it.rec.accentKey);
  assert.equal(new Set(keys).size, ACCENT_KEYS.length, keys.join());
  for (const [a, b] of A.neighbors(items.map((it) => it.rect))) assert.notEqual(keys[a], keys[b], `${a} and ${b} touch`);
});

test('the tile lock refuses a second tile, in the old and the new format, and gives up after a minute', () => {
  const lock = path.join(process.env.TABBY_HOME, 'tile.lock');
  fs.mkdirSync(path.dirname(lock), { recursive: true });
  fs.writeFileSync(lock, `${process.pid} ${Date.now()}`);
  assert.equal(T.tile(undefined, { ttys: [] }), 'Already tiling, one moment.');
  fs.writeFileSync(lock, JSON.stringify({ pid: process.pid, at: Date.now(), text: 'Placing 2 windows', fraction: 0.75 }));
  assert.equal(T.tile(undefined, { ttys: [] }), 'Already tiling, one moment.');
  fs.writeFileSync(lock, JSON.stringify({ pid: process.pid, at: Date.now() - 61_000 }));
  assert.match(T.tile(undefined, { ttys: [] }), /^No Claude sessions/);
  assert.ok(!fs.existsSync(lock), 'released afterwards');
});

test('progress outside a tile writes nothing', () => {
  T.progress('Placing 2 windows', 0.75);
  assert.ok(!fs.existsSync(path.join(process.env.TABBY_HOME, 'tile.lock')));
});
