// Context-window usage: exact numbers from Claude's statusLine JSON when available,
// otherwise estimated from the last assistant turn in the transcript.
import fs from 'node:fs';

const TAIL = 256 * 1024;

function slice(file, bytes, fromEnd) {
  let fd;
  try {
    fd = fs.openSync(file, 'r');
    const { size } = fs.fstatSync(fd);
    const len = Math.min(size, bytes);
    const buf = Buffer.alloc(len);
    fs.readSync(fd, buf, 0, len, fromEnd ? size - len : 0);
    return buf.toString('utf8');
  } catch {
    return '';
  } finally {
    if (fd !== undefined) try { fs.closeSync(fd); } catch {}
  }
}
const tail = (file, bytes = TAIL) => slice(file, bytes, true);
const head = (file, bytes = 64 * 1024) => slice(file, bytes, false);

// The session's model id ("claude-opus-5-5[1m]") is recorded at start and on /model switches.
function lastModelId(file) {
  for (const text of [tail(file), head(file)]) {
    const ids = [...text.matchAll(/"modelId":"([^"]+)"/g)];
    if (ids.length) return ids.at(-1)[1];
  }
  return '';
}

function lines(file) {
  return tail(file)
    .split('\n')
    .filter((l) => l.startsWith('{'));
}

export function contextFromTranscript(file) {
  if (!file) return null;
  const ls = lines(file);
  let usage = null;
  let model = '';
  for (let i = ls.length - 1; i >= 0 && !usage; i--) {
    if (!ls[i].includes('"type":"assistant"') || ls[i].includes('"isSidechain":true')) continue;
    try {
      const e = JSON.parse(ls[i]);
      const u = e.message?.usage;
      // Interrupted or synthetic turns carry zero usage; the real context is on an earlier turn.
      if (u && (u.input_tokens || 0) + (u.cache_creation_input_tokens || 0) + (u.cache_read_input_tokens || 0) > 0) {
        usage = u;
        model = e.message.model || '';
      }
    } catch {}
  }
  if (!usage) return null;
  const usedTokens = (usage.input_tokens || 0) + (usage.cache_creation_input_tokens || 0) + (usage.cache_read_input_tokens || 0);
  const big = /\[1m\]/.test(lastModelId(file)) || usedTokens > 200_000;
  const windowSize = big ? 1_000_000 : 200_000;
  return { usedTokens, windowSize, usedPct: Math.round((usedTokens / windowSize) * 100), model: prettyModel(model), at: Date.now(), source: 'transcript' };
}

export function contextFromStatusline(input) {
  const cw = input?.context_window;
  if (!cw) return null;
  const windowSize = cw.context_window_size || 200_000;
  const cur = cw.current_usage;
  const usedTokens = cur ? (cur.input_tokens || 0) + (cur.cache_creation_input_tokens || 0) + (cur.cache_read_input_tokens || 0) : null;
  const usedPct = typeof cw.used_percentage === 'number' ? Math.round(cw.used_percentage) : usedTokens != null ? Math.round((usedTokens / windowSize) * 100) : null;
  return {
    usedTokens,
    windowSize,
    usedPct,
    costUsd: input.cost?.total_cost_usd ?? null,
    model: input.model?.display_name || prettyModel(input.model?.id || ''),
    at: Date.now(),
    source: 'statusline',
  };
}

export function prettyModel(id) {
  const m = /claude-(\w+)-(\d+)(?:-(\d+))?/.exec(id || '');
  if (!m) return id || '';
  const name = m[1][0].toUpperCase() + m[1].slice(1);
  return m[3] && m[3].length <= 2 ? `${name} ${m[2]}.${m[3]}` : `${name} ${m[2]}`;
}

// Last assistant text (for the namer's summary) — plain text blocks only.
export function lastAssistantText(file, max = 600) {
  const ls = lines(file);
  for (let i = ls.length - 1; i >= 0; i--) {
    if (!ls[i].includes('"type":"assistant"') || ls[i].includes('"isSidechain":true')) continue;
    try {
      const e = JSON.parse(ls[i]);
      const text = (e.message?.content || [])
        .filter((c) => c.type === 'text')
        .map((c) => c.text)
        .join(' ')
        .trim();
      if (text) return text.length > max ? text.slice(0, max) + '…' : text;
    } catch {}
  }
  return '';
}
