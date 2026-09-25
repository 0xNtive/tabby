// Every running Claude session: Claude's own registry joined with tabby's records, in the
// order the island lists them (needs you → working → your turn, then oldest first).
import path from 'node:path';
import { paths, readRegistry, listSessions, isAlive, projectName } from './state.js';
import { ttyOfPid, terminalTitles } from './term.js';
import { contextFromTranscript } from './context.js';

export function transcriptFor(cwd, id) {
  if (!cwd || !id) return null;
  return path.join(paths.claudeDir, 'projects', cwd.replace(/[/.]/g, '-'), `${id}.jsonl`);
}

const RANK = { waiting: 0, error: 1, busy: 2, idle: 3, new: 4, shell: 5 };

export function mergedSessions({ withTitles = true, withContext = true } = {}) {
  const reg = readRegistry();
  const recs = listSessions();
  const out = [];
  let titles = null;
  const termTitle = (tty) => (withTitles ? (titles ||= terminalTitles()).get(tty) || '' : '');
  for (const r of reg.values()) {
    if (r.kind && r.kind !== 'interactive') continue;
    const rec = recs.find((s) => s.sessionId === r.sessionId) || recs.find((s) => s.pid === r.pid && s.status !== 'ended');
    let ctx = rec?.context;
    if (withContext && !(ctx?.at && Date.now() - ctx.at < 120_000)) {
      ctx = contextFromTranscript(rec?.transcriptPath || transcriptFor(r.cwd, r.sessionId)) || ctx;
    }
    const tty = rec?.tty || ttyOfPid(r.pid);
    const claudeName = r.nameSource === 'derived' && !rec?.title ? termTitle(tty) || r.name : r.name;
    out.push({
      ...(rec || {}),
      pid: r.pid,
      sessionId: r.sessionId,
      cwd: r.cwd,
      project: rec?.project || projectName(r.cwd),
      status: r.status || rec?.status,
      waitingFor: r.waitingFor || rec?.waitingFor,
      claudeName,
      tracked: !!rec,
      context: ctx,
      tty,
      term: rec?.term || 'apple-terminal',
      startedAt: rec?.startedAt || r.startedAt,
      statusAt: r.statusUpdatedAt || rec?.statusAt,
    });
  }
  for (const s of recs) if (s.bare && isAlive(s.pid) && s.status !== 'ended') out.push({ ...s, tracked: true });
  return out.sort((a, b) => (RANK[a.status] ?? 9) - (RANK[b.status] ?? 9) || (a.startedAt || 0) - (b.startedAt || 0));
}

export const sessionTitle = (s) => s.title || s.claudeName || s.project || 'Claude';
