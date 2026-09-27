// Claude Code statusLine command: shows the tab's identity inside Claude (works in every
// terminal) and records exact context usage for `tabby ls` and the island.
import { readSession, patchSession, readConfig, projectName } from './state.js';
import { contextFromStatusline } from './context.js';
import { displayTitle } from './apply.js';
import { ansiFg, ensureContrast } from './color.js';

const RESET = '\x1b[0m';
const DIM = '\x1b[2m';
const BOLD = '\x1b[1m';

// Context used, as a number: a bar read as progress. Amber from 70 %, red from 90 %, drawn on
// the session's tinted background (kept at >= 3:1 against it).
function contextUsed(pct, accent, bg) {
  const p = Math.round(Math.max(0, Math.min(100, pct)));
  const raw = p >= 90 ? '#e06c75' : p >= 70 ? '#e5c07b' : accent;
  const color = bg ? ensureContrast(raw, bg, 3) : raw;
  return `${ansiFg(color)}${p}%${RESET} ${DIM}context${RESET}`;
}

export function statusline(input) {
  const id = input?.session_id;
  let rec = id ? readSession(id) : null;
  const ctx = contextFromStatusline(input);
  if (rec && ctx) {
    const prev = rec.context || {};
    if (prev.usedPct !== ctx.usedPct || prev.costUsd !== ctx.costUsd || prev.source !== 'statusline' || Date.now() - (prev.at || 0) > 20_000) {
      rec = patchSession(id, { context: ctx });
    }
  }
  const cfg = readConfig();
  const accent = rec?.cursor || rec?.accent || '#8b949e';
  const title = rec ? displayTitle(rec) : input?.session_name || projectName(input?.workspace?.current_dir || input?.cwd) || 'Claude';
  const glyph = rec ? cfg.status[rec.status] || '' : '';
  const parts = [`${ansiFg(accent)}●${RESET} ${BOLD}${title}${RESET}${glyph ? ` ${DIM}${glyph}${RESET}` : ''}`];
  if (ctx?.usedPct != null) parts.push(contextUsed(ctx.usedPct, accent, rec?.bg));
  const tail = [ctx?.model, ctx?.costUsd != null ? `$${ctx.costUsd.toFixed(2)}` : null, rec?.project].filter(Boolean).join(' · ');
  if (tail) parts.push(`${DIM}${tail}${RESET}`);
  return parts.join('  ');
}
