// Claude Code statusLine command: shows the tab's identity inside Claude (works in every
// terminal) and records exact context usage for `tabby ls` and the island.
import { readSession, patchSession, readConfig, projectName } from './state.js';
import { contextFromStatusline } from './context.js';
import { displayTitle } from './apply.js';
import { ansiFg } from './color.js';

const RESET = '\x1b[0m';
const DIM = '\x1b[2m';
const BOLD = '\x1b[1m';

function meter(pct, accent, width = 10) {
  const p = Math.max(0, Math.min(100, pct));
  const filled = Math.round((p / 100) * width);
  const color = p >= 90 ? '#e06c75' : p >= 70 ? '#e5c07b' : accent;
  return `${ansiFg(color)}${'▰'.repeat(filled)}${DIM}${'▱'.repeat(width - filled)}${RESET}`;
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
  const accent = rec?.accent || '#8b949e';
  const title = rec ? displayTitle(rec) : input?.session_name || projectName(input?.workspace?.current_dir || input?.cwd) || 'Claude';
  const glyph = rec ? cfg.status[rec.status] || '' : '';
  const parts = [`${ansiFg(accent)}●${RESET} ${BOLD}${title}${RESET}${glyph ? ` ${DIM}${glyph}${RESET}` : ''}`];
  if (ctx?.usedPct != null) parts.push(`${meter(ctx.usedPct, accent)} ${ctx.usedPct}%`);
  const tail = [ctx?.model, ctx?.costUsd != null ? `$${ctx.costUsd.toFixed(2)}` : null, rec?.project].filter(Boolean).join(' · ');
  if (tail) parts.push(`${DIM}${tail}${RESET}`);
  return parts.join('  ');
}
