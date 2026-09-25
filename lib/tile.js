// Window management for Claude sessions: tile their terminal windows into a grid (pulling
// tabs out into their own windows first), and jump to the next session that needs you.
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { paths, readJson, writeJson } from './state.js';
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
  delay 0.25
  tell application "System Events" to tell process "Terminal"
    click menu item "Move Tab to New Window" of menu "Window" of menu bar 1
  end tell
  return "ok"
end run`;

// Sessions that share a window or a tab group (same frame) get pulled out into their own windows.
function untab(app, sessions, byTty) {
  if (app !== 'Terminal') return { moved: 0, blocked: false };
  const seen = new Set();
  let moved = 0;
  for (const s of sessions) {
    const w = byTty.get(s.tty);
    if (!w) continue;
    const key = w.bounds || `id:${w.id}`;
    if (!seen.has(key)) {
      seen.add(key);
      continue;
    }
    const r = osa(UNTAB, [String(w.id), s.tty]);
    if (r.status !== 0) return { moved, blocked: /assistive|not allowed|1719|25211|1743/i.test(r.stderr || '') };
    moved++;
  }
  return { moved, blocked: false };
}

export function tile(n, { dryRun = false } = {}) {
  const sessions = mergedSessions({ withTitles: false, withContext: false })
    .filter((s) => s.tty && APPS[s.term])
    .sort((a, b) => (a.startedAt || 0) - (b.startedAt || 0));
  if (!sessions.length) return 'No Claude sessions in Terminal.app or iTerm2 to tile.';
  const want = n ? sessions.slice(-n) : sessions; // with a limit, keep the most recent sessions
  const frame = visibleFrame();
  const notes = [];
  const placed = [];
  for (const app of new Set(want.map((s) => APPS[s.term]))) {
    const group = want.filter((s) => APPS[s.term] === app);
    let byTty = windowsByTty(app);
    const res = dryRun ? { moved: 0, blocked: false } : untab(app, group, byTty);
    if (res.moved) byTty = windowsByTty(app);
    if (res.blocked) notes.push('Some sessions are tabs of one window. To split them automatically, allow your terminal (or Tabby Island) under System Settings › Privacy & Security › Accessibility.');
    for (const s of group) {
      const w = byTty.get(s.tty);
      if (w && !placed.some((p) => p.app === app && p.wid === w.id)) placed.push({ app, wid: w.id, tty: s.tty });
    }
  }
  if (!placed.length) return 'Could not find the terminal windows of your sessions.';
  const count = Math.max(n || 0, placed.length);
  const rects = cells(count, frame);
  const byApp = {};
  placed.forEach((p, i) => (byApp[p.app] ||= []).push({ ...p, rect: rects[i] }));
  if (dryRun) {
    const [cols, rows] = grid(count);
    return [`Would tile ${placed.length} window${placed.length === 1 ? '' : 's'} in a ${cols}×${rows} grid on a ${frame.w}×${frame.h} screen:`, ...placed.map((p, i) => `  ${p.app} window ${p.wid} (${p.tty}) → {${rects[i].join(', ')}}`)].join('\n');
  }
  let stuck = 0;
  for (const [app, list] of Object.entries(byApp)) {
    const lines = list.map(({ wid, rect }) => `  set bounds of window id ${wid} to {${rect.join(', ')}}`);
    const front = list
      .slice()
      .reverse()
      .map(({ wid }) => (app === 'Terminal' ? `  set index of window id ${wid} to 1` : `  select window id ${wid}`));
    osa(`tell application "${app}"\n${lines.join('\n')}\n${front.join('\n')}\n  activate\nend tell`);
    const after = windowsByTty(app);
    stuck += list.filter(({ tty, rect }) => after.get(tty)?.bounds !== rect.join(',')).length;
  }
  if (stuck && !notes.length) notes.push(`${stuck} window${stuck === 1 ? '' : 's'} could not be moved (still a tab of another window?).`);
  const [cols, rows] = grid(count);
  return [`Tiled ${placed.length - stuck} session${placed.length - stuck === 1 ? '' : 's'} in a ${cols}×${rows} grid.`, ...notes].join('\n');
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
