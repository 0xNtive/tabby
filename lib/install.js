// One-command setup / teardown. Every change is reversible and settings.json is backed up first.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { paths, readJson, writeJson, readConfig, ensureDirs } from './state.js';
import { themesExport } from './themes.js';
import { setTerminalTabTitles } from './terminal-prefs.js';

export const ROOT = fileURLToPath(new URL('..', import.meta.url)).replace(/\/$/, '');
export const CLI = path.join(ROOT, 'bin', 'tabby.js');
export const LAUNCHER = path.join(paths.root, 'bin', 'tabby.mjs');
const LAUNCHER_SH = path.join(paths.root, 'bin', 'tabby');
const SHELL_FILE = path.join(paths.root, 'shell', 'tabby.sh');
const ZSHRC = path.join(os.homedir(), '.zshrc');
const BASHRC = path.join(os.homedir(), '.bashrc');
const BEGIN = '# >>> tabby (claude tab colors) >>>';
const END = '# <<< tabby <<<';
const COMMAND = path.join(paths.claudeDir, 'commands', 'tab.md');
const COMMAND_TAG = '<!-- tabby:user-command -->';
const MARKETPLACE = 'tabby';
const PLUGIN = 'tabby@tabby';
const GITHUB = '0xNtive/tabby';

const sh = (cmd, args) => spawnSync(cmd, args, { encoding: 'utf8', timeout: 120_000 });

// Copies that can disappear: versioned plugin-cache dirs and npx scratch installs.
export const ephemeralRoot = (root = ROOT) => /\/plugins\/cache\/|\/_npx\//.test(root);

// The node running tabby, via a stable path (Homebrew's Cellar path changes on every upgrade).
export function nodePath() {
  const exe = process.execPath;
  const cellar = /^(.*)\/Cellar\/node(@\d+)?\/[^/]+\/bin\/node$/.exec(exe);
  if (cellar && fs.existsSync(`${cellar[1]}/bin/node`)) return `${cellar[1]}/bin/node`;
  if (!exe.includes('/Cellar/')) return exe;
  const r = sh('/bin/sh', ['-lc', 'command -v node']);
  return (r.stdout || '').trim() || exe;
}

function backupSettings() {
  if (!fs.existsSync(paths.settings)) return null;
  fs.mkdirSync(paths.backups, { recursive: true });
  const dest = path.join(paths.backups, `settings.${new Date().toISOString().replace(/[:.]/g, '-')}.json`);
  fs.copyFileSync(paths.settings, dest);
  return dest;
}

const statusCommand = () => `node "${LAUNCHER}" statusline`;
const isOurStatus = (s) => typeof s?.command === 'string' && /tabby(\.m?js)?"?\s+statusline/.test(s.command);

export function pluginInstalled() {
  const reg = readJson(path.join(paths.claudeDir, 'plugins', 'installed_plugins.json'), {});
  return Object.keys(reg?.plugins || {}).some((k) => k.startsWith('tabby@'));
}

// ~/.claude/tabby/bin/tabby.mjs runs the newest installed copy: $TABBY_ROOT, then the copy that
// ran install (if it is a stable checkout or npm install), then the newest plugin-cache version.
export function writeLauncher() {
  const pinned = ephemeralRoot() ? null : ROOT;
  const src = `#!/usr/bin/env node
// tabby launcher, written by \`tabby install\`. Runs the newest installed copy of tabby.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const pinned = ${JSON.stringify(pinned)};
const cache = path.join(process.env.CLAUDE_CONFIG_DIR || path.join(os.homedir(), '.claude'), 'plugins', 'cache');
const list = (dir) => { try { return fs.readdirSync(dir); } catch { return []; } };
const newer = (a, b) => {
  const x = a.split('.').map(Number), y = b.split('.').map(Number);
  for (let i = 0; i < 3; i++) if ((x[i] || 0) !== (y[i] || 0)) return (x[i] || 0) > (y[i] || 0);
  return false;
};
let best = null;
for (const market of list(cache)) {
  for (const version of list(path.join(cache, market, 'tabby'))) {
    const cli = path.join(cache, market, 'tabby', version, 'bin', 'tabby.js');
    if (fs.existsSync(cli) && (!best || newer(version, best.version))) best = { version, cli };
  }
}
const candidates = [process.env.TABBY_ROOT && path.join(process.env.TABBY_ROOT, 'bin', 'tabby.js'), pinned && path.join(pinned, 'bin', 'tabby.js'), best?.cli];
const cli = candidates.find((p) => p && fs.existsSync(p));
if (!cli) {
  console.error('tabby: no installation found. Reinstall with /plugin install tabby@tabby');
  process.exit(1);
}
await import(pathToFileURL(cli).href);
`;
  fs.mkdirSync(path.dirname(LAUNCHER), { recursive: true });
  fs.writeFileSync(LAUNCHER, src, { mode: 0o755 });
  fs.writeFileSync(LAUNCHER_SH, `#!/bin/sh\nexec node "${LAUNCHER}" "$@"\n`, { mode: 0o755 });
  fs.mkdirSync(path.dirname(SHELL_FILE), { recursive: true });
  fs.copyFileSync(path.join(ROOT, 'shell', 'tabby.sh'), SHELL_FILE);
}

