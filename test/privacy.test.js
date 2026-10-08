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
  `#!/bin/sh\nn=$(ls "${calls}" | grep -c '\\.argv$')\nprintf '%s\\n' "$@" > "${calls}/$n.argv"\ncat > "${calls}/$n.stdin"\npwd > "${calls}/$n.pwd"\nprintf '%s' '{"result":"{\\"title\\": \\"Stripe Webhook Retries\\", \\"summary\\": \\"Retrying failed webhooks.\\"}"}'\n`,
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

test('the CLI has no network code of its own: network tools run only in the updater, the island download and the installer', () => {
  const files = [...sources('lib', ['.js']), ...sources('bin', ['.js', '.sh']), ...sources('hooks', ['.sh', '.json']), ...sources('shell', ['.sh']), ...sources('scripts', ['.js']), 'install.sh'];
  const forbidden = /from ['"](?:node:)?(?:https?|http2|net|tls|dgram|dns)['"]|require\(['"](?:node:)?(?:https?|http2|net|tls|dgram|dns)['"]\)|\bfetch\s*\(|XMLHttpRequest|WebSocket|EventSource|sendBeacon|NSURLSession|NSURLConnection|NSURLRequest|dataWithContentsOfURL|do shell script/;
  const TOOLS = 'curl|wget|nc|ncat|netcat|scp|sftp|rsync|ssh|ftp|telnet|gh|git';
  // A call to a network tool, as opposed to the word in a message that says how to reinstall. In
  // JavaScript: run()/spawn()/exec*() with the tool as the program (a path to it included), or a
  // shell line that interpolates into it. In a shell script: the tool starting a command, once
  // strings and comments are taken out.
  const jsCall = new RegExp(`\\b(?:run|spawn|spawnSync|exec|execSync|execFile|execFileSync)\\(\\s*['"\`](?:[^'"\`\\n]*/)?(?:${TOOLS})['"\`]|\\b(?:${TOOLS}) -[a-zA-Z]+ [^|\\n]*\\$\\{`);
  const shCall = new RegExp(`(?:^|[\\s;|&({])(?:${TOOLS})\\s+-`);
  const callsTool = (file, text) =>
    file.endsWith('.sh') ? text.split('\n').some((line) => shCall.test(line.replace(/'[^']*'|"[^"]*"/g, '').replace(/#.*$/, ''))) : jsCall.test(text);
  // Who may, and the hosts each names (www.apple.com is the plist DTD in the launchd job).
  const allowed = {
    'lib/island.js': ['github.com', 'www.apple.com'],
    'lib/update.js': ['github.com', 'codeload.github.com', 'claude-tabby.vercel.app'],
    'install.sh': ['nodejs.org', 'codeload.github.com', 'github.com', 'claude-tabby.vercel.app', 'claude.com'],
  };
  const callers = [];
  for (const file of files) {
    const text = fs.readFileSync(path.join(ROOT, file), 'utf8');
    assert.ok(!forbidden.test(text), `${file} uses a network API`);
    if (callsTool(file, text)) callers.push(file);
  }
  assert.deepEqual(callers.sort(), Object.keys(allowed).sort(), 'network tools run only in the updater, the island download and the installer');
  for (const [file, hosts] of Object.entries(allowed)) {
    const named = [...fs.readFileSync(path.join(ROOT, file), 'utf8').matchAll(/https?:\/\/([a-z0-9.-]+)/g)].map((m) => m[1]);
    for (const host of named) assert.ok(hosts.includes(host), `${file} names ${host}`);
  }
});

test('Tabby Island has no network code at all', () => {
  const forbidden = /URLSession|URLRequest|NSURLConnection|CFNetwork|NWConnection|NWPathMonitor|import Network|WKWebView|import WebKit|CFSocket|CFStream|NSURLDownload|AsyncImage|dataTask|downloadTask|uploadTask|String\(contentsOf|NSData\(contentsOf|NSString\(contentsOf|getaddrinfo|CFHost|sockaddr|NSSocket/;
  for (const file of sources('island/Sources', ['.swift'])) {
    const text = fs.readFileSync(path.join(ROOT, file), 'utf8');
    assert.ok(!forbidden.test(text), `${file} uses a network API`);
    // Data(contentsOf:) reads files: never a URL made from a string, which could be a web address.
    assert.ok(!/Data\(contentsOf:\s*URL\(string/.test(text), `${file} reads a URL`);
    // Web addresses appear only as the About panel's links.
    if (file !== 'island/Sources/Brand.swift') assert.ok(!/https?:\/\//.test(text), `${file} names a web address`);
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
  // Files an older tabby made readable to others (logs, backups, old records) are tightened too.
  const old = path.join(S.paths.sessions, 'OLD.json');
  fs.writeFileSync(old, '{"sessionId":"OLD"}\n');
  fs.chmodSync(old, 0o644);
  fs.mkdirSync(S.paths.backups, { recursive: true });
  fs.chmodSync(S.paths.backups, 0o755);
  const backup = path.join(S.paths.backups, 'settings.old.json');
  fs.writeFileSync(backup, '{}\n');
  fs.chmodSync(backup, 0o644);
  S.ensureDirs();
  assert.equal(mode(old), 0o600);
  assert.equal(mode(S.paths.backups), 0o700);
  assert.equal(mode(backup), 0o600);
  fs.rmSync(old);
  fs.rmSync(backup);
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
  // Only the user's own settings and no MCP: a project's .claude/settings.json in the working
  // directory (read without a trust prompt in -p mode) could otherwise point the API, with the
  // prompt and the login token, at another host. And that directory is tabby's own, not /tmp.
  assert.equal(args[args.indexOf('--setting-sources') + 1], 'user', 'user settings only');
  assert.ok(args.includes('--strict-mcp-config'), 'no MCP servers');
  const pwd = fs.readFileSync(path.join(calls, `${before}.pwd`), 'utf8').trim();
  assert.equal(fs.realpathSync(pwd), fs.realpathSync(S.paths.root), 'runs in ~/.claude/tabby, not a shared temporary folder');
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
