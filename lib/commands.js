// The /tab command language, shared by the in-Claude slash command (intercepted by the
// UserPromptSubmit hook, so it costs no tokens) and the `tabby` CLI.
import { THEMES, ACCENT_KEYS, findTheme, strictTheme, getTheme, parseColor, accentHex, themesExport } from './themes.js';
import { readConfig, writeConfig, patchSession, liveSessions, rememberProjectColor, writeJson, paths } from './state.js';
import { withLook, applySession, clearSession, displayTitle } from './apply.js';
import { chooseLook } from './assign.js';
import { spawnNamer } from './namer.js';
import { markerFor, STRENGTHS, MARKER_STYLES } from './color.js';
import { tile, next } from './tile.js';
import { runSetup } from './setup.js';

export const isTabCommand = (prompt) => /^\s*\/(?:tabby:)?tab(?:\s|$)/i.test(String(prompt || ''));
export const tabArgs = (prompt) => String(prompt || '').trim().replace(/^\/(?:tabby:)?tab\b/i, '').trim();

const unquote = (s) => s.trim().replace(/^(["'])(.*)\1$/s, '$2').trim();
const STATUS_WORDS = { new: 'new', busy: 'working', idle: 'your turn', waiting: 'needs you', error: 'error', ended: 'ended' };

function repaint(rec, cfg, { colors = true } = {}) {
  applySession(rec, cfg, { colors, title: true });
  return rec;
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
    '/tab tile [2|3|4|6|8]    fill the screen with session windows   /tab next   jump to who needs you',
    `/tab strength subtle|medium|bold · /tab marker ${MARKER_STYLES.join('|')} · /tab mode tint|themes`,
  ].join('\n');
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
  const next = repaint(patchSession(rec.sessionId, withLook({ ...rec, accentKey: key }, cfg)), cfg);
  rememberProjectColor(next.cwd, next.theme, next.accentKey);
  return { message: `${markerFor(next.accent, 'circle')} Color → ${key} (${next.accent}) · ${getTheme(next.theme).name}` };
}

function setTheme(rec, cfg, word, all) {
  const theme = findTheme(word);
  if (!theme) return { message: `Unknown theme "${word}".\n\n${themeList(cfg, rec?.theme)}` };
  if (all) {
    const cfg2 = writeConfig({ theme: theme.id });
    exportThemes(cfg2);
    const sessions = liveSessions();
    for (const s of sessions) repaint(patchSession(s.sessionId, withLook({ ...s, theme: theme.id }, cfg2)), cfg2);
    return { message: `Theme → ${theme.name} for all ${sessions.length} tab${sessions.length === 1 ? '' : 's'} (and new ones).` };
  }
  if (!rec) return { message: 'No session here — use "all" to change every tab.' };
  const next = repaint(patchSession(rec.sessionId, withLook({ ...rec, theme: theme.id }, cfg)), cfg);
  rememberProjectColor(next.cwd, next.theme, next.accentKey);
  return { message: `${markerFor(next.accent, 'circle')} Theme → ${theme.name} for this tab · "/tab theme ${theme.id} all" for every tab` };
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
  if (verb === 'tile') return { message: tile(Number(restWords[0]) || undefined) };
  if (verb === 'next') return { message: next() };
  if (verb === 'island') return { message: runSetup('island') };
  if (verb === 'theme' && !restNoAll) return { message: themeList(cfg, rec?.theme) };
  if (verb === 'theme') return setTheme(rec, cfg, restNoAll, wantsAll);
  if (verb === 'strength' || verb === 'tint') {
    if (!STRENGTHS[restWords[0]]) return { message: `Strength: ${Object.keys(STRENGTHS).join(' | ')} (now ${cfg.strength})` };
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
  if (verb === 'namer') {
    if (!['ai', 'heuristic', 'off'].includes(restWords[0])) return { message: `Namer: ai | heuristic | off (now ${cfg.namer})` };
    writeConfig({ namer: restWords[0] });
    return { message: `Auto-naming → ${restWords[0]}.` };
  }

  if (!rec) return { message: 'No tabby session in this tab. Start Claude here (or pass --session).' };

  if (verb === 'name' || verb === 'rename' || verb === 'title') {
    const text = unquote(rest).slice(0, 60);
    if (!text) return runCommand('auto', { rec, cfg });
    const next = repaint(patchSession(rec.sessionId, { title: text, titleSource: 'manual' }), cfg, { colors: false });
    return { message: `${markerFor(next.accent, 'circle')} Renamed → ${text}   (AI naming paused · /tab auto to resume)`, sessionTitle: text };
  }
  if (verb === 'auto') {
    const next = patchSession(rec.sessionId, { titleSource: rec.titleSource === 'ai' ? 'ai' : 'project', namedAt: 0 });
    if ((next.prompts || []).length && cfg.namer !== 'off') spawnNamer(next.sessionId);
    return { message: `${markerFor(next.accent, 'circle')} AI naming on — a fresh name arrives in a few seconds.` };
  }
  if (verb === 'color' || verb === 'colour' || verb === 'c') {
    if (!restWords[0]) return { message: colorList(rec, cfg) };
    return setColor(rec, cfg, restWords[0].toLowerCase());
  }
  if (verb === 'note' || verb === 'summary') {
    patchSession(rec.sessionId, { note: unquote(rest).slice(0, 280) || null });
    return { message: rest ? `Note saved — it shows when you hover this session in the island.` : 'Note cleared.' };
  }
  if (verb === 'reset') {
    const auto = chooseLook({ cwd: rec.cwd, sessionId: rec.sessionId }, cfg);
    const next = repaint(patchSession(rec.sessionId, withLook({ ...rec, ...auto, disabled: false, title: '', titleSource: 'project', namedAt: 0, note: null }, cfg)), cfg);
    if ((next.prompts || []).length && cfg.namer !== 'off') spawnNamer(next.sessionId);
    return { message: `${markerFor(next.accent, 'circle')} Reset → ${next.accentKey} · ${getTheme(next.theme).name}, AI name on the way.` };
  }
  if (verb === 'off') {
    clearSession(rec);
    patchSession(rec.sessionId, { disabled: true });
    return { message: 'tabby is off for this tab (terminal colors restored). /tab on to turn it back on.' };
  }
  if (verb === 'on') {
    const next = repaint(patchSession(rec.sessionId, withLook({ ...rec, disabled: false }, cfg)), cfg);
    return { message: `${markerFor(next.accent, 'circle')} tabby is back on for this tab.` };
  }

  // Shortcuts: "/tab teal", "/tab nord", otherwise the whole text is the new name.
  if (!restWords.length && ACCENT_KEYS.concat(['next', 'random']).includes(verb)) return setColor(rec, cfg, verb);
  if (!restWords.length && parseColor(verb) && /^#/.test(verb)) return setColor(rec, cfg, verb);
  const exactTheme = strictTheme(verb);
  if (exactTheme && (!rest || (wantsAll && !restNoAll))) return setTheme(rec, cfg, exactTheme.id, wantsAll);
  return runCommand(`name ${raw}`, { rec, cfg });
}
