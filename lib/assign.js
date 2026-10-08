// Automatic, eye-friendly color assignment: every live session gets a hue (and title marker)
// that no other live session is using; a project gets its remembered color back when free.
import { getTheme, AUTO_ORDER, VARIETY_POOL, ACCENT_KEYS, accentHex } from './themes.js';
import { hexToOklch, hueDistance, markerFor } from './color.js';
import { liveSessions, readProjects } from './state.js';

function accentCandidates(theme) {
  const keys = Object.keys(theme.accents);
  return [...AUTO_ORDER.filter((k) => keys.includes(k)), ...keys.filter((k) => !AUTO_ORDER.includes(k))];
}

function pickTheme(cfg, others, affinity) {
  if (cfg.auto !== 'themes') return getTheme(cfg.theme);
  const inUse = new Set(others.map((s) => s.theme));
  if (affinity?.theme && !inUse.has(affinity.theme)) return getTheme(affinity.theme);
  const free = VARIETY_POOL.find((id) => !inUse.has(id));
  if (free) return getTheme(free);
  const counts = VARIETY_POOL.map((id) => [id, others.filter((s) => s.theme === id).length]);
  counts.sort((a, b) => a[1] - b[1]);
  return getTheme(counts[0][0]);
}

export function chooseLook({ cwd, sessionId }, cfg, others = liveSessions().filter((s) => s.sessionId !== sessionId)) {
  const affinity = readProjects()[cwd];
  const theme = pickTheme(cfg, others, affinity);
  const sameTheme = others.filter((s) => s.theme === theme.id);
  const usedKeys = new Set(sameTheme.map((s) => s.accentKey));
  const usedMarkers = new Set(others.filter((s) => s.accent).map((s) => markerFor(s.accent, cfg.marker)));
  const usedHues = others.filter((s) => s.accent).map((s) => hexToOklch(s.accent).h);
  const cands = accentCandidates(theme);

  let best = cands[0];
  let bestScore = -Infinity;
  cands.forEach((key, i) => {
    const hex = accentHex(theme, key);
    const h = hexToOklch(hex).h;
    const free = !usedKeys.has(key);
    let score = (cands.length - i) * 0.5;
    if (affinity?.accentKey === key && free && (!affinity.theme || affinity.theme === theme.id)) score += 10000;
    if (!usedMarkers.has(markerFor(hex, cfg.marker))) score += 1000;
    if (free) score += 500;
    score += usedHues.length ? Math.min(...usedHues.map((u) => hueDistance(u, h))) : 180;
    if (score > bestScore) [best, bestScore] = [key, score];
  });
  return { theme: theme.id, accentKey: best };
}

// Windows that share an edge: [l, t, r, b] rects in screen points, a few points apart at most
// (the tile gap, plus Terminal rounding a window down to whole character cells).
export function neighbors(rects, slack = 48) {
  const pairs = [];
  const overlap = (a0, a1, b0, b1) => Math.min(a1, b1) - Math.max(a0, b0) > 0;
  for (let i = 0; i < rects.length; i++) {
    for (let j = i + 1; j < rects.length; j++) {
      const a = rects[i], b = rects[j];
      if (!a || !b) continue;
      const side = (Math.abs(a[2] - b[0]) <= slack || Math.abs(b[2] - a[0]) <= slack) && overlap(a[1], a[3], b[1], b[3]);
      const stacked = (Math.abs(a[3] - b[1]) <= slack || Math.abs(b[3] - a[1]) <= slack) && overlap(a[0], a[2], b[0], b[2]);
      if (side || stacked) pairs.push([i, j]);
    }
  }
  return pairs;
}

function* combinations(list, k, start = 0, picked = []) {
  if (picked.length === k) {
    yield picked;
    return;
  }
  for (let i = start; i <= list.length - (k - picked.length); i++) yield* combinations(list, k, i + 1, [...picked, list[i]]);
}

function* permutations(list) {
  if (list.length <= 1) {
    yield list;
    return;
  }
  for (let i = 0; i < list.length; i++) {
    for (const rest of permutations([...list.slice(0, i), ...list.slice(i + 1)])) yield [list[i], ...rest];
  }
}

