#!/usr/bin/env node
// tabby — name, color and track every Claude Code session's terminal tab.
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import {
  paths, readConfig, writeConfig, readSession, patchSession, listSessions, liveSessions,
  readRegistry, isAlive, projectName, ensureDirs, log, readJson, rememberProjectColor,
} from '../lib/state.js';
import { THEMES, getTheme, themesExport } from '../lib/themes.js';
import { detectTerminal, caps, ownTty, ttyOfPid, focusTab, terminalTitles } from '../lib/term.js';
import { chooseLook } from '../lib/assign.js';
import { withLook, applySession, displayTitle, targetOf } from '../lib/apply.js';
import { runCommand, helpText } from '../lib/commands.js';
import { handleHook, refreshContext, wantsRename } from '../lib/hooks.js';
import { runNamer } from '../lib/namer.js';
import { statusline } from '../lib/statusline.js';
import { install, uninstall, pluginInstalled, writeExports, ROOT, nodePath, LAUNCHER } from '../lib/install.js';
import { ansiFg, ansiBg, markerFor } from '../lib/color.js';
import { mergedSessions, transcriptFor } from '../lib/sessions.js';
import { tile, next } from '../lib/tile.js';
import { termsAccepted, acceptTerms, TERMS_SUMMARY, TERMS_VERSION } from '../lib/terms.js';
import { runSetup } from '../lib/setup.js';
import { setTerminalTabTitles, useTwin, restoreProfile, switchOpenTabs, twins, setBoldColor } from '../lib/terminal-prefs.js';
import { runTicker, tickerPid } from '../lib/ticker.js';
import { claudeTheme, claudeMode } from '../lib/claude-palette.js';

const RESET = '\x1b[0m';
const DIM = '\x1b[2m';
const BOLD = '\x1b[1m';
const color = process.stdout.isTTY && !process.env.NO_COLOR;
const c = (code, s) => (color ? code + s + RESET : s);

// ---------- argv ----------
const argv = process.argv.slice(2);
const flags = {};
const pos = [];
const VALUE_FLAGS = new Set(['session', 's', 'name', 'n', 'color', 'theme', 'dir', 'ttys']);
for (let i = 0; i < argv.length; i++) {
  const a = argv[i];
  if (a === '--') {
    pos.push(...argv.slice(i + 1));
    break;
  }
  const m = /^--?([\w-]+)(?:=(.*))?$/.exec(a);
  if (m && isNaN(Number(a))) {
    const key = m[1];
    if (m[2] !== undefined) flags[key] = m[2];
    else if (VALUE_FLAGS.has(key) && argv[i + 1] !== undefined) flags[key] = argv[++i];
    else flags[key] = true;
  } else pos.push(a);
}
const sessionQuery = flags.session || flags.s;

function readStdinJson() {
  try {
    const raw = fs.readFileSync(0, 'utf8');
    return raw.trim() ? JSON.parse(raw) : {};
  } catch {
    return {};
  }
}

// ---------- session targeting ----------
function findSession(q) {
  const all = listSessions();
  const live = all.filter((s) => s.status !== 'ended' && isAlive(s.pid));
  const pool = [...live, ...all.filter((s) => !live.includes(s))];
  const ql = String(q).toLowerCase();
  return (
    pool.find((s) => s.sessionId === q) ||
    pool.find((s) => s.sessionId.startsWith(q)) ||
    pool.find((s) => String(s.pid) === q) ||
    pool.find((s) => s.tty === q || s.tty === `/dev/${q}`) ||
    live.find((s) => (s.title || '').toLowerCase() === ql) ||
    live.find((s) => (s.project || '').toLowerCase() === ql) ||
    live.find((s) => (s.title || '').toLowerCase().includes(ql)) ||
    live.find((s) => (s.project || '').toLowerCase().includes(ql)) ||
    adoptFromRegistry(q)
  );
}

