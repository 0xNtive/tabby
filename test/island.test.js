// The ready-made island is installed only when its signature checks out (lib/island.js).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

process.env.TABBY_HOME = fs.mkdtempSync(path.join(os.tmpdir(), 'tabby-island-'));
process.env.TABBY_NO_ISLAND = '1';
const { signed, download } = await import('../lib/island.js');

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'tabby-island-zip-'));
const zip = path.join(tmp, 'TabbyIsland.zip');
fs.writeFileSync(zip, crypto.randomBytes(4096));
const { publicKey, privateKey } = crypto.generateKeyPairSync('ed25519');
const sign = (file, key = privateKey) => crypto.sign(null, fs.readFileSync(file), key).toString('base64') + '\n';

test('a zip is accepted only with a signature from the key tabby trusts', () => {
  assert.equal(signed(zip, sign(zip), publicKey), true);
  const changed = path.join(tmp, 'changed.zip');
  const bytes = Buffer.from(fs.readFileSync(zip));
  bytes[100] ^= 1;
  fs.writeFileSync(changed, bytes);
  assert.equal(signed(changed, sign(zip), publicKey), false, 'one bit changed');
  assert.equal(signed(zip, sign(zip, crypto.generateKeyPairSync('ed25519').privateKey), publicKey), false, 'another key');
  assert.equal(signed(zip, sign(zip)), false, 'not the release key');
  for (const junk of ['', 'not base64', 'AAAA', null, undefined]) assert.equal(signed(zip, junk, publicKey), false, String(junk));
});

test('a zip of your own (TABBY_ISLAND_URL) is refused inside Claude Code', () => {
  const ROOT = fileURLToPath(new URL('..', import.meta.url));
  const script = `import { download } from ${JSON.stringify(path.join(ROOT, 'lib', 'island.js'))}; console.log(JSON.stringify(download()));`;
  const run = (env) => JSON.parse(spawnSync(process.execPath, ['--input-type=module', '-e', script], { encoding: 'utf8', env: { ...process.env, TABBY_ISLAND_URL: `file://${zip}`, CLAUDECODE: '', CLAUDE_PROJECT_DIR: '', ...env } }).stdout);
  assert.match(run({ CLAUDE_PROJECT_DIR: '/some/repo' }).error, /ignored/);
  assert.match(run({ CLAUDECODE: '1' }).error, /ignored/);
  // In a shell of your own it's used (this one isn't a real app, so it fails to unpack).
  assert.match(run({}).error, /could not unpack/);
  assert.equal(typeof download, 'function');
});
