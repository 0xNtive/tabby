// Tab names: instant heuristic + a background Haiku call through the user's own Claude
// login (`claude -p --safe-mode`, no hooks/plugins/MCP, thinking off: ~2s, ~$0.001).
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawn, spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { paths, readSession, patchSession, readConfig, isAlive, log } from './state.js';
import { lastAssistantText } from './context.js';
import { applySession } from './apply.js';

const CLI = fileURLToPath(new URL('../bin/tabby.js', import.meta.url));

const FILLER = /^(ok(ay)?|so|um+|uh+|hey|hi|hello|please|pls|well|alright|right|now|also|and|but|then|yeah|yes|great|cool|thanks?|thank you)\b[\s,.!:;-]*/i;
const LEAD =
  /^((can|could|would|will) you( please)?|i('d| would) like( you)?( to)?|i (need|want|have|think)( you)?( to)?|help me( to)?|let'?s|let us|we (need|should|want)( to)?|go( ahead( and)?)?|please)\s+/i;
const STOP = new Set(
  'the a an to of for and or with in on at my our this that these those it its is are be been so we i you me some any all just really very also like kind sort thing things stuff please get make do does did can could would should will there here what how why when which into from about as by up out if then than'.split(' ')
);

export function heuristicTitle(prompt) {
  let s = String(prompt || '')
    .replace(/```[\s\S]*?```/g, ' ')
    .replace(/https?:\/\/\S+/g, ' ')
    .split(/[.?!\n]/)
    .map((x) => x.trim())
    .find((x) => x.length > 3) || '';
  for (let i = 0; i < 6; i++) {
    const before = s;
    s = s.replace(FILLER, '').replace(LEAD, '').trim();
    if (s === before) break;
  }
  const words = s
    .split(/\s+/)
    .map((w) => w.replace(/[^\p{L}\p{N}#.+_/-]/gu, ''))
    .filter((w) => w && !STOP.has(w.toLowerCase()));
  const out = [];
  for (const w of words) {
    const next = [...out, w[0].toUpperCase() + w.slice(1)].join(' ');
    if (next.length > 28 || out.length >= 4) break;
    out.push(w[0].toUpperCase() + w.slice(1));
  }
  return out.join(' ');
}

export function cleanAiTitle(t) {
  let s = String(t || '')
    .replace(/[\p{Extended_Pictographic}‍️]/gu, '')
    .replace(/^["'`\s]+|["'`\s.:;,!]+$/g, '')
    .replace(/\s+/g, ' ')
    .trim();
  if (s.length > 32) {
    const cut = s.slice(0, 31);
    s = cut.slice(0, cut.lastIndexOf(' ') > 12 ? cut.lastIndexOf(' ') : 31).trim();
  }
  return s;
}

export function parseNamerOutput(stdout) {
  let text = stdout;
  try {
    const outer = JSON.parse(stdout);
    text = outer.structured_output ? JSON.stringify(outer.structured_output) : outer.result ?? stdout;
  } catch {}
  const m = /\{[\s\S]*\}/.exec(String(text));
  if (!m) return null;
  try {
    const j = JSON.parse(m[0]);
    const title = cleanAiTitle(j.title);
    if (!title) return null;
    const summary = String(j.summary || '').replace(/\s+/g, ' ').trim().slice(0, 180);
    return { title, summary };
  } catch {
    return null;
  }
}

const SYSTEM = `You label terminal tabs so a developer juggling several Claude Code sessions can tell them apart at a glance.
Reply with JSON only, no code fences: {"title": "...", "summary": "..."}
- title: 2-4 words, max 28 characters, Title Case, specific to the actual task (e.g. "Stripe Webhook Retries", "Flaky Auth Tests", "Tab Color Themes"). Never generic ("Coding Help", "Bug Fix", "New Session"). No project name, no emoji, no quotes.
- summary: one sentence, max 140 characters: what is being worked on and toward what goal, concrete nouns first.
- If a current title is given and the latest requests continue the same task, return the same title.`;

export function namerPrompt(rec, lastText = '') {
  const prompts = (rec.prompts || []).slice(-6).map((p, i) => `${i + 1}. ${p}`).join('\n');
  return [
    `Project: ${rec.project || '(none)'} (${rec.cwd || ''})`,
    ['ai', 'claude'].includes(rec.titleSource) && rec.title ? `Current title: ${rec.title}` : '',
    `User requests, oldest first:\n${prompts}`,
    lastText ? `Claude's latest reply (excerpt): ${lastText}` : '',
  ]
    .filter(Boolean)
    .join('\n\n');
}

function childEnv() {
  const env = { ...process.env };
  for (const k of Object.keys(env)) {
    if (/^CLAUDE_CODE_(SESSION|MESSAGING|BRIDGE|CHILD|ENTRYPOINT|EXECPATH|SSE_PORT)/.test(k) || k === 'CLAUDECODE' || k === 'CLAUDE_PID' || k === 'CLAUDE_EFFORT') {
      delete env[k];
    }
  }
  return { ...env, CLAUDE_CODE_DISABLE_THINKING: '1', CLAUDE_CODE_DISABLE_TERMINAL_TITLE: '1', TABBY_INTERNAL: '1' };
}

export function callHaiku(prompt, { model = 'haiku', claudeBin } = {}) {
  const bin = claudeBin || process.env.CLAUDE_CODE_EXECPATH || 'claude';
  const args = ['-p', '--safe-mode', '--model', model, '--effort', 'low', '--no-session-persistence', '--tools', '', '--system-prompt', SYSTEM, '--output-format', 'json', prompt];
  const r = spawnSync(bin, args, { env: childEnv(), cwd: os.tmpdir(), encoding: 'utf8', timeout: 60_000, stdio: ['ignore', 'pipe', 'pipe'] });
  if (r.error || r.status !== 0) {
    log('namer: claude failed', { status: r.status, error: r.error?.message, stderr: (r.stderr || '').slice(0, 300) });
    return null;
  }
  return parseNamerOutput(r.stdout);
}

const lockFile = (id) => path.join(paths.sessions, `${id}.naming`);

function takeLock(id) {
  const f = lockFile(id);
  try {
    const [pid, ts] = fs.readFileSync(f, 'utf8').split(' ').map(Number);
    if (isAlive(pid) && Date.now() - ts < 90_000) return false;
  } catch {}
  fs.writeFileSync(f, `${process.pid} ${Date.now()}`);
  return true;
}

function spawnCli(args) {
  try {
    const child = spawn(process.execPath, [CLI, ...args], { detached: true, stdio: 'ignore', env: { ...process.env, TABBY_INTERNAL: '1' } });
    child.unref();
  } catch (e) {
    log('spawn failed', args[0], e.message);
  }
}

export const spawnNamer = (sessionId) => spawnCli(['_name', sessionId]);
export const spawnAfterTurn = (sessionId) => spawnCli(['_after', sessionId]);

// Runs in the detached child. Re-runs once if prompts arrived while it was busy.
export function runNamer(sessionId) {
  if (!takeLock(sessionId)) {
    patchSession(sessionId, { nameDirty: true });
    return;
  }
  try {
    for (let round = 0; round < 2; round++) {
      const rec = readSession(sessionId);
      if (!rec || rec.titleSource === 'manual' || rec.titleSource === 'user' || !(rec.prompts || []).length) return;
      const cfg = readConfig();
      patchSession(sessionId, { nameDirty: false });
      const lastText = lastAssistantText(rec.transcriptPath);
      const result = callHaiku(namerPrompt(rec, lastText), { model: cfg.namerModel });
      const fresh = readSession(sessionId);
      if (!fresh || fresh.titleSource === 'manual' || fresh.titleSource === 'user') return;
      const named = result
        ? { title: result.title, summary: result.summary || fresh.summary, titleSource: 'ai', namedWithReply: !!lastText }
        : fresh.titleSource === 'ai'
          ? {}
          : { title: heuristicTitle((fresh.prompts || []).at(-1)) || fresh.title, titleSource: 'heuristic' };
      const next = patchSession(sessionId, { ...named, namedAt: Date.now(), namedAtPrompt: fresh.promptCount || 0 });
      log('namer:', sessionId.slice(0, 8), result ? `"${result.title}"` : 'fallback');
      if (next.status !== 'ended') applySession(next, cfg, { title: true });
      if (!readSession(sessionId)?.nameDirty) return;
    }
  } finally {
    try { fs.unlinkSync(lockFile(sessionId)); } catch {}
  }
}