// Fresh looks for a set of windows side by side, chosen together: every window its own hue,
// windows that touch as far apart on the color wheel as the palette allows, calm hues first, and
// a window keeps its color when nothing clearly better exists (tiling twice doesn't reshuffle).
// items: [{ rec, rect }] in grid order. A look the user picked by hand (lookSource "manual") stays,
// and the rest work around it. With auto = "themes", each window also gets its own theme.
// others: live sessions that aren't in the grid (their hues are avoided while there's room).
// Returns [{ sessionId, theme, accentKey }] for the windows that change.
export function spreadLooks(items, cfg, others = []) {
  const fixed = (rec) => rec.lookSource === 'manual';
  const themes = items.map(({ rec }) => getTheme(rec.theme || cfg.theme).id);
  if (cfg.auto === 'themes') {
    const taken = new Set(items.filter(({ rec }) => fixed(rec)).map(({ rec }) => getTheme(rec.theme || cfg.theme).id));
    items.forEach(({ rec }, i) => {
      if (fixed(rec)) return;
      const own = themes[i];
      themes[i] = VARIETY_POOL.includes(own) && !taken.has(own) ? own : VARIETY_POOL.find((id) => !taken.has(id)) || own;
      taken.add(themes[i]);
    });
  }
  const hues = themes.map((id) => Object.fromEntries(ACCENT_KEYS.map((key) => [key, hexToOklch(accentHex(getTheme(id), key)).h])));
  const hue = (i, key) => hues[i][key] ?? hexToOklch(accentHex(getTheme(themes[i]), key)).h;
  const rank = (key) => (AUTO_ORDER.includes(key) ? AUTO_ORDER.indexOf(key) : AUTO_ORDER.length);
  const pairs = neighbors(items.map((it) => it.rect));
  const free = items.map((it, i) => i).filter((i) => !fixed(items[i].rec));
  const keys = items.map(({ rec }, i) => (fixed(rec) ? rec.accentKey || accentCandidates(getTheme(themes[i]))[0] : null));
  const othersKeys = new Set(others.map((s) => s.accentKey).filter(Boolean));

  const score = (assign) => {
    const h = assign.map((key, i) => hue(i, key));
    const near = pairs.length ? Math.min(...pairs.map(([a, b]) => hueDistance(h[a], h[b]))) : 180;
    let spread = 180;
    for (let a = 0; a < h.length; a++) for (let b = a + 1; b < h.length; b++) spread = Math.min(spread, hueDistance(h[a], h[b]));
    // Every window apart from every other first; the ones that touch, furthest apart next.
    let s = spread * 3 + near * 1.5;
    for (const i of free) {
      s -= rank(assign[i]) * 2;
      if (!getTheme(themes[i]).accents[assign[i]]) s -= 100; // the theme has no such hue
      if (othersKeys.has(assign[i])) s -= 40;
      if (assign[i] === items[i].rec.accentKey) s += 6;
    }
    return s;
  };

  const palette = ACCENT_KEYS.filter((k) => !keys.includes(k));
  let best = null;
  let bestScore = -Infinity;
  if (free.length && free.length <= palette.length) {
    // At most 8 hues: try every set of them in every order (8! at worst, well under 100 ms).
    for (const set of combinations(palette, free.length)) {
      for (const order of permutations(set)) {
        const assign = keys.slice();
        free.forEach((i, k) => (assign[i] = order[k]));
        const s = score(assign);
        if (s > bestScore) [best, bestScore] = [assign, s];
      }
    }
  } else if (free.length) {
    // More windows than hues: one at a time, as far as possible from the windows it touches.
    best = keys.slice();
    for (const i of free) {
      const touching = pairs.flatMap(([a, b]) => (a === i ? [b] : b === i ? [a] : [])).filter((j) => best[j]);
      let pick = null;
      let pickScore = -Infinity;
      for (const key of ACCENT_KEYS) {
        const d = touching.length ? Math.min(...touching.map((j) => hueDistance(hue(i, key), hue(j, best[j])))) : 180;
        const used = best.filter((k) => k === key).length;
        const missing = getTheme(themes[i]).accents[key] ? 0 : 1;
        // Every hue once before any comes back.
        const s = d * 3 - used * 1000 - missing * 100 - rank(key) * 2;
        if (s > pickScore) [pick, pickScore] = [key, s];
      }
      best[i] = pick;
    }
  }
  if (!best) return [];
  return free
    .map((i) => ({ sessionId: items[i].rec.sessionId, theme: themes[i], accentKey: best[i] }))
    .filter((look, k) => look.theme !== items[free[k]].rec.theme || look.accentKey !== items[free[k]].rec.accentKey);
}
