import { test } from 'node:test';
import assert from 'node:assert/strict';
import { heuristicTitle, cleanAiTitle, parseNamerOutput } from '../lib/namer.js';
import { isTabCommand, tabArgs } from '../lib/commands.js';
import { isSetupCommand, setupArgs } from '../lib/setup.js';
import { grid, cells, landed, placeable, fullScreen } from '../lib/tile.js';
import { frameTitle } from '../lib/ticker.js';
import { DEFAULT_CONFIG } from '../lib/state.js';

test('heuristic titles drop filler and keep the task', () => {
  assert.equal(heuristicTitle('okay so can you fix the flaky login tests in the auth module'), 'Fix Flaky Login Tests');
  assert.equal(heuristicTitle('Please add Stripe webhook retries'), 'Add Stripe Webhook Retries');
  assert.equal(heuristicTitle('```js\nfoo()\n```'), '');
  assert.ok(heuristicTitle('uh I need you to refactor the payments service to use the new ledger API').length <= 28);
});

test('AI output parsing is forgiving (code fences, structured output) and strict on content', () => {
  const fenced = JSON.stringify({ result: '```json\n{"title": "Terminal Tab Manager", "summary": "Building a tab organizer."}\n```' });
  assert.deepEqual(parseNamerOutput(fenced), { title: 'Terminal Tab Manager', summary: 'Building a tab organizer.' });
  const structured = JSON.stringify({ result: '', structured_output: { title: 'Tab Themes', summary: 's' } });
  assert.equal(parseNamerOutput(structured).title, 'Tab Themes');
  assert.equal(parseNamerOutput('nonsense'), null);
  assert.equal(parseNamerOutput(JSON.stringify({ result: '{"title": ""}' })), null);
  assert.equal(cleanAiTitle('"🚀 Deploy Pipeline Fix."'), 'Deploy Pipeline Fix');
  assert.ok(cleanAiTitle('A Very Long Title That Keeps Going Past The Limit For Tabs').length <= 32);
  assert.equal(cleanAiTitle('Tabby Process Killer And Session History'), 'Tabby Process Killer', 'never ends on a joining word');
  assert.equal(cleanAiTitle('Search And Replace'), 'Search And Replace', 'short names keep their words');
});

test('/tab detection', () => {
  assert.ok(isTabCommand('/tab'));
  assert.ok(isTabCommand('/tab color teal'));
  assert.ok(isTabCommand('  /tabby:tab theme nord'));
  assert.ok(!isTabCommand('/table stuff'));
  assert.ok(!isTabCommand('please /tab this'));
  assert.equal(tabArgs('/tab   theme nord all'), 'theme nord all');
});

test('/tabby:setup detection', () => {
  assert.ok(isSetupCommand('/tabby:setup'));
  assert.ok(isSetupCommand('/tabby:setup accept'));
  assert.ok(isSetupCommand('/tab setup'));
  assert.ok(!isSetupCommand('/tab setupx'));
  assert.equal(setupArgs('/tabby:setup Accept'), 'accept');
  assert.equal(setupArgs('/tab setup island'), 'island');
});

test('tiling grids fill the screen', () => {
  assert.deepEqual(grid(4), [2, 2]);
  assert.deepEqual(grid(6), [3, 2]);
  assert.deepEqual(grid(8), [4, 2]);
  assert.deepEqual(grid(3), [3, 1]);
  const r = cells(4, { x: 0, y: 25, w: 1000, h: 800 }, 10);
  assert.equal(r.length, 4);
  assert.deepEqual(r[0], [10, 35, 495, 420]);
  assert.deepEqual(r[3], [505, 430, 990, 815], "10 px gutters on every side");
});

test('title animation frames', () => {
  const cfg = { ...DEFAULT_CONFIG };
  const rec = { title: 'Auth', status: 'busy', term: 'apple-terminal', accent: '#77b7f4' };
  const frames = [0, 1, 2, 3].map((t) => frameTitle(rec, cfg, t));
  assert.equal(new Set(frames).size, 4, 'the spinner moves');
  assert.ok(frames.every((f) => f.endsWith('Auth')));
  const waiting = [0, 4].map((t) => frameTitle({ ...rec, status: 'waiting' }, cfg, t));
  assert.ok(waiting[0].includes('🔔') && !waiting[1].includes('🔔'), 'the bell blinks');
});

test('a tiled window counts as placed despite character-cell snapping', () => {
  assert.ok(landed('6,39,502,894', [6, 39, 502, 894]));
  assert.ok(landed('6, 39, 489, 880', [6, 39, 502, 894]), 'Terminal rounds the size down to whole cells');
  assert.ok(!landed('0,33,1512,982', [6, 39, 502, 894]), 'a window left full screen is not placed');
  assert.ok(!landed('', [6, 39, 502, 894]));
});

test('tiling never resizes a background tab: only windows on screen are placed', () => {
  const byTty = new Map([
    ['/dev/ttys000', { id: 1, bounds: '6,39,502,894' }],
    ['/dev/ttys001', { id: 2, bounds: '0,33,1512,982' }], // front tab of a group
    ['/dev/ttys003', { id: 3, bounds: '0,33,1512,982' }], // background tab of the same group
  ]);
  const ttys = [...byTty.keys()];
  const { units, skipped } = placeable('Terminal', ttys, byTty, new Set([1, 2]));
  assert.deepEqual(units.map((u) => u.id), [1, 2]);
  assert.deepEqual(skipped, ['/dev/ttys003']);
  const sameFrame = placeable('Terminal', ttys, byTty, new Set([1, 2, 3]));
  assert.equal(sameFrame.units.length, 3, 'separate windows that share a frame are all placed');
  assert.equal(placeable('iTerm2', ttys, byTty, null).units.length, 3, 'iTerm2 windows hold their own tabs');
});

test('a full-screen window is never resized (it would shrink inside its own desktop)', () => {
  const screen = { x: 0, y: 33, w: 1512, h: 867, screenW: 1512, screenH: 982 };
  assert.ok(fullScreen('0,33,1512,982', screen), 'full screen below the camera notch');
  assert.ok(fullScreen('0,0,1512,982', screen));
  assert.ok(!fullScreen('0,33,1512,900', screen), 'a maximized window above the Dock');
  assert.ok(!fullScreen('6,39,502,894', screen));
  const byTty = new Map([['/dev/ttys000', { id: 1, bounds: '6,39,502,894' }], ['/dev/ttys001', { id: 2, bounds: '0,33,1512,982' }]]);
  const { units, skipped } = placeable('Terminal', [...byTty.keys()], byTty, new Set([1, 2]), screen);
  assert.deepEqual(units.map((u) => u.id), [1]);
  assert.deepEqual(skipped, ['/dev/ttys001']);
});
