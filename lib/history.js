// Sessions you ran before, newest first, and going back to one: its tab when it's still open,
// else a new window running `claude --resume <id>` in its folder. Claude keeps a resumed
// session's id, so tabby finds its record again: same name, same color.
import fs from 'node:fs';
import os from 'node:os';
import { listSessions, readRegistry, isAlive, plain, readConfig, paths } from './state.js';
import { transcriptFor } from './sessions.js';
import { focusTab } from './term.js';
import { targetOf } from './apply.js';
import { heuristicTitle } from './namer.js';
import { newSession } from './launch.js';

const home = (p) => (p && p.startsWith(`${os.homedir()}/`) ? `~${p.slice(os.homedir().length)}` : p);

// A session's name, never Claude's stand-in ("tabby-4f"): tabby's, else one from what you asked.
export function historyTitle(rec) {
  const title = plain(rec.title || '').trim();
  if (title) return title;
  const asked = (rec.prompts || []).find((p) => String(p).trim());
  return (asked && heuristicTitle(asked)) || rec.project || 'Claude session';
}

const transcript = (rec) => rec.transcriptPath || transcriptFor(rec.cwd, rec.sessionId);
const exists = (file) => {
  try {
    return !!file && fs.statSync(file).isFile();
  } catch {
    return false;
  }
};

// How the session last ran, from its transcript (Claude notes the permission mode on each
// prompt): records from before tabby kept it themselves.
export function transcriptMode(file) {
  let fd;
  try {
    fd = fs.openSync(file, 'r');
    const size = fs.fstatSync(fd).size;
    const length = Math.min(size, 512 * 1024);
    const buf = Buffer.alloc(length);
    fs.readSync(fd, buf, 0, length, size - length);
    const all = [...buf.toString('utf8').matchAll(/"permissionMode":"(\w+)"/g)];
    return all.at(-1)?.[1] || null;
  } catch {
    return null;
  } finally {
    if (fd !== undefined) fs.closeSync(fd);
  }
}

// Running now: Claude's registry has it, or its tab's process still runs it.
function liveIds() {
  const ids = new Set();
  for (const r of readRegistry().values()) if (r.sessionId) ids.add(r.sessionId);
  return ids;
}

export function history({ limit = 50, records = null, live = null } = {}) {
  const running = live || liveIds();
  // Claude builds without the registry: a record whose process still runs is open.
  const noRegistry = !live && !fs.existsSync(paths.registry);
  const rows = [];
  for (const rec of records || listSessions()) {
    if (!rec?.sessionId || rec.bare || String(rec.sessionId).startsWith('tty-') || !rec.cwd) continue;
    const file = transcript(rec);
    // Opened and closed without a word: nothing to go back to.
    if (!(rec.promptCount > 0) && !(rec.prompts || []).length && !exists(file)) continue;
    const isLive = running.has(rec.sessionId) || (noRegistry && rec.status !== 'ended' && isAlive(rec.pid));
    rows.push({
      sessionId: rec.sessionId,
      title: historyTitle(rec),
      named: !!plain(rec.title || '').trim(),
      project: rec.project || null,
      cwd: rec.cwd,
      summary: plain(rec.note || rec.summary || '').trim() || null,
      lastPrompt: plain((rec.prompts || []).at(-1) || '').replace(/\s+/g, ' ').trim().slice(0, 240) || null,
      prompts: rec.promptCount || (rec.prompts || []).length || 0,
      startedAt: rec.startedAt || null,
      lastAt: rec.updatedAt || rec.statusAt || rec.startedAt || 0,
      live: isLive,
      status: isLive ? rec.status : 'ended',
      accent: rec.accent || null,
      dot: rec.dot || null,
      resumable: isLive || exists(file),
    });
  }
  return rows.sort((a, b) => b.lastAt - a.lastAt).slice(0, limit > 0 ? limit : undefined);
}

// One session by id (or its start), else the newest whose name or folder matches.
export function findPast(query, rows = history({ limit: 0 })) {
  const q = String(query || '').trim().toLowerCase();
  if (!q) return rows[0] || null;
  if (/^\d{1,3}$/.test(q)) return rows[Number(q) - 1] || null; // the number `tabby history` shows
  return (
    rows.find((r) => r.sessionId === q) ||
    rows.find((r) => q.length >= 4 && r.sessionId.startsWith(q)) ||
    rows.find((r) => r.title.toLowerCase() === q) ||
    rows.find((r) => r.title.toLowerCase().includes(q)) ||
    rows.find((r) => (r.project || '').toLowerCase() === q) ||
    rows.find((r) => (r.summary || '').toLowerCase().includes(q)) ||
    null
  );
}

// opts: dangerous (skip permissions; the session's own mode when not given), term, screen, dryRun.
export function resume(query, opts = {}) {
  const rows = opts.rows || history({ limit: 0 });
  const row = findPast(query, rows);
  if (!row) return { ok: false, message: query ? `No past session matches "${query}". Try: tabby history` : 'No past sessions yet.' };
  const rec = (opts.records || listSessions()).find((s) => s.sessionId === row.sessionId) || {};
  if (row.live) {
    const ok = !opts.dryRun && focusTab(targetOf(rec));
    return { ok: ok || !!opts.dryRun, message: opts.dryRun ? `Would bring "${row.title}" to the front: it's still open.` : ok ? `→ ${row.title} (still open)` : `"${row.title}" is still open, but its tab couldn't be brought to the front from here.`, live: true };
  }
  if (!row.resumable) return { ok: false, message: `"${row.title}" left nothing to resume (Claude has no transcript for it).` };
  if (!/^[\w-]+$/.test(row.sessionId)) return { ok: false, message: 'That session id is not one Claude made.' };
  if (!fs.existsSync(row.cwd)) return { ok: false, message: `Its folder is gone: ${home(row.cwd)}` };
  const cfg = readConfig();
  // The way it ran before: skipping permissions only if it did (or, not knowing, if quick launch does).
  const mode = rec.permissionMode || transcriptMode(transcript({ ...rec, ...row }));
  const dangerous = opts.dangerous ?? (mode ? mode === 'bypassPermissions' : cfg.launchSkipPermissions === true);
  const message = newSession({ dir: row.cwd, resume: row.sessionId, dangerous, term: opts.term || rec.term, screen: opts.screen, dryRun: opts.dryRun });
  return { ok: /^(Opened|Would open)/.test(message), message: message.replace(/^Opened /, `Resumed "${row.title}": opened `) };
}

const ago = (ms) => {
  const m = Math.max(0, Math.round((Date.now() - ms) / 60_000));
  return m < 60 ? `${m}m` : m < 1440 ? `${Math.round(m / 60)}h` : `${Math.round(m / 1440)}d`;
};

export function historyReport(rows = history()) {
  if (!rows.length) return 'No past sessions yet.';
  const pad = (s, n) => {
    const t = [...String(s || '')];
    return t.length > n ? t.slice(0, n - 1).join('') + '…' : t.join('') + ' '.repeat(n - t.length);
  };
  const lines = rows.map((r, i) => `${String(i + 1).padStart(3)}  ${r.live ? '●' : ' '} ${pad(r.title, 30)} ${pad(r.project, 16)} ${pad(ago(r.lastAt), 4)}  ${pad(r.summary || r.lastPrompt || '', 70)}`);
  return [...lines, '', 'Go back to one: tabby resume <number|name|id>   (● still open: it comes to the front)'].join('\n');
}
