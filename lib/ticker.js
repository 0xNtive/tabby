// Animated tab titles. While any session is working or waiting, one background process redraws
// their titles a few times a second: a spinner for "working", a blinking bell for "needs you"
// (plus a pulsing tab color on iTerm2). It exits by itself a minute after everything is idle.
import fs from 'node:fs';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { paths, readConfig, readJson, isAlive, log } from './state.js';
import { titleText } from './apply.js';
import { writeTty, sequences } from './term.js';

const CLI = fileURLToPath(new URL('../bin/tabby.js', import.meta.url));
const pidFile = () => path.join(paths.root, 'ticker.pid');
const AMBER = '#ffa138';

export function tickerPid() {
  try {
    const pid = Number(fs.readFileSync(pidFile(), 'utf8'));
    return isAlive(pid) ? pid : 0;
  } catch {
    return 0;
  }
}

// Called by hooks whenever a session starts working or starts waiting. Cheap when running.
export function ensureTicker(cfg = readConfig()) {
  if (cfg.animate === false || tickerPid()) return;
  try {
    spawn(process.execPath, [CLI, '_ticker'], { detached: true, stdio: 'ignore', env: { ...process.env, TABBY_INTERNAL: '1' } }).unref();
  } catch (e) {
    log('ticker spawn failed', e.message);
  }
}

// The title for one animation frame.
export function frameTitle(rec, cfg, tick) {
  if (rec.status === 'busy') {
    const frames = [...(cfg.spinner || '◐◓◑◒')];
    return titleText(rec, { ...cfg, status: { ...cfg.status, busy: frames[tick % frames.length] } });
  }
  if (rec.status === 'waiting') {
    const show = tick % 6 < 4; // the bell is lit two thirds of the time
    return titleText(rec, { ...cfg, status: { ...cfg.status, waiting: show ? cfg.status.waiting : '　' } });
  }
  return titleText(rec, cfg);
}

export function runTicker() {
  fs.mkdirSync(paths.root, { recursive: true });
  fs.writeFileSync(pidFile(), String(process.pid));
  let cfg = readConfig();
  const fps = Math.min(12, Math.max(2, Number(cfg.fps) || 6));
  const files = new Map(); // path -> { mtime, rec }
  const written = new Map(); // sessionId -> last title
  let candidates = [];
  let tick = 0;
  let idleSince = Date.now();

  const rescan = () => {
    let names = [];
    try {
      names = fs.readdirSync(paths.sessions).filter((n) => n.endsWith('.json'));
    } catch {}
    candidates = names.map((n) => path.join(paths.sessions, n));
  };
  const load = (file) => {
    let st;
    try {
      st = fs.statSync(file);
    } catch {
      files.delete(file);
      return null;
    }
    const hit = files.get(file);
    if (hit && hit.mtime === st.mtimeMs) return hit.rec;
    const rec = readJson(file);
    files.set(file, { mtime: st.mtimeMs, rec });
    return rec;
  };

  const stop = () => {
    clearInterval(timer);
    try {
      if (Number(fs.readFileSync(pidFile(), 'utf8')) === process.pid) fs.unlinkSync(pidFile());
    } catch {}
    process.exit(0);
  };

  rescan();
  const timer = setInterval(() => {
    tick++;
    if (tick % (fps * 2) === 0) rescan();
    if (tick % (fps * 5) === 0) cfg = readConfig();
    if (cfg.animate === false) return stop();
    let active = 0;
    for (const file of candidates) {
      const s = load(file);
      if (!s || !s.ownsTitle || s.disabled || !s.tty || s.status === 'ended' || s.term === 'tmux') continue;
      if (s.status === 'busy' || s.status === 'waiting') {
        if (!isAlive(s.pid)) continue;
        active++;
      } else if (!written.has(s.sessionId)) continue; // never animated: the hooks own its title
      const title = frameTitle(s, cfg, tick);
      let seq = '';
      if (written.get(s.sessionId) !== title) seq += sequences(s.term, { title });
      if (s.term === 'iterm2' && s.status === 'waiting' && tick % 3 === 0) {
        seq += sequences('iterm2', { tabColor: tick % 6 === 0 ? AMBER : s.accent });
      }
      if (!seq) continue;
      written.set(s.sessionId, title);
      writeTty(s.tty, seq);
      if (s.status !== 'busy' && s.status !== 'waiting') written.delete(s.sessionId); // settled: hand back to the hooks
    }
    if (active) idleSince = Date.now();
    else if (Date.now() - idleSince > 60_000) stop();
  }, Math.round(1000 / fps));
  process.on('SIGTERM', stop);
  process.on('SIGINT', stop);
}