// A running Claude session tabby hasn't seen yet (started before install): adopt it on demand.
function adoptFromRegistry(q) {
  for (const r of readRegistry().values()) {
    if (r.kind && r.kind !== 'interactive') continue;
    if (r.sessionId === q || String(r.pid) === String(q) || (q.length >= 6 && r.sessionId?.startsWith(q))) return adoptOne(r);
  }
  return null;
}

function adoptOne(r, titles = null) {
  const tty = ttyOfPid(r.pid);
  if (!tty) return null;
  const cfg = readConfig();
  const title = (titles || terminalTitles()).get(tty) || '';
  const auto = chooseLook({ cwd: r.cwd, sessionId: r.sessionId }, cfg, liveSessions());
  const rec = patchSession(
    r.sessionId,
    withLook({ v: 1, sessionId: r.sessionId, pid: r.pid, tty, term: detectTerminal(), cwd: r.cwd, project: projectName(r.cwd), ownsTitle: false, status: r.status || 'idle', statusAt: Date.now(), title, titleSource: title ? 'claude' : 'project', adopted: true, transcriptPath: transcriptFor(r.cwd, r.sessionId), startedAt: r.startedAt || Date.now(), ...auto }, cfg)
  );
  applySession(rec, cfg, { colors: true, title: false });
  rememberProjectColor(rec.cwd, rec.theme, rec.accentKey);
  return rec;
}

// A plain terminal tab without Claude can be named/colored too.
function bareTab(tty) {
  const id = `tty-${path.basename(tty)}`;
  const existing = readSession(id);
  if (existing && isAlive(existing.pid) && existing.status !== 'ended') return existing;
  const cfg = readConfig();
  const auto = chooseLook({ cwd: process.cwd(), sessionId: id }, cfg);
  return patchSession(
    id,
    withLook(
      { v: 1, sessionId: id, pid: process.ppid, tty, term: detectTerminal(), tmuxPane: process.env.TMUX_PANE || null, cwd: process.cwd(), project: projectName(process.cwd()), ownsTitle: true, status: 'shell', statusAt: Date.now(), title: '', titleSource: 'project', bare: true, startedAt: Date.now(), ...auto },
      cfg
    )
  );
}

function currentSession({ create = true } = {}) {
  if (sessionQuery) return findSession(sessionQuery);
  if (process.env.CLAUDE_CODE_SESSION_ID) {
    const r = readSession(process.env.CLAUDE_CODE_SESSION_ID);
    if (r) return r;
  }
  const tty = ownTty();
  if (!tty) return null;
  return liveSessions().find((s) => s.tty === tty) || (create ? bareTab(tty) : null);
}

// ---------- pretty output ----------
function ago(ms) {
  const s = Math.max(0, Math.round((Date.now() - ms) / 1000));
  if (s < 60) return `${s}s`;
  if (s < 3600) return `${Math.round(s / 60)}m`;
  if (s < 86400) return `${Math.round(s / 3600)}h`;
  return `${Math.round(s / 86400)}d`;
}

function meter(pct, accent, width = 8) {
  if (pct == null) return ' '.repeat(width + 5);
  const filled = Math.round((Math.min(100, pct) / 100) * width);
  const col = pct >= 90 ? '#e06c75' : pct >= 70 ? '#e5c07b' : accent;
  return `${c(ansiFg(col), '▰'.repeat(filled))}${c(DIM, '▱'.repeat(width - filled))} ${String(pct).padStart(3)}%`;
}

const pad = (s, n) => {
  const t = String(s || '');
  const w = [...t].length;
  return w > n ? [...t].slice(0, n - 1).join('') + '…' : t + ' '.repeat(n - w);
};

