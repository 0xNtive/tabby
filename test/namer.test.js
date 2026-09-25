import { test } from 'node:test';
import assert from 'node:assert/strict';
import { heuristicTitle, cleanAiTitle, parseNamerOutput } from '../lib/namer.js';
import { isTabCommand, tabArgs } from '../lib/commands.js';
import { isSetupCommand, setupArgs } from '../lib/setup.js';
import { grid, cells } from '../lib/tile.js';
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
