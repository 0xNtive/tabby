// Claude sessions that were already open when tabby was set up. Claude Code loads a plugin's
// hooks only when a session starts (or on /reload-plugins), but hooks in settings.json reach
// sessions that are already running (verified on Claude Code 2.1.296). So setup adopts the open
// sessions (their colors right away) and adds tabby's hooks to settings.json for those Claude
// processes only: names, status and /tab follow without a restart or a /reload-plugins.
//
// For any one Claude process exactly one side answers: these hooks for the processes listed in
// bridge.json, the plugin's for every other (bin/tabby.sh drops the rest before Node starts).
// Once the last listed process has ended, the hooks come out of settings.json again.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  paths, readJson, writeJson, readConfig, patchSession, readRegistry, liveSessions, isAlive,
  projectName, rememberProjectColor, readSettings, backupSettings, log,
} from './state.js';
import { detectTerminal, whereFrom, ttyOfPid, envOfPid, terminalTitles } from './term.js';
import { chooseLook } from './assign.js';
import { withLook, applySession } from './apply.js';
import { transcriptFor } from './sessions.js';

const FILE = path.join(paths.root, 'bridge.json');
const PIDS = path.join(paths.root, 'bridge.pids'); // the same pids, one per line, for bin/tabby.sh
const LAUNCHER_SH = path.join(paths.root, 'bin', 'tabby');
const PLUGIN_HOOKS = fileURLToPath(new URL('../hooks/hooks.json', import.meta.url));
const SH = fileURLToPath(new URL('../bin/tabby.sh', import.meta.url));

const command = (event) => `sh "${LAUNCHER_SH}" hook ${event} --bridge`;
const isOurs = (h) => typeof h?.command === 'string' && /tabby"? hook \w+ --bridge$/.test(h.command);
const hasOurs = (group) => Array.isArray(group?.hooks) && group.hooks.some(isOurs);

// The plugin's own events, timeouts and async flags, through the launcher.
export function bridgeHooks() {
  const plugin = readJson(PLUGIN_HOOKS, {})?.hooks || {};
  return Object.fromEntries(Object.entries(plugin).map(([event, groups]) => {
    const h = groups?.[0]?.hooks?.[0] || {};
    return [event, [{ hooks: [{ type: 'command', command: command(event), timeout: h.timeout || 10, ...(h.async ? { async: true } : {}) }] }]];
  }));
}

export const pids = () => (readJson(FILE, null)?.pids || []).map(Number).filter(Boolean);
export const has = (pid) => !!Number(pid) && pids().includes(Number(pid));

// Still running: alive and in Claude's registry (a reused pid isn't a Claude session).
const running = (pid, reg = readRegistry()) => isAlive(pid) && reg.has(Number(pid));

export function installed(settings = readSettings()) {
  return Object.values(settings?.hooks || {}).some((groups) => Array.isArray(groups) && groups.some(hasOurs));
}

export function withHooks(settings) {
  const hooks = { ...(settings.hooks || {}) };
  for (const [event, groups] of Object.entries(bridgeHooks())) {
    const cur = Array.isArray(hooks[event]) ? hooks[event] : [];
    if (!cur.some(hasOurs)) hooks[event] = [...cur, ...groups];
  }
  return { ...settings, hooks };
}

// Only what the bridge added goes: your own hooks, and their order, stay as they were.
export function withoutHooks(settings) {
  if (!installed(settings)) return settings;
  const hooks = {};
  for (const [event, groups] of Object.entries(settings.hooks)) {
    if (!Array.isArray(groups) || !groups.some(hasOurs)) {
      hooks[event] = groups;
      continue;
    }
    const kept = groups
      .map((g) => (hasOurs(g) ? { ...g, hooks: g.hooks.filter((h) => !isOurs(h)) } : g))
      .filter((g, i) => !hasOurs(groups[i]) || g.hooks.length);
    if (kept.length) hooks[event] = kept;
  }
  const out = { ...settings, hooks };
  if (!Object.keys(hooks).length) delete out.hooks;
  return out;
}

function writePids(list) {
  if (!list.length) {
    for (const f of [FILE, PIDS]) try { fs.unlinkSync(f); } catch {}
    return;
  }
  writeJson(FILE, { pids: list, at: Date.now() });
  const tmp = `${PIDS}.${process.pid}.tmp`;
  fs.writeFileSync(tmp, list.join('\n') + '\n', { mode: 0o600 });
  fs.renameSync(tmp, PIDS);
}

// One read of the terminal's tab titles per terminal app, and only of the app this runs in: asking
// another one would be a new macOS automation prompt in the middle of setup.
function titleReader() {
  const here = detectTerminal();
  const seen = new Map();
  return (term) => {
    if (term !== here) return new Map();
    if (!seen.has(term)) seen.set(term, terminalTitles(term));
    return seen.get(term);
  };
}