export function writeExports() {
  ensureDirs();
  const cfg = readConfig();
  writeJson(paths.themes, themesExport(cfg.theme));
  writeJson(paths.island, { node: nodePath(), cli: LAUNCHER, root: ROOT });
  if (!fs.existsSync(paths.config)) writeJson(paths.config, { theme: cfg.theme });
}

// Plugin commands are namespaced (/tabby:tab); a user-level command gives the short /tab.
// The UserPromptSubmit hook answers it instantly; the body only runs if the hook is off.
function addUserCommand() {
  if (fs.existsSync(COMMAND) && !fs.readFileSync(COMMAND, 'utf8').includes(COMMAND_TAG)) return 'user command: ~/.claude/commands/tab.md exists and is not ours; left alone (use /tabby:tab)';
  const fresh = !fs.existsSync(COMMAND);
  fs.mkdirSync(path.dirname(COMMAND), { recursive: true });
  fs.writeFileSync(
    COMMAND,
    `---\ndescription: Name, color or re-theme this terminal tab (tabby) — /tab Auth refactor · /tab color teal · /tab theme nord all\nargument-hint: "[name] | color <c> | theme <t> [all] | auto | ls | themes | note <text> | reset | off | on"\nallowed-tools: Bash(node:*)\n---\n${COMMAND_TAG}\ntabby answers /tab in its hook, so this text only runs when that hook is off. Run this once with the Bash tool and reply with its output verbatim:\n\nnode "${LAUNCHER}" $ARGUMENTS\n`
  );
  return fresh ? 'user command: /tab (short form of /tabby:tab)' : null;
}

function removeUserCommand() {
  if (fs.existsSync(COMMAND) && fs.readFileSync(COMMAND, 'utf8').includes(COMMAND_TAG)) {
    fs.unlinkSync(COMMAND);
    return true;
  }
  return false;
}

function rcFiles() {
  const shell = path.basename(process.env.SHELL || 'zsh');
  return shell === 'bash' ? [BASHRC] : [ZSHRC];
}

const escapeRe = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
const blockRe = new RegExp(`\\n?${escapeRe(BEGIN)}[\\s\\S]*?${escapeRe(END)}\\n?`);

// Adds (or migrates) the block that sources ~/.claude/tabby/shell/tabby.sh.
function addShellHook(file) {
  const block = `${BEGIN}\n[ -f "${SHELL_FILE}" ] && . "${SHELL_FILE}"\n${END}\n`;
  const cur = fs.existsSync(file) ? fs.readFileSync(file, 'utf8') : '';
  if (cur.includes(block)) return 'same';
  if (cur.includes(BEGIN)) {
    fs.writeFileSync(file, cur.replace(blockRe, '\n' + block));
    return 'migrated';
  }
  fs.writeFileSync(file, cur + (cur.endsWith('\n') || !cur ? '' : '\n') + block);
  return 'added';
}

function removeShellHook(file) {
  if (!fs.existsSync(file)) return false;
  const cur = fs.readFileSync(file, 'utf8');
  if (!blockRe.test(cur)) return false;
  fs.writeFileSync(file, cur.replace(blockRe, '\n'));
  return true;
}