function printLs() {
  const cfg = readConfig();
  const rows = mergedSessions();
  if (flags.json) return console.log(JSON.stringify(rows, null, 2));
  if (!rows.length) return console.log('No Claude sessions running.');
  const words = { waiting: 'needs you', busy: 'working', idle: 'your turn', new: 'new', error: 'error', shell: 'shell' };
  for (const s of rows) {
    const accent = s.accent || '#8b949e';
    const glyph = cfg.status[s.status] || ' ';
    const title = s.title || s.claudeName || s.project;
    const swatch = s.bg ? c(ansiBg(s.bg) + ansiFg(accent), ' ● ') : c(ansiFg(accent), ' ● ');
    const status = s.status === 'waiting' ? c(ansiFg('#e5c07b'), pad(words.waiting, 10)) : c(DIM, pad(words[s.status] || s.status || '', 10));
    const line = `${swatch} ${pad(glyph, 2)} ${c(BOLD, pad(title, 28))} ${c(DIM, pad(s.project, 12))} ${meter(s.context?.usedPct, accent)}  ${status} ${c(DIM, pad(ago(s.statusAt || s.startedAt || Date.now()), 4))}`;
    console.log(line);
    const about = s.note || s.summary || (s.prompts || []).at(-1);
    if (about) console.log(`      ${c(DIM, pad(about, 96))}`);
    if (!s.tracked) console.log(`      ${c(DIM, 'not tracked yet — restart this session (or run: tabby adopt)')}`);
  }
}

function printThemes() {
  const cfg = readConfig();
  for (const t of THEMES) {
    const dots = Object.values(t.accents).map((h) => c(ansiFg(h), '●')).join(' ');
    const sample = color ? `${ansiBg(t.bg)}${ansiFg(t.fg)}  ${pad(t.name, 18)} ${Object.values(t.accents).map((h) => ansiFg(h) + '●').join(' ')}${ansiFg(t.fg)}  hello world  ${RESET}` : `  ${pad(t.name, 18)} ${dots}`;
    console.log(`${pad(t.id, 18)} ${sample} ${c(DIM, `${t.mode}${t.calm ? ' · calm' : ''}${t.id === cfg.theme ? ' · default' : ''}`)}`);
  }
  console.log(c(DIM, '\n/tab theme <id> (this tab) · /tab theme <id> all (every tab) · tabby theme <id> --all'));
}

