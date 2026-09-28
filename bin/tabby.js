#!/usr/bin/env node
// tabby — name, color and track every Claude Code session's terminal tab.
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import {
  readConfig, writeConfig, readSession, patchSession, listSessions, liveSessions,
  readRegistry, isAlive, projectName, ensureDirs, log, rememberProjectColor,
} from '../lib/state.js';
import { THEMES, getTheme, themesExport } from '../lib/themes.js';
import { detectTerminal, ownTty, ttyOfPid, focusTab, terminalTitles } from '../lib/term.js';
import { chooseLook } from '../lib/assign.js';
import { withLook, applySession, displayTitle, targetOf } from '../lib/apply.js';
import { runCommand, helpText } from '../lib/commands.js';
import { handleHook, refreshContext, wantsRename } from '../lib/hooks.js';
import { runNamer } from '../lib/namer.js';
import { statusline } from '../lib/statusline.js';
import { install, uninstall, pluginInstalled, writeExports, ROOT } from '../lib/install.js';
import { ansiFg, ansiBg, markerFor } from '../lib/color.js';
import { mergedSessions, transcriptFor } from '../lib/sessions.js';
import { tile, next, screensCommand } from '../lib/tile.js';
import { newSession as launch, listFolders } from '../lib/launch.js';
import { termsAccepted, acceptTerms, TERMS_SUMMARY } from '../lib/terms.js';
import { runSetup } from '../lib/setup.js';
import { setTerminalTabTitles, useTwin, restoreProfile, switchOpenTabs, setBoldColor } from '../lib/terminal-prefs.js';
import { runTicker } from '../lib/ticker.js';
import * as islandApp from '../lib/island.js';
import { printDoctor } from '../lib/doctor.js';

const RESET = '\x1b[0m';
const DIM = '\x1b[2m';
const BOLD = '\x1b[1m';
const color = process.stdout.isTTY && !process.env.NO_COLOR;
const c = (code, s) => (color ? code + s + RESET : s);

// ---------- argv ----------
const argv = process.argv.slice(2);
const flags = {};
const pos = [];
const VALUE_FLAGS = new Set(['session', 's', 'name', 'n', 'color', 'theme', 'dir', 'ttys', 'only', 'screens', 'screen', 'term']);
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

