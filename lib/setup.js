// "/tabby:setup": show the terms, record acceptance, run the one-time setup. Answered by the
// UserPromptSubmit hook (no model call) and by `tabby setup` in a shell.
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { termsAccepted, acceptTerms, TERMS_SUMMARY } from './terms.js';
import { install } from './install.js';

const CLI = fileURLToPath(new URL('../bin/tabby.js', import.meta.url));
const SETUP_RE = /^\s*\/(?:tabby:setup|(?:tabby:)?tab\s+setup)(?=\s|$)/i;

export const isSetupCommand = (prompt) => SETUP_RE.test(String(prompt || ''));
export const setupArgs = (prompt) => String(prompt || '').trim().replace(SETUP_RE, '').trim().toLowerCase();

function finish(steps) {
  return [
    '✓ tabby is on.',
    ...steps.map((s) => `  • ${s}`),
    '',
    'New Claude sessions are organized automatically; in sessions that are already open, run /reload-plugins.',
    'Next: /tabby:setup island for the macOS session island · /tab for commands.',
  ].join('\n');
}

// args: '' | 'accept' | 'island'. Returns the message to show.
export function runSetup(args = '', { plugin = false } = {}) {
  if (args === 'island') {
    if (!termsAccepted()) return runSetup('');
    spawn(process.execPath, [CLI, 'island'], { detached: true, stdio: 'ignore', env: { ...process.env, TABBY_INTERNAL: '1' } }).unref();
    return 'Building Tabby Island (about 15 s)… it appears at the top center of your screen. Needs Xcode Command Line Tools (xcode-select --install).';
  }
  if (args === 'accept' || args === 'yes' || termsAccepted()) {
    if (!termsAccepted()) acceptTerms('user');
    return finish(install({ plugin }));
  }
  return [TERMS_SUMMARY, '', 'To agree and finish setup, type:  /tabby:setup accept', 'To leave instead:  /plugin uninstall tabby@tabby'].join('\n');
}
