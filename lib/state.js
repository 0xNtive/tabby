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
  focusMode: false, // Tabby Island covers Terminal windows you're not in while Claude works, until it needs you
  focusIdle: false, // focus mode keeps a window covered when it's your turn, with a "Your turn" button
};

// Everything under ~/.claude/tabby is the owner's alone (session records hold prompt excerpts):
// folders 0700, files 0600, and folders an older tabby made are tightened on the way past.
function privateDir(dir) {
  fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
  try {
    if (fs.statSync(dir).mode & 0o077) fs.chmodSync(dir, 0o700);
  } catch {}
}

export function ensureDirs() {
  privateDir(paths.root);
  privateDir(paths.sessions);
}

// Text from outside (a model's reply, a folder's name, an environment variable) with nothing a
// terminal acts on left in it: control characters (C0, DEL, C1) and bidi overrides become spaces.
const UNSAFE_TEXT = /[\x00-\x1f\x7f-\x9f\u061c\u200e\u200f\u202a-\u202e\u2066-\u2069]/g;
export const plain = (s) => String(s ?? '').replace(UNSAFE_TEXT, ' ');

export function readJson(file, fallback = null) {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch {
    return fallback;
  }
}

// Atomic. tabby's own files are the owner's alone. Any other file (Claude's settings.json) keeps
// its mode, and a symlink keeps pointing where it did: the file behind it is the one replaced.
export function writeJson(file, data) {
  let target = file;
  let mode = 0o600;
  const ours = path.resolve(file).startsWith(path.resolve(paths.root) + path.sep);
  try {
    target = fs.realpathSync(file);
    if (!ours) mode = fs.statSync(target).mode & 0o777;
  } catch {}
  if (ours) privateDir(paths.root);
  fs.mkdirSync(path.dirname(target), { recursive: true, mode: ours ? 0o700 : 0o777 });
  const tmp = `${target}.${process.pid}.${Date.now()}.tmp`;
  fs.writeFileSync(tmp, JSON.stringify(data, null, 2) + '\n', { mode });
  fs.chmodSync(tmp, mode);
  fs.renameSync(tmp, target);
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

// A session id as a file name.
export const sessionKey = (id) => String(id).replace(/[^\w.-]/g, '_');
const sessionFile = (id) => path.join(paths.sessions, `${sessionKey(id)}.json`);

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
    privateDir(paths.root);
    const line = `${new Date().toISOString()} ${args.map((a) => (typeof a === 'string' ? a : JSON.stringify(a))).join(' ')}\n`;
    const st = fs.statSync(paths.log, { throwIfNoEntry: false });
    if (st && st.size > 512 * 1024) fs.renameSync(paths.log, paths.log + '.1');
    fs.appendFileSync(paths.log, line, { mode: 0o600 });
  } catch {}
}

export function projectName(cwd) {
  return cwd ? plain(path.basename(cwd)).trim() : '';
}
