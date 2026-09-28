// Update checks and notices, against a throwaway home (no network: TABBY_LATEST fakes GitHub).
import { test, before } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'tabby-update-'));
process.env.HOME = tmp;
process.env.TABBY_HOME = path.join(tmp, 'tabby');
process.env.CLAUDE_CONFIG_DIR = path.join(tmp, 'claude');
process.env.TABBY_NO_ISLAND = '1';
fs.mkdirSync(process.env.TABBY_HOME, { recursive: true });

let U, I;
before(async () => {
  U = await import('../lib/update.js');
  I = await import('../lib/island.js');
});

test('a newer release is reported, and the notice shows once a day per version', () => {
  const current = I.version();
  const [a, b, c] = current.split('.').map(Number);
  process.env.TABBY_LATEST = `${a}.${b}.${c + 1}`;
  const r = U.check();
  assert.equal(r.available, true);
  assert.equal(r.latest, process.env.TABBY_LATEST);
  assert.equal(U.cached().available, true, 'cached result');
  const cfg = { updateCheck: true };
  assert.match(U.notice(cfg), /is out .*\/tab update/);
  assert.equal(U.notice(cfg), null, 'not twice in a day');
  assert.equal(U.notice({ updateCheck: false }), null, 'off when checks are off');
});

test('the same or an older release is not an update', () => {
  process.env.TABBY_LATEST = I.version();
  assert.equal(U.check().available, false);
  process.env.TABBY_LATEST = '0.0.1';
  assert.equal(U.check().available, false);
});

test('background checks respect the setting and the 6-hour spacing', () => {
  const file = path.join(process.env.TABBY_HOME, 'update-check.json');
  fs.writeFileSync(file, JSON.stringify({ latest: '0.0.1', checkedAt: Date.now() }));
  U.checkInBackground({ updateCheck: true }); // fresh: nothing to do
  assert.equal(JSON.parse(fs.readFileSync(file, 'utf8')).latest, '0.0.1');
  fs.writeFileSync(file, JSON.stringify({ latest: '0.0.1', checkedAt: 0 }));
  U.checkInBackground({ updateCheck: false }); // off
  assert.equal(JSON.parse(fs.readFileSync(file, 'utf8')).checkedAt, 0);
});
