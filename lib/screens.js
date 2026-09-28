// Displays, and which of them Claude sessions go on. Tiling and `tabby new` place windows only on
// the screens you picked (say, just the vertical monitor, keeping the main screen free), each
// screen laid out for its shape: a portrait screen stacks rows, a landscape one lines up columns.
//
// Config: tileScreens = "current" (default: the screen you're on, NSScreen.mainScreen) | "all" |
// ["<display key>", …]. A display key is its UUID (CGDisplayCreateUUIDFromDisplayID, stable across
// reconnects and re-numbering), or "name@WxH" when macOS has none. A chosen screen that is
// unplugged is skipped; with none of them connected, tiling falls back to the current screen.
//
// Coordinates are AppleScript window bounds: origin at the top-left of the menu-bar screen, y down.
import { spawnSync } from 'node:child_process';

const JXA = `ObjC.import('AppKit'); ObjC.import('CoreGraphics');
var uuids = true;
try { ObjC.import('ColorSync'); } catch (e) { uuids = false; }
var all = $.NSScreen.screens, primaryH = all.objectAtIndex(0).frame.size.height, main = $.NSScreen.mainScreen, out = [];
for (var i = 0; i < all.count; i++) {
  var s = all.objectAtIndex(i), f = s.frame, v = s.visibleFrame;
  var did = ObjC.unwrap(s.deviceDescription.objectForKey('NSScreenNumber'));
  var uuid = null;
  if (uuids) { try { uuid = ObjC.castRefToObject($.CFUUIDCreateString(null, $.CGDisplayCreateUUIDFromDisplayID(did))).js; } catch (e) {} }
  var name = ''; try { name = ObjC.unwrap(s.localizedName) || ''; } catch (e) {}
  var notch = 0; try { notch = s.safeAreaInsets.top; } catch (e) {}
  out.push({ uuid: uuid || null, name: name, primary: i === 0, current: main && main.isEqual(s),
    builtin: !!$.CGDisplayIsBuiltin(did), rotation: $.CGDisplayRotation(did), notch: notch,
    full: { x: f.origin.x, y: primaryH - f.origin.y - f.size.height, w: f.size.width, h: f.size.height },
    frame: { x: v.origin.x, y: primaryH - v.origin.y - v.size.height, w: v.size.width, h: v.size.height } });
}
JSON.stringify(out);`;

// Every display, left to right then top to bottom (the order `tabby tile screens` numbers them).
export function listScreens() {
  if (process.platform !== 'darwin') return [];
  if (process.env.TABBY_SCREENS) return sortScreens(JSON.parse(process.env.TABBY_SCREENS).map(normalize)); // tests, dry runs
  const r = spawnSync('osascript', ['-l', 'JavaScript', '-e', JXA], { encoding: 'utf8', timeout: 10_000 });
  try {
    return sortScreens(JSON.parse(r.stdout).map(normalize));
  } catch {
    return [];
  }
}

function normalize(s) {
  const full = s.full || s.frame;
  return { ...s, full, key: screenKey({ ...s, full }), portrait: full.h > full.w };
}

export const screenKey = (s) => s.uuid || `${s.name || 'Display'}@${Math.round(s.full.w)}x${Math.round(s.full.h)}`;
export const sortScreens = (screens) => [...screens].sort((a, b) => a.full.x - b.full.x || a.full.y - b.full.y);

export function describe(s) {
  const tags = [s.primary && 'main', s.current && 'current', s.builtin && 'built-in', s.notch && 'notch', s.portrait && 'portrait'].filter(Boolean);
  return `${s.name || 'Display'}  ${Math.round(s.full.w)}×${Math.round(s.full.h)}${tags.length ? `  (${tags.join(', ')})` : ''}`;
}

