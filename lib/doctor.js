// `tabby doctor`: every piece of a working install, checked, each with the one thing to do when
// it isn't right. `--json` is for Claude (the install guide hands the machine's quirks to it):
// { ok, version, next, checks: [{ id, title, status: ok|warn|fail|info|skip, detail, fix? }] }
// fix = { run: "<command>" } for Claude to run, or { tell: "<text>" } for the person to do.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { paths, readConfig, readJson, readRegistry, liveSessions } from './state.js';
import { termsAccepted, TERMS_VERSION } from './terms.js';
import { detectTerminal, caps, ownTty } from './term.js';
import { getTheme } from './themes.js';
import { claudeTheme, claudeMode } from './claude-palette.js';
import { LAUNCHER } from './install.js';
import * as island from './island.js';
import { cached as cachedUpdate } from './update.js';

// The way to run tabby from any shell, including Claude's Bash tool (no `tabby` function there).
export const T = `sh "${path.join(paths.root, 'bin', 'tabby')}"`;
const INSTALL_ONE_LINER = 'curl -fsSL https://claude-tabby.vercel.app/install | bash -s -- --yes';

const has = (file, text) => fs.existsSync(file) && fs.readFileSync(file, 'utf8').includes(text);

function claudeCli() {
  const found = [process.env.CLAUDE_BIN, 'claude', path.join(os.homedir(), '.local/bin/claude'), path.join(os.homedir(), '.claude/local/claude'), '/opt/homebrew/bin/claude', '/usr/local/bin/claude']
    .filter(Boolean)
    .map((bin) => ({ bin, r: spawnSync(bin, ['--version'], { encoding: 'utf8', timeout: 10_000 }) }))
    .find(({ r }) => r.status === 0);
  return found ? { bin: found.bin, version: found.r.stdout.trim().split('\n')[0].replace(/\s*\(Claude Code\)/, '') } : null;
}

function installedPlugin() {
  const reg = readJson(path.join(paths.claudeDir, 'plugins', 'installed_plugins.json'), {}) || {};
  const key = Object.keys(reg.plugins || {}).find((k) => k.startsWith('tabby@'));
  if (!key) return null;
  const entry = [].concat(reg.plugins[key]).at(-1) || {};
  return { key, version: entry.version, path: entry.installPath };
}

const PERMISSION_NAMES = { accessibility: 'Accessibility', terminal: 'Control Terminal', iterm: 'Control iTerm2', systemEvents: 'Control System Events' };

