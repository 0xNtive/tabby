// Processes your sessions leave running: dev servers on localhost ports, leftovers whose terminal
// or Claude session is gone, and anything else of yours started from a terminal that eats CPU or
// memory. Only processes started from a terminal or by Claude are looked at (their environment
// says so); launchd services, apps, shells you type in and Claude itself never are. Nothing is
// stopped until you ask: `tabby procs stop`, /tab procs stop, or the island's Processes page.
import { spawnSync } from 'node:child_process';
import os from 'node:os';
import path from 'node:path';
import { listSessions, readRegistry, plain } from './state.js';

const HOUR = 3600e3;
// What makes a process worth listing (cpu in %, memory in MB) and a session "idle" for long.
export const LIMITS = { cpu: 15, memMB: 400, idleMs: 2 * HOUR, seedCpu: 5, seedMemMB: 150 };

const SHELLS = new Set(['zsh', 'bash', 'sh', 'fish', 'dash', 'tcsh', 'csh', 'ksh', 'nu', 'login']);
// Never offered: agents and multiplexers outlive their terminal on purpose; the rest are yours.
const KEEP = new Set(['ssh-agent', 'gpg-agent', 'tmux', 'screen', 'mosh-server', 'caffeinate', 'sudo', 'launchd', 'claude', 'TabbyIsland', 'zellij']);
const SYSTEM = /^\/(?:System|usr\/libexec|usr\/sbin|sbin|Library\/Apple)\//;
// Apps you open (not a CLI tool that happens to live in a bundle, like Homebrew's Python).
const APP = /^(?:\/System)?\/Applications\/|^\/Users\/[^/]+\/Applications\//;
const OURS = /(?:^|\/)tabby\.(?:js|mjs|sh)\b|TabbyIsland/;
// Started on purpose and meant to keep running (a VM, a database, a tunnel): listed, never stale.
const DAEMON = /^(?:docker|dockerd|com\.docker\..*|colima|limactl|lima-.*|qemu-system-.*|vfkit|ollama|postgres|postmaster|mysqld|mariadbd|mongod|redis-server|valkey-server|memcached|nginx|httpd|caddy|traefik|tailscaled?|cloudflared|ngrok|syncthing|emacs|code-server|minikube|k3s|podman|gvproxy|sshd?|autossh)$/i;
// What a dev server or a script runs on: a leftover of these from a plain terminal is stale.
const RUNTIME = /^(?:node|bun|deno|python[\d.]*|Python|ruby|php|java|perl|go|cargo|npm|npx|pnpm|yarn|tsx|ts-node|uv|uvicorn|gunicorn|esbuild|vite|next-server)$/;

const env = { ...process.env, LC_ALL: 'C', LANG: 'C' };
function run(cmd, args) {
  const r = spawnSync(cmd, args, { encoding: 'utf8', timeout: 8000, maxBuffer: 32 * 1024 * 1024, env });
  return r.stdout || '';
}

const base = (p) => path.basename(String(p || '').replace(/^-/, ''));

// `ps -o pid=,ppid=,uid=,pcpu=,rss=,lstart=,tty=,command=`: the start time is five words.
const PS_LINE = /^\s*(\d+)\s+(\d+)\s+(\d+)\s+([\d.]+)\s+(\d+)\s+(\w{3} \w{3}\s+\d+ \d\d:\d\d:\d\d \d{4})\s+(\S+)\s(.*)$/;
export function parsePs(text) {
  const out = new Map();
  for (const line of String(text).split('\n')) {
    const m = PS_LINE.exec(line);
    if (!m) continue;
    const started = Date.parse(m[6].replace(/\s+/g, ' '));
    out.set(Number(m[1]), {
      pid: Number(m[1]),
      ppid: Number(m[2]),
      uid: Number(m[3]),
      cpu: Number(m[4]) || 0,
      memMB: Math.round(Number(m[5]) / 1024),
      startedAt: Number.isFinite(started) ? started : 0,
      tty: m[7],
      command: m[8].trim(),
    });
  }
  return out;
}