// ---------- commands ----------
function doctor() {
  const cfg = readConfig();
  const term = detectTerminal();
  const cp = caps(term);
  const settings = readJson(paths.settings, {}) || {};
  const claude = spawnSync('claude', ['--version'], { encoding: 'utf8' });
  const islandApp = path.join(ROOT, 'island', 'build', 'Tabby Island.app');
  const islandUp = spawnSync('pgrep', ['-x', 'TabbyIsland']).status === 0;
  const ok = (b) => (b ? c(ansiFg('#98c379'), '✓') : c(ansiFg('#e06c75'), '✗'));
  const rows = [
    ['terminal', `${cp.label}  colors ${ok(cp.colors)}  tab color ${cp.tabColor ? ok(true) : c(DIM, '✗ → emoji marker in title')}  focus ${ok(cp.focus)}`],
    ['this tab', ownTty() || c(DIM, 'no tty')],
    ['node', process.version],
    ['claude', (claude.stdout || '').trim() || c(ansiFg('#e06c75'), 'not found on PATH')],
    ['plugin', pluginInstalled() ? `${ok(true)} installed (hooks + /tab)` : `${ok(false)} not installed → tabby install  (or: claude --plugin-dir ${ROOT})`],
    ['tab titles', settings.env?.CLAUDE_CODE_DISABLE_TERMINAL_TITLE === '1' ? `${ok(true)} tabby owns titles (color marker + status)` : `${c(DIM, '–')} Claude owns titles (names sync, no color marker)`],
    ['statusline', /statusline/.test(settings.statusLine?.command || '') && /tabby/.test(settings.statusLine?.command || '') ? `${ok(true)} tab name + context meter` : c(DIM, settings.statusLine ? 'your own statusLine (kept)' : 'off')],
    ['shell flags', ['.zshrc', '.bashrc'].some((f) => (fs.existsSync(path.join(process.env.HOME, f)) ? fs.readFileSync(path.join(process.env.HOME, f), 'utf8') : '').includes('>>> tabby')) ? `${ok(true)} claude --tab/--color/--theme` : c(DIM, 'off')],
    ['naming', `${cfg.namer}${cfg.namer === 'ai' ? ` (${cfg.namerModel} via your Claude login)` : ''}`],
    ['theme', `${getTheme(cfg.theme).name} · ${cfg.auto} mode · ${cfg.strength} tint · ${cfg.marker} markers`],
    ['island', fs.existsSync(islandApp) ? `${ok(true)} built${islandUp ? ', running' : ' (tabby island)'}` : c(DIM, 'not built → tabby island')],
    ['terms', termsAccepted(cfg) ? `${ok(true)} accepted (${TERMS_VERSION})` : `${ok(false)} not accepted → tabby setup`],
    ['Claude theme', getTheme(cfg.theme).mode === claudeMode() ? `${ok(true)} ${claudeTheme()} (matches ${getTheme(cfg.theme).name})` : `${ok(false)} ${claudeTheme()}, but ${getTheme(cfg.theme).name} is ${getTheme(cfg.theme).mode}: Claude's text will be hard to read. Use /theme in Claude or a ${claudeMode()} tabby theme`],
    ['Terminal titles', term === 'apple-terminal' ? (cfg.terminalTabTitles ? `${ok(true)} only the session name (Claude tabs use ${twins().join(', ') || 'a “· tabby” copy of their profile'})` : c(DIM, 'windows show folder, process and args too → tabby terminal-titles on')) : c(DIM, 'n/a')],
    ['animation', cfg.animate === false ? c(DIM, 'off') : `${ok(true)} spinner + blinking bell${tickerPid() ? ' (running)' : ''}`],
    ['watermark', process.platform !== 'darwin' ? c(DIM, 'n/a (Tabby Island, macOS)') : cfg.watermark === false ? c(DIM, 'off → /tab watermark on') : `${ok(true)} each Terminal.app session's topic over its window${islandUp ? '' : ' (when Tabby Island runs: tabby island)'}`],
    ['sessions', `${[...readRegistry().values()].filter((r) => r.kind === 'interactive').length} running · ${liveSessions().length} tracked`],
    ['state', paths.root],
  ];
  for (const [k, v] of rows) console.log(`  ${c(DIM, pad(k, 16))} ${v}`);
}

// Color sessions that were already running before tabby was installed (colors only —
// Claude keeps drawing their titles until they restart with the plugin).
function adopt() {
  const titles = terminalTitles();
  const only = pos[1] ? String(pos[1]).toLowerCase() : null;
  let n = 0;
  for (const r of readRegistry().values()) {
    if (r.kind && r.kind !== 'interactive') continue;
    if (readSession(r.sessionId)) continue;
    if (only && !`${r.cwd} ${r.name} ${r.pid} ${titles.get(ttyOfPid(r.pid)) || ''}`.toLowerCase().includes(only)) continue;
    const rec = adoptOne(r, titles);
    if (!rec) continue;
    console.log(`  ${markerFor(rec.accent, 'circle')} ${pad(rec.title || rec.project, 34)} ${rec.accentKey} · ${getTheme(rec.theme).name}  (${rec.tty})`);
    n++;
  }
  console.log(n ? `Adopted ${n} running session${n === 1 ? '' : 's'} (colors now; AI names, status and /tab after a restart — claude --continue keeps the conversation).` : 'Nothing to adopt — every running session is already tracked.');
}

