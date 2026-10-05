// What tabby promises about privacy and safety, held in place: nothing in it talks to the
// network except the few places listed here, what a person typed leaves the machine only through
// the AI namer (and only while the namer is "ai"), state files are the owner's alone, and text
// from outside never carries control characters into a terminal.
import { test, before } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = fileURLToPath(new URL('..', import.meta.url));
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'tabby-privacy-'));
process.env.HOME = tmp;
process.env.TABBY_HOME = path.join(tmp, 'tabby');
process.env.CLAUDE_CONFIG_DIR = path.join(tmp, 'claude');
process.env.TABBY_NO_TERMINAL_PROFILES = '1';
process.env.TABBY_NO_ISLAND = '1';
process.env.TABBY_NO_UPDATE_CHECK = '1';
delete process.env.TMUX;
delete process.env.TABBY_INTERNAL;

// A stand-in for `claude`: records how it was called and answers like the namer's model would.
const fakeClaude = path.join(tmp, 'claude-fake');
const calls = path.join(tmp, 'calls');
fs.mkdirSync(calls);
fs.writeFileSync(
  fakeClaude,
  `#!/bin/sh\nn=$(ls "${calls}" | wc -l | tr -d ' ')\nprintf '%s\\n' "$@" > "${calls}/$n.argv"\ncat > "${calls}/$n.stdin"\nprintf '%s' '{"result":"{\\"title\\": \\"Stripe Webhook Retries\\", \\"summary\\": \\"Retrying failed webhooks.\\"}"}'\n`,
  { mode: 0o755 }
);
process.env.CLAUDE_CODE_EXECPATH = fakeClaude;
const callCount = () => fs.readdirSync(calls).filter((n) => n.endsWith('.argv')).length;

let S, N, T, C, I;
before(async () => {
  S = await import('../lib/state.js');
  N = await import('../lib/namer.js');
  T = await import('../lib/term.js');
  C = await import('../lib/commands.js');
  I = await import('../lib/install.js');
});

const sources = (dir, ext) =>
  fs.readdirSync(path.join(ROOT, dir)).filter((n) => ext.some((e) => n.endsWith(e))).map((n) => path.join(dir, n));