// `ps -o pid=,comm=`: the executable (a full path when there is one).
export function parseComm(text) {
  const out = new Map();
  for (const line of String(text).split('\n')) {
    const m = /^\s*(\d+)\s(.*)$/.exec(line);
    if (m) out.set(Number(m[1]), m[2].trim());
  }
  return out;
}

// `lsof -Fpn`: "p<pid>" starts a process, "n<address>" names one of its files.
export function parseLsof(text) {
  const out = new Map();
  let pid = 0;
  for (const line of String(text).split('\n')) {
    if (line[0] === 'p') pid = Number(line.slice(1));
    else if (line[0] === 'n' && pid) (out.get(pid) || out.set(pid, []).get(pid)).push(line.slice(1));
  }
  return out;
}

export const portOf = (address) => {
  const m = /:(\d+)$/.exec(String(address));
  return m ? Number(m[1]) : null;
};

// The variables that say where a process came from, from `ps -E` (the command, then its
// environment). The last match wins: the environment follows the arguments.
const MARKERS = ['TERM_SESSION_ID', 'TERM_PROGRAM', 'CLAUDECODE', 'CLAUDE_CODE_SESSION_ID', 'CLAUDE_PID', 'XPC_SERVICE_NAME', 'TMUX', 'SSH_CONNECTION'];
export function parseEnv(text) {
  const out = new Map();
  for (const line of String(text).split('\n')) {
    const m = /^\s*(\d+)\s(.*)$/.exec(line);
    if (!m) continue;
    const vars = {};
    for (const key of MARKERS) {
      const all = [...m[2].matchAll(new RegExp(`(?:^|\\s)${key}=(\\S*)`, 'g'))];
      if (all.length) vars[key] = all.at(-1)[1];
    }
    out.set(Number(m[1]), vars);
  }
  return out;
}

// Started from a terminal or by Claude, and not a launchd job (those carry their label).
export function fromTerminal(vars = {}) {
  const service = vars.XPC_SERVICE_NAME && vars.XPC_SERVICE_NAME !== '0';
  return !service && !!(vars.TERM_SESSION_ID || vars.TERM_PROGRAM || vars.CLAUDECODE || vars.TMUX || vars.SSH_CONNECTION);
}

const isClaude = (p, exe) => base(exe || p.command.split(' ')[0]) === 'claude';
const headless = (p) => /--headless\b/.test(p.command);

