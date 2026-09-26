// Persistent state under ~/.claude/tabby: config, one JSON record per Claude session,
// project -> color affinity, and read access to Claude Code's own live-session registry.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const HOME = os.homedir();
const CLAUDE_DIR = process.env.CLAUDE_CONFIG_DIR || path.join(HOME, '.claude');
const ROOT = process.env.TABBY_HOME || path.join(CLAUDE_DIR, 'tabby');

export const paths = {
  claudeDir: CLAUDE_DIR,
  root: ROOT,
  sessions: path.join(ROOT, 'sessions'),
  config: path.join(ROOT, 'config.json'),
  projects: path.join(ROOT, 'projects.json'),
  themes: path.join(ROOT, 'themes.json'),
  island: path.join(ROOT, 'island.json'),
  log: path.join(ROOT, 'tabby.log'),
  backups: path.join(ROOT, 'backups'),
  registry: path.join(CLAUDE_DIR, 'sessions'),
  settings: path.join(CLAUDE_DIR, 'settings.json'),
};

export const DEFAULT_CONFIG = {
  enabled: true,
  theme: 'tabby', // default theme for new sessions
  auto: 'tint', // 'tint': one theme, a different accent tint per session | 'themes': a different theme per session
  strength: 'medium', // background tint: subtle | medium | bold
  marker: 'circle', // colored emoji in the tab title: circle | square | heart | none
  namer: 'ai', // ai (Haiku via your Claude login) | heuristic | off
  namerModel: 'haiku',
  syncClaudeName: true, // also show AI names in Claude's prompt box and /resume picker
  titleFormat: '{marker} {status} {title}',
  status: { new: '✳', busy: '◐', idle: '✳', waiting: '🔔', error: '⚠' },
  resetOnExit: true,
  watermark: true, // Tabby Island draws each session's topic, large and faint, over its Terminal window
};

export function ensureDirs() {
  fs.mkdirSync(paths.sessions, { recursive: true });
}

export function readJson(file, fallback = null) {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch {
    return fallback;
  }
}

export function writeJson(file, data) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const tmp = `${file}.${process.pid}.${Date.now()}.tmp`;
  fs.writeFileSync(tmp, JSON.stringify(data, null, 2) + '\n');
  fs.renameSync(tmp, file);
}

export function readConfig() {
  const user = readJson(paths.config, {}) || {};
  return { ...DEFAULT_CONFIG, ...user, status: { ...DEFAULT_CONFIG.status, ...(user.status || {}) } };
}

export function writeConfig(patch) {
  const cur = readJson(paths.config, {}) || {};
  writeJson(paths.config, { ...cur, ...patch });
  return readConfig();
}

const sessionFile = (id) => path.join(paths.sessions, `${String(id).replace(/[^\w.-]/g, '_')}.json`);

export function readSession(id) {
  return id ? readJson(sessionFile(id)) : null;
}

// Patch semantics: re-read right before writing so concurrent hooks don't clobber each other.
export function patchSession(id, patch) {
  const cur = readSession(id) || { v: 1, sessionId: id, startedAt: Date.now() };
  const next = { ...cur, ...patch, updatedAt: Date.now() };
  writeJson(sessionFile(id), next);
  return next;
}

export function deleteSession(id) {
  try {
    fs.unlinkSync(sessionFile(id));
  } catch {}
}

export function listSessions() {
  let names = [];
  try {
    names = fs.readdirSync(paths.sessions).filter((n) => n.endsWith('.json'));
  } catch {}
  return names.map((n) => readJson(path.join(paths.sessions, n))).filter(Boolean);
}

export function isAlive(pid) {
  if (!pid) return false;
  try {
    process.kill(Number(pid), 0);
    return true;
  } catch (e) {
    return e.code === 'EPERM';
  }
}

// Claude Code keeps ~/.claude/sessions/<pid>.json for every running session (name, status, cwd).
export function readRegistry() {
  const out = new Map();
  let names = [];
  try {
    names = fs.readdirSync(paths.registry).filter((n) => /^\d+\.json$/.test(n));
  } catch {}
  for (const n of names) {
    const r = readJson(path.join(paths.registry, n));
    if (r && r.pid && isAlive(r.pid)) out.set(Number(r.pid), r);
  }
  return out;
}

export function registryEntry(pid) {
  const r = pid ? readJson(path.join(paths.registry, `${pid}.json`)) : null;
  return r && r.pid ? r : null;
}

// Live sessions = records whose Claude process is still running and not ended.
export function liveSessions() {
  return listSessions().filter((s) => s.status !== 'ended' && isAlive(s.pid));
}

export function readProjects() {
  return readJson(paths.projects, {}) || {};
}

export function rememberProjectColor(cwd, theme, accentKey) {
  if (!cwd || !accentKey) return;
  const p = readProjects();
  p[cwd] = { theme, accentKey, at: Date.now() };
  writeJson(paths.projects, p);
}

// Drop records of sessions that ended more than `days` ago (kept for a while so resumes keep their name).
export function pruneSessions(days = 30) {
  const cutoff = Date.now() - days * 864e5;
  for (const s of listSessions()) {
    const dead = s.status === 'ended' || !isAlive(s.pid);
    if (dead && (s.updatedAt || 0) < cutoff) deleteSession(s.sessionId);
  }
}

export function log(...args) {
  try {
    fs.mkdirSync(paths.root, { recursive: true });
    const line = `${new Date().toISOString()} ${args.map((a) => (typeof a === 'string' ? a : JSON.stringify(a))).join(' ')}\n`;
    const st = fs.statSync(paths.log, { throwIfNoEntry: false });
    if (st && st.size > 512 * 1024) fs.renameSync(paths.log, paths.log + '.1');
    fs.appendFileSync(paths.log, line);
  } catch {}
}

export function projectName(cwd) {
  return cwd ? path.basename(cwd) : '';
}
