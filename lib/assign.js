// Automatic, eye-friendly color assignment: every live session gets a hue (and title marker)
// that no other live session is using; a project gets its remembered color back when free.
import { getTheme, AUTO_ORDER, VARIETY_POOL, accentHex } from './themes.js';
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
