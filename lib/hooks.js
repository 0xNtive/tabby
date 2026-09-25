// Claude Code hook handlers. Every handler is best-effort: it must never break or slow a session.
import {
  readConfig, writeConfig, readSession, patchSession, listSessions, liveSessions, registryEntry,
  rememberProjectColor, pruneSessions, projectName, ensureDirs, log,
} from './state.js';
import { detectTerminal, findClaude } from './term.js';
import { chooseLook } from './assign.js';
import { withLook, applySession, clearSession } from './apply.js';
import { spawnNamer, spawnAfterTurn, heuristicTitle } from './namer.js';
import { contextFromTranscript } from './context.js';
import { findTheme, parseColor } from './themes.js';
import { isTabCommand, tabArgs, runCommand } from './commands.js';
import { termsAccepted } from './terms.js';
import { isSetupCommand, setupArgs, runSetup } from './setup.js';
import { ensureTicker } from './ticker.js';

const now = () => Date.now();
const pick = (o, keys) => Object.fromEntries(keys.filter((k) => o?.[k] !== undefined).map((k) => [k, o[k]]));
const clip = (s, n) => (s.length > n ? s.slice(0, n - 1) + '…' : s);
const MANUAL = new Set(['manual', 'user']);
const envOwnsTitle = () => !!process.env.CLAUDE_CODE_DISABLE_TERMINAL_TITLE && process.env.CLAUDE_CODE_DISABLE_TERMINAL_TITLE !== '0';

// A blocked prompt: the reason is shown to the user and nothing reaches the model.
const block = (reason, sessionTitle) => ({
  decision: 'block',
  reason,
  hookSpecificOutput: { hookEventName: 'UserPromptSubmit', suppressOriginalPrompt: true, ...(sessionTitle ? { sessionTitle } : {}) },
});

export function handleHook(event, input) {
  if (process.env.TABBY_INTERNAL) return null;
  const cfg = readConfig();
  if (!cfg.enabled || process.env.TABBY_OFF === '1' || !input?.session_id) return null;
  ensureDirs();
  if (event === 'UserPromptSubmit' && isSetupCommand(input.prompt)) return block(runSetup(setupArgs(input.prompt)));
  if (!termsAccepted(cfg)) return inactive(event, input, cfg);
  switch (event) {
    case 'SessionStart':
      return sessionStart(input, cfg);
    case 'UserPromptSubmit':
      return promptSubmit(input, cfg);
    case 'PostToolUse':
      // Only un-stick "needs you" after a permission/question was answered; never undo "your turn".
      return setStatus(input, cfg, 'busy', null, { onlyFrom: ['waiting', 'error'] });
    case 'PermissionRequest':
      return setStatus(input, cfg, 'waiting', 'permission');
    case 'Notification':
      return notification(input, cfg);
    case 'Stop':
      return stop(input, cfg);
    case 'StopFailure':
      return setStatus(input, cfg, 'error', null);
    case 'SessionEnd':
      return sessionEnd(input, cfg);
    default:
      return null;
  }
}

// Until the terms are accepted tabby does nothing, except point at /tabby:setup (at most every 6 h).
function inactive(event, input, cfg) {
  if (event === 'SessionStart') {
    if (now() - (cfg.termsNudgedAt || 0) < 6 * 3600e3) return null;
    writeConfig({ termsNudgedAt: now() });
    return { systemMessage: 'tabby is installed but off until you accept its terms. Type /tabby:setup to review them.' };
  }
  if (event === 'UserPromptSubmit' && isTabCommand(input.prompt)) return block('tabby is off until you accept its terms. Type /tabby:setup to review them.');
  return null;
}

function sessionStart(input, cfg) {
  return syncName(startSession(input, cfg), cfg, 'SessionStart');
}