// The config value from what someone typed: "all", "current", or screens by number (as listed),
// name (any part of it) or key, comma-separated. Returns { value, error }.
export function parseSelection(input, screens) {
  const text = String(input ?? '').trim();
  if (!text || /^(current|main|default)$/i.test(text)) return { value: 'current' };
  if (/^all$/i.test(text)) return { value: 'all' };
  const keys = [];
  for (const raw of text.split(',').map((t) => t.trim()).filter(Boolean)) {
    // A plain number is always a position in the list ("7" is not part of "U2720Q").
    const hit = /^\d+$/.test(raw)
      ? screens[Number(raw) - 1]
      : screens.find((s) => s.key === raw) || screens.find((s) => (s.name || '').toLowerCase().includes(raw.toLowerCase()));
    if (!hit) return { error: `No screen "${raw}". Screens: ${screens.map((s, i) => `${i + 1} ${s.name}`).join(', ')}` };
    if (!keys.includes(hit.key)) keys.push(hit.key);
  }
  return { value: keys };
}

// The screens to use for `pref` (see the file comment), and a note when that had to change.
export function chooseScreens(screens, pref = 'current') {
  if (!screens.length) return { screens: [], note: null };
  const current = screens.find((s) => s.current) || screens.find((s) => s.primary) || screens[0];
  if (pref === 'all') return { screens, note: null };
  if (Array.isArray(pref) && pref.length) {
    const picked = screens.filter((s) => pref.includes(s.key));
    if (picked.length) return { screens: picked, note: picked.length < pref.length ? `${pref.length - picked.length} of your chosen screens isn't connected: using the other${picked.length === 1 ? '' : 's'}.` : null };
    return { screens: [current], note: "None of your chosen screens is connected, so this used the one you're on." };
  }
  return { screens: [current], note: null };
}

// Columns × rows for n windows on a frame of this aspect (width / height). Landscape prefers wide
// grids (side by side), portrait the same grid turned (stacked).
export function grid(n, aspect = 16 / 10) {
  const fixed = { 1: [1, 1], 2: [2, 1], 3: [3, 1], 4: [2, 2], 5: [3, 2], 6: [3, 2], 7: [4, 2], 8: [4, 2], 9: [3, 3] };
  let g = fixed[n];
  if (!g) {
    const cols = Math.ceil(Math.sqrt(n * 1.6));
    g = [cols, Math.ceil(n / cols)];
  }
  return aspect < 1 ? [g[1], g[0]] : g;
}

// n cells ({left, top, right, bottom}) filling a frame, row by row.
export function cells(n, frame, gap = 6) {
  if (n <= 0) return [];
  const [cols, rows] = grid(n, frame.w / frame.h);
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

// How many of n windows each screen gets: in proportion to its usable area (largest remainder).
// With fewer windows than screens, the biggest screens get them.
export function distribute(n, screens) {
  if (!screens.length) return [];
  const areas = screens.map((s) => s.frame.w * s.frame.h);
  const total = areas.reduce((a, b) => a + b, 0) || 1;
  const exact = areas.map((a) => (n * a) / total);
  const counts = exact.map(Math.floor);
  let left = n - counts.reduce((a, b) => a + b, 0);
  const order = exact.map((e, i) => ({ i, rest: e - Math.floor(e), area: areas[i] })).sort((a, b) => b.rest - a.rest || b.area - a.area || a.i - b.i);
  for (const { i } of order) {
    if (left <= 0) break;
    counts[i]++;
    left--;
  }
  return counts;
}

// n rects over the chosen screens, in screen order: [{ rect, screen }].
export function layout(n, screens, gap = 6) {
  const counts = distribute(n, screens);
  const out = [];
  screens.forEach((screen, i) => {
    for (const rect of cells(counts[i], screen.frame, gap)) out.push({ rect, screen });
  });
  return out;
}

// Where a single new window goes on a screen: centered, a comfortable size.
export function centered(screen, { w = 0.62, h = 0.72, maxW = 1280, maxH = 900 } = {}) {
  const f = screen.frame;
  const width = Math.round(Math.min(f.w * w, maxW));
  const height = Math.round(Math.min(f.h * h, maxH));
  const left = Math.round(f.x + (f.w - width) / 2);
  const top = Math.round(f.y + (f.h - height) / 2);
  return [left, top, left + width, top + height];
}

// A window that fills a whole display (full screen, or zoomed to cover it).
export function fullScreenOn(bounds, screens) {
  const [l, t, r, b] = String(bounds || '').split(',').map(Number);
  if ([l, t, r, b].some(Number.isNaN)) return false;
  return screens.some(({ full: f }) => l <= f.x && r >= f.x + f.w && b >= f.y + f.h && t <= f.y + 40);
}