// Context used, as a number (a bar reads as progress): "46% ctx", amber from 70 %, red from 90 %.
function contextUsed(pct) {
  if (pct == null) return ' '.repeat(8);
  const p = Math.round(Math.min(100, Math.max(0, pct)));
  const col = p >= 90 ? '#e06c75' : p >= 70 ? '#e5c07b' : null;
  const text = `${String(p).padStart(3)}%`;
  return `${col ? c(ansiFg(col), text) : text} ${c(DIM, 'ctx')}`;
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
    const line = `${swatch} ${pad(glyph, 2)} ${c(BOLD, pad(title, 28))} ${c(DIM, pad(s.project, 12))} ${contextUsed(s.context?.usedPct)}  ${status} ${c(DIM, pad(ago(s.statusAt || s.startedAt || Date.now()), 4))}`;
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

const shq = (s) => `'${String(s).replace(/'/g, `'\\''`)}'`;
const asq = (s) => String(s).replace(/\\/g, '\\\\').replace(/"/g, '\\"');

// `tabby new [dir|recent folder] [-n name] [--dangerous] [--screen s] [--term t]`, or `--list`.
function newSession() {
  if (flags.list) return console.log(listFolders({ json: !!flags.json }));
  const str = (v) => (typeof v === 'string' ? v : undefined);
  console.log(launch({
    dir: pos[1] || str(flags.dir),
    name: str(flags.name) || str(flags.n),
    dangerous: !!(flags.dangerous || flags['skip-permissions'] || flags['dangerously-skip-permissions']),
    color: str(flags.color),
    theme: str(flags.theme),
    term: str(flags.term),
    screen: str(flags.screen),
    dryRun: !!flags['dry-run'],
  }));
}

// The macOS session island. install: the ready-made download (a local build if that fails),
// kept in ~/Applications, opened at login, started with its setup window.
function island(sub = 'start') {
  writeExports();
  const quiet = !!flags.quiet;
  const say = (m) => !quiet && m && console.log(m);
  switch (sub) {
    case 'stop':
      islandApp.quit();
      return say('Tabby Island stopped.');
    case 'install':
    case 'update':
    case 'build': {
      const res = islandApp.install({ prefer: sub === 'build' || flags.build ? 'build' : 'download', quiet: quiet || sub !== 'build' });
      say(res.message);
      if (!res.ok) {
        process.exitCode = res.unsupported ? 0 : 1;
        return;
      }
      if (sub === 'update') return;
      if (!flags['no-login']) say(islandApp.login(true));
      if (flags['no-launch']) return;
      return say(islandApp.start({ onboarding: flags['no-onboarding'] ? null : 'welcome' }).message);
    }
    case 'login':
      return say(islandApp.login(!flags.off));
    case 'onboarding':
    case 'setup':
      return say(islandApp.start({ onboarding: 'welcome' }).message);
    case 'permissions':
    case 'accessibility':
      return say(islandApp.start({ onboarding: 'permissions' }).message);
    case 'status':
      return console.log(JSON.stringify({ app: islandApp.findApp(), version: islandApp.appVersion(islandApp.findApp() || islandApp.APP), running: islandApp.running(), login: islandApp.loginOn(), status: islandApp.status() }, null, 2));
    default: {
      if (!islandApp.findApp()) {
        const why = islandApp.unsupported();
        if (why) return say(why);
        return island('install');
      }
      const res = islandApp.start();
      say(res.message);
      if (!res.ok) process.exitCode = 1;
    }
  }
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
    --active | --only 1,3,auth | --all   which sessions (active = working or needs you)
    --screens 2 | all | current          which screens, this once
  tabby tile screens [2|1,2|all|current]   list the displays / choose where sessions go
  tabby themes                preview all ${THEMES.length} themes
  tabby <name|color|theme|note|auto|reset|off|on> …   same as /tab, for this tab or --session <q>
  tabby new [dir|name] [-n name] [--dangerous] [--screen s] [--color c] [--theme t]
                              a new window running claude (a recent folder by name works)
  tabby new --list            recent and frequent folders, best first
  tabby adopt                 color sessions that were started before tabby
  tabby island [install|update|stop|login|setup|permissions|status]   the macOS session island
                              (install: the ready-made download; build: compile it here)
  tabby watermark on|off      the topic in large, faint letters over each Terminal window
  tabby focus-mode on|off     while Claude works, other Terminal windows show only their topic
  tabby terminal-titles on|off      Terminal.app windows show only the session name
  tabby install / uninstall   setup (asks you to accept the terms) / revert everything
  tabby terms                 the terms of use
  tabby doctor [--json]       check every part of the install, with the fix for each
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
  process.stdout.write('Accept the tabby terms? [Y/n] ');
  const buf = Buffer.alloc(64);
  let n = 0;
  for (let i = 0; i < 100 && !n; i++) {
    try {
      n = fs.readSync(0, buf, 0, 64, null);
    } catch (e) {
      if (e.code !== 'EAGAIN') break;
    }
  }
  // Enter alone accepts; no answer at all (end of input) does not.
  if (n > 0 && /^(y(es)?)?$/i.test(buf.toString('utf8', 0, n).trim())) {
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
      if (!ensureTerms()) {
        process.exitCode = 2;
        return;
      }
      console.log(c(BOLD, 'Installing tabby'));
      for (const s of install({ statusline: !flags['no-statusline'], shell: !flags['no-shell'], plugin: !flags['no-plugin'], title: !flags['no-title'], terminalTitles: !flags['no-terminal-titles'] })) console.log('  • ' + s);
      console.log('\nNew Claude sessions are organized automatically. Run `tabby adopt` to color the ones already open,\n`tabby island` for the session island, and open a new shell for the claude --tab/--color/--theme flags.');
      return;
    }
    case 'uninstall':
      for (const s of uninstall()) console.log('  • ' + s);
      return;
    case 'doctor':
      return console.log(printDoctor({ json: !!flags.json, color: !!color }));
    case 'ls':
    case 'list':
      return printLs();
    case 'themes':
    case 'preview':
      return printThemes();
    case 'next':
      return console.log(next());
    case 'tile':
      if (pos[1] === 'screens') return console.log(screensCommand(pos.slice(2).join(' ')));
      return console.log(tile(Number(pos[1]) || undefined, {
        dryRun: !!flags['dry-run'],
        ttys: typeof flags.ttys === 'string' ? flags.ttys.split(',') : undefined,
        active: !!flags.active,
        all: !!flags.all,
        only: typeof flags.only === 'string' ? flags.only : undefined,
        screens: typeof flags.screens === 'string' ? flags.screens : undefined,
      }));
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
