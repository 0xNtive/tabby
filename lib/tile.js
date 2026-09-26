// Window management for Claude sessions: tile their terminal windows into a grid (pulling
// tabs out into their own windows first), and jump to the next session that needs you.
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { paths, readJson, writeJson, isAlive } from './state.js';
import { focusTab } from './term.js';
import { mergedSessions, sessionTitle } from './sessions.js';
import { targetOf } from './apply.js';

const osa = (script, args = [], lang) =>
  spawnSync('osascript', [...(lang ? ['-l', lang] : []), '-e', script, ...args], { encoding: 'utf8', timeout: 15_000 });

// Columns × rows for n windows (landscape screens: prefer wide grids).
export function grid(n) {
  const fixed = { 1: [1, 1], 2: [2, 1], 3: [3, 1], 4: [2, 2], 5: [3, 2], 6: [3, 2], 7: [4, 2], 8: [4, 2], 9: [3, 3] };
  if (fixed[n]) return fixed[n];
  const cols = Math.ceil(Math.sqrt(n * 1.6));
  return [cols, Math.ceil(n / cols)];
}

// Cells in AppleScript window coordinates ({left, top, right, bottom}, origin top-left of the main display).
export function cells(n, frame, gap = 6) {
  const [cols, rows] = grid(n);
  const w = (frame.w - gap * (cols + 1)) / cols;
  const h = (frame.h - gap * (rows + 1)) / rows;
  return Array.from({ length: n }, (_, i) => {
    const c = i % cols;
    const r = Math.floor(i / cols);
    const left = Math.round(frame.x + gap + c * (w + gap));
    const top = Math.round(frame.y + gap + r * (h + gap));
    return [left, top, Math.round(left + w), Math.round(top + h)];
  });
}

function visibleFrame() {
  const js = `ObjC.import('AppKit');
var s = $.NSScreen.mainScreen, f = s.visibleFrame, primary = $.NSScreen.screens.objectAtIndex(0).frame;
JSON.stringify({ x: f.origin.x, y: primary.size.height - f.origin.y - f.size.height, w: f.size.width, h: f.size.height });`;
  try {
    return JSON.parse(osa(js, [], 'JavaScript').stdout);
  } catch {
    return { x: 0, y: 25, w: 1440, h: 875 };
  }
}

const APPS = { 'apple-terminal': 'Terminal', iterm2: 'iTerm2' };

// Every tab of a terminal app: tty → { id, bounds, index, minimized }. On current macOS each
// Terminal.app tab is its own window inside a native tab group, and the group shares one frame.
function windowsByTty(app) {
  const script =
    app === 'iTerm2'
      ? `tell application "iTerm2"
  set out to ""
  repeat with w in windows
    set b to bounds of w
    repeat with t in tabs of w
      repeat with s in sessions of t
        set out to out & (id of w) & (ASCII character 9) & (tty of s) & (ASCII character 9) & (item 1 of b) & "," & (item 2 of b) & "," & (item 3 of b) & "," & (item 4 of b) & (ASCII character 9) & (index of w) & (ASCII character 9) & "false" & linefeed
      end repeat
    end repeat
  end repeat
  return out
end tell`
      : `tell application "Terminal"
  set out to ""
  repeat with w in windows
    set b to bounds of w
    repeat with t in tabs of w
      set out to out & (id of w) & (ASCII character 9) & (tty of t) & (ASCII character 9) & (item 1 of b) & "," & (item 2 of b) & "," & (item 3 of b) & "," & (item 4 of b) & (ASCII character 9) & (index of w) & (ASCII character 9) & (miniaturized of w) & linefeed
    end repeat
  end repeat
  return out
end tell`;
  const map = new Map();
  for (const line of (osa(script).stdout || '').split('\n')) {
    const [id, tty, bounds, index, minimized] = line.split('\t');
    if (id && tty) map.set(tty.trim(), { id: Number(id), bounds: (bounds || '').trim(), index: Number(index) || 0, minimized: (minimized || '').trim() === 'true' });
  }
  return map;
}

