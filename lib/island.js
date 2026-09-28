// Tabby Island on disk: getting it (a ready-made download from the GitHub release, or a local
// build as the fallback), keeping it in ~/Applications, starting it, and reading what it reports.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawn, spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { paths, readJson, writeJson, log } from './state.js';

export const ROOT = fileURLToPath(new URL('..', import.meta.url)).replace(/\/$/, '');
const CLI = path.join(ROOT, 'bin', 'tabby.js');
export const BUNDLE_ID = 'dev.tabby.island';
const REPO = '0xNtive/tabby';
const ZIP = 'TabbyIsland.zip';
export const MIN_MACOS = 14;

// Where it lives: one stable place, so updates, the login item and macOS permissions all
// point at the same app. TABBY_ISLAND_APP overrides it (tests, a custom location).
export const APP = process.env.TABBY_ISLAND_APP || path.join(os.homedir(), 'Applications', 'Tabby Island.app');
export const BUILD_APP = path.join(ROOT, 'island', 'build', 'Tabby Island.app');
const LOGIN_PLIST = path.join(os.homedir(), 'Library', 'LaunchAgents', `${BUNDLE_ID}.plist`);
const STATUS = path.join(paths.root, 'island-status.json');
const UPDATE_MARK = path.join(paths.root, 'island-update.json');

const run = (cmd, args, opts = {}) => spawnSync(cmd, args, { encoding: 'utf8', timeout: 120_000, ...opts });
const pause = (ms) => Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
const tail = (s, n = 6) => String(s || '').trim().split('\n').slice(-n).join('\n');

export const version = () => readJson(path.join(ROOT, 'package.json'), {})?.version || '0.0.0';

export function newer(a, b) {
  const x = String(a).split('.').map(Number);
  const y = String(b).split('.').map(Number);
  for (let i = 0; i < 3; i++) if ((x[i] || 0) !== (y[i] || 0)) return (x[i] || 0) > (y[i] || 0);
  return false;
}

export function macosVersion() {
  if (process.platform !== 'darwin') return null;
  return (run('sw_vers', ['-productVersion']).stdout || '').trim() || null;
}

// Why the island can't run on this machine, or null when it can.
export function unsupported() {
  if (process.env.TABBY_NO_ISLAND) return 'Tabby Island is turned off here (TABBY_NO_ISLAND).';
  if (process.platform !== 'darwin') return 'Tabby Island is a macOS app; everything else in tabby works here.';
  const v = macosVersion();
  if (v && Number(v.split('.')[0]) < MIN_MACOS) return `Tabby Island needs macOS ${MIN_MACOS} (Sonoma) or newer; this Mac runs ${v}. Everything else in tabby works.`;
  return null;
}

export function appVersion(app = APP) {
  const plist = path.join(app, 'Contents', 'Info.plist');
  if (!fs.existsSync(plist)) return null;
  const r = run('plutil', ['-extract', 'CFBundleShortVersionString', 'raw', '-o', '-', plist]);
  return r.status === 0 ? r.stdout.trim() : null;
}

// The island to run: the installed one, else a local build (a checkout or an older install).
export function findApp() {
  if (fs.existsSync(APP)) return APP;
  if (fs.existsSync(BUILD_APP)) return BUILD_APP;
  return null;
}

// TABBY_ISLAND_SANDBOX: install into TABBY_ISLAND_APP without touching the island that runs
// (a test install next to a real one).
const SANDBOX = !!process.env.TABBY_ISLAND_SANDBOX;

export const running = () => !SANDBOX && run('pgrep', ['-x', 'TabbyIsland']).status === 0;

export function quit() {
  if (!running()) return false;
  run('osascript', ['-e', `quit app id "${BUNDLE_ID}"`], { timeout: 5000 });
  for (let i = 0; i < 40 && running(); i++) pause(100);
  if (running()) run('pkill', ['-x', 'TabbyIsland']);
  for (let i = 0; i < 20 && running(); i++) pause(100);
  return true;
}

// ---------- getting it ----------

function sha256(file) {
  const r = run('shasum', ['-a', '256', file]);
  return r.status === 0 ? r.stdout.split(/\s+/)[0] : null;
}

function curl(url, dest) {
  const r = run('curl', ['-fsSL', '--retry', '2', '--connect-timeout', '15', '--max-time', '300', '-o', dest, url], { timeout: 320_000 });
  return r.status === 0 ? null : tail(r.stderr, 2) || `curl exited ${r.status}`;
}

