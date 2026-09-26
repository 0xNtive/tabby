// Terminal.app titles windows "folder — title — process ◂ args — size", which buries the session
// name. Those parts are profile settings, and Terminal only reads its preferences at launch (and
// rewrites them from memory), so editing preferences never sticks while it runs.
//
// What works live: a twin of the tab's profile ("Man Page · tabby") with those parts switched off,
// imported the way Terminal imports any .terminal file, and each Claude tab switched to it while
// its session runs. The twin keeps the original's font and look; tabby draws its colors on top.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawn, spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { paths, readConfig, writeConfig, liveSessions, log } from './state.js';
import { applySession } from './apply.js';

const CLI = fileURLToPath(new URL('../bin/tabby.js', import.meta.url));
export const SUFFIX = ' · tabby';
// Everything but the title tabby sets (OSC 0). A tab label is built from the same parts plus that
// title, so the tab parts go too. (OSC 1 tab titles are no way around it: a window with one tab
// then shows "window title — tab title".)
const TITLE_KEYS = [
  'ShowComponentsWhenTabHasCustomTitle', 'ShowRepresentedURLInTabTitle', 'ShowRepresentedURLPathInTabTitle',
  'ShowActiveProcessInTabTitle', 'ShowActiveProcessArgumentsInTabTitle', 'ShowTTYNameInTabTitle',
  'ShowActiveProcessInTitle', 'ShowActiveProcessArgumentsInTitle', 'ShowRepresentedURLInTitle',
  'ShowRepresentedURLPathInTitle', 'ShowDimensionsInTitle', 'ShowTTYNameInTitle', 'ShowShellCommandInTitle',
  'ShowWindowSettingsNameInTitle', 'ShowCommandKeyInTitle',
];
const PB = '/usr/libexec/PlistBuddy';
const run = (cmd, args) => spawnSync(cmd, args, { encoding: 'utf8', timeout: 20_000 });
const osa = (script, args = []) => run('osascript', ['-e', script, ...args]);
const out = (r) => (r.status === 0 ? r.stdout.trim() : '');
const esc = (s) => s.replace(/([\\: ])/g, '\\$1');
const sleep = (ms) => Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
export const isTwin = (name) => String(name || '').endsWith(SUFFIX);

const available = () => process.platform === 'darwin' && !process.env.TABBY_NO_TERMINAL_PROFILES;
// Every script starts with this, so asking never launches Terminal.app (iTerm users, CI).
const RUNNING = 'if application "Terminal" is not running then return ""';

// Switch the tab on `tty` to its profile's twin when the twin exists.
const USE = `on run argv
  ${RUNNING}
  set ttyName to item 1 of argv
  set suffix to item 2 of argv
  tell application "Terminal"
    repeat with w in windows
      repeat with t in tabs of w
        if tty of t is ttyName then
          set p to name of current settings of t
          if p ends with suffix then return "already"
          if exists settings set (p & suffix) then
            set current settings of t to settings set (p & suffix)
            return "switched"
          end if
          return "missing" & linefeed & p
        end if
      end repeat
    end repeat
  end tell
  return "notab"
end run`;

// Put tabs on a twin back on its original profile: the tab on `tty`, or every tab when it's "*".
const RESTORE = `on run argv
  ${RUNNING}
  set ttyName to item 1 of argv
  set suffix to item 2 of argv
  set n to 0
  tell application "Terminal"
    repeat with w in windows
      repeat with t in tabs of w
        if ttyName is "*" or tty of t is ttyName then
          set p to name of current settings of t
          if p ends with suffix then
            set base to text 1 thru -((length of suffix) + 1) of p
            if exists settings set base then
              set current settings of t to settings set base
              set n to n + 1
            end if
          end if
        end if
      end repeat
    end repeat
  end tell
  return n
end run`;

