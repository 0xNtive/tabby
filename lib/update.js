// Updates, from the terminal (`tabby update`, `/tab update`) or from Tabby Island: is a newer
// tabby out, and getting it in one go. The plugin updates first; then the NEW version's own
// `_after-update` runs, so each release decides what its update needs (setup changes, the island).
//
// Checking asks github.com where its "latest release" link points (one HEAD request, nothing
// about you), at most every 6 hours in the background. `tabby config updateCheck false` stops
// the automatic checks; `tabby update --check` still asks when you do.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawn, spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { paths, readJson, writeJson, log } from './state.js';
import { version, newer } from './island.js';

const LATEST = 'https://github.com/0xNtive/tabby/releases/latest';
const REPO_TARBALL = 'https://codeload.github.com/0xNtive/tabby/tar.gz/refs/heads/main';
const CHECK = path.join(paths.root, 'update-check.json');
const STATE = path.join(paths.root, 'update-state.json');
const CLI = fileURLToPath(new URL('../bin/tabby.js', import.meta.url));
export const CHECK_EVERY = 6 * 3600e3;
const NOTICE_EVERY = 24 * 3600e3;

const run = (cmd, args, opts = {}) => spawnSync(cmd, args, { encoding: 'utf8', timeout: 180_000, ...opts });
const lastLine = (s) => String(s || '').trim().split('\n').filter(Boolean).pop() || '';

// ---------- checking ----------

// The newest release's version, from where /releases/latest redirects. TABBY_LATEST fakes it.
export function latestRelease() {
  if (process.env.TABBY_LATEST) return { latest: process.env.TABBY_LATEST };
  const r = run('curl', ['-sSI', '--proto', '=https', '--max-time', '10', LATEST], { timeout: 15_000 });
  const m = /^location:\s*\S*\/releases\/tag\/v?(\d+\.\d+\.\d+)\s*$/im.exec(r.stdout || '');
  if (m) return { latest: m[1] };
  return { error: r.status !== 0 ? lastLine(r.stderr) || `curl exited ${r.status}` : 'GitHub named no latest release' };
}

const summarize = (current, rec) => ({
  current,
  latest: rec?.latest || null,
  available: !!rec?.latest && newer(rec.latest, current),
  checkedAt: rec?.checkedAt || null,
  error: rec?.error || null,
});

// What the last check found, without asking again.
export const cached = () => summarize(version(), readJson(CHECK, null));

export function check() {
  const before = readJson(CHECK, null) || {};
  const got = latestRelease();
  const rec = { ...before, latest: got.latest || before.latest || null, checkedAt: Date.now(), error: got.error || null };
  writeJson(CHECK, rec);
  return summarize(version(), rec);
}

// SessionStart: an old check is refreshed in the background (never blocks the hook).
export function checkInBackground(cfg) {
  if (cfg.updateCheck === false || process.env.TABBY_INTERNAL || process.env.TABBY_NO_UPDATE_CHECK) return;
  const rec = readJson(CHECK, null);
  if (rec?.checkedAt && Date.now() - rec.checkedAt < CHECK_EVERY) return;
  writeJson(CHECK, { ...(rec || {}), checkedAt: Date.now() }); // one check at a time
  spawn(process.execPath, [CLI, 'update', '--check', '--quiet'], { detached: true, stdio: 'ignore', env: { ...process.env, TABBY_INTERNAL: '1' } }).unref();
}

// SessionStart: one line when a newer tabby is out, at most once a day per version.
export function notice(cfg) {
  if (cfg.updateCheck === false) return null;
  const c = cached();
  if (!c.available) return null;
  const rec = readJson(CHECK, {}) || {};
  if (rec.noticed === c.latest && Date.now() - (rec.noticedAt || 0) < NOTICE_EVERY) return null;
  writeJson(CHECK, { ...rec, noticed: c.latest, noticedAt: Date.now() });
  return `tabby ${c.latest} is out (you have ${c.current}). Type /tab update, or run: tabby update`;
}

// ---------- updating ----------

export const readState = () => readJson(STATE, null);
const setState = (patch) => writeJson(STATE, { ...(readJson(STATE, {}) || {}), ...patch, at: Date.now() });

export function claudeBin() {
  for (const bin of [process.env.CLAUDE_BIN, 'claude', path.join(os.homedir(), '.local/bin/claude'), path.join(paths.claudeDir, 'local/claude'), '/opt/homebrew/bin/claude', '/usr/local/bin/claude']) {
    if (bin && run(bin, ['--version'], { timeout: 15_000 }).status === 0) return bin;
  }
  return null;
}

