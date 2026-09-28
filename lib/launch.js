// `tabby new`: a new terminal window running claude in a folder, on the screen you keep Claude
// sessions on. The island's quick launch (⌃⌥L) calls this too.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { readConfig, liveSessions } from './state.js';
import { detectTerminal } from './term.js';
import { listScreens, chooseScreens, parseSelection, centered } from './screens.js';
import { recentFolders } from './recent.js';

export const SKIP_PERMISSIONS = '--dangerously-skip-permissions';

const shq = (s) => `'${String(s).replace(/'/g, `'\\''`)}'`;
const asq = (s) => String(s).replace(/\\/g, '\\\\').replace(/"/g, '\\"');
const home = (p) => (p.startsWith(`${os.homedir()}/`) ? `~${p.slice(os.homedir().length)}` : p);

// A folder from what was typed: a path (~ works), else the best recent folder whose name matches.
export function resolveFolder(input, folders = null) {
  const raw = String(input || '').trim();
  if (!raw) return { dir: process.cwd() };
  const expanded = raw === '~' ? os.homedir() : raw.startsWith('~/') ? path.join(os.homedir(), raw.slice(2)) : raw;
  const abs = path.resolve(expanded);
  if (fs.existsSync(abs) && fs.statSync(abs).isDirectory()) return { dir: abs };
  if (raw.includes('/')) return { error: `No such folder: ${raw}` };
  const q = raw.toLowerCase();
  const list = folders || recentFolders();
  const exact = list.find((f) => f.name.toLowerCase() === q) || list.find((f) => path.basename(f.path).toLowerCase() === q);
  if (exact) return { dir: exact.path };
  const loose = list.find((f) => f.name.toLowerCase().includes(q));
  return loose ? { dir: loose.path, loose: true } : { error: `No folder "${raw}" here or among your recent ones (tabby new --list).` };
}

// The command typed into the new window.
export function claudeCommand(dir, { name, dangerous = false, color, theme } = {}) {
  const env = [color && `TABBY_COLOR=${shq(color)}`, theme && `TABBY_THEME=${shq(theme)}`].filter(Boolean).join(' ');
  const args = [name && `--name ${shq(name)}`, dangerous && SKIP_PERMISSIONS].filter(Boolean).join(' ');
  return `cd ${shq(dir)} && ${env ? `${env} ` : ''}claude${args ? ` ${args}` : ''}`;
}

// Terminal.app or iTerm2: asked for, the one this runs in, else the one your sessions use.
export function pickTerminal(asked, here = detectTerminal(), sessions = null) {
  const want = String(asked || '').toLowerCase();
  if (/iterm/.test(want)) return 'iterm2';
  if (/terminal|apple/.test(want)) return 'apple-terminal';
  if (here === 'iterm2' || here === 'apple-terminal') return here;
  const counts = {};
  for (const s of sessions || liveSessions()) if (s.term === 'iterm2' || s.term === 'apple-terminal') counts[s.term] = (counts[s.term] || 0) + 1;
  return (counts.iterm2 || 0) > (counts['apple-terminal'] || 0) ? 'iterm2' : 'apple-terminal';
}

// Where the window goes: `--screen` for this one, else your tiling screens when you picked some
// (the first of them); with the default ("the screen you're on"), wherever the terminal puts it.
export function placement(screenArg, cfg = readConfig(), screens = null) {
  const pref = screenArg ? null : cfg.tileScreens;
  if (!screenArg && !Array.isArray(pref) && pref !== 'all') return null;
  const connected = screens || listScreens();
  if (!connected.length) return null;
  let value = pref;
  if (screenArg) {
    const parsed = parseSelection(screenArg, connected);
    if (parsed.error) return { error: parsed.error };
    value = parsed.value;
  }
  const { screens: chosen } = chooseScreens(connected, value);
  const screen = value === 'all' ? chosen.find((s) => s.current) || chosen[0] : chosen[0];
  return screen ? { screen, rect: centered(screen) } : null;
}

export function launchScript(term, cmd, rect) {
  const bounds = rect ? `{${rect.join(', ')}}` : null;
  if (term === 'iterm2') {
    return `tell application "iTerm2"
  set w to (create window with default profile)
  tell current session of w to write text "${asq(cmd)}"
${bounds ? `  set bounds of w to ${bounds}\n` : ''}  activate
end tell`;
  }
  return `tell application "Terminal"
  do script "${asq(cmd)}"
${bounds ? `  set bounds of front window to ${bounds}\n` : ''}  activate
end tell`;
}

// opts: dir (a path or a recent folder's name), name, dangerous, color, theme, term, screen, dryRun.
export function newSession(opts = {}) {
  const where = resolveFolder(opts.dir, opts.folders);
  if (where.error) return where.error;
  // Skipping permissions in a folder guessed from part of its name is too easy to get wrong.
  if (opts.dangerous && where.loose) return `"${opts.dir}" only partly matches ${home(where.dir)}. To skip permissions, give the folder's full name or path.`;
  const term = pickTerminal(opts.term);
  const place = placement(opts.screen);
  if (place?.error) return place.error;
  const cmd = claudeCommand(where.dir, opts);
  const script = launchScript(term, cmd, place?.rect);
  const what = `${home(where.dir)}${opts.name ? ` as "${opts.name}"` : ''} in ${term === 'iterm2' ? 'iTerm2' : 'Terminal'}${opts.dangerous ? ', skipping permissions' : ''}${place ? ` on ${place.screen.name || 'your screen'}` : ''}`;
  if (opts.dryRun) return `Would open ${what}:\n  ${cmd}`;
  const r = spawnSync('osascript', ['-e', script], { encoding: 'utf8', timeout: 20_000 });
  return r.status === 0 ? `Opened ${what}.` : `Could not open a terminal: ${(r.stderr || '').trim()}`;
}

// `tabby new --list`: the folders quick launch offers, best first.
export function listFolders({ json = false, limit = 20 } = {}) {
  const folders = recentFolders({ limit: limit > 0 ? limit : Infinity });
  if (json) return JSON.stringify(folders.map((f) => ({ ...f, display: home(f.path) })), null, 2);
  if (!folders.length) return 'No recent folders yet: they come from the Claude sessions you run.';
  const ago = (ms) => {
    const m = Math.max(0, Math.round((Date.now() - ms) / 60_000));
    return m < 60 ? `${m}m` : m < 1440 ? `${Math.round(m / 60)}h` : `${Math.round(m / 1440)}d`;
  };
  return folders.map((f, i) => `${String(i + 1).padStart(3)}  ${f.name.padEnd(22)} ${home(f.path).padEnd(42)} ${f.sessions} session${f.sessions === 1 ? '' : 's'}${f.live ? `, ${f.live} running` : ''} · ${ago(f.lastUsed)} ago`).join('\n');
}