// A short name for what a process is: "vite", "next dev", "python http.server", "server.js".
const TOOLS = /\b(vite|next|nuxt|astro|remix|webpack(?:-dev-server)?|esbuild|tsc|tsx|nodemon|jest|vitest|playwright|storybook|expo|metro|wrangler|vercel|netlify|firebase|prisma|json-server|http-server|live-server|serve|turbo|nx|parcel|rollup|svelte-kit|ng|gatsby|eleventy|hugo|jekyll|ts-node|bun|deno)\b/;
export function describe(command, exe = '') {
  const cmd = String(command || '').trim();
  const words = cmd.split(/\s+/);
  const prog = base(exe || words[0]);
  if (headless({ command: cmd })) return /chrom/i.test(cmd) ? 'Chrome (headless)' : `${prog} (headless)`;
  // Next.js and others rename their process ("next-server (v15.1.0)").
  if (!words[0].includes('/') && /^[\w-]+ \(v[\d.]+/.test(cmd)) return words[0];
  const args = words.slice(1);
  if (/^(npm|pnpm|yarn|bun)$/.test(prog)) {
    const i = args.findIndex((a) => !a.startsWith('-'));
    return [prog, ...args.slice(i < 0 ? 0 : i, (i < 0 ? 0 : i) + 2)].join(' ').trim();
  }
  if (/^(node|bun|deno|tsx|ts-node)$/.test(prog)) {
    const mod = /node_modules\/(?:\.bin\/)?((?:@[\w.-]+\/)?[\w.-]+)/.exec(cmd);
    if (mod) {
      const tool = mod[1].replace(/^@[\w.-]+\//, '');
      const sub = args.find((a, i) => i > 0 && /^(dev|start|serve|preview|watch|build|test)$/.test(a));
      return sub ? `${tool} ${sub}` : tool;
    }
    if (args.some((a) => /^(-e|--eval|-p|--print)$/.test(a))) return `${prog} -e`;
    const script = args.find((a, i) => !a.startsWith('-') && !/^(-r|--require|--import|--loader|-C|--conditions)$/.test(args[i - 1] || '') && !/^(run|serve|start)$/.test(a));
    if (script) return base(script);
    return prog;
  }
  if (/^python[\d.]*$|^Python$/.test(prog)) {
    const m = args.indexOf('-m');
    if (m >= 0 && args[m + 1]) return `python ${args[m + 1]}`;
    const script = args.find((a) => !a.startsWith('-'));
    if (script && base(script) === 'manage.py') return `django ${args[args.indexOf(script) + 1] || ''}`.trim();
    return script ? base(script) : 'python';
  }
  if (/^(ruby|php|java|perl)$/.test(prog)) {
    const script = args.find((a) => !a.startsWith('-'));
    return script ? `${prog} ${base(script)}` : prog;
  }
  const tool = TOOLS.exec(prog);
  return tool ? prog : prog || 'process';
}

export function duration(ms) {
  const m = Math.max(0, Math.round(ms / 60_000));
  if (m < 60) return `${m} min`;
  const h = Math.round(m / 60);
  return h < 48 ? `${h} h` : `${Math.round(h / 24)} d`;
}

// What's running. `system` stands in for the commands (tests); `now` for the clock.
export function scan({ system = null, now = Date.now(), self = process.pid } = {}) {
  const sys = system || liveSystem();
  const all = parsePs(sys.ps());
  const comm = parseComm(sys.comm());
  const uid = sys.uid ?? (process.getuid ? process.getuid() : -1);
  const listening = parseLsof(sys.listening(uid));
  const ports = new Map([...listening].map(([pid, names]) => [pid, [...new Set(names.map(portOf).filter(Boolean))].sort((a, b) => a - b)]));
  const exe = (p) => comm.get(p.pid) || p.command.split(' ')[0];

  // This scan and whatever runs it (the island, a Claude session's /tab) are never offered.
  const spare = new Set([0, 1]);
  for (let p = all.get(self), hops = 0; p && hops < 64; p = all.get(p.ppid), hops++) spare.add(p.pid);
  spare.add(self);

  const children = new Map();
  for (const p of all.values()) (children.get(p.ppid) || children.set(p.ppid, []).get(p.ppid)).push(p);
  const registry = sys.registry();
  const claudePids = new Set([...registry.keys()]);
  for (const p of all.values()) if (isClaude(p, exe(p))) claudePids.add(p.pid);

  // Where a group of processes starts: just below Claude, the shell you type in, an app, or launchd.
  const boundary = (q) =>
    !q || q.pid <= 1 || q.uid !== uid || claudePids.has(q.pid) || (SHELLS.has(base(exe(q))) && q.tty !== '??') ||
    APP.test(exe(q)) || SYSTEM.test(exe(q)) || KEEP.has(base(exe(q)));
  const rootOf = (p) => {
    let r = p;
    for (let hops = 0; hops < 64; hops++) {
      const q = all.get(r.ppid);
      if (boundary(q)) return r;
      r = q;
    }
    return r;
  };
  const members = (root) => {
    const out = [];
    const walk = (p, depth) => {
      if (depth > 32 || p.uid !== uid) return;
      out.push(p);
      for (const c of children.get(p.pid) || []) walk(c, depth + 1);
    };
    walk(root, 0);
    return out;
  };

  // Never a group of its own: Claude, apps, the system's own programs, what stays on purpose.
  const never = (p) => {
    const file = exe(p);
    return claudePids.has(p.pid) || KEEP.has(base(file)) || SYSTEM.test(file) || OURS.test(p.command) || (APP.test(file) && !headless(p));
  };

  // Seeds: yours, and listening, left behind, or busy; each brings its whole group along.
  const roots = new Map();
  for (const p of all.values()) {
    if (p.uid !== uid || spare.has(p.pid)) continue;
    const seed = ports.has(p.pid) || p.ppid === 1 || p.cpu >= LIMITS.seedCpu || p.memMB >= LIMITS.seedMemMB;
    if (!seed) continue;
    const root = rootOf(p);
    if (!spare.has(root.pid) && !never(root)) roots.set(root.pid, root);
  }
  const vars = parseEnv(sys.env([...roots.keys()]));

  const records = sys.sessions();
  const byId = new Map(records.map((r) => [r.sessionId, r]));
  const sessionOfPid = (pid) => {
    const reg = registry.get(pid);
    const rec = (reg && byId.get(reg.sessionId)) || records.filter((r) => r.pid === pid && r.status !== 'ended').sort((a, b) => (b.updatedAt || 0) - (a.updatedAt || 0))[0];
    return { reg, rec };
  };

  const items = [];
  for (const root of roots.values()) {
    const rootExe = exe(root);
    const v = vars.get(root.pid) || {};
    if (!fromTerminal(v)) continue;
    const parent = all.get(root.ppid);
    // Claude's own helpers (MCP servers) run right under it, not through a shell.
    if (parent && claudePids.has(parent.pid) && !SHELLS.has(base(rootExe))) continue;
    if (SHELLS.has(base(rootExe)) && root.tty !== '??' && root.ppid !== 1) continue;

    const group = members(root).filter((p) => !spare.has(p.pid) && !OURS.test(p.command));
    if (!group.length) continue;
    const groupPorts = [...new Set(group.flatMap((p) => ports.get(p.pid) || []))].sort((a, b) => a - b);
    const cpu = Math.round(group.reduce((s, p) => s + p.cpu, 0) * 10) / 10;
    const memMB = group.reduce((s, p) => s + p.memMB, 0);
    const orphan = root.ppid === 1;
    if (!groupPorts.length && !orphan && cpu < LIMITS.cpu && memMB < LIMITS.memMB) continue;

    // The process that best says what this is: the one listening, else the busiest non-shell.
    const named =
      group.find((p) => ports.has(p.pid)) ||
      [...group].filter((p) => !SHELLS.has(base(exe(p)))).sort((a, b) => b.cpu + b.memMB / 50 - (a.cpu + a.memMB / 50))[0] ||
      root;

    // Whose it is: the Claude session it runs under, or the one it came from (its environment
    // names it: a server started with `&` outlives the tool call's shell, not its session).
    const fromRec = v.CLAUDE_CODE_SESSION_ID ? byId.get(v.CLAUDE_CODE_SESSION_ID) : null;
    const claudePid =
      parent && claudePids.has(parent.pid)
        ? parent.pid
        : claudePids.has(Number(v.CLAUDE_PID)) && registry.has(Number(v.CLAUDE_PID))
          ? Number(v.CLAUDE_PID)
          : [...registry.values()].find((r) => r.sessionId && r.sessionId === v.CLAUDE_CODE_SESSION_ID)?.pid ||
            (fromRec?.pid && claudePids.has(fromRec.pid) && fromRec.status !== 'ended' ? fromRec.pid : null);
    let owner = { kind: v.CLAUDECODE ? 'claude' : 'terminal', live: !orphan };
    if (claudePid) {
      const { reg, rec } = sessionOfPid(claudePid);
      const statusAt = Math.max(Number(reg?.statusUpdatedAt) || 0, Number(rec?.statusAt) || 0);
      const status = reg?.status || rec?.status || 'idle';
      owner = {
        kind: 'claude',
        live: true,
        sessionId: reg?.sessionId || rec?.sessionId || null,
        title: plain(rec?.title || '').trim() || null,
        project: rec?.project || null,
        status,
        idleMs: status === 'busy' || !statusAt ? 0 : Math.max(0, now - statusAt),
      };
    } else if (v.CLAUDE_CODE_SESSION_ID) {
      owner = { kind: 'claude', live: false, sessionId: v.CLAUDE_CODE_SESSION_ID, title: plain(fromRec?.title || '').trim() || null, project: fromRec?.project || null };
    }
    const leftover = orphan && !owner.live;
    const daemon = group.some((p) => DAEMON.test(base(exe(p))));
    // A plain terminal's process outlives it only when it was detached on purpose (nohup, &
    // disown): stale only when it's a dev server or script, not anything else left to run.
    const devish = headless(named) || group.some((p) => RUNTIME.test(base(exe(p))));

    const age = root.startedAt ? now - root.startedAt : 0;
    let stale = false;
    let why;
    if (daemon) {
      why = leftover ? 'in the background' : owner.kind === 'claude' && owner.live ? 'session open' : 'in a terminal';
    } else if (leftover && (owner.kind === 'claude' || devish)) {
      stale = true;
      why = owner.kind === 'claude' ? 'session ended' : 'left running';
    } else if (leftover) {
      why = 'in the background';
    } else if (owner.kind === 'claude' && owner.live && owner.status !== 'busy' && owner.idleMs >= LIMITS.idleMs && age >= LIMITS.idleMs) {
      stale = true;
      why = `session idle ${duration(owner.idleMs)}`;
    } else if (owner.kind === 'claude' && owner.live) {
      why = owner.status === 'busy' ? 'session working' : 'session open';
    } else {
      why = 'in a terminal';
    }

    items.push({
      id: `${root.pid}-${Math.round(root.startedAt / 1000)}`,
      pid: root.pid,
      pids: group.map((p) => p.pid),
      // A name, never the command line: arguments can carry tokens.
      label: plain(describe(named.command, exe(named))).trim().slice(0, 48) || 'process',
      ports: groupPorts,
      cpu,
      memMB,
      startedAt: root.startedAt,
      count: group.length,
      owner,
      leftover,
      stale,
      why,
      _cwdPid: named.pid,
    });
  }

  // Each one's folder, for the project it belongs to.
  const cwds = parseLsof(sys.cwd(items.map((i) => i._cwdPid)));
  const home = os.homedir();
  for (const item of items) {
    const dir = cwds.get(item._cwdPid)?.[0] || null;
    delete item._cwdPid;
    item.cwd = dir;
    item.project = item.owner.project || (dir && dir !== '/' ? (dir === home ? '~' : plain(path.basename(dir)).trim()) : null);
  }

  items.sort((a, b) => Number(b.stale) - Number(a.stale) || b.cpu + b.memMB / 50 - (a.cpu + a.memMB / 50));
  const stale = items.filter((i) => i.stale);
  return {
    at: now,
    items,
    stale: { count: stale.length, memMB: stale.reduce((s, i) => s + i.memMB, 0), cpu: Math.round(stale.reduce((s, i) => s + i.cpu, 0) * 10) / 10 },
  };
}

const chunks = (list, size = 150) => Array.from({ length: Math.ceil(list.length / size) }, (_, i) => list.slice(i * size, i * size + size));

function liveSystem() {
  return {
    ps: () => run('ps', ['-axww', '-o', 'pid=,ppid=,uid=,pcpu=,rss=,lstart=,tty=,command=']),
    comm: () => run('ps', ['-ax', '-o', 'pid=,comm=']),
    listening: (uid) => run('lsof', ['-nP', '-iTCP', '-sTCP:LISTEN', '-a', '-u', String(uid), '-Fpn']),
    env: (pids) => chunks(pids).map((some) => run('ps', ['-E', '-ww', '-o', 'pid=,command=', '-p', some.join(',')])).join('\n'),
    cwd: (pids) => chunks(pids).map((some) => run('lsof', ['-a', '-d', 'cwd', '-Fpn', '-p', some.join(',')])).join('\n'),
    registry: () => readRegistry(),
    sessions: () => listSessions(),
  };
}

const sleep = (ms) => Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
const alive = (pid) => {
  try {
    process.kill(pid, 0);
    return true;
  } catch (e) {
    return e.code === 'EPERM';
  }
};

// Stops what `which` names, from a fresh scan: "stale", "all", or ids/pids the island showed. An id
// carries the start time, so a pid reused since the list was drawn is never hit. Each group gets
// SIGTERM, and SIGKILL after 2 s if it's still there.
export function stop(which = 'stale', { scanned = null, kill = process.kill.bind(process), isAlive = alive, wait = sleep } = {}) {
  const list = scanned || scan();
  const wanted = Array.isArray(which) ? which.map(String) : [String(which)];
  const pick = (item) =>
    wanted.includes('all') || (wanted.includes('stale') && item.stale) || wanted.includes(item.id) || wanted.includes(String(item.pid));
  const targets = list.items.filter(pick);
  const stopped = [];
  const failed = [];
  for (const item of targets) {
    const pids = [...item.pids].reverse(); // children before their parents
    let error = null;
    for (const pid of pids) {
      try {
        kill(pid, 'SIGTERM');
      } catch (e) {
        if (e.code !== 'ESRCH') error = e.code || e.message;
      }
    }
    item._error = error;
  }
  for (let waited = 0; waited < 2000 && targets.some((t) => t.pids.some(isAlive)); waited += 100) wait(100);
  for (const item of targets) {
    for (const pid of item.pids.filter(isAlive)) {
      try {
        kill(pid, 'SIGKILL');
      } catch {}
    }
  }
  if (targets.some((t) => t.pids.some(isAlive))) wait(200);
  for (const item of targets) {
    const left = item.pids.filter(isAlive);
    const entry = { id: item.id, pid: item.pid, label: item.label, ports: item.ports, memMB: item.memMB, cpu: item.cpu };
    if (left.length === item.pids.length) failed.push({ ...entry, error: item._error || 'still running' });
    else stopped.push(entry);
    delete item._error;
  }
  return {
    stopped,
    failed,
    memMB: stopped.reduce((s, i) => s + i.memMB, 0),
    cpu: Math.round(stopped.reduce((s, i) => s + i.cpu, 0) * 10) / 10,
    unknown: wanted.filter((w) => !['stale', 'all'].includes(w) && !targets.some((t) => t.id === w || String(t.pid) === w)),
  };
}

const mem = (mb) => (mb >= 1024 ? `${(mb / 1024).toFixed(1)} GB` : `${mb} MB`);
const where = (i) => [i.project, i.owner.title].filter(Boolean).join(' · ');
function line(i, now) {
  const port = i.ports.length ? ` :${i.ports.join(', :')}` : '';
  const facts = [`${i.cpu}% CPU`, mem(i.memMB), `up ${duration(now - i.startedAt)}`].join(' · ');
  return `  ${i.stale ? '●' : '○'} ${(i.label + port).padEnd(30)} ${(where(i) || '').padEnd(32)} ${facts}   ${i.why}`;
}

export function report(result = scan(), { now = Date.now() } = {}) {
  const stale = result.items.filter((i) => i.stale);
  const rest = result.items.filter((i) => !i.stale);
  if (!result.items.length) return 'Nothing to clean up: no dev servers, leftovers or heavy processes started from a terminal.';
  const out = [];
  if (stale.length) {
    out.push(`Stale (${stale.length}) · ${mem(result.stale.memMB)} · ${result.stale.cpu}% CPU. Stop them all: tabby procs stop  (in Claude: /tab procs stop)`);
    out.push(...stale.map((i) => line(i, now)));
  } else out.push('Nothing stale.');
  if (rest.length) {
    out.push('', `Running (${rest.length}), stop one with: tabby procs stop <pid>`);
    out.push(...rest.map((i) => line(i, now)));
  }
  return out.join('\n');
}

export function stopReport(res) {
  if (!res.stopped.length && !res.failed.length) return res.unknown.length ? `No such process in the list: ${res.unknown.join(', ')}.` : 'Nothing stale to stop.';
  const out = [];
  if (res.stopped.length) out.push(`Stopped ${res.stopped.length}: ${res.stopped.map((s) => s.label + (s.ports.length ? ` :${s.ports[0]}` : '')).join(', ')}. Freed ${mem(res.memMB)}${res.cpu ? ` and ${res.cpu}% CPU` : ''}.`);
  if (res.failed.length) out.push(`Could not stop: ${res.failed.map((f) => `${f.label} (${f.error})`).join(', ')}.`);
  return out.join('\n');
}
