// Terminal.app shows "custom title — process ◂ command args" in every tab, which buries the
// name. Profiles have a hidden switch, ShowComponentsWhenTabHasCustomTitle: turned off, a tab
// with a custom title (tabby's) shows only that title. We flip it for every profile, through
// cfprefsd (defaults export → PlistBuddy → defaults import), after backing the domain up.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { paths, readConfig, writeConfig } from './state.js';

const DOMAIN = 'com.apple.Terminal';
const KEY = 'ShowComponentsWhenTabHasCustomTitle';
const PLIST = path.join(os.homedir(), 'Library', 'Preferences', `${DOMAIN}.plist`);
const run = (cmd, args) => spawnSync(cmd, args, { encoding: 'utf8', timeout: 20_000 });
const esc = (s) => s.replace(/([\\: ])/g, '\\$1');

function profileNames(file) {
  const out = run('/usr/libexec/PlistBuddy', ['-c', `Print :${esc('Window Settings')}`, file]).stdout || '';
  return [...out.matchAll(/^ {4}(\S[^\n]*?) = Dict \{$/gm)].map((m) => m[1]);
}

// on=true: tabs with a custom title show only that title. on=false: Terminal's default.
export function setTerminalTabTitles(on) {
  if (process.platform !== 'darwin' || !fs.existsSync(PLIST)) return null;
  const cfg = readConfig();
  if (!on && !cfg.terminalTabTitles) return null; // never touched it
  const tmp = path.join(os.tmpdir(), `tabby-terminal-${process.pid}.plist`);
  try {
    if (run('defaults', ['export', DOMAIN, tmp]).status !== 0) return 'Terminal titles: could not read Terminal preferences';
    const names = profileNames(tmp);
    if (!names.length) return null;
    const want = on ? 'false' : 'true';
    const cmds = [];
    for (const name of names) {
      const key = `:${esc('Window Settings')}:${esc(name)}:${KEY}`;
      const cur = run('/usr/libexec/PlistBuddy', ['-c', `Print ${key}`, tmp]);
      if (cur.status === 0 && cur.stdout.trim() === want) continue;
      cmds.push('-c', cur.status === 0 ? `Set ${key} ${want}` : `Add ${key} bool ${want}`);
    }
    if (!cmds.length) {
      if (on && !cfg.terminalTabTitles) writeConfig({ terminalTabTitles: true });
      return null;
    }
    fs.mkdirSync(paths.backups, { recursive: true });
    const backup = path.join(paths.backups, `${DOMAIN}.${new Date().toISOString().replace(/[:.]/g, '-')}.plist`);
    fs.copyFileSync(tmp, backup);
    if (run('/usr/libexec/PlistBuddy', [...cmds, tmp]).status !== 0) return 'Terminal titles: could not update preferences';
    if (run('defaults', ['import', DOMAIN, tmp]).status !== 0) return 'Terminal titles: could not save preferences';
    writeConfig({ terminalTabTitles: on });
    return on
      ? `Terminal.app: tabs show only the session name (${names.length} profiles; backup ${path.basename(backup)}). Takes effect in new tabs, or all tabs after restarting Terminal.`
      : 'Terminal.app: tab titles back to Terminal defaults';
  } finally {
    try { fs.unlinkSync(tmp); } catch {}
  }
}
