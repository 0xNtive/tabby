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

// Every tab of a terminal app: tty → { id, bounds }. On current macOS each Terminal.app tab is
// its own window inside a native tab group, and the group shares one frame.
function windowsByTty(app) {
  const script =
    app === 'iTerm2'
      ? `tell application "iTerm2"
  set out to ""
  repeat with w in windows
    set b to bounds of w
    repeat with t in tabs of w
      repeat with s in sessions of t
        set out to out & (id of w) & (ASCII character 9) & (tty of s) & (ASCII character 9) & (item 1 of b) & "," & (item 2 of b) & "," & (item 3 of b) & "," & (item 4 of b) & linefeed
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
      set out to out & (id of w) & (ASCII character 9) & (tty of t) & (ASCII character 9) & (item 1 of b) & "," & (item 2 of b) & "," & (item 3 of b) & "," & (item 4 of b) & linefeed
    end repeat
  end repeat
  return out
end tell`;
  const map = new Map();
  for (const line of (osa(script).stdout || '').split('\n')) {
    const [id, tty, bounds] = line.split('\t');
    if (id && tty) map.set(tty.trim(), { id: Number(id), bounds: (bounds || '').trim() });
  }
  return map;
}

// Terminal.app: "Window › Move Tab to New Window" through System Events (needs Accessibility).
const UNTAB = `on run argv
  set wid to (item 1 of argv) as integer
  set ttyName to item 2 of argv
  tell application "Terminal"
    activate
    repeat with t in tabs of window id wid
      if tty of t is ttyName then set selected of t to true
    end repeat
    set index of window id wid to 1
  end tell
  delay 0.3
  tell application "System Events" to tell process "Terminal"
    click menu item "Move Tab to New Window" of menu "Window" of menu bar 1
  end tell
  return "ok"
end run`;

const sleep = (ms) => Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
const nums = (bounds) => String(bounds || '').split(',').map(Number);

// Terminal sizes windows in whole character cells, so a window can come out a little smaller
// than asked; its top-left corner lands exactly.
export function landed(bounds, rect) {
  const b = nums(bounds);
  if (b.length !== 4 || b.some(Number.isNaN)) return false;
  return Math.abs(b[0] - rect[0]) <= 4 && Math.abs(b[1] - rect[1]) <= 4 && Math.abs(b[2] - rect[2]) <= 32 && Math.abs(b[3] - rect[3]) <= 32;
}

function setBounds(app, id, rect) {
  return osa(`tell application "${app}" to set bounds of window id ${id} to {${rect.join(', ')}}`).status === 0;
}

// Arrange the windows showing these ttys (in order) into a grid of max(n, windows) cells.
// Tabs of one macOS tab group share a frame, so moving one moves all of them. Windows that
// share a frame are therefore tested by moving the first: whatever moves along is a tab and
// gets pulled into its own window (needs Accessibility), waited for, then placed.
export function tileTtys(app, ttys, n, { dryRun = false } = {}) {
  const frame = visibleFrame();
  let byTty = windowsByTty(app);
  const order = [];
  for (const tty of ttys) {
    const w = byTty.get(tty);
    if (w && !order.some((o) => o.id === w.id)) order.push({ tty, id: w.id });
  }
  if (!order.length) return { placed: 0, lines: ['Could not find the terminal windows of your sessions.'] };
  const count = Math.max(n || 0, order.length);
  const rects = cells(count, frame);
  const cell = (tty) => rects[order.findIndex((o) => o.tty === tty)];
  const [cols, rows] = grid(count);
  if (dryRun) {
    return { placed: 0, lines: [`Would tile ${order.length} window${order.length === 1 ? '' : 's'} in a ${cols}×${rows} grid on a ${frame.w}×${frame.h} screen:`, ...order.map((o, i) => `  ${app} window ${o.id} (${o.tty}, now ${byTty.get(o.tty)?.bounds}) → {${rects[i].join(', ')}}`)] };
  }

  // 1. Find tabs: among windows sharing a frame, move the first and see who follows.
  const tabs = []; // { tty, host }
  const seenFrames = new Map(); // bounds -> first tty with that frame
  for (const o of order) {
    const b = byTty.get(o.tty)?.bounds;
    if (!seenFrames.has(b)) seenFrames.set(b, []);
    seenFrames.get(b).push(o.tty);
  }
  for (const group of seenFrames.values()) {
    if (group.length < 2) continue;
    const [first, ...rest] = group;
    setBounds(app, byTty.get(first).id, cell(first));
    sleep(200);
    byTty = windowsByTty(app);
    for (const tty of rest) if (byTty.get(tty)?.bounds === byTty.get(first)?.bounds) tabs.push({ tty, host: first });
  }

  // 2. Pull tabs into their own windows and wait until each has its own frame.
  const notes = [];
  const stuckTabs = new Set();
  for (const t of tabs) {
    if (app !== 'Terminal') {
      stuckTabs.add(t.tty);
      continue;
    }
    const r = osa(UNTAB, [String(byTty.get(t.tty).id), t.tty]);
    if (r.status !== 0) {
      tabs.slice(tabs.indexOf(t)).forEach((x) => stuckTabs.add(x.tty));
      notes.push(/assistive|not allowed|1719|25211|1743/i.test(r.stderr || '')
        ? 'Some sessions are tabs of one window. To split them, allow your terminal (or Tabby Island) under System Settings › Privacy & Security › Accessibility, then tile again.'
        : 'Could not split tabs into windows.');
      break;
    }
    for (let k = 0; k < 20; k++) {
      sleep(150);
      byTty = windowsByTty(app);
      if (byTty.get(t.tty)?.bounds !== byTty.get(t.host)?.bounds) break;
    }
  }
  if (tabs.length) sleep(350); // the tab-out animation settles the new window's frame last

  // 3. Place every window, then verify and retry the ones macOS moved again.
  const targets = order.filter((o) => !stuckTabs.has(o.tty));
  for (let attempt = 0; attempt < 4; attempt++) {
    byTty = windowsByTty(app);
    const off = targets.filter((o) => !landed(byTty.get(o.tty)?.bounds, cell(o.tty)));
    if (!off.length) break;
    for (const o of off) setBounds(app, byTty.get(o.tty)?.id ?? o.id, cell(o.tty));
    sleep(250);
  }
  byTty = windowsByTty(app);
  const good = targets.filter((o) => landed(byTty.get(o.tty)?.bounds, cell(o.tty)));
  const front = good
    .slice()
    .reverse()
    .map((o) => (app === 'Terminal' ? `  set index of window id ${byTty.get(o.tty).id} to 1` : `  select window id ${byTty.get(o.tty).id}`));
  if (front.length) osa(`tell application "${app}"\n${front.join('\n')}\n  activate\nend tell`);
  if (good.length < targets.length) notes.push(`${targets.length - good.length} window${targets.length - good.length === 1 ? '' : 's'} did not take the new size (full screen or snapped by macOS?).`);
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