// Local checkouts and npm installs register themselves; npx copies point at GitHub.
function marketplaceSource() {
  return /\/_npx\/|\/node_modules\//.test(ROOT) ? GITHUB : ROOT;
}

export function install({ statusline = true, shell = true, plugin = true, title = true, terminalTitles = true } = {}) {
  const steps = [];
  writeLauncher();
  writeExports();
  steps.push(`launcher + state → ${paths.root}`);

  const settings = readJson(paths.settings, {}) || {};
  const backup = backupSettings();
  let changed = false;
  if (title && settings.env?.CLAUDE_CODE_DISABLE_TERMINAL_TITLE !== '1') {
    settings.env = { ...(settings.env || {}), CLAUDE_CODE_DISABLE_TERMINAL_TITLE: '1' };
    changed = true;
    steps.push('settings.json: tabby draws the tab title (CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1)');
  }
  if (statusline) {
    if (!settings.statusLine || (isOurStatus(settings.statusLine) && settings.statusLine.command !== statusCommand())) {
      settings.statusLine = { type: 'command', command: statusCommand(), padding: 0 };
      changed = true;
      steps.push('settings.json: statusLine → tab name + context meter');
    } else if (!isOurStatus(settings.statusLine)) {
      steps.push('statusLine: you already have one; left untouched');
    }
  }
  if (changed) {
    writeJson(paths.settings, settings);
    if (backup) steps.push(`backup: ${backup}`);
  }

  if (plugin) {
    if (pluginInstalled()) steps.push('plugin: already installed');
    else {
      const source = marketplaceSource();
      const a = sh('claude', ['plugin', 'marketplace', 'add', source]);
      const b = sh('claude', ['plugin', 'install', PLUGIN]);
      steps.push(b.status === 0 ? `plugin: installed tabby@tabby from ${source}` : `plugin: install failed (${(b.stderr || b.stdout || a.stderr || '').trim().split('\n').pop()})`);
    }
  }

  const cmd = addUserCommand();
  if (cmd) steps.push(cmd);
  if (shell) {
    for (const f of rcFiles()) {
      const r = addShellHook(f);
      if (r !== 'same') steps.push(`shell: claude --tab/--color/--theme flags + \`tabby\` command via ${f}${r === 'migrated' ? ' (updated)' : ''}`);
    }
  }
  if (terminalTitles && process.platform === 'darwin') {
    const r = setTerminalTabTitles(true);
    if (r) steps.push(r);
  }
  return steps;
}

export function uninstall() {
  const steps = [];
  const settings = readJson(paths.settings, null);
  if (settings) {
    const backup = backupSettings();
    let changed = false;
    if (settings.env?.CLAUDE_CODE_DISABLE_TERMINAL_TITLE) {
      delete settings.env.CLAUDE_CODE_DISABLE_TERMINAL_TITLE;
      if (!Object.keys(settings.env).length) delete settings.env;
      changed = true;
    }
    if (isOurStatus(settings.statusLine)) {
      delete settings.statusLine;
      changed = true;
    }
    if (changed) {
      writeJson(paths.settings, settings);
      steps.push(`settings.json restored (backup: ${backup})`);
    }
  }
  if (pluginInstalled()) {
    sh('claude', ['plugin', 'uninstall', PLUGIN]);
    sh('claude', ['plugin', 'marketplace', 'remove', MARKETPLACE]);
    steps.push('plugin: removed');
  }
  if (removeUserCommand()) steps.push('user command /tab: removed');
  for (const f of [ZSHRC, BASHRC]) if (removeShellHook(f)) steps.push(`shell: removed from ${f}`);
  if (process.platform === 'darwin') {
    const r = setTerminalTabTitles(false);
    if (r) steps.push(r);
  }
  for (const f of [LAUNCHER, LAUNCHER_SH, SHELL_FILE]) try { fs.unlinkSync(f); } catch {}
  spawnSync('pkill', ['-x', 'TabbyIsland'], { stdio: 'ignore' });
  steps.push(`state kept in ${paths.root} (delete it to forget names and colors)`);
  return steps;
}
