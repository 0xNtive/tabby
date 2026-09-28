// Recent and frequently used project folders, for starting a new session fast (the island's
// quick launch, `tabby new --list`). Ranked by frecency: every session started in a folder counts,
// recent ones far more than old ones. Sources: tabby's session records, Claude Code's own history
// (~/.claude/projects: one transcript per session, its cwd inside) and the sessions running now.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { paths, listSessions, readRegistry, projectName } from './state.js';

const HOUR = 3600e3;
const DAY = 24 * HOUR;

// What one visit is worth by its age (like a browser's frecency).
export function weight(age) {
  if (age < 4 * HOUR) return 100;
  if (age < DAY) return 70;
  if (age < 3 * DAY) return 50;
  if (age < 7 * DAY) return 30;
  if (age < 30 * DAY) return 15;
  return 5;
}

// A folder as it is on disk (macOS: "~/dev/x" and "~/Dev/x" are one folder), or null if it's gone.
function onDisk(p) {
  try {
    return fs.statSync(p).isDirectory() ? fs.realpathSync.native(p) : null;
  } catch {
    return null;
  }
}

// visits: [{ path, at, live? }] → [{ path, name, score, sessions, lastUsed, live }], best first.
// Only folders that exist; never temporary ones.
export function rankFolders(visits, { now = Date.now(), resolve = onDisk, limit = 40 } = {}) {
  const temp = [os.tmpdir(), '/tmp', '/private/tmp', '/var/folders', '/private/var/folders'].map((p) => p.replace(/\/$/, ''));
  const resolved = new Map();
  const byPath = new Map();
  for (const v of visits) {
    if (!v?.path || !path.isAbsolute(v.path)) continue;
    if (!resolved.has(v.path)) resolved.set(v.path, resolve(v.path));
    const p = resolved.get(v.path);
    if (!p || temp.some((t) => p === t || p.startsWith(`${t}/`))) continue;
    const f = byPath.get(p) || { path: p, name: projectName(p) || path.basename(p) || p, score: 0, sessions: 0, lastUsed: 0, live: 0 };
    const at = Math.min(v.at || 0, now);
    f.score += weight(now - at) + (v.live ? 25 : 0);
    f.sessions += v.live ? 0 : 1;
    f.live += v.live ? 1 : 0;
    f.lastUsed = Math.max(f.lastUsed, at);
    byPath.set(p, f);
  }
  return [...byPath.values()]
    .sort((a, b) => b.score - a.score || b.lastUsed - a.lastUsed || a.path.localeCompare(b.path))
    .slice(0, limit);
}

// The cwd a project's transcripts were written in (the folder name alone is lossy: "/" and "."
// both become "-"). Reads the start of its newest transcript.
function projectCwd(dir, files) {
  for (const f of files) {
    let fd;
    try {
      fd = fs.openSync(path.join(dir, f.name), 'r');
      const buf = Buffer.alloc(64 * 1024);
      const n = fs.readSync(fd, buf, 0, buf.length, 0);
      const m = /"cwd"\s*:\s*"((?:[^"\\]|\\.)*)"/.exec(buf.toString('utf8', 0, n));
      if (m) return JSON.parse(`"${m[1]}"`);
    } catch {
    } finally {
      if (fd !== undefined) fs.closeSync(fd);
    }
  }
  return null;
}

// Every visit tabby can find (see rankFolders): one per session, however many sources know it.
export function collectVisits({ perProject = 40 } = {}) {
  const visits = [];
  const seen = new Set();
  const projects = path.join(paths.claudeDir, 'projects');
  let dirs = [];
  try {
    dirs = fs.readdirSync(projects, { withFileTypes: true }).filter((d) => d.isDirectory());
  } catch {}
  for (const d of dirs) {
    const dir = path.join(projects, d.name);
    let files = [];
    try {
      files = fs
        .readdirSync(dir)
        .filter((n) => n.endsWith('.jsonl'))
        .map((name) => {
          try {
            return { name, at: fs.statSync(path.join(dir, name)).mtimeMs };
          } catch {
            return null;
          }
        })
        .filter(Boolean)
        .sort((a, b) => b.at - a.at)
        .slice(0, perProject);
    } catch {}
    if (!files.length) continue;
    const cwd = projectCwd(dir, files.slice(0, 3));
    if (!cwd) continue;
    for (const f of files) {
      visits.push({ path: cwd, at: f.at });
      seen.add(f.name.replace(/\.jsonl$/, ''));
    }
  }
  for (const s of listSessions()) {
    if (s.cwd && !s.bare && !seen.has(s.sessionId)) visits.push({ path: s.cwd, at: s.updatedAt || s.startedAt || 0 });
  }
  const now = Date.now();
  for (const r of readRegistry().values()) {
    if (r.cwd && (!r.kind || r.kind === 'interactive')) visits.push({ path: r.cwd, at: now, live: true });
  }
  return visits;
}

export const recentFolders = (opts = {}) => rankFolders(collectVisits(opts), opts);
