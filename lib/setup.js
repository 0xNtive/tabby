// "/tabby:setup": show the terms, record acceptance, run the one-time setup. Answered by the
// UserPromptSubmit hook (no model call) and by `tabby setup` in a shell.
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { termsAccepted, acceptTerms, TERMS_SUMMARY } from './terms.js';
import { install } from './install.js';
import { unsupported } from './island.js';

const CLI = fileURLToPath(new URL('../bin/tabby.js', import.meta.url));
const SETUP_RE = /^\s*\/(?:tabby:setup|(?:tabby:)?tab\s+setup)(?=\s|$)/i;

export const isSetupCommand = (prompt) => SETUP_RE.test(String(prompt || ''));
export const setupArgs = (prompt) => String(prompt || '').trim().replace(SETUP_RE, '').trim().toLowerCase();

// Gets Tabby Island (the download, or a local build) in the background; its setup window opens
// when it's ready. Null when this machine can't run it.
function islandInBackground() {
  if (unsupported()) return null;
  spawn(process.execPath, [CLI, 'island', 'install', '--quiet'], { detached: true, stdio: 'ignore', env: { ...process.env, TABBY_INTERNAL: '1' } }).unref();
  return 'Tabby Island is on its way: its setup window opens in a few seconds and walks you through the permissions.';
}

function finish(steps) {
  const isl = islandInBackground();
  return [
    '✓ tabby is on.',
    ...steps.map((s) => `  • ${s}`),
    ...(isl ? [`  • ${isl}`] : []),
    '',
    'New Claude sessions are organized automatically; in sessions that are already open, run /reload-plugins.',
    'Stuck? Ask Claude: "fix tabby" (it runs tabby doctor). /tab for commands.',
  ].join('\n');
}

// args: '' | 'accept' | 'island'. Returns the message to show.
export function runSetup(args = '', { plugin = false } = {}) {
  if (args === 'island') {
    if (!termsAccepted()) return runSetup('');
    return islandInBackground() || unsupported();
  }
  if (args === 'accept' || args === 'yes' || termsAccepted()) {
    if (!termsAccepted()) acceptTerms('user');
    return finish(install({ plugin }));
  }
  return [TERMS_SUMMARY, '', 'To agree and finish setup, type:  /tabby:setup accept', 'To leave instead:  /plugin uninstall tabby@tabby'].join('\n');
}