// While importing: does the twin exist yet, is Terminal frontmost, and every window as
// "id tty busy miniaturized profile" (the front window first).
const IMPORT_STATE = `on run argv
  ${RUNNING}
  tell application "Terminal"
    set r to ((exists settings set (item 1 of argv)) as string) & " " & (frontmost as string)
    repeat with w in windows
      set line_ to (id of w) as string
      try
        set t to selected tab of w
        set line_ to line_ & " " & (tty of t) & " " & ((busy of t) as string) & " " & ((miniaturized of w) as string) & " " & (name of current settings of t)
      end try
      set r to r & linefeed & line_
    end repeat
    return r
  end tell
end run`;

function importState(twin) {
  const [head = '', ...rows] = out(osa(IMPORT_STATE, [twin])).split('\n');
  const [exists, frontmost] = head.split(' ');
  const windows = rows.map((l) => l.split(' ')).map(([id, tty, busy, mini, ...profile]) => ({ id, tty, busy: busy === 'true', mini: mini === 'true', profile: profile.join(' ') }));
  return { exists: exists === 'true', frontmost: frontmost === 'true', windows };
}

// One import at a time: two sessions starting together would otherwise import the same twin twice.
function withLock(fn) {
  const lock = path.join(paths.root, 'profile.lock');
  for (let i = 0; i < 150; i++) {
    try {
      fs.writeFileSync(lock, String(process.pid), { flag: 'wx' });
      try { return fn(); } finally { fs.rmSync(lock, { force: true }); }
    } catch (e) {
      if (e.code !== 'EEXIST') throw e;
      try { if (Date.now() - fs.statSync(lock).mtimeMs > 20_000) fs.rmSync(lock, { force: true }); } catch {}
      sleep(100);
    }
  }
  return null;
}

// Import "<profile> · tabby". Terminal opens a window when it imports a profile: hand focus straight
// back to the window you were in, end that window's fresh shell (so closing it can't ask about
// running processes) and close it. It's on screen for a moment, once per profile.
function importTwin(profile) {
  const twin = profile + SUFFIX;
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'tabby-profile-'));
  const exported = path.join(dir, 'terminal.plist');
  const file = path.join(dir, `${profile.replace(/[/:]/g, '-')}${SUFFIX}.terminal`);
  try {
    const start = importState(twin);
    if (start.exists) return twin;
    if (run('defaults', ['export', 'com.apple.Terminal', exported]).status !== 0) return null;
    const xml = run(PB, ['-x', '-c', `Print :${esc('Window Settings')}:${esc(profile)}`, exported]);
    if (xml.status !== 0 || !xml.stdout.includes('<dict>')) return null;
    fs.writeFileSync(file, xml.stdout);
    // plutil, one key per call: PlistBuddy aborts when handed more than about a dozen commands.
    for (const [key, type, value] of [['name', '-string', twin], ['type', '-string', 'Window Settings'], ...TITLE_KEYS.map((k) => [k, '-bool', 'NO'])]) {
      if (run('plutil', ['-replace', key, type, value, file]).status !== 0) return null;
    }
    const before = new Set(start.windows.map((w) => w.id));
    const front = start.frontmost && start.windows.find((w) => !w.mini && w.tty);
    run('open', ['-g', file]);
    let state = start;
    let spawned = [];
    for (let i = 0; i < 50 && !(state.exists && spawned.length); i++) {
      sleep(100);
      state = importState(twin);
      // Only a new window on the new twin: never a window you opened meanwhile.
      spawned = state.windows.filter((w) => !before.has(w.id) && w.tty && w.profile === twin);
    }
    if (spawned.length) {
      if (front) osa(`tell application "Terminal" to set index of (every window whose id is ${Number(front.id)}) to 1`);
      for (const w of spawned) {
        const pids = out(run('ps', ['-t', w.tty.replace('/dev/', ''), '-o', 'pid='])).split(/\s+/).map(Number).filter(Boolean);
        for (const pid of pids) try { process.kill(pid, 'SIGKILL'); } catch {}
      }
      for (let i = 0; i < 30; i++) {
        const busy = importState(twin).windows.some((w) => spawned.some((s) => s.id === w.id) && w.busy);
        if (!busy) break;
        sleep(100);
      }
      for (const w of spawned) osa(`tell application "Terminal" to close (every window whose id is ${Number(w.id)})`);
    }
    if (!state.exists) return null;
    log('terminal profile twin', twin);
    return twin;
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
}