export function downloadUrls(v = version()) {
  if (process.env.TABBY_ISLAND_URL) return [process.env.TABBY_ISLAND_URL];
  return [`https://github.com/${REPO}/releases/download/v${v}/${ZIP}`, `https://github.com/${REPO}/releases/latest/download/${ZIP}`];
}

// Downloads and unpacks the ready-made island into a temp folder. Every zip on the release has
// a .sha256 next to it; a download that doesn't match is thrown away.
export function download(v = version()) {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'tabby-island-'));
  const errors = [];
  for (const url of downloadUrls(v)) {
    const zip = path.join(tmp, ZIP);
    const err = curl(url, zip);
    if (err) {
      errors.push(`${url}: ${err}`);
      continue;
    }
    const sumFile = path.join(tmp, `${ZIP}.sha256`);
    const custom = !!process.env.TABBY_ISLAND_URL;
    if (curl(`${url}.sha256`, sumFile)) {
      if (!custom) {
        errors.push(`${url}: no checksum next to it`);
        continue;
      }
    } else {
      const want = fs.readFileSync(sumFile, 'utf8').trim().split(/\s+/)[0];
      if (want !== sha256(zip)) {
        errors.push(`${url}: checksum mismatch`);
        continue;
      }
    }
    const out = path.join(tmp, 'app');
    const x = run('ditto', ['-x', '-k', zip, out]);
    const app = path.join(out, 'Tabby Island.app');
    if (x.status !== 0 || !fs.existsSync(app)) {
      errors.push(`${url}: could not unpack (${tail(x.stderr, 1)})`);
      continue;
    }
    return { app, version: appVersion(app), url, tmp };
  }
  return { error: errors.join('\n') || 'no download URL', tmp };
}

export const canBuild = () => process.platform === 'darwin' && run('xcode-select', ['-p']).status === 0 && run('xcrun', ['--find', 'swiftc']).status === 0;

// Compiles island/ here (Xcode Command Line Tools, about 30 s).
export function build({ quiet = false } = {}) {
  const r = run('bash', [path.join(ROOT, 'island', 'build.sh')], { timeout: 600_000, stdio: quiet ? 'pipe' : ['ignore', 'inherit', 'inherit'] });
  if (r.status === 0 && fs.existsSync(BUILD_APP)) return { app: BUILD_APP, version: appVersion(BUILD_APP) };
  return { error: quiet ? tail(r.stderr || r.stdout) || `build.sh exited ${r.status}` : `build.sh exited ${r.status}` };
}

// Puts an app bundle at APP: the running island quits first and comes back after.
export function place(src) {
  if (path.resolve(src) === path.resolve(APP)) return { restarted: false };
  const was = quit();
  fs.mkdirSync(path.dirname(APP), { recursive: true });
  const next = `${APP}.new`;
  fs.rmSync(next, { recursive: true, force: true });
  const c = run('ditto', [src, next]);
  if (c.status !== 0) throw new Error(`could not copy the app to ${path.dirname(APP)}: ${tail(c.stderr, 2)}`);
  fs.rmSync(APP, { recursive: true, force: true });
  fs.renameSync(next, APP);
  // Downloads through a browser carry a quarantine flag; ours come through curl, but be sure.
  run('xattr', ['-dr', 'com.apple.quarantine', APP]);
  if (was) start();
  return { restarted: was };
}

// Gets the island onto this Mac: the download first, a local build when that fails. `prefer:
// 'build'` compiles first (a checkout with changes). Returns { ok, how, version, message }.
export function install({ prefer = 'download', quiet = false } = {}) {
  const why = unsupported();
  if (why) return { ok: false, message: why, unsupported: true };
  const tries = prefer === 'build' ? ['build', 'download'] : ['download', 'build'];
  const problems = [];
  for (const how of tries) {
    if (how === 'build' && !canBuild()) {
      problems.push('build: needs the Xcode Command Line Tools (xcode-select --install)');
      continue;
    }
    const got = how === 'download' ? download() : build({ quiet });
    if (got.error) {
      problems.push(`${how}: ${got.error}`);
      if (got.tmp) fs.rmSync(got.tmp, { recursive: true, force: true });
      continue;
    }
    try {
      place(got.app);
    } catch (e) {
      problems.push(`${how}: ${e.message}`);
      continue;
    } finally {
      if (got.tmp) fs.rmSync(got.tmp, { recursive: true, force: true });
    }
    const v = appVersion();
    writeJson(UPDATE_MARK, { version: v, at: Date.now(), how });
    return { ok: true, how, version: v, message: `Tabby Island${v ? ` ${v}` : ''} ${how === 'download' ? 'downloaded' : 'built'} → ${APP}` };
  }
  log('island install failed', problems.join(' | '));
  return { ok: false, message: `Tabby Island could not be installed.\n  ${problems.join('\n  ')}` };
}

