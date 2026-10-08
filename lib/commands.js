// The /tab command language, shared by the in-Claude slash command (intercepted by the
// UserPromptSubmit hook, so it costs no tokens) and the `tabby` CLI.
import { THEMES, ACCENT_KEYS, findTheme, strictTheme, getTheme, parseColor, accentHex, themesExport } from './themes.js';
import { readConfig, writeConfig, patchSession, liveSessions, rememberProjectColor, writeJson, paths, plain } from './state.js';
import { withLook, applySession, clearSession, displayTitle } from './apply.js';
import { chooseLook } from './assign.js';
import { spawnNamer, heuristicTitle } from './namer.js';
import { markerFor, STRENGTHS, MARKER_STYLES } from './color.js';
import { claudeMode } from './claude-palette.js';
import { tile, next, screensCommand } from './tile.js';
import { cached as cachedUpdate, updateInBackground } from './update.js';
import { runSetup } from './setup.js';
import { spawnProfile } from './terminal-prefs.js';

export const isTabCommand = (prompt) => /^\s*\/(?:tabby:)?tab(?:\s|$)/i.test(String(prompt || ''));
export const tabArgs = (prompt) => String(prompt || '').trim().replace(/^\/(?:tabby:)?tab\b/i, '').trim();

const unquote = (s) => s.trim().replace(/^(["'])(.*)\1$/s, '$2').trim();
const STATUS_WORDS = { new: 'new', busy: 'working', idle: 'your turn', waiting: 'needs you', error: 'error', ended: 'ended' };

function repaint(rec, cfg, { colors = true } = {}) {
  applySession(rec, cfg, { colors, title: true });
  return rec;
}

// A fresh automatic name: the model's when the namer is "ai"; worked out here, with nothing
// leaving the machine, when it's "heuristic"; none when it's off.
function autoName(rec, cfg) {
  if (!(rec.prompts || []).length) return { rec, note: 'a name arrives after your next prompt.' };
  if (cfg.namer === 'ai') {
    spawnNamer(rec.sessionId);
    return { rec, note: 'a fresh AI name arrives in a few seconds.' };
  }
  if (cfg.namer === 'heuristic') {
    const title = heuristicTitle(rec.prompts.at(-1));
    const next = title ? repaint(patchSession(rec.sessionId, { title, titleSource: 'heuristic' }), cfg, { colors: false }) : rec;
    return { rec: next, note: 'named on this machine (the namer is set to heuristic; /tab namer ai for AI names).' };
  }
  return { rec, note: 'automatic names are off (/tab namer ai or heuristic turns them on).' };
}

function exportThemes(cfg) {
  try {
    writeJson(paths.themes, themesExport(cfg.theme));
  } catch {}
}

function sessionLine(s, cfg) {
  const glyph = cfg.status[s.status] || '';
  const ctx = s.context?.usedPct != null ? ` · ${s.context.usedPct}% ctx` : '';
  return `${markerFor(s.accent, 'circle')} ${glyph} ${displayTitle(s)} — ${s.project || '?'}${ctx} · ${STATUS_WORDS[s.status] || s.status}`;
}

export function helpText(rec, cfg) {
  const who = rec
    ? `${markerFor(rec.accent, 'circle')} ${displayTitle(rec)} · ${rec.accentKey} · ${getTheme(rec.theme).name} · ${rec.titleSource === 'ai' ? 'AI-named' : MANUAL_LABEL[rec.titleSource] || 'waiting for first prompt'}`
    : 'No tabby session in this tab.';
  return [
    who,
    '',
    '/tab <name>              rename this tab         /tab auto        back to AI names',
    `/tab color <color>       ${ACCENT_KEYS.join(' ')} · next · #hex`,
    '/tab theme <theme>       this tab only           /tab theme <theme> all → every tab',
    '/tab themes · /tab colors · /tab ls · /tab note <text> · /tab reset · /tab off|on',
    '/tab tile [2|3|4|6|8] [active|all]   fill your screens with session windows, each in its own color   /tab next   jump to who needs you',
    '/tab tile colors on|off  whether tiling recolors the windows (hand-picked colors always stay)',
    '/tab update             get the newest tabby (plugin, setup, island), in the background',
    '/tab watermark [on|off]  the topic in large, faint letters over each Terminal window (Tabby Island)',
    "/tab focus-mode [on|off] cover Terminal windows you're not in while Claude works, until it needs you",
    "/tab focus-mode idle [on|off]   when Claude is done: the gist of its reply and a Show full reply button (on), or the whole reply (off)",
    `/tab strength subtle|medium|bold · /tab marker ${MARKER_STYLES.join('|')} · /tab mode tint|themes`,
  ].join('\n');
}
// "ctrl+opt+w" (config) → "⌃⌥W". Null when that shortcut is off.
const MOD_SYMBOLS = { ctrl: '⌃', control: '⌃', opt: '⌥', option: '⌥', alt: '⌥', shift: '⇧', cmd: '⌘', command: '⌘' };
export function islandShortcut(cfg, action, fallback) {
  if (cfg.islandHotkeys === false) return null;
  const spec = cfg.islandShortcuts?.[action];
  if (spec === undefined) return fallback;
  if (!spec) return null;
  const parts = String(spec).toLowerCase().split('+');
  const key = parts.pop();
  const mods = '⌃⌥⇧⌘'.split('').filter((m) => parts.some((p) => MOD_SYMBOLS[p] === m)).join('');
  return mods + (key === 'space' ? 'Space' : key.toUpperCase());
}

const MANUAL_LABEL = { manual: 'named by you', user: 'named with /rename', heuristic: 'auto-named', project: 'waiting for first prompt' };

function themeList(cfg, current) {
  const rows = THEMES.map((t) => {
    const dots = Object.values(t.accents).slice(0, 6).map((h) => markerFor(h, 'circle')).join('');
    const mark = t.id === current ? '▸' : ' ';
    return `${mark} ${t.id.padEnd(18)} ${dots.padEnd(12)} ${t.mode}${t.calm ? ' · calm' : ''}${t.id === cfg.theme ? ' · default' : ''}`;
  });
  return ['Themes (/tab theme <name>, add "all" for every tab):', ...rows].join('\n');
}

function colorList(rec, cfg) {
  const theme = getTheme(rec?.theme || cfg.theme);
  const used = new Set(liveSessions().filter((s) => s.sessionId !== rec?.sessionId && s.theme === theme.id).map((s) => s.accentKey));
  const rows = ACCENT_KEYS.map((k) => {
    const hex = accentHex(theme, k);
    const tag = rec?.accentKey === k ? ' ◂ this tab' : used.has(k) ? ' · in use' : '';
    return `${markerFor(hex, 'circle')} ${k.padEnd(7)} ${hex}${tag}`;
  });
  return [`Colors in ${theme.name} (/tab color <name>):`, ...rows].join('\n');
}

function setColor(rec, cfg, word) {
  const theme = getTheme(rec.theme || cfg.theme);
  let key = parseColor(word);
  const keys = Object.keys(theme.accents);
  if (word === 'next' || word === 'random') {
    const pool = ACCENT_KEYS.filter((k) => keys.includes(k));
    const i = pool.indexOf(rec.accentKey);
    key = word === 'next' ? pool[(i + 1) % pool.length] : pool.filter((k) => k !== rec.accentKey)[Math.floor(Math.random() * (pool.length - 1))];
  } else if (word === 'auto') {
    key = chooseLook({ cwd: rec.cwd, sessionId: rec.sessionId }, { ...cfg, auto: 'tint', theme: theme.id }).accentKey;
  }
  if (!key) return { message: `Unknown color "${word}". Try: ${ACCENT_KEYS.join(', ')}, next, auto or a #hex.` };
  // Picked by hand (unless "auto"): tiling leaves it alone when it recolors windows.
  const source = word === 'auto' ? 'auto' : 'manual';
  const next = repaint(patchSession(rec.sessionId, withLook({ ...rec, accentKey: key, lookSource: source }, cfg)), cfg);
  rememberProjectColor(next.cwd, next.theme, next.accentKey);
  return { message: `${markerFor(next.accent, 'circle')} Color → ${key} (${next.accent}) · ${getTheme(next.theme).name}` };
}

// Claude Code draws its UI in one global theme (white text when dark, black when light), so a
// tabby theme of the other mode leaves Claude's own text unreadable.
export function modeWarning(theme) {
  const claude = claudeMode();
  if (theme.mode === claude) return '';
  return theme.mode === 'light'
    ? `\nHeads-up: Claude Code is on its dark theme, which draws white text: unreadable on ${theme.name}. Type /theme and pick a light Claude theme, or choose a dark tabby theme.`
    : `\nHeads-up: Claude Code is on its light theme, which draws black text: unreadable on ${theme.name}. Type /theme and pick a dark Claude theme, or choose a light tabby theme.`;
}

function setTheme(rec, cfg, word, all) {
  const theme = findTheme(word);
  if (!theme) return { message: `Unknown theme "${word}".\n\n${themeList(cfg, rec?.theme)}` };
  if (all) {
    const cfg2 = writeConfig({ theme: theme.id });
    exportThemes(cfg2);
    const sessions = liveSessions();
    for (const s of sessions) repaint(patchSession(s.sessionId, withLook({ ...s, theme: theme.id }, cfg2)), cfg2);
    return { message: `Theme → ${theme.name} for all ${sessions.length} tab${sessions.length === 1 ? '' : 's'} (and new ones).${modeWarning(theme)}` };
  }
  if (!rec) return { message: 'No session here — use "all" to change every tab.' };
  const next = repaint(patchSession(rec.sessionId, withLook({ ...rec, theme: theme.id, lookSource: 'manual' }, cfg)), cfg);
  rememberProjectColor(next.cwd, next.theme, next.accentKey);
  return { message: `${markerFor(next.accent, 'circle')} Theme → ${theme.name} for this tab · "/tab theme ${theme.id} all" for every tab${modeWarning(theme)}` };
}

function setGlobal(cfg, patch, label) {
  const cfg2 = writeConfig(patch);
  for (const s of liveSessions()) repaint(patchSession(s.sessionId, withLook(s, cfg2)), cfg2);
  return { message: label };
}

// args: the text after "/tab". ctx: { rec, cfg, all }.
export function runCommand(args, { rec, cfg = readConfig(), all = false } = {}) {
  const raw = String(args || '').trim();
  const [first = '', ...restWords] = raw.split(/\s+/);
  const verb = first.toLowerCase();
  const rest = raw.slice(first.length).trim();
  const wantsAll = all || /\s(all|--all|everywhere|everything)$/i.test(' ' + rest);
  const restNoAll = rest.replace(/\s*(all|--all|everywhere|everything)$/i, '').trim();

  if (!verb || verb === 'help' || verb === '?' || verb === '-h' || verb === '--help') return { message: helpText(rec, cfg) };
  if (verb === 'themes') return { message: themeList(cfg, rec?.theme) };
  if (verb === 'colors' || verb === 'colours') return { message: colorList(rec, cfg) };
  if (verb === 'ls' || verb === 'list' || verb === 'sessions') {
    const live = liveSessions().sort((a, b) => (a.startedAt || 0) - (b.startedAt || 0));
    return { message: live.length ? [`${live.length} Claude session${live.length === 1 ? '' : 's'}:`, ...live.map((s) => sessionLine(s, cfg))].join('\n') : 'No live sessions.' };
  }
  if (verb === 'update') {
    const u = cachedUpdate();
    updateInBackground();
    return { message: `Updating tabby in the background${u.available ? ` to ${u.latest}` : ''}: the plugin, then Tabby Island (it restarts if it needs to). When it's done, type /reload-plugins here. Progress: ~/.claude/tabby/update.log` };
  }
  if (verb === 'tile' && restWords[0]?.toLowerCase() === 'screens') return { message: screensCommand(restWords.slice(1).join(' ')) };
  if (verb === 'tile' && /^(colou?rs|recolou?r)$/i.test(restWords[0] || '')) {
    const word = (restWords[1] || '').toLowerCase();
    const on = ['on', 'true', 'yes'].includes(word) ? true : ['off', 'false', 'no'].includes(word) ? false : word ? null : cfg.tileRecolor === false;
    if (on === null) return { message: `Tile colors: on | off (now ${cfg.tileRecolor === false ? 'off' : 'on'})` };
    writeConfig({ tileRecolor: on });
    return {
      message: on
        ? 'Tiling now gives each window its own color, with windows side by side far apart. Colors you picked with /tab color stay.'
        : 'Tiling leaves colors as they are. /tab tile colors on brings it back.',
    };
  }
  if (verb === 'tile') {
    // /tab tile [n] [active|all]
    const n = Number(restWords.find((w) => /^\d+$/.test(w))) || undefined;
    const words = restWords.map((w) => w.toLowerCase());
    return { message: tile(n, { active: words.includes('active'), all: words.includes('all') }) };
  }
  if (verb === 'next') return { message: next() };
  if (verb === 'island') return { message: runSetup('island') };
  if (verb === 'theme' && !restNoAll) return { message: themeList(cfg, rec?.theme) };
  if (verb === 'theme') return setTheme(rec, cfg, restNoAll, wantsAll);
  if (verb === 'strength' || verb === 'tint') {
    if (!Object.hasOwn(STRENGTHS, restWords[0] || '')) return { message: `Strength: ${Object.keys(STRENGTHS).join(' | ')} (now ${cfg.strength})` };
    return setGlobal(cfg, { strength: restWords[0] }, `Tint strength → ${restWords[0]} for all tabs.`);
  }
  if (verb === 'marker') {
    if (!MARKER_STYLES.includes(restWords[0])) return { message: `Marker: ${MARKER_STYLES.join(' | ')} (now ${cfg.marker})` };
    return setGlobal(cfg, { marker: restWords[0] }, `Title marker → ${restWords[0]}.`);
  }
  if (verb === 'mode') {
    if (!['tint', 'themes'].includes(restWords[0])) return { message: `Mode: tint (one theme, a tint per tab) | themes (a different theme per tab). Now ${cfg.auto}.` };
    writeConfig({ auto: restWords[0] });
    return { message: `Auto mode → ${restWords[0]} (applies to new sessions; "/tab reset" to re-roll this one).` };
  }
  if (verb === 'watermark' || verb === 'wm') {
    const word = (restWords[0] || '').toLowerCase();
    const on = ['on', 'true', 'yes'].includes(word) ? true : ['off', 'false', 'no'].includes(word) ? false : word ? null : cfg.watermark === false;
    if (on === null) return { message: `Watermark: on | off (now ${cfg.watermark === false ? 'off' : 'on'})` };
    writeConfig({ watermark: on });
    const key = islandShortcut(cfg, 'watermark', '⌃⌥W');
    return {
      message: on
        ? `Watermark on: Tabby Island shows each session's topic in large, faint letters over its Terminal window.${key ? ` ${key} toggles it;` : ''} Settings › Watermark changes the look.`
        : `Watermark off. /tab watermark on${key ? ` (or ${key})` : ''} brings it back.`,
    };
  }
  if (verb === 'focus-mode' || verb === 'focusmode') {
    const word = (restWords[0] || '').toLowerCase();
    const onOff = (w, toggled) => (['on', 'true', 'yes'].includes(w) ? true : ['off', 'false', 'no'].includes(w) ? false : w ? null : toggled);
    if (word === 'idle') {
      // Stay covered when it's your turn: the cover then shows the gist of Claude's reply.
      const stay = onOff((restWords[1] || '').toLowerCase(), cfg.focusIdle !== true);
      if (stay === null) return { message: `Focus mode idle: on | off (now ${cfg.focusIdle === true ? 'on' : 'off'})` };
      writeConfig({ focusIdle: stay });
      const off = cfg.focusMode === true ? '' : ' Focus mode itself is off: /tab focus-mode on.';
      return {
        message: stay
          ? `Focus mode stays on when it's your turn: a window Claude is done in keeps its cover and shows how Claude's reply opens and what it asks, with a "Show full reply" button.${off}`
          : `Focus mode opens a window when it's your turn again.${off}`,
      };
    }
    const on = onOff(word, cfg.focusMode !== true);
    if (on === null) return { message: `Focus mode: on | off | idle on | idle off (now ${cfg.focusMode === true ? 'on' : 'off'}${cfg.focusIdle === true ? ', staying covered when it\'s your turn' : ''})` };
    writeConfig({ focusMode: on });
    return {
      message: on
        ? "Focus mode on: while Claude works, Tabby Island covers each Terminal window you're not in with its topic and what's running. It opens when Claude needs you, or when you click it. Settings › Focus shows a preview."
        : 'Focus mode off: every Terminal window shows what Claude writes. /tab focus-mode on brings it back.',
    };
  }
  if (verb === 'namer') {
    if (!['ai', 'heuristic', 'off'].includes(restWords[0])) return { message: `Namer: ai | heuristic | off (now ${cfg.namer})` };
    writeConfig({ namer: restWords[0] });
    return { message: `Auto-naming → ${restWords[0]}.` };
  }

  if (!rec) return { message: 'No tabby session in this tab. Start Claude here (or pass --session).' };

  if (verb === 'name' || verb === 'rename' || verb === 'title') {
    const text = plain(unquote(rest)).replace(/ {2,}/g, ' ').trim().slice(0, 60);
    if (!text) return runCommand('auto', { rec, cfg });
    const next = repaint(patchSession(rec.sessionId, { title: text, titleSource: 'manual' }), cfg, { colors: false });
    return { message: `${markerFor(next.accent, 'circle')} Renamed → ${text}   (AI naming paused · /tab auto to resume)`, sessionTitle: text };
  }
  if (verb === 'auto') {
    const next = patchSession(rec.sessionId, { titleSource: rec.titleSource === 'ai' ? 'ai' : 'project', namedAt: 0 });
    const named = autoName(next, cfg);
    return { message: `${markerFor(next.accent, 'circle')} Automatic naming on — ${named.note}` };
  }
  if (verb === 'color' || verb === 'colour' || verb === 'c') {
    if (!restWords[0]) return { message: colorList(rec, cfg) };
    return setColor(rec, cfg, restWords[0].toLowerCase());
  }
  if (verb === 'note' || verb === 'summary') {
    patchSession(rec.sessionId, { note: plain(unquote(rest)).trim().slice(0, 280) || null });
    return { message: rest ? `Note saved — it shows when you hover this session in the island.` : 'Note cleared.' };
  }
  if (verb === 'reset') {
    const auto = chooseLook({ cwd: rec.cwd, sessionId: rec.sessionId }, cfg);
    const next = repaint(patchSession(rec.sessionId, withLook({ ...rec, ...auto, lookSource: 'auto', disabled: false, title: '', titleSource: 'project', namedAt: 0, note: null }, cfg)), cfg);
    const named = autoName(next, cfg);
    return { message: `${markerFor(next.accent, 'circle')} Reset → ${next.accentKey} · ${getTheme(next.theme).name}; ${named.note}` };
  }
  if (verb === 'off') {
    clearSession(rec);
    if (cfg.terminalTabTitles && rec.term === 'apple-terminal') spawnProfile('restore', rec.tty);
    patchSession(rec.sessionId, { disabled: true });
    return { message: 'tabby is off for this tab (terminal colors restored). /tab on to turn it back on.' };
  }
  if (verb === 'on') {
    const next = repaint(patchSession(rec.sessionId, withLook({ ...rec, disabled: false }, cfg)), cfg);
    if (cfg.terminalTabTitles && rec.term === 'apple-terminal') spawnProfile('use', rec.sessionId);
    return { message: `${markerFor(next.accent, 'circle')} tabby is back on for this tab.` };
  }

  // Shortcuts: "/tab teal", "/tab nord", otherwise the whole text is the new name.
  if (!restWords.length && ACCENT_KEYS.concat(['next', 'random']).includes(verb)) return setColor(rec, cfg, verb);
  if (!restWords.length && parseColor(verb) && /^#/.test(verb)) return setColor(rec, cfg, verb);
  const exactTheme = strictTheme(verb);
  if (exactTheme && (!rest || (wantsAll && !restNoAll))) return setTheme(rec, cfg, exactTheme.id, wantsAll);
  return runCommand(`name ${raw}`, { rec, cfg });
}