test('the CLI has no network code of its own: only curl, only in the updater and the island download', () => {
  const files = [...sources('lib', ['.js']), ...sources('bin', ['.js', '.sh']), ...sources('hooks', ['.sh', '.json']), ...sources('shell', ['.sh']), ...sources('scripts', ['.js'])];
  const forbidden = /from ['"](?:node:)?(?:https?|http2|net|tls|dgram|dns)['"]|require\(['"](?:node:)?(?:https?|http2|net|tls|dgram|dns)['"]\)|\bfetch\s*\(|XMLHttpRequest|WebSocket|EventSource|sendBeacon/;
  const curls = [];
  for (const file of files) {
    const text = fs.readFileSync(path.join(ROOT, file), 'utf8');
    assert.ok(!forbidden.test(text), `${file} uses a network API`);
    // A call, not the word in a message telling someone how to reinstall.
    if (/run\('curl'|spawnSync\('curl'|\bcurl -[a-zA-Z]+ [^|]*\$\{/.test(text)) curls.push(file);
    assert.ok(!/\b(?:wget|nc|ncat|scp|rsync|ssh)\s+-/.test(text), `${file} runs a network tool`);
  }
  assert.deepEqual(curls.sort(), ['lib/island.js', 'lib/update.js'], 'curl is called only by the updater and the island download');
  // Those two talk to GitHub and nowhere else.
  for (const file of curls) {
    const hosts = [...fs.readFileSync(path.join(ROOT, file), 'utf8').matchAll(/https?:\/\/([a-z0-9.-]+)/g)].map((m) => m[1]);
    for (const host of hosts) assert.ok(['github.com', 'codeload.github.com', 'claude-tabby.vercel.app', 'www.apple.com'].includes(host), `${file} names ${host}`);
  }
});

test('Tabby Island has no network code at all', () => {
  const forbidden = /URLSession|URLRequest|NSURLConnection|CFNetwork|NWConnection|import Network|WKWebView|import WebKit|CFSocket|CFStream|NSURLDownload|AsyncImage/;
  for (const file of sources('island/Sources', ['.swift'])) {
    assert.ok(!forbidden.test(fs.readFileSync(path.join(ROOT, file), 'utf8')), `${file} uses a network API`);
  }
});

test('state under ~/.claude/tabby is the owner’s alone', () => {
  S.patchSession('P1', { prompts: ['a prompt nobody else should read'], cwd: '/work/secret-project' });
  S.writeConfig({ namer: 'heuristic' });
  S.log('a line');
  const mode = (p) => fs.statSync(p).mode & 0o777;
  assert.equal(mode(S.paths.root), 0o700);
  assert.equal(mode(S.paths.sessions), 0o700);
  assert.equal(mode(path.join(S.paths.sessions, 'P1.json')), 0o600);
  assert.equal(mode(S.paths.config), 0o600);
  assert.equal(mode(S.paths.log), 0o600);
  // A folder an older tabby made world-readable is tightened the next time tabby runs.
  fs.chmodSync(S.paths.root, 0o755);
  fs.chmodSync(S.paths.sessions, 0o755);
  S.ensureDirs();
  assert.equal(mode(S.paths.root), 0o700);
  assert.equal(mode(S.paths.sessions), 0o700);
});

test('rewriting a file that isn’t tabby’s keeps its mode and its symlink', () => {
  const real = path.join(tmp, 'dotfiles', 'settings.json');
  fs.mkdirSync(path.dirname(real), { recursive: true });
  fs.writeFileSync(real, '{"a":1}\n', { mode: 0o640 });
  fs.chmodSync(real, 0o640);
  const link = path.join(tmp, 'settings-link.json');
  fs.symlinkSync(real, link);
  S.writeJson(link, { a: 2 });
  assert.ok(fs.lstatSync(link).isSymbolicLink(), 'still a symlink');
  assert.deepEqual(JSON.parse(fs.readFileSync(real, 'utf8')), { a: 2 });
  assert.equal(fs.statSync(real).mode & 0o777, 0o640);
});

test('a settings.json that isn’t valid JSON is left exactly as it is', () => {
  fs.mkdirSync(S.paths.claudeDir, { recursive: true });
  const broken = '{\n  // my own comment\n  "model": "opus",\n}\n';
  fs.writeFileSync(S.paths.settings, broken);
  const steps = I.install({ shell: false, plugin: false, terminalTitles: false });
  assert.equal(fs.readFileSync(S.paths.settings, 'utf8'), broken);
  assert.ok(steps.some((s) => /isn't valid JSON/.test(s)), steps.join('\n'));
  fs.rmSync(S.paths.settings);
});

test('the namer sends the prompt on stdin, the folder’s name but never its path, and can use no tools', () => {
  const rec = { project: 'api', cwd: '/Users/someone/clients/acme-secret/api', prompts: ['retry failed stripe webhooks'], title: '' };
  const prompt = N.namerPrompt(rec, 'I will add exponential backoff.');
  assert.ok(prompt.includes('Project: api'));
  assert.ok(!prompt.includes('/Users/someone') && !prompt.includes('acme-secret'), 'no path');
  const before = callCount();
  assert.deepEqual(N.callHaiku(prompt, { claudeBin: fakeClaude }), { title: 'Stripe Webhook Retries', summary: 'Retrying failed webhooks.' });
  const argv = fs.readFileSync(path.join(calls, `${before}.argv`), 'utf8');
  const stdin = fs.readFileSync(path.join(calls, `${before}.stdin`), 'utf8');
  assert.ok(!argv.includes('retry failed stripe webhooks'), 'the prompt is not on the command line (ps shows that to every account)');
  assert.equal(stdin, prompt);
  const args = argv.trimEnd().split('\n');
  assert.ok(args.includes('--safe-mode') && args.includes('--no-session-persistence'));
  assert.equal(args[args.indexOf('--tools') + 1], '', 'no tools');
});

test('with the namer on "heuristic" or "off", nothing calls the model', () => {
  S.patchSession('H1', { prompts: ['fix the flaky login tests'], promptCount: 1, titleSource: 'project', title: '', tty: path.join(tmp, 'h1.tty'), term: 'apple-terminal', cwd: '/work/api', project: 'api', theme: 'tabby', accentKey: 'blue' });
  for (const namer of ['heuristic', 'off']) {
    S.writeConfig({ namer });
    const before = callCount();
    N.runNamer('H1');
    for (const command of ['auto', 'reset', 'name']) C.runCommand(command, { rec: S.readSession('H1'), cfg: S.readConfig() });
    assert.equal(callCount(), before, `${namer}: no call`);
  }
  S.writeConfig({ namer: 'heuristic' });
  const out = C.runCommand('auto', { rec: S.readSession('H1'), cfg: S.readConfig() });
  assert.match(out.message, /named on this machine/);
  assert.equal(S.readSession('H1').title, 'Fix Flaky Login Tests');
  assert.equal(S.readSession('H1').titleSource, 'heuristic');
  S.writeConfig({ namer: 'ai' });
  const before = callCount();
  N.runNamer('H1');
  assert.equal(callCount(), before + 1, 'ai: one call');
  assert.equal(S.readSession('H1').title, 'Stripe Webhook Retries');
  S.writeConfig({ namer: 'heuristic' });
});

test('control characters and bidi overrides never reach a title, a summary or the terminal', () => {
  const hostile = JSON.stringify({ result: JSON.stringify({ title: 'Auth\u001b]0;PWN\u0007 Fix', summary: 'ok\u001b]52;c;ZXZpbA==\u0007 \u009d0;x\u009c ‮evil' }) });
  const parsed = N.parseNamerOutput(hostile);
  assert.ok(!/[\x00-\x1f\x7f-\x9f‪-‮⁦-⁩]/.test(parsed.title + parsed.summary), JSON.stringify(parsed));
  assert.equal(S.plain('a\u001bb\u0007c\u009bd‮e'), 'a b c d e');
  assert.equal(T.cleanTitle('x\u009d0;spoof\u009c y‮'), 'x 0;spoof y');
  assert.equal(S.projectName('/work/bad\u001b[31mname'), 'bad [31mname');
  // A title is text in the format string, never a replacement pattern.
  const rec = { title: 'Costs $& more', status: 'idle', term: 'ghostty' };
  assert.ok(T.sequences('ghostty', { title: 'Costs $& more' }).includes('Costs $& more'));
  assert.equal(rec.title, 'Costs $& more');
});

test('/tab strength only takes its own three words', () => {
  const cfg = S.readConfig();
  for (const word of ['constructor', 'toString', '__proto__', '']) {
    assert.match(C.runCommand(`strength ${word}`, { rec: S.readSession('H1'), cfg }).message, /^Strength: /);
  }
  assert.equal(S.readConfig().strength, cfg.strength);
});