// Bring Terminal forward and wait until it is: when its windows are on another desktop (Space)
// macOS slides over first, and until then nothing about its windows can be trusted.
const ACTIVATE = `on run argv
  tell application "Terminal"
    repeat with i in argv
      if miniaturized of window id (i as integer) then set miniaturized of window id (i as integer) to false
    end repeat
    activate
  end tell
  repeat 40 times
    tell application "Terminal" to if frontmost then return "ok"
    delay 0.05
  end repeat
  return "timeout"
end run`;

// Bring one session's window forward, wait until Accessibility sees it in front, and while it
// holds other tabs, click "Window › Move Tab to New Window". Needs Accessibility (System Events).
const SPLIT = `on run argv
  set wid to (item 1 of argv) as integer
  tell application "Terminal"
    if miniaturized of window id wid then set miniaturized of window id wid to false
    set index of window id wid to 1
    activate
    set b to bounds of window id wid
  end tell
  set ready to false
  repeat 60 times
    tell application "Terminal" to set isFront to frontmost and (index of window id wid) is 1
    if isFront then
      tell application "System Events" to tell process "Terminal"
        if (count windows) > 0 then
          set p to position of window 1
          set z to size of window 1
          -- the front window Accessibility sees must be this one (same frame, give or take a point)
          set dx to (item 1 of p) - (item 1 of b)
          set dy to (item 2 of p) - (item 2 of b)
          set dw to (item 1 of p) + (item 1 of z) - (item 3 of b)
          if dx ≥ -2 and dx ≤ 2 and dy ≥ -2 and dy ≤ 2 and dw ≥ -2 and dw ≤ 2 then set ready to true
        end if
      end tell
    end if
    if ready then exit repeat
    delay 0.05
    tell application "Terminal" to set b to bounds of window id wid
  end repeat
  if not ready then return "notready"
  set moved to 0
  repeat 12 times
    tell application "System Events" to tell process "Terminal"
      set n to 0
      try
        set n to count radio buttons of tab group 1 of window 1
      end try
      if n < 2 then return "alone " & moved
      set mi to menu item "Move Tab to New Window" of menu "Window" of menu bar 1
      set clicked to false
      repeat 20 times
        if enabled of mi then
          click mi
          set clicked to true
          exit repeat
        end if
        delay 0.05
      end repeat
      if not clicked then return "stuck " & moved
    end tell
    set moved to moved + 1
    delay 0.6
  end repeat
  return "stuck " & moved
end run`;

const PROBE_AX = 'tell application "System Events" to tell process "Terminal" to get enabled of menu item "Move Tab to New Window" of menu "Window" of menu bar 1';
const axDenied = (stderr) => /assistive|not allowed|1719|25211|1743|not authorized/i.test(stderr || '');
// Who needs the permission: the island runs tabby itself, otherwise it's the terminal app.
const axApp = () => (process.env.TABBY_SOURCE === 'island' ? 'Tabby Island' : 'your terminal app');

// Window ids on screen right now. A background tab of a tab group is not on screen (nor is a window
// on another desktop), and needs no permission to ask.
function onScreen() {
  const js = `ObjC.import('CoreGraphics');
const a = ObjC.deepUnwrap(ObjC.castRefToObject($.CGWindowListCopyWindowInfo($.kCGWindowListOptionOnScreenOnly | $.kCGWindowListExcludeDesktopElements, 0))) || [];
JSON.stringify(a.filter((w) => w.kCGWindowLayer === 0).map((w) => w.kCGWindowNumber));`;
  try {
    return new Set(JSON.parse(osa(js, [], 'JavaScript').stdout));
  } catch {
    return null;
  }
}

const sleep = (ms) => Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
const nums = (bounds) => String(bounds || '').split(',').map(Number);

// Terminal sizes windows in whole character cells, so a window can come out a little smaller
// than asked; its top-left corner lands exactly.
export function landed(bounds, rect) {
  const b = nums(bounds);
  if (b.length !== 4 || b.some(Number.isNaN)) return false;
  return Math.abs(b[0] - rect[0]) <= 4 && Math.abs(b[1] - rect[1]) <= 4 && Math.abs(b[2] - rect[2]) <= 32 && Math.abs(b[3] - rect[3]) <= 32;
}