// Installed without git, the plugin's marketplace is a folder of ours: fetch main into it again.
function refreshDownloadedMarketplace() {
  const known = readJson(path.join(paths.claudeDir, 'plugins', 'known_marketplaces.json'), {}) || {};
  const src = known.tabby?.source;
  if (src?.source !== 'directory' || !src.path?.startsWith(path.join(paths.root, 'src'))) return null;
  const dir = path.join(paths.root, 'src');
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'tabby-src-'));
  const tarball = path.join(tmp, 'tabby.tar.gz');
  let r = run('curl', ['-fsSL', '--retry', '2', '--proto', '=https', '-o', tarball, REPO_TARBALL]);
  if (r.status === 0) r = run('tar', ['-xzf', tarball, '-C', tmp]);
  if (r.status !== 0 || !fs.existsSync(path.join(tmp, 'tabby-main'))) {
    fs.rmSync(tmp, { recursive: true, force: true });
    return `could not download tabby (${lastLine(r.stderr) || 'curl failed'})`;
  }
  fs.rmSync(path.join(dir, 'tabby-main'), { recursive: true, force: true });
  fs.mkdirSync(dir, { recursive: true });
  fs.renameSync(path.join(tmp, 'tabby-main'), path.join(dir, 'tabby-main'));
  fs.rmSync(tmp, { recursive: true, force: true });
  return null;
}

// The newest installed copy of the plugin: the tabby marketplace's own, never a plugin of the
// same name from somewhere else.
function newestRoot() {
  const dir = path.join(paths.claudeDir, 'plugins', 'cache', 'tabby', 'tabby');
  let best = null;
  for (const v of fs.existsSync(dir) ? fs.readdirSync(dir) : []) {
    if (fs.existsSync(path.join(dir, v, 'bin', 'tabby.js')) && (!best || newer(v, best.version))) best = { version: v, root: path.join(dir, v) };
  }
  return best;
}

// `tabby update`. `say` prints progress; the result is also in update-state.json for the island.
export function update({ say = console.log } = {}) {
  const from = version();
  setState({ state: 'running', from, to: null, message: 'Checking for a newer tabby…' });
  const fail = (message) => {
    setState({ state: 'failed', message });
    log('update failed', message);
    return { ok: false, from, message };
  };

  const c = check();
  if (c.error && !c.latest) say(`Couldn't reach GitHub (${c.error}); updating from what Claude Code can fetch.`);
  if (c.available) say(`tabby ${c.latest} is out (you have ${from}). Updating…`);

  const claude = claudeBin();
  if (!claude) return fail("Claude Code's `claude` command isn't on PATH, so the plugin can't update. Run the installer again: curl -fsSL https://claude-tabby.vercel.app/install | bash");
  const refreshed = refreshDownloadedMarketplace();
  if (refreshed) return fail(refreshed);
  const m = run(claude, ['plugin', 'marketplace', 'update', 'tabby']);
  const p = run(claude, ['plugin', 'update', 'tabby@tabby']);
  log('update plugin', m.status, lastLine(m.stdout || m.stderr), p.status, lastLine(p.stdout || p.stderr));
  if (p.status !== 0 && m.status !== 0) return fail(`Claude Code couldn't update the plugin: ${lastLine(p.stderr || p.stdout || m.stderr)}`);

  const next = newestRoot();
  const to = next?.version || from;
  setState({ to, message: to === from ? 'Checking Tabby Island…' : `Updating to ${to}…` });
  // The rest runs as the new version, which knows what its update needs.
  const cli = next ? path.join(next.root, 'bin', 'tabby.js') : CLI;
  const after = run(process.execPath, [cli, '_after-update', from], { timeout: 600_000, stdio: ['ignore', 'pipe', 'pipe'] });
  for (const line of String(after.stdout || '').split('\n').filter(Boolean)) say(`  ${line}`);
  if (after.status !== 0) return fail(`The update to ${to} stopped: ${lastLine(after.stderr || after.stdout) || `exit ${after.status}`}`);

  const message = to === from ? `tabby ${from} is the latest.` : `Updated tabby ${from} → ${to}. In Claude sessions that are open, type /reload-plugins.`;
  setState({ state: to === from ? 'current' : 'done', to, message });
  return { ok: true, from, to, message };
}

// Starts `tabby update` detached, its output in update.log (Tabby Island and /tab update).
export function updateInBackground() {
  const out = fs.openSync(path.join(paths.root, 'update.log'), 'a', 0o600);
  setState({ state: 'running', from: version(), to: null, message: 'Starting the update…' });
  spawn(process.execPath, [CLI, 'update', '--quiet'], { detached: true, stdio: ['ignore', out, out] }).unref();
}