const xmlEscape = (s) => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
const shq = (s) => `'${String(s).replace(/'/g, `'\\''`)}'`;
const asq = (s) => String(s).replace(/\\/g, '\\\\').replace(/"/g, '\\"');

function newSession() {
  const dir = path.resolve(pos[1] || flags.dir || process.cwd());
  const env = [flags.color && `TABBY_COLOR=${shq(flags.color)}`, flags.theme && `TABBY_THEME=${shq(flags.theme)}`].filter(Boolean).join(' ');
  const name = flags.name || flags.n;
  const cmd = `cd ${shq(dir)} && ${env ? env + ' ' : ''}claude${name ? ` --name ${shq(name)}` : ''}`;
  const term = detectTerminal();
  const script =
    term === 'iterm2'
      ? `tell application "iTerm2"\n create window with default profile\n tell current session of current window to write text "${asq(cmd)}"\n activate\nend tell`
      : `tell application "Terminal"\n do script "${asq(cmd)}"\n activate\nend tell`;
  const r = spawnSync('osascript', ['-e', script], { encoding: 'utf8' });
  console.log(r.status === 0 ? `Opened ${dir}${name ? ` as "${name}"` : ''}` : `Could not open a terminal: ${r.stderr}`);
}

function island(sub = 'start') {
  const app = path.join(ROOT, 'island', 'build', 'Tabby Island.app');
  writeExports();
  if (sub === 'stop') {
    spawnSync('osascript', ['-e', 'quit app "Tabby Island"'], { stdio: 'ignore' });
    return console.log('Tabby Island stopped.');
  }
  if (sub === 'build' || !fs.existsSync(app)) {
    const r = spawnSync('bash', [path.join(ROOT, 'island', 'build.sh')], { stdio: 'inherit' });
    if (r.status !== 0) return console.log('Build failed (needs Xcode command line tools: xcode-select --install).');
    if (sub === 'build') return;
  }
  if (sub === 'login') return islandLogin();
  if (sub === 'accessibility') {
    // Restart it with the flag: the island asks macOS itself, so the permission is Tabby Island's.
    spawnSync('osascript', ['-e', 'quit app "Tabby Island"'], { stdio: 'ignore' });
    spawnSync('open', [app, '--args', '--allow-accessibility']);
    return console.log('Tabby Island asks for Accessibility: in System Settings, switch Tabby Island on. Tiling can then split tabs and leave full screen.');
  }
  spawnSync('open', [app]);
  console.log('Tabby Island is running — hover the top-center of your screen.');
}

// At login, the launcher opens the newest installed island (a version's own folder goes away
// after an update).
function islandLogin() {
  const plist = path.join(process.env.HOME, 'Library', 'LaunchAgents', 'dev.tabby.island.plist');
  if (flags.off) {
    spawnSync('launchctl', ['unload', plist], { stdio: 'ignore' });
    try { fs.unlinkSync(plist); } catch {}
    return console.log('Tabby Island will no longer start at login.');
  }
  fs.mkdirSync(path.dirname(plist), { recursive: true });
  fs.writeFileSync(
    plist,
    `<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0"><dict>\n<key>Label</key><string>dev.tabby.island</string>\n<key>ProgramArguments</key><array><string>${xmlEscape(nodePath())}</string><string>${xmlEscape(LAUNCHER)}</string><string>island</string></array>\n<key>RunAtLoad</key><true/>\n</dict></plist>\n`
  );
  spawnSync('launchctl', ['load', plist], { stdio: 'ignore' });
  console.log(`Tabby Island starts at login (${plist}). Undo: tabby island login --off`);
}

function config() {
  const [, key, ...val] = pos;
  if (!key) return console.log(JSON.stringify(readConfig(), null, 2));
  const raw = val.join(' ');
  let v = raw;
  try { v = JSON.parse(raw); } catch {}
  writeConfig({ [key]: v });
  if (key === 'theme') writeExports();
  console.log(`${key} = ${JSON.stringify(v)}`);
}

