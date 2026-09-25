// User agreement: tabby stays inert until the current terms version is accepted.
import { readConfig, writeConfig } from './state.js';

export const TERMS_VERSION = '2026-09-25';
export const TERMS_URL = 'https://claude-tabby.vercel.app/terms';

export function termsAccepted(cfg = readConfig()) {
  return cfg.termsAccepted?.version === TERMS_VERSION;
}

export function acceptTerms(by = 'user') {
  writeConfig({ termsAccepted: { version: TERMS_VERSION, at: new Date().toISOString(), by } });
}

export const TERMS_SUMMARY = [
  `tabby Terms of Use (${TERMS_VERSION}), the short version:`,
  '  • Runs locally. No servers, no telemetry. Tab names come from Claude Haiku through YOUR Claude Code login.',
  '  • Changes terminal titles/colors and a few Claude Code settings; `tabby uninstall` reverts them.',
  '  • Free. Future versions may show clearly labeled sponsored messages in tabby\'s own UI (island, status line, CLI),',
  '    never inside your prompts, conversations or the model\'s context, and never targeted using your code or prompts.',
  '  • Provided as is, without warranty. Not affiliated with Anthropic.',
  `  Full terms: ${TERMS_URL}`,
].join('\n');
