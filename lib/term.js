// Terminal detection, finding the tab's TTY, and writing titles/colors to it.
// Hooks run without a controlling terminal, so we write escape sequences straight to the
// TTY device of the Claude process (any process of the same user may write to it).
import fs from 'node:fs';
import { execFileSync, spawn, spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { hexToRgb } from './color.js';
import { plain } from './state.js';

const CLI = fileURLToPath(new URL('../bin/tabby.js', import.meta.url));

// TERM_PROGRAM, as each terminal sets it for its own tabs. A tmux that isn't around any more
// (TERM_PROGRAM=tmux without TMUX) gets nothing tmux-specific.
const PROGRAMS = { 'iTerm.app': 'iterm2', Apple_Terminal: 'apple-terminal', ghostty: 'ghostty', WezTerm: 'wezterm', vscode: 'vscode', WarpTerminal: 'warp', Tabby: 'tabby', Hyper: 'hyper', tmux: 'generic', zed: 'generic', rio: 'generic' };

export function detectTerminal(env = process.env) {
  const tp = env.TERM_PROGRAM || '';
  const term = env.TERM || '';
  // Multiplexers keep the outer terminal's TERM_PROGRAM, so they come first.
  if (env.TMUX) return 'tmux';
  if (env.STY) return 'screen';
  if (env.ZELLIJ) return 'zellij';
  // The terminal that owns the tab sets TERM_PROGRAM. The marker variables below leak into apps
  // started from a shell (VS Code opened with `code .` from iTerm2 keeps LC_TERMINAL=iTerm2), so
  // they only count when TERM_PROGRAM is empty: over SSH, where LC_TERMINAL is forwarded.
  if (tp) return PROGRAMS[tp] || 'generic';
  // Every tab gets a fresh TERM (SSH forwards it), so a terminal's own terminfo name beats a marker.
  if (/ghostty/.test(term)) return 'ghostty';
  if (/kitty/.test(term)) return 'kitty';
  if (/alacritty/.test(term)) return 'alacritty';
  if (env.LC_TERMINAL === 'iTerm2') return 'iterm2';
  if (env.GHOSTTY_RESOURCES_DIR) return 'ghostty';
  if (env.WEZTERM_PANE) return 'wezterm';
  if (env.KITTY_WINDOW_ID) return 'kitty';
  if (env.ALACRITTY_WINDOW_ID) return 'alacritty';
  return 'generic';
}

// What each terminal can show. `marker` = put a colored emoji in the title because the
// terminal has no per-tab color of its own.
export const CAPS = {
  'apple-terminal': { title: true, colors: true, tabColor: false, marker: true, focus: true, label: 'Terminal.app' },
  iterm2: { title: true, colors: true, tabColor: true, marker: false, focus: true, label: 'iTerm2' },
  ghostty: { title: true, colors: true, tabColor: false, marker: true, focus: false, label: 'Ghostty' },
  wezterm: { title: true, colors: true, tabColor: false, marker: true, focus: false, label: 'WezTerm' },
  kitty: { title: true, colors: true, tabColor: false, marker: true, focus: false, label: 'kitty' },
  vscode: { title: true, colors: true, tabColor: false, marker: true, focus: false, label: 'VS Code / Cursor' },
  warp: { title: true, colors: false, tabColor: false, marker: true, focus: false, label: 'Warp' },
  tabby: { title: true, colors: true, tabColor: false, marker: true, focus: false, label: 'Tabby' },
  alacritty: { title: true, colors: true, tabColor: false, marker: true, focus: false, label: 'Alacritty' },
  hyper: { title: true, colors: true, tabColor: false, marker: true, focus: false, label: 'Hyper' },
  tmux: { title: true, colors: true, tabColor: true, marker: false, focus: true, label: 'tmux' },
  // screen keeps OSC 0 as the window's hardstatus (its "xterm title hack") and passes no colors
  // on; neither multiplexer can say which outer tab holds it, so there's no jumping to it.
  screen: { title: true, colors: false, tabColor: false, marker: true, focus: false, label: 'GNU screen' },
  zellij: { title: true, colors: true, tabColor: false, marker: true, focus: false, label: 'Zellij' },
  generic: { title: true, colors: true, tabColor: false, marker: true, focus: false, label: 'terminal' },
};

export const caps = (term) => CAPS[term] || CAPS.generic;

function ps(fields, pid, opts = []) {
  try {
    return execFileSync('ps', [...opts, '-o', `${fields}=`, '-p', String(pid)], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim();
  } catch {
    return '';
  }
}

export function ttyOfPid(pid) {
  const t = ps('tty', pid);
  return t && !t.startsWith('?') ? `/dev/${t}` : null;
}

// Where a tab lives, from its shell's environment: the terminal, the tmux pane and server (the
// socket is the first field of $TMUX), and the app (macOS sets __CFBundleIdentifier for shells an
// app starts: com.apple.Terminal, com.microsoft.VSCode…).
export function whereFrom(env) {
  const app = env.__CFBundleIdentifier || '';
  return {
    term: detectTerminal(env),
    tmuxPane: env.TMUX_PANE || null,
    tmuxSocket: env.TMUX ? env.TMUX.split(',')[0] : null,
    bundleId: /^[A-Za-z0-9.-]{1,100}$/.test(app) ? app : null,
    termSessionId: env.ITERM_SESSION_ID || env.TERM_SESSION_ID || null,
  };
}

// What detectTerminal reads, from another process's environment (your own processes only: macOS
// `ps -E`, Linux /proc): a session started before tabby says which terminal it's in.
const TERM_KEYS = new Set(['TERM_PROGRAM', 'TERM_PROGRAM_VERSION', 'LC_TERMINAL', 'TERM', 'COLORTERM', 'TMUX', 'TMUX_PANE', 'STY', 'ZELLIJ', 'ITERM_SESSION_ID', 'TERM_SESSION_ID', 'GHOSTTY_RESOURCES_DIR', 'WEZTERM_PANE', 'KITTY_WINDOW_ID', 'ALACRITTY_WINDOW_ID', '__CFBundleIdentifier']);
export function envOfPid(pid) {
  const out = {};
  if (!Number(pid)) return out;
  let words;
  try {
    words = fs.readFileSync(`/proc/${Number(pid)}/environ`, 'utf8').split('\0');
  } catch {
    // `ps -E` prints the arguments, then the environment, all joined by spaces: a `KEY=val`
    // argument would pass for the environment. The arguments alone come off the front first.
    const all = ps('command', Number(pid), ['-wwE']);
    const args = ps('command', Number(pid), ['-ww']);
    words = (args && all.startsWith(args) ? all.slice(args.length) : all).split(' ');
  }
  for (const w of words) {
    const eq = w.indexOf('=');
    if (eq > 0 && TERM_KEYS.has(w.slice(0, eq))) out[w.slice(0, eq)] = w.slice(eq + 1);
  }
  return out;
}

// The Claude process that owns this hook, and its TTY. Claude exports CLAUDE_PID to hooks
// and tools; otherwise walk up the process tree to the first ancestor with a terminal.
export function findClaude(env = process.env) {
  if (env.TABBY_TTY) return { pid: Number(env.CLAUDE_PID) || process.ppid, tty: env.TABBY_TTY };
  if (env.CLAUDE_PID) {
    const tty = ttyOfPid(env.CLAUDE_PID);
    if (tty) return { pid: Number(env.CLAUDE_PID), tty };
  }
  let pid = process.ppid;
  for (let i = 0; i < 8 && pid > 1; i++) {
    const out = ps('ppid,tty,comm', pid);
    const m = /^\s*(\d+)\s+(\S+)\s+(.*)$/.exec(out);
    if (!m) break;
    const [, ppid, tty, comm] = m;
    if (!tty.startsWith('?')) return { pid: /claude/i.test(comm) ? pid : Number(env.CLAUDE_PID) || pid, tty: `/dev/${tty}` };
    pid = Number(ppid);
  }
  return { pid: Number(env.CLAUDE_PID) || null, tty: null };
}

// TTY of the shell running this CLI (when used in a plain terminal tab).
export function ownTty() {
  try {
    if (process.stdout.isTTY || process.stdin.isTTY) {
      const t = execFileSync('tty', { encoding: 'utf8', stdio: ['inherit', 'pipe', 'ignore'] }).trim();
      if (t.startsWith('/dev/')) return t;
    }
  } catch {}
  return ttyOfPid(process.ppid);
}

export function writeTty(tty, data) {
  if (!tty || !data) return false;
  let fd;
  try {
    fd = fs.openSync(tty, fs.constants.O_WRONLY | fs.constants.O_APPEND | fs.constants.O_NOCTTY | fs.constants.O_NONBLOCK);
    fs.writeSync(fd, data);
    return true;
  } catch {
    return false;
  } finally {
    if (fd !== undefined) try { fs.closeSync(fd); } catch {}
  }
}

const OSC = (body) => `\x1b]${body}\x07`;

export function cleanTitle(s, max = 90) {
  const t = plain(s).replace(/ {2,}/g, ' ').trim();
  return t.length > max ? t.slice(0, max - 1) + '…' : t;
}

const rgb255 = (hex) => hexToRgb(hex).map((v) => Math.round(v * 255));

const itermTabColor = (hex) => {
  const [r, g, b] = rgb255(hex);
  return OSC(`6;1;bg;red;brightness;${r}`) + OSC(`6;1;bg;green;brightness;${g}`) + OSC(`6;1;bg;blue;brightness;${b}`);
};

export function sequences(term, { title, look, reset, tabColor } = {}) {
  let s = '';
  if (tabColor && term === 'iterm2') s += itermTabColor(tabColor);
  if (reset && caps(term).colors) {
    s += OSC('110') + OSC('111') + OSC('112');
    if (term === 'iterm2') s += OSC('6;1;bg;*;default');
  }
  if (look && caps(term).colors) {
    s += OSC(`10;${look.fg}`) + OSC(`11;${look.bg}`) + OSC(`12;${look.cursor}`);
    if (term === 'iterm2') s += itermTabColor(look.accent);
  }
  if (title !== undefined && title !== null) s += OSC(`0;${cleanTitle(title)}`);
  return s;
}

// The tmux server a pane lives on is named by its socket (the first field of $TMUX): without
// `-S`, a command from the island or another terminal reaches the default server instead.
export const tmuxArgs = (target, args) => {
  const sock = target?.tmuxSocket;
  return typeof sock === 'string' && sock.startsWith('/') && !/[\x00-\x1f\x7f]/.test(sock) ? ['-S', sock, ...args] : args;
};

function tmux(target, args) {
  try {
    spawnSync('tmux', tmuxArgs(target, args), { stdio: 'ignore', timeout: 1500 });
  } catch {}
}

// Apply title/colors to one tab. `target` = { tty, term, tmuxPane, tmuxSocket }.
export function applyToTab(target, { title, look, reset } = {}) {
  if (!target) return false;
  if (target.term === 'tmux' && target.tmuxPane) {
    const p = target.tmuxPane;
    // Pane options rather than `select-pane -P`, which tmux's manual no longer lists.
    if (reset) {
      tmux(target, ['set-option', '-pu', '-t', p, 'window-style']);
      tmux(target, ['set-option', '-pu', '-t', p, 'window-active-style']);
      tmux(target, ['set-option', '-wu', '-t', p, 'window-status-style']);
      tmux(target, ['set-option', '-wu', '-t', p, 'window-status-current-style']);
      tmux(target, ['set-option', '-w', '-t', p, 'automatic-rename', 'on']);
    }
    if (look) {
      tmux(target, ['set-option', '-p', '-t', p, 'window-style', `bg=${look.bg},fg=${look.fg}`]);
      tmux(target, ['set-option', '-p', '-t', p, 'window-active-style', `bg=${look.bg},fg=${look.fg}`]);
      tmux(target, ['set-option', '-w', '-t', p, 'window-status-style', `fg=${look.accent}`]);
      tmux(target, ['set-option', '-w', '-t', p, 'window-status-current-style', `fg=${look.bg},bg=${look.accent},bold`]);
    }
    // tmux expands #{…} and #(…) in a window name: a doubled # is a plain one.
    if (title) tmux(target, ['rename-window', '-t', p, cleanTitle(title, 40).replace(/#/g, '##')]);
    return true;
  }
  const ok = writeTty(target.tty, sequences(target.term, { title, look, reset }));
  if (target.term === 'apple-terminal' && (look || reset)) boldColor(target.tty, look ? 'text' : 'reset');
  return ok;
}

// Terminal.app draws bold text in the profile's own bold color, which no escape code changes: a
// light profile's black bold would vanish on a dark tabby background. AppleScript can set it per
// tab; that's slow, so it happens in the background (`tabby _profile bold <tty> text|reset`).
function boldColor(tty, color) {
  if (process.platform !== 'darwin' || process.env.TABBY_NO_TERMINAL_PROFILES || !tty) return;
  try {
    spawn(process.execPath, [CLI, '_profile', 'bold', tty, color], { detached: true, stdio: 'ignore', env: { ...process.env, TABBY_INTERNAL: '1' } }).unref();
  } catch {}
}

const FOCUS_TERMINAL = `on run argv
  set ttyName to item 1 of argv
  tell application "Terminal"
    repeat with w in windows
      repeat with t in tabs of w
        if tty of t is ttyName then
          if miniaturized of w then set miniaturized of w to false
          set selected of t to true
          set index of w to 1
          activate
          return "ok"
        end if
      end repeat
    end repeat
  end tell
  return "missing"
end run`;

const FOCUS_ITERM = `on run argv
  set ttyName to item 1 of argv
  tell application "iTerm2"
    repeat with w in windows
      repeat with t in tabs of w
        repeat with s in sessions of t
          if tty of s is ttyName then
            select w
            tell t to select
            tell s to select
            activate
            return "ok"
          end if
        end repeat
      end repeat
    end repeat
  end tell
  return "missing"
end run`;

// Two Apple events for every tab at once (tab by tab took a round trip per property per tab).
const TITLES_TERMINAL = `tell application "Terminal"
  set ttys to tty of every tab of every window
  set names to custom title of every tab of every window
end tell
set out to ""
repeat with i from 1 to count of ttys
  set wt to item i of ttys
  set wn to item i of names
  repeat with j from 1 to count of wt
    set out to out & (item j of wt) & (ASCII character 9) & (item j of wn) & linefeed
  end repeat
end repeat
return out`;

const TITLES_ITERM = `tell application "iTerm2"
  set out to ""
  repeat with w in windows
    repeat with t in tabs of w
      repeat with s in sessions of t
        set out to out & (tty of s) & (ASCII character 9) & (name of s) & linefeed
      end repeat
    end repeat
  end repeat
  return out
end tell`;

// Strip Claude's spinner/idle glyphs (and tabby's marker) from a tab title.
export const stripGlyphs = (t) => String(t || '').replace(/^[\s✳◐-◓⠀-⣿✢-✽·*🔔⚠\u{1F534}-\u{1F7EB}⚪⚫]+/u, '').trim();

// tty -> current tab title, read from the terminal (the only place Claude keeps its AI topic title).
export function terminalTitles(term = detectTerminal()) {
  const script = term === 'iterm2' ? TITLES_ITERM : term === 'apple-terminal' ? TITLES_TERMINAL : null;
  const out = new Map();
  if (!script) return out;
  const r = spawnSync('osascript', ['-e', script], { encoding: 'utf8', timeout: 4000 });
  for (const line of (r.stdout || '').split('\n')) {
    const [tty, title] = line.split('\t');
    if (tty && title) out.set(tty.trim(), stripGlyphs(title));
  }
  return out;
}

// Bring the tab of a session to the front.
export function focusTab(target) {
  if (!target) return false;
  if (target.term === 'tmux' && target.tmuxPane) {
    tmux(target, ['select-window', '-t', target.tmuxPane]);
    tmux(target, ['select-pane', '-t', target.tmuxPane]);
    return true;
  }
  const script = target.term === 'iterm2' ? FOCUS_ITERM : target.term === 'apple-terminal' ? FOCUS_TERMINAL : null;
  // A tty is a device path; anything else (a value starting with "-" would be read as an
  // osascript option) is not passed on.
  if (!script || !String(target.tty || '').startsWith('/dev/')) return false;
  const r = spawnSync('osascript', ['-e', script, target.tty], { encoding: 'utf8', timeout: 5000 });
  return (r.stdout || '').trim() === 'ok';
}