// Create (or restore) the record for a session and paint its tab.
export function startSession(input, cfg) {
  const env = process.env;
  const id = input.session_id;
  const { pid, tty } = findClaude(env);
  const prev = readSession(id);
  const others = liveSessions().filter((s) => s.sessionId !== id && s.pid !== pid);
  // Same Claude process, earlier session id => /clear or /resume inside this tab: keep the tab's identity.
  const sibling = listSessions()
    .filter((s) => s.sessionId !== id && pid && s.pid === pid)
    .sort((a, b) => (b.updatedAt || 0) - (a.updatedAt || 0))[0];

  let identity = {};
  if (prev) {
    identity = pick(prev, ['title', 'titleSource', 'summary', 'note', 'theme', 'accentKey', 'prompts', 'promptCount', 'namedAt', 'namedAtPrompt', 'namedWithReply', 'context', 'disabled']);
    const clash = others.some((s) => s.theme === prev.theme && s.accentKey === prev.accentKey);
    if (clash) delete identity.accentKey;
  } else if (sibling) {
    identity = pick(sibling, ['theme', 'accentKey', 'note', 'disabled']);
    if (MANUAL.has(sibling.titleSource)) Object.assign(identity, pick(sibling, ['title', 'titleSource']));
    if (sibling.status !== 'ended') patchSession(sibling.sessionId, { status: 'ended', statusAt: now() });
  }

  // Launch flags (see shell/tabby.zsh): claude --color teal --theme nord --tab "Name"
  if (env.TABBY_THEME && findTheme(env.TABBY_THEME)) identity.theme = findTheme(env.TABBY_THEME).id;
  if (env.TABBY_COLOR && parseColor(env.TABBY_COLOR)) identity.accentKey = parseColor(env.TABBY_COLOR);
  if (env.TABBY_NAME) Object.assign(identity, { title: env.TABBY_NAME.trim(), titleSource: 'manual' });

  const reg = registryEntry(pid);
  if (reg?.nameSource === 'user' && reg.name && !identity.title) Object.assign(identity, { title: reg.name, titleSource: 'user' });

  if (!identity.theme || !identity.accentKey) {
    const auto = chooseLook({ cwd: input.cwd, sessionId: id }, identity.theme ? { ...cfg, auto: 'tint', theme: identity.theme } : cfg, others);
    identity.theme ||= auto.theme;
    identity.accentKey ||= auto.accentKey;
  }

  const base = {
    v: 1,
    sessionId: id,
    pid,
    tty,
    term: detectTerminal(env),
    tmuxPane: env.TMUX_PANE || null,
    termSessionId: env.ITERM_SESSION_ID || env.TERM_SESSION_ID || null,
    cwd: input.cwd,
    project: projectName(input.cwd),
    transcriptPath: input.transcript_path,
    ownsTitle: envOwnsTitle(),
    status: 'new',
    statusAt: now(),
    waitingFor: null,
    startedAt: prev?.startedAt || now(),
    source: input.source || 'startup',
  };
  if (!identity.title) Object.assign(identity, { title: '', titleSource: 'project' });

  const rec = patchSession(id, withLook({ ...base, ...identity }, cfg));
  rememberProjectColor(input.cwd, rec.theme, rec.accentKey);
  applySession(rec, cfg, { colors: true, title: true });
  if (Math.random() < 0.1) pruneSessions(30);
  log('start', id.slice(0, 8), rec.project, rec.theme, rec.accentKey, rec.tty, input.source || '');
  return rec;
}

// Tell Claude Code the tab name so its prompt box and /resume picker match the tab.
function syncName(rec, cfg, eventName) {
  if (!rec || !cfg.syncClaudeName || !rec.title || !['ai', 'manual'].includes(rec.titleSource) || rec.title === rec.pushedTitle) return null;
  patchSession(rec.sessionId, { pushedTitle: rec.title });
  return { hookSpecificOutput: { hookEventName: eventName, sessionTitle: rec.title } };
}