// Colors now for a session tabby hasn't seen (it started before tabby); its hooks fill in the rest.
export function adoptOne(r, titlesFor = titleReader()) {
  const tty = ttyOfPid(r.pid);
  if (!tty) return null;
  const env = envOfPid(r.pid);
  const where = whereFrom(Object.keys(env).length ? env : process.env);
  const cfg = readConfig();
  const title = titlesFor(where.term).get(tty) || '';
  const auto = chooseLook({ cwd: r.cwd, sessionId: r.sessionId }, cfg, liveSessions());
  const rec = patchSession(
    r.sessionId,
    withLook({
      v: 1, sessionId: r.sessionId, pid: r.pid, tty, ...where, cwd: r.cwd, project: projectName(r.cwd),
      ownsTitle: false, status: r.status || 'idle', statusAt: Date.now(), title, titleSource: title ? 'claude' : 'project',
      adopted: true, transcriptPath: transcriptFor(r.cwd, r.sessionId), startedAt: r.startedAt || Date.now(), ...auto,
    }, cfg)
  );
  applySession(rec, cfg, { colors: true, title: false });
  rememberProjectColor(rec.cwd, rec.theme, rec.accentKey);
  return rec;
}

// Every open Claude session tabby isn't answering for: adopted (colors now), and bridged when
// settings.json can take the hooks. `only` narrows it to sessions matching some text.
// Returns { adopted: [records], count: bridged sessions, hooks: bool, why }.
export function open({ only = null } = {}) {
  const reg = readRegistry();
  // Run from a plugin hook (/tabby:setup), this session already has the plugin's hooks.
  const self = process.env.CLAUDE_PLUGIN_ROOT ? Number(process.env.CLAUDE_PID) || 0 : 0;
  const live = liveSessions();
  const titlesFor = titleReader();
  const list = new Set(pids().filter((p) => running(p, reg)));
  const adopted = [];
  for (const r of reg.values()) {
    if ((r.kind && r.kind !== 'interactive') || Number(r.pid) === self) continue;
    if (only && !`${r.cwd} ${r.name} ${r.pid}`.toLowerCase().includes(String(only).toLowerCase())) continue;
    const rec = live.find((s) => s.pid === r.pid);
    if (rec && !rec.adopted) continue; // started with the plugin's hooks
    list.add(Number(r.pid));
    if (!rec) {
      const a = adoptOne(r, titlesFor);
      if (a) adopted.push(a);
    }
  }
  const ids = [...list];
  if (!ids.length) return { adopted, count: 0, hooks: false };
  const settings = readSettings();
  const why = !settings ? "settings.json isn't valid JSON" : settings.disableAllHooks ? 'hooks are turned off in settings.json (disableAllHooks)' : null;
  if (why) return { adopted, count: ids.length, hooks: false, why };
  // The sh launcher drops other sessions' calls before Node starts; one from before the bridge can't.
  try {
    if (fs.existsSync(LAUNCHER_SH) && !fs.readFileSync(LAUNCHER_SH, 'utf8').includes('--bridge')) fs.copyFileSync(SH, LAUNCHER_SH);
  } catch {}
  writePids(ids);
  if (!installed(settings)) {
    backupSettings();
    writeJson(paths.settings, withHooks(settings));
  }
  log('bridge: open for', ids.join(','));
  return { adopted, count: ids.length, hooks: true };
}

// The hooks come out once none of the bridged Claude processes is running (`leaving`: the one
// whose session is ending right now).
export function tidy({ leaving = 0 } = {}) {
  if (!fs.existsSync(FILE) && !installed()) return false;
  const reg = readRegistry();
  if (pids().some((p) => p !== Number(leaving) && running(p, reg))) return false;
  close('its sessions have ended');
  return true;
}

export function close(reason = '') {
  writePids([]);
  const settings = readSettings();
  if (settings && installed(settings)) {
    backupSettings();
    writeJson(paths.settings, withoutHooks(settings));
    log(`bridge: closed (${reason})`);
    return true;
  }
  return false;
}

// One line for setup and `tabby adopt`.
export function describe(res) {
  if (!res.count && !res.adopted.length) return null;
  const n = res.count || res.adopted.length;
  const s = n === 1 ? 'session' : 'sessions';
  if (res.hooks) return `the ${n} Claude ${s} already open ${n === 1 ? 'is' : 'are'} on too: colors now, names and status from the next prompt, /tab works there`;
  return `the ${n} Claude ${s} already open got ${n === 1 ? 'its color' : 'their colors'}; for names, status and /tab type /reload-plugins in each${res.why ? ` (${res.why})` : ''}`;
}