// One AppleScript call for many windows: [{ id, rect }].
function setBoundsAll(app, moves) {
  if (!moves.length) return;
  const lines = moves.map(({ id, rect }) => `  if miniaturized of window id ${id} then set miniaturized of window id ${id} to false\n  set bounds of window id ${id} to {${rect.join(', ')}}`);
  osa(`tell application "${app}"\n${lines.join('\n')}\nend tell`);
}

// Which session windows can be placed. Terminal.app: tabs of one macOS tab group share a frame,
// and resizing a background tab only squeezes its terminal inside the group. So Terminal comes
// forward first, and with Accessibility every session's tab is moved into its own window. Then
// only windows actually on screen are placed: never a background tab. Without Accessibility a
// tab group still moves as one unit through its front tab.
export function placeable(app, present, byTty, visible) {
  const units = [];
  const skipped = [];
  for (const tty of present) {
    const w = byTty.get(tty);
    if (!w || units.some((u) => u.id === w.id)) continue;
    if (app === 'Terminal' && visible && !visible.has(w.id)) skipped.push(tty);
    else units.push({ id: w.id, tty, bounds: w.bounds });
  }
  return { units, skipped };
}

// Arrange the windows showing these ttys (in order) into a grid of max(n, windows) cells.
export function tileTtys(app, ttys, n, { dryRun = false } = {}) {
  const frame = visibleFrame();
  let byTty = windowsByTty(app);
  const present = ttys.filter((tty) => byTty.has(tty));
  if (!present.length) return { placed: 0, lines: ['Could not find the terminal windows of your sessions.'] };
  const notes = [];
  let visible = null;

  if (app === 'Terminal' && !dryRun) {
    // 1. Split tab groups (with Accessibility), one session at a time.
    let canSplit = !process.env.TABBY_TILE_NO_AX; // env: test the no-Accessibility path
    if (canSplit) {
      const probe = osa(PROBE_AX);
      if (probe.status !== 0) {
        canSplit = false;
        if (axDenied(probe.stderr)) notes.push(`Tabs can only be split into windows with Accessibility: allow ${axApp()} under System Settings › Privacy & Security › Accessibility, then tile again.`);
      }
    }
    osa(ACTIVATE, [...new Set(present.map((tty) => String(byTty.get(tty).id)))]);
    if (canSplit) {
      let stuck = 0;
      for (const tty of present) {
        const w = windowsByTty(app).get(tty);
        if (!w) continue;
        const r = osa(SPLIT, [String(w.id)]);
        if (r.status !== 0) {
          if (axDenied(r.stderr)) notes.push(`Accessibility was turned off while tiling; allow ${axApp()} again and tile again.`);
          break;
        }
        if (!r.stdout.startsWith('alone')) stuck++;
      }
      if (stuck) notes.push(`${stuck} session${stuck === 1 ? '' : 's'} could not be moved out of ${stuck === 1 ? 'its' : 'their'} tab group.`);
    }
    // 2. Let the last window finish animating, then see what's really on screen.
    for (let i = 0; i < 8; i++) {
      sleep(150);
      byTty = windowsByTty(app);
      visible = onScreen();
      if (visible && present.every((tty) => visible.has(byTty.get(tty)?.id))) break;
    }
  }

  const { units, skipped } = placeable(app, present, byTty, visible);
  if (skipped.length) {
    const one = skipped.length === 1;
    notes.push(`${skipped.length} session${one ? ' was' : 's were'} left in place: ${one ? "it's a tab" : "they're tabs"} in another window (splitting tabs needs Accessibility for ${axApp()}) or on another desktop.`);
  }
  if (!units.length) return { placed: 0, lines: notes };

  const count = Math.max(n || 0, units.length);
  const rects = cells(count, frame);
  const [cols, rows] = grid(count);
  if (dryRun) {
    return { placed: 0, lines: [`Would tile ${units.length} window${units.length === 1 ? '' : 's'} in a ${cols}×${rows} grid on a ${frame.w}×${frame.h} screen (tabs are split into windows first):`, ...units.map((u, i) => `  ${app} window ${u.id} (${u.tty}, now ${u.bounds}) → {${rects[i].join(', ')}}`), ...notes] };
  }

  // 3. Place, then verify and retry the ones macOS moved again.
  for (let attempt = 0; attempt < 4; attempt++) {
    byTty = windowsByTty(app);
    const off = units.map((u, i) => ({ u, i })).filter(({ u, i }) => !landed(byTty.get(u.tty)?.bounds, rects[i]));
    if (!off.length) break;
    setBoundsAll(app, off.map(({ u, i }) => ({ id: byTty.get(u.tty)?.id ?? u.id, rect: rects[i] })));
    sleep(250);
  }
  byTty = windowsByTty(app);
  const good = units.filter((u, i) => landed(byTty.get(u.tty)?.bounds, rects[i]));
  const front = good
    .slice()
    .reverse()
    .map((u) => (app === 'Terminal' ? `  set index of window id ${byTty.get(u.tty).id} to 1` : `  select window id ${byTty.get(u.tty).id}`));
  if (front.length) osa(`tell application "${app}"\n${front.join('\n')}\n  activate\nend tell`);
  if (good.length < units.length) notes.push(`${units.length - good.length} window${units.length - good.length === 1 ? '' : 's'} did not take the new size (full screen, or snapped by macOS?).`);
  return { placed: good.length, grid: `${cols}×${rows}`, lines: notes };
}