const HELP = `tabby — name, color and track your Claude Code tabs

  in Claude:   /tab <name> · /tab color teal · /tab theme nord [all] · /tab ls · /tab (help)
  at launch:   claude --tab "Auth refactor" --color teal --theme nord   (after tabby install)

  tabby ls                    every running session: name, status, context, summary
  tabby next                  jump to the next session that needs you
  tabby focus <n|query>       jump to session n (as listed) or by name
  tabby tile [2|3|4|6|8]      fill the screen with session windows (tabs become windows)
  tabby themes                preview all ${THEMES.length} themes
  tabby <name|color|theme|note|auto|reset|off|on> …   same as /tab, for this tab or --session <q>
  tabby new [dir] [-n name] [--color c] [--theme t]   open a new tab running claude
  tabby adopt                 color sessions that were started before tabby
  tabby island [build|stop|login|accessibility]   the macOS session island (Settings: ⌃⌥, or its menu-bar icon)
  tabby watermark on|off      the topic in large, faint letters over each Terminal window
  tabby terminal-titles on|off      Terminal.app windows show only the session name
  tabby install / uninstall   setup (asks you to accept the terms) / revert everything
  tabby terms                 the terms of use
  tabby doctor                what works in this terminal
  tabby config [key value]    e.g. tabby config strength subtle · tabby config animate false`;

// Interactive acceptance for `tabby install` / `tabby setup` in a shell.
function ensureTerms() {
  if (termsAccepted()) return true;
  console.log(TERMS_SUMMARY + '\n');
  if (flags['accept-terms']) {
    acceptTerms('cli');
    return true;
  }
  if (!process.stdin.isTTY) {
    console.log('Run again with --accept-terms to agree.');
    return false;
  }
  process.stdout.write('Accept the tabby terms? [y/N] ');
  const buf = Buffer.alloc(64);
  let n = 0;
  for (let i = 0; i < 100 && !n; i++) {
    try {
      n = fs.readSync(0, buf, 0, 64, null);
    } catch (e) {
      if (e.code !== 'EAGAIN') break;
    }
  }
  if (/^y(es)?$/i.test(buf.toString('utf8', 0, n).trim())) {
    acceptTerms('cli');
    return true;
  }
  console.log('Nothing was changed.');
  return false;
}

// Commands that change terminals or settings wait for the terms; read-only ones don't.
const GATED = new Set(['next', 'tile', 'adopt', 'new', 'island', 'terminal-titles', 'focus']);