// ---------- running it ----------

// `onboarding`: its setup window (welcome, or 'permissions' to start at the permissions). A
// running island ignores new arguments, so it restarts for those.
export function start({ onboarding = null, background = true } = {}) {
  const app = findApp();
  if (!app) return { ok: false, message: 'Tabby Island is not installed. Run: tabby island install' };
  if (onboarding) quit();
  const args = [...(background && !onboarding ? ['-g'] : []), app];
  if (onboarding) args.push('--args', onboarding === 'permissions' ? '--allow-accessibility' : '--onboarding');
  if (!onboarding && running()) return { ok: true, message: 'Tabby Island is running: hover the top center of your screen.' };
  if (SANDBOX) return { ok: true, message: `(sandbox) would open ${args.join(' ')}` };
  const r = run('open', args);
  if (r.status !== 0) return { ok: false, message: `macOS would not open ${app}: ${tail(r.stderr, 2)}` };
  forget('quitByUser');
  return { ok: true, message: onboarding ? 'Tabby Island opened its setup window: it walks you through the permissions.' : 'Tabby Island is running: hover the top center of your screen.' };
}

const xmlEscape = (s) => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');

// At login, launchd starts the app's own executable, so macOS lists it as Tabby Island.
export function login(on = true) {
  if (!on) {
    run('launchctl', ['unload', LOGIN_PLIST]);
    try { fs.unlinkSync(LOGIN_PLIST); } catch {}
    return 'Tabby Island will no longer start at login.';
  }
  const app = findApp();
  if (!app) return 'Tabby Island is not installed yet: tabby island install';
  fs.mkdirSync(path.dirname(LOGIN_PLIST), { recursive: true });
  fs.writeFileSync(
    LOGIN_PLIST,
    `<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0"><dict>\n<key>Label</key><string>${BUNDLE_ID}</string>\n<key>ProgramArguments</key><array><string>${xmlEscape(path.join(app, 'Contents', 'MacOS', 'TabbyIsland'))}</string></array>\n<key>RunAtLoad</key><true/>\n<key>ProcessType</key><string>Interactive</string>\n</dict></plist>\n`
  );
  return `Tabby Island starts at login. Undo: tabby island login --off`;
}

export const loginOn = () => fs.existsSync(LOGIN_PLIST);
export const loginTarget = () => {
  const m = /<array><string>([^<]*)<\/string>/.exec(fs.existsSync(LOGIN_PLIST) ? fs.readFileSync(LOGIN_PLIST, 'utf8') : '');
  return m ? m[1].replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&amp;/g, '&') : null;
};

// What the island last wrote about itself (permissions, screen, version); null if it never ran.
export function status() {
  const s = readJson(STATUS, null);
  if (!s) return null;
  return { ...s, live: running() };
}

function forget(key) {
  const s = readJson(STATUS, null);
  if (s && key in s) {
    delete s[key];
    writeJson(STATUS, s);
  }
}

// ---------- in the background, from SessionStart ----------

// Starts the island when a Claude session starts (unless you quit it yourself), and replaces an
// island older than this tabby with the matching download. Never blocks the hook.
export function keepCurrent(cfg) {
  if (process.platform !== 'darwin' || process.env.TABBY_INTERNAL || process.env.TABBY_NO_ISLAND || cfg.island === false || cfg.island === 'off') return;
  if (!fs.existsSync(APP)) return;
  const have = appVersion();
  const want = version();
  if (have && newer(want, have)) {
    const mark = readJson(UPDATE_MARK, {}) || {};
    if (mark.tried === want && Date.now() - (mark.triedAt || 0) < 6 * 3600e3) return;
    writeJson(UPDATE_MARK, { ...mark, tried: want, triedAt: Date.now() });
    spawn(process.execPath, [CLI, 'island', 'update', '--quiet'], { detached: true, stdio: 'ignore', env: { ...process.env, TABBY_INTERNAL: '1' } }).unref();
    return;
  }
  if (cfg.islandAutostart === false || readJson(STATUS, {})?.quitByUser || running()) return;
  spawn('open', ['-g', APP], { detached: true, stdio: 'ignore' }).unref();
}