function promptSubmit(input, cfg) {
  const id = input.session_id;
  const prompt = String(input.prompt || '');
  let rec = readSession(id) || startSession(input, cfg);

  if (isTabCommand(prompt)) {
    const res = runCommand(tabArgs(prompt), { rec, cfg });
    // Claude ignores sessionTitle on a blocked prompt (2.1.281); the rename syncs on the next real prompt.
    return block(res.message, cfg.syncClaudeName ? res.sessionTitle : undefined);
  }
  if (rec.disabled) return null;

  // Re-read on every prompt: a session adopted before install (or after /reload-plugins) only
  // hands the title over once Claude runs with CLAUDE_CODE_DISABLE_TERMINAL_TITLE.
  const patch = { status: 'busy', statusAt: now(), waitingFor: null, ownsTitle: envOwnsTitle() };
  const reg = registryEntry(rec.pid);
  if (reg?.nameSource === 'user' && reg.name && reg.name !== rec.title && reg.name !== rec.pushedTitle) {
    Object.assign(patch, { title: reg.name, titleSource: 'user' }); // renamed with /rename or claude -n
  }
  const text = prompt.trim();
  const isSlash = text.startsWith('/');
  if (text && !isSlash) {
    patch.prompts = [...(rec.prompts || []), clip(text.replace(/\s+/g, ' '), 400)].slice(-8);
    patch.promptCount = (rec.promptCount || 0) + 1;
  }
  rec = refreshContext(patchSession(id, patch));
  applySession(rec, cfg, { colors: true, title: true });
  if (rec.ownsTitle) ensureTicker(cfg);

  const manual = MANUAL.has(rec.titleSource);
  if (!manual && text && !isSlash && cfg.namer !== 'off') {
    if (cfg.namer === 'heuristic') {
      const t = heuristicTitle(text);
      if (t && !['heuristic', 'claude'].includes(rec.titleSource)) {
        rec = patchSession(id, { title: t, titleSource: 'heuristic' });
        applySession(rec, cfg, { title: true });
      }
    } else if (rec.titleSource !== 'ai') {
      spawnNamer(id);
    }
  }
  return syncName(rec, cfg, 'UserPromptSubmit');
}

function setStatus(input, cfg, status, waitingFor, { onlyFrom } = {}) {
  const rec = readSession(input.session_id);
  if (!rec || rec.disabled || rec.status === 'ended') return null;
  if (onlyFrom && !onlyFrom.includes(rec.status)) return null;
  const next = patchSession(rec.sessionId, { status, statusAt: now(), waitingFor });
  applySession(next, cfg, { title: true });
  if (next.ownsTitle && (status === 'busy' || status === 'waiting')) ensureTicker(cfg);
  return null;
}

function notification(input, cfg) {
  const t = input.notification_type || '';
  if (['permission_prompt'].includes(t)) return setStatus(input, cfg, 'waiting', 'permission');
  if (['elicitation_dialog', 'elicitation_url_dialog', 'agent_needs_input'].includes(t)) return setStatus(input, cfg, 'waiting', 'input');
  return null;
}

// Transcript usage from the turn that just ended (skipped when the statusLine keeps it exact).
export function refreshContext(rec) {
  if (!rec || (rec.context?.source === 'statusline' && now() - (rec.context.at || 0) < 30_000)) return rec;
  const ctx = contextFromTranscript(rec.transcriptPath);
  return ctx ? patchSession(rec.sessionId, { context: { ...(rec.context || {}), ...ctx } }) : rec;
}

export function wantsRename(rec, cfg) {
  if (!rec || cfg.namer !== 'ai' || MANUAL.has(rec.titleSource) || !(rec.promptCount > 0)) return false;
  const newPrompts = rec.promptCount > (rec.namedAtPrompt || 0);
  return (newPrompts || !rec.namedWithReply) && now() - (rec.namedAt || 0) > 45_000;
}

function stop(input, cfg) {
  const rec = readSession(input.session_id);
  if (!rec || rec.disabled) return null;
  const next = patchSession(rec.sessionId, { status: 'idle', statusAt: now(), waitingFor: null });
  applySession(next, cfg, { title: true });
  // Claude flushes the turn's last transcript line just after Stop; finish the rest in the background.
  spawnAfterTurn(next.sessionId);
  return null;
}

function sessionEnd(input, cfg) {
  const rec = readSession(input.session_id);
  if (!rec) return null;
  patchSession(rec.sessionId, { status: 'ended', statusAt: now(), endReason: input.reason || '' });
  if (['clear', 'resume'].includes(input.reason)) return null; // the tab lives on with a new session
  if (cfg.resetOnExit && !rec.disabled) clearSession(rec);
  return null;
}