// Switch the tab on `tty` to the twin of its profile, importing the twin the first time.
// Returns 'switched' (colors need repainting), 'already', or null.
export function useTwin(tty) {
  if (!tty || !available()) return null;
  const r = out(osa(USE, [tty, SUFFIX]));
  if (r === 'already' || r === 'switched') return r;
  if (!r.startsWith('missing\n')) return null;
  const twin = withLock(() => importTwin(r.slice('missing\n'.length)));
  return twin && out(osa(USE, [tty, SUFFIX])) === 'switched' ? 'switched' : null;
}

// Put the tab on `tty` (or every tab, '*') back on its own profile. Returns how many moved.
export function restoreProfile(tty) {
  if (!tty || !available()) return 0;
  return Number(out(osa(RESTORE, [tty, SUFFIX]))) || 0;
}

// A tab's bold text color: its text color ("text", after tabby set that with OSC 10; copied as
// is, since Terminal keeps colors in its own color space), or its profile's again ("reset").
const BOLD = `on run argv
  ${RUNNING}
  set ttyName to item 1 of argv
  tell application "Terminal"
    repeat with w in windows
      repeat with t in tabs of w
        if tty of t is ttyName then
          if item 2 of argv is "reset" then
            -- by name: "current settings of t" is the tab's own copy, bold color included
            set bold text color of t to bold text color of settings set (name of current settings of t)
          else
            set bold text color of t to normal text color of t
          end if
          return "ok"
        end if
      end repeat
    end repeat
  end tell
  return ""
end run`;

export function setBoldColor(tty, mode = 'text') {
  if (!tty || !available()) return false;
  return out(osa(BOLD, [tty, mode === 'reset' ? 'reset' : 'text'])) === 'ok';
}

export const twins = () =>
  available() ? out(osa(`${RUNNING}\ntell application "Terminal" to get name of every settings set whose name ends with "${SUFFIX}"`)).split(', ').filter(Boolean) : [];

// Work that runs in the background, out of the hooks' way: `_profile use <session>`, `_profile restore <tty>`.
export function spawnProfile(...args) {
  try {
    spawn(process.execPath, [CLI, '_profile', ...args], { detached: true, stdio: 'ignore', env: { ...process.env, TABBY_INTERNAL: '1' } }).unref();
  } catch (e) {
    log('spawn failed', '_profile', e.message);
  }
}

// Switch every open Claude tab in Terminal.app and repaint it (a profile switch resets colors).
export function switchOpenTabs() {
  const cfg = readConfig();
  let n = 0;
  for (const rec of liveSessions().filter((s) => s.term === 'apple-terminal' && s.tty && !s.disabled)) {
    const r = useTwin(rec.tty);
    if (r === 'switched') applySession(rec, cfg, { colors: true, title: true });
    if (r) n++;
  }
  return n;
}

// `tabby terminal-titles on|off`, setup and uninstall.
export function setTerminalTabTitles(on, { background = false } = {}) {
  if (process.platform !== 'darwin') return null;
  const was = readConfig().terminalTabTitles;
  writeConfig({ terminalTabTitles: on });
  if (on) {
    if (background) spawnProfile('all');
    const n = background ? null : switchOpenTabs();
    return `Terminal.app: Claude windows and tabs show only the session name${n === null ? '' : ` (${n} open tab${n === 1 ? '' : 's'})`}. Each Claude tab uses a "· tabby" copy of its profile while it runs.`;
  }
  const moved = restoreProfile('*');
  const removed = twins();
  // Only after the tabs are back: deleting a profile in use moves its tabs to the default profile.
  if (removed.length) osa(`tell application "Terminal" to delete (every settings set whose name ends with "${SUFFIX}")`);
  if (!was && !moved && !removed.length) return null;
  return `Terminal.app titles back to your profiles' defaults${moved ? ` (${moved} tab${moved === 1 ? '' : 's'} restored)` : ''}${removed.length ? `; removed ${removed.join(', ')}` : ''}.`;
}