export function diagnose() {
  const cfg = readConfig();
  const checks = [];
  const add = (id, title, status, detail, fix) => checks.push({ id, title, status, detail, ...(fix ? { fix } : {}) });
  const v = island.version();

  // Runtime and Claude Code
  add('node', 'Node.js', 'ok', `${process.version} (${process.execPath})`);
  const claude = claudeCli();
  add('claude', 'Claude Code CLI', claude ? 'ok' : 'warn', claude ? `${claude.version} (${claude.bin})` : 'not found on PATH: AI tab names need it',
    claude ? null : { tell: 'Make the `claude` command available in a terminal (Claude Code\'s installer adds ~/.local/bin to PATH), then open a new terminal.' });

  // The plugin: hooks and /tabby:* commands
  const plugin = installedPlugin();
  add('plugin', 'tabby plugin', plugin ? 'ok' : 'fail', plugin ? `${plugin.key} ${plugin.version || ''}`.trim() : 'not installed',
    plugin ? null : { run: 'claude plugin marketplace add 0xNtive/tabby && claude plugin install tabby@tabby' });

  const upd = cachedUpdate();
  add('update', 'Up to date', upd.available ? 'warn' : upd.latest ? 'ok' : 'info',
    upd.available ? `${upd.latest} is out (this is ${upd.current})` : upd.latest ? `${upd.current} is the latest` : cfg.updateCheck === false ? 'automatic checks are off' : 'not checked yet',
    upd.available ? { run: `${T} update` } : null);

  // Terms, then the one-time setup
  const accepted = termsAccepted(cfg);
  add('terms', 'Terms accepted', accepted ? 'ok' : 'fail', accepted ? `version ${TERMS_VERSION} (${cfg.termsAccepted.by})` : 'not yet: tabby stays off until they are',
    accepted ? null : { tell: `Show the person the terms (${T} terms, or https://claude-tabby.vercel.app/terms) and ask them to accept. Only after they say yes, run: ${T} install --accept-terms` });
  const settings = readJson(paths.settings, {}) || {};
  const launcherOk = fs.existsSync(LAUNCHER) && fs.existsSync(path.join(paths.root, 'bin', 'tabby'));
  const titleOk = settings.env?.CLAUDE_CODE_DISABLE_TERMINAL_TITLE === '1';
  const tabCmd = has(path.join(paths.claudeDir, 'commands', 'tab.md'), 'tabby:user-command');
  const setupOk = launcherOk && titleOk && tabCmd;
  add('setup', 'One-time setup', setupOk ? 'ok' : accepted ? 'fail' : 'skip',
    setupOk ? 'launcher, tab titles, /tab' : [!launcherOk && 'launcher missing', !titleOk && 'Claude still draws tab titles', !tabCmd && 'no /tab command'].filter(Boolean).join(', '),
    setupOk || !accepted ? null : { run: `${T} install` });
  const status = settings.statusLine?.command || '';
  add('statusline', 'Status line', /tabby/.test(status) && /statusline/.test(status) ? 'ok' : 'info', /tabby/.test(status) ? 'tab name + context %' : settings.statusLine ? 'your own status line (kept)' : 'off');

  // Sessions: hooks only reach sessions started (or reloaded) after the plugin was installed.
  const running = [...readRegistry().values()].filter((r) => !r.kind || r.kind === 'interactive');
  const tracked = new Set(liveSessions().map((s) => s.sessionId));
  const untracked = running.filter((r) => !tracked.has(r.sessionId)).length;
  add('sessions', 'Claude sessions', !running.length ? 'info' : untracked ? 'warn' : 'ok',
    `${running.length} running, ${running.length - untracked} tracked by tabby`,
    untracked && accepted ? { tell: `Sessions started before tabby aren't tracked yet: type /reload-plugins in each (or restart it; claude --continue keeps the conversation). New sessions are tracked automatically.` } : null);

  const term = detectTerminal();
  const cp = caps(term);
  add('terminal', 'Terminal', 'info', `${cp.label}${ownTty() ? '' : ' (no tab here)'}: colors ${cp.colors ? 'yes' : 'no'}, tab color ${cp.tabColor ? 'yes' : 'a colored marker in the title'}, jump to tab ${cp.focus ? 'yes' : 'no'}`);
  add('theme', 'Theme', getTheme(cfg.theme).mode === claudeMode() ? 'ok' : 'warn',
    `${getTheme(cfg.theme).name} (${getTheme(cfg.theme).mode}); Claude uses ${claudeTheme()}`,
    getTheme(cfg.theme).mode === claudeMode() ? null : { tell: `Claude's text is hard to read on a ${getTheme(cfg.theme).mode} theme while Claude is in ${claudeMode()} mode: pick a ${claudeMode()} tabby theme with /tab theme <id> all, or switch Claude with /theme.` });

  // Tabby Island (macOS). What you turned off on purpose is reported, never "fixed".
  const why = island.unsupported();
  if (why) {
    add('island', 'Tabby Island', 'skip', why);
  } else if (cfg.island === false || cfg.island === 'off') {
    add('island', 'Tabby Island', 'skip', 'turned off (to add it: tabby config island true, then tabby island install)');
  } else {
    const app = island.findApp();
    const have = app && island.appVersion(app);
    const inPlace = app === island.APP;
    const last = island.lastInstall();
    add('island', 'Tabby Island installed', !app || !inPlace || (have && island.newer(v, have)) ? 'warn' : 'ok',
      !app ? `not installed${last && !last.ok ? ` (last try: ${last.message.split('\n').slice(-1)[0].trim()})` : ''}`
        : `${have || '?'} at ${app}${!inPlace ? ' (a local build, not the installed app)' : ''}${have && island.newer(v, have) ? `, older than tabby ${v}` : ''}`,
      !app || !inPlace ? { run: `${T} island install` } : have && island.newer(v, have) ? { run: `${T} island update` } : null);
    if (app) {
      const live = island.running();
      const st = island.status();
      if (live) add('island-running', 'Tabby Island running', 'ok', 'yes: hover the top center of the screen');
      else if (st?.quitByUser) add('island-running', 'Tabby Island running', 'info', 'no: you quit it (tabby island starts it)');
      else add('island-running', 'Tabby Island running', 'warn', 'not running', { run: `${T} island` });
      const target = island.loginTarget();
      const loginOk = !!target && fs.existsSync(target);
      if (loginOk) add('island-login', 'Opens at login', 'ok', 'yes');
      else if (cfg.islandLogin === false) add('island-login', 'Opens at login', 'info', 'off (tabby island login turns it on)');
      else add('island-login', 'Opens at login', 'warn', target ? 'points at an app that moved' : 'no', { run: `${T} island login` });
      if (!st || !st.permissions) {
        add('island-permissions', 'Island permissions', 'skip', live ? 'the island hasn\'t reported yet (update it: tabby island update)' : 'reported once the island runs');
      } else {
        const needed = Object.entries(st.permissions).filter(([, s]) => s !== 'notNeeded');
        const missing = needed.filter(([, s]) => s !== 'allowed');
        const denied = missing.filter(([, s]) => s === 'denied');
        const list = needed.map(([k, s]) => `${PERMISSION_NAMES[k] || k}: ${s}`).join(', ') || 'none needed for this terminal';
        if (!live) {
          add('island-permissions', 'Island permissions', 'info', `as of when it last ran: ${list}`);
        } else {
          add('island-permissions', 'Island permissions', missing.length ? 'warn' : 'ok', list,
            !missing.length ? null
              : denied.length ? { tell: `macOS remembers a "Don't Allow". In Tabby Island's setup window (${T} island permissions opens it) click "Ask Again" next to ${denied.map(([k]) => PERMISSION_NAMES[k] || k).join(' and ')}, then Allow.` }
                : { tell: `Tabby Island's setup window lists them (${T} island permissions opens it): click Allow on each and answer the macOS prompt. For Accessibility, switch Tabby Island on in System Settings › Privacy & Security › Accessibility.` });
        }
      }
    }
  }

  const ok = checks.every((c) => c.status !== 'fail');
  const next = checks.find((c) => c.status === 'fail' && c.fix) || checks.find((c) => c.status === 'warn' && c.fix) || null;
  return { ok, version: v, platform: `${process.platform} ${island.macosVersion() || os.release()} ${os.arch()}`, reinstall: INSTALL_ONE_LINER, next: next ? { id: next.id, ...next.fix } : null, checks };
}

export function printDoctor({ json = false, color = true } = {}) {
  const d = diagnose();
  if (json) return JSON.stringify(d, null, 2);
  const paint = (code, s) => (color ? `\x1b[${code}m${s}\x1b[0m` : s);
  const mark = { ok: paint('32', '✓'), warn: paint('33', '!'), fail: paint('31', '✗'), info: paint('2', '·'), skip: paint('2', '–') };
  const lines = [`tabby ${d.version} · ${d.platform}`];
  for (const c of d.checks) {
    lines.push(`  ${mark[c.status]} ${c.title.padEnd(26)} ${c.status === 'info' || c.status === 'skip' ? paint('2', c.detail) : c.detail}`);
    if (c.fix) lines.push(`      ${paint('2', '→')} ${c.fix.run ? `run: ${c.fix.run}` : c.fix.tell}`);
  }
  lines.push(d.ok ? (d.next ? '\nWorking, with the notes above.' : '\nEverything works.') : `\nNot working yet. Stuck? In Claude Code, ask: "fix tabby".`);
  return lines.join('\n');
}
