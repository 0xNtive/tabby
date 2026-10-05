// Render a session's tab title and push its look to the terminal.
import { resolveLook } from './themes.js';
import { applyToTab, caps } from './term.js';
import { markerFor } from './color.js';

export function targetOf(rec) {
  return rec && { tty: rec.tty, term: rec.term, tmuxPane: rec.tmuxPane };
}

export function displayTitle(rec) {
  return rec.title || rec.claudeName || rec.project || 'Claude';
}

export function titleText(rec, cfg) {
  const glyph = cfg.status[rec.status] ?? '';
  const marker = caps(rec.term).marker && rec.accent ? markerFor(rec.accent, cfg.marker) : '';
  return cfg.titleFormat
    .replace('{marker}', () => marker)
    .replace('{status}', () => glyph)
    .replace('{title}', () => displayTitle(rec))
    .replace('{project}', () => rec.project || '')
    .replace(/ {2,}/g, ' ') // plain spaces only: the blinking bell's U+3000 placeholder keeps the width steady
    .trim();
}

// Recompute the concrete colors for a record (after theme/accent/strength changes).
export function withLook(rec, cfg) {
  const look = resolveLook({ theme: rec.theme, accentKey: rec.accentKey }, cfg);
  return { ...rec, theme: look.theme, accentKey: look.accentKey, accent: look.accent, bg: look.bg, fg: look.fg, cursor: look.cursor, dot: look.dot, marker: look.marker };
}

// opts: { colors: push colors, title: push title (only if we own it), reset: restore terminal defaults first }
export function applySession(rec, cfg, { colors = false, title = true, reset = false } = {}) {
  if (!rec || rec.disabled) return false;
  const look = colors ? { bg: rec.bg, fg: rec.fg, cursor: rec.cursor || rec.accent, accent: rec.accent } : null;
  const t = title && rec.ownsTitle ? titleText(rec, cfg) : undefined;
  if (!look && t === undefined && !reset) return true;
  return applyToTab(targetOf(rec), { look, title: t, reset });
}

// Restore the tab to the terminal profile's own colors (and clear our title).
export function clearSession(rec) {
  if (!rec) return false;
  return applyToTab(targetOf(rec), { reset: true, title: rec.ownsTitle ? '' : undefined });
}
