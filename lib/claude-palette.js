// Claude Code paints its own UI colors (dim text, suggestions, diffs, its orange) on top of the
// terminal background. These are its dark and light palettes (Claude Code 2.1.x), used to check
// that tabby's backgrounds keep Claude's interface readable. Claude designed them for a black
// or a white background; the further a theme's background is from that, the more contrast is lost.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { contrast } from './color.js';

export const CLAUDE_PALETTES = {
  dark: {
    text: '#ffffff', inactive: '#999999', suggestion: '#b1b9f9', claude: '#d77757', success: '#4eba65', error: '#ff6b80',
    warning: '#ffc107', diffAddedWord: '#38a660', diffRemovedWord: '#b3596b', planMode: '#48968c', ide: '#4782c8',
  },
  light: {
    text: '#000000', inactive: '#666666', suggestion: '#5769f7', claude: '#d77757', success: '#2c7a39', error: '#ab2b3f',
    warning: '#966c1e', diffAddedWord: '#2f9d44', diffRemovedWord: '#d1454b', planMode: '#006666', ide: '#4782c8',
  },
};
const REFERENCE = { dark: '#000000', light: '#ffffff' };

// Claude's theme setting ("dark" when unset); /theme writes it to ~/.claude.json.
export function claudeTheme() {
  try {
    const file = path.join(process.env.CLAUDE_CONFIG_DIR || os.homedir(), '.claude.json');
    return JSON.parse(fs.readFileSync(file, 'utf8')).theme || 'dark';
  } catch {
    return 'dark';
  }
}
export const claudeMode = (theme = claudeTheme()) => (String(theme).startsWith('light') ? 'light' : 'dark');

// How much of Claude's intended contrast survives on these backgrounds (worst role, worst bg).
export function claudeReadability(bgs, mode) {
  const palette = CLAUDE_PALETTES[mode];
  let keep = Infinity;
  let worst = Infinity;
  let role = '';
  for (const bg of bgs) {
    for (const [name, color] of Object.entries(palette)) {
      if (name === 'text') continue; // body text is fine everywhere; the colored roles are what fade
      const ratio = contrast(color, bg);
      const kept = ratio / contrast(color, REFERENCE[mode]);
      if (kept < keep) [keep, role] = [kept, name];
      worst = Math.min(worst, ratio);
    }
  }
  return { mode, keep: +keep.toFixed(2), worst: +worst.toFixed(2), role };
}