// Only one tile at a time (a double-pressed ⌃⌥G would otherwise fight itself).
function withTileLock(fn) {
  const file = path.join(paths.root, 'tile.lock');
  try {
    const [pid, at] = fs.readFileSync(file, 'utf8').split(' ').map(Number);
    if (isAlive(pid) && Date.now() - at < 60_000) return 'Already tiling, one moment.';
  } catch {}
  fs.mkdirSync(paths.root, { recursive: true });
  fs.writeFileSync(file, `${process.pid} ${Date.now()}`);
  try {
    return fn();
  } finally {
    try { fs.unlinkSync(file); } catch {}
  }
}

export function tile(n, { dryRun = false, ttys } = {}) {
  return withTileLock(() => {
    const sessions = ttys
      ? ttys.map((tty) => ({ tty, term: 'apple-terminal' }))
      : mergedSessions({ withTitles: false, withContext: false })
          .filter((s) => s.tty && APPS[s.term])
          .sort((a, b) => (a.startedAt || 0) - (b.startedAt || 0));
    if (!sessions.length) return 'No Claude sessions in Terminal.app or iTerm2 to tile.';
    const want = n && !ttys ? sessions.slice(-n) : sessions; // with a limit, keep the most recent sessions
    const out = [];
    let placed = 0;
    let gridName = '';
    for (const app of new Set(want.map((s) => APPS[s.term]))) {
      const res = tileTtys(app, want.filter((s) => APPS[s.term] === app).map((s) => s.tty), n, { dryRun });
      placed += res.placed;
      gridName = res.grid || gridName;
      out.push(...res.lines);
    }
    if (dryRun) return out.join('\n');
    return [placed ? `Tiled ${placed} session${placed === 1 ? '' : 's'} in a ${gridName} grid.` : 'Nothing was tiled.', ...out].join('\n');
  });
}

// Cycle through sessions that want you: waiting first, then "your turn" (most recent first).
export function next() {
  const all = mergedSessions({ withTitles: true, withContext: false }).filter((s) => s.tty);
  const waiting = all.filter((s) => s.status === 'waiting').sort((a, b) => (a.statusAt || 0) - (b.statusAt || 0));
  const idle = all.filter((s) => s.status === 'idle' || s.status === 'error').sort((a, b) => (b.statusAt || 0) - (a.statusAt || 0));
  const queue = [...waiting, ...idle];
  if (!queue.length) return all.length ? 'Every session is working. Nothing needs you right now.' : 'No Claude sessions running.';
  const file = path.join(paths.root, 'focus.json');
  const last = readJson(file, {})?.sessionId;
  const i = queue.findIndex((s) => s.sessionId === last);
  const pick = queue[(i + 1) % queue.length];
  writeJson(file, { sessionId: pick.sessionId, at: Date.now() });
  const ok = focusTab(targetOf(pick));
  return ok ? `→ ${sessionTitle(pick)} (${pick.status === 'waiting' ? 'needs you' : 'your turn'})` : `Could not focus ${sessionTitle(pick)} from here.`;
}