function main() {
  const cmd = pos[0];
  const changes = GATED.has(cmd) || !['hook', '_name', '_after', '_profile', 'statusline', 'install', 'uninstall', 'doctor', 'ls', 'list', 'themes', 'preview', 'setup', 'terms', 'root', '_ticker', 'help', '--help', '-h', 'version', 'config', undefined].includes(cmd);
  if (changes && !termsAccepted() && !(cmd === 'island' && pos[1] === 'stop')) {
    return console.log('tabby is off until you accept its terms. Run: tabby setup');
  }
  switch (cmd) {
    case 'hook': {
      const input = readStdinJson();
      try {
        const out = handleHook(pos[1], input);
        if (out) process.stdout.write(JSON.stringify(out));
      } catch (e) {
        log('hook error', pos[1], e.stack || e.message);
      }
      return;
    }
    case '_name':
      try { runNamer(pos[1]); } catch (e) { log('namer error', e.stack || e.message); }
      return;
    case '_after':
      // After a turn: wait for Claude to flush the transcript, record context, refresh the AI name.
      setTimeout(() => {
        try {
          const rec = refreshContext(readSession(pos[1]));
          if (wantsRename(rec, readConfig())) runNamer(pos[1]);
        } catch (e) {
          log('after-turn error', e.stack || e.message);
        }
      }, 1500);
      return;
    case 'statusline':
      try { process.stdout.write(statusline(readStdinJson())); } catch (e) { log('statusline error', e.message); }
      return;
    case 'install': {
      if (!ensureTerms()) return;
      console.log(BOLD + 'Installing tabby' + RESET);
      for (const s of install({ statusline: !flags['no-statusline'], shell: !flags['no-shell'], plugin: !flags['no-plugin'], title: !flags['no-title'], terminalTitles: !flags['no-terminal-titles'] })) console.log('  • ' + s);
      console.log('\nNew Claude sessions are organized automatically. Run `tabby adopt` to color the ones already open,\n`tabby island` for the session island, and open a new shell for the claude --tab/--color/--theme flags.');
      return;
    }
    case 'uninstall':
      for (const s of uninstall()) console.log('  • ' + s);
      return;
    case 'doctor':
      return doctor();
    case 'ls':
    case 'list':
      return printLs();
    case 'themes':
    case 'preview':
      return printThemes();
    case 'next':
      return console.log(next());
    case 'tile':
      return console.log(tile(Number(pos[1]) || undefined, { dryRun: !!flags['dry-run'], ttys: typeof flags.ttys === 'string' ? flags.ttys.split(',') : undefined }));
    case 'terminal-titles': {
      const on = !['off', 'false', 'no'].includes(String(pos[1] || 'on').toLowerCase());
      return console.log(setTerminalTabTitles(on) || `Terminal.app tab titles already ${on ? 'show only the session name' : 'at Terminal defaults'}.`);
    }
    case 'setup':
      if (pos[1] === 'island' || ensureTerms()) console.log(runSetup(pos[1] === 'island' ? 'island' : 'accept', { plugin: !pluginInstalled() }));
      return;
    case 'terms':
      return console.log(fs.existsSync(path.join(ROOT, 'TERMS.md')) ? fs.readFileSync(path.join(ROOT, 'TERMS.md'), 'utf8') : TERMS_SUMMARY);
    case 'root':
      return console.log(ROOT);
    case '_ticker':
      return runTicker();
    case '_profile':
      // Background half of the Terminal.app title profiles (see lib/terminal-prefs.js).
      try {
        if (pos[1] === 'all') switchOpenTabs();
        else if (pos[1] === 'restore') restoreProfile(pos[2]);
        else if (pos[1] === 'bold') setBoldColor(pos[2], pos[3]);
        else if (pos[1] === 'use') {
          const rec = readSession(pos[2]);
          if (rec && !rec.disabled && useTwin(rec.tty) === 'switched') applySession(readSession(pos[2]), readConfig(), { colors: true, title: true });
        }
      } catch (e) {
        log('profile error', pos[1], e.stack || e.message);
      }
      return;
    case 'focus': {
      const n = Number(pos[1]);
      const rec = sessionQuery ? findSession(sessionQuery) : Number.isInteger(n) && n > 0 ? mergedSessions({ withContext: false })[n - 1] : pos[1] ? findSession(pos[1]) : null;
      if (!rec) return console.log('No such session.');
      return console.log(focusTab(targetOf(rec)) ? `→ ${displayTitle(rec)}` : 'Could not focus that tab from here.');
    }
    case 'adopt':
      ensureDirs();
      return adopt();
    case 'new':
      return newSession();
    case 'island':
      return island(pos[1]);
    case 'config':
      return config();
    case 'help':
    case '--help':
    case '-h':
      return console.log(HELP);
    case 'version':
      return console.log(JSON.parse(fs.readFileSync(path.join(ROOT, 'package.json'), 'utf8')).version);
    default: {
      if (!cmd && !Object.keys(flags).length) {
        const rec = currentSession({ create: false });
        if (!rec) return console.log(HELP), printLs();
      }
      ensureDirs();
      const rec = currentSession();
      if (sessionQuery && !rec) return console.log(`No session matches "${sessionQuery}". Try: tabby ls`);
      let args = pos.join(' ');
      if (flags.auto) args = 'auto';
      if (flags.name && !pos.length) args = `name ${flags.name}`;
      if (flags.color && !pos.length) args = `color ${flags.color}`;
      if (flags.theme && !pos.length) args = `theme ${flags.theme}`;
      const res = runCommand(args, { rec, cfg: readConfig(), all: !!flags.all });
      console.log(res.message);
    }
  }
}

main();
