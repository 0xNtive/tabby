import { test } from 'node:test';
import assert from 'node:assert/strict';
import { THEMES, ACCENT_KEYS, GROUPS, findTheme, strictTheme, parseColor, resolveLook, accentHex, audit, themesExport } from '../lib/themes.js';
import { contrast, isHex, markerFor } from '../lib/color.js';

const STRENGTHS = ['subtle', 'medium', 'bold'];

test('every theme is well-formed', () => {
  assert.ok(THEMES.length >= 50, `only ${THEMES.length} themes`);
  const ids = new Set();
  for (const t of THEMES) {
    assert.ok(!ids.has(t.id), `duplicate ${t.id}`);
    ids.add(t.id);
    assert.ok(isHex(t.bg) && isHex(t.fg), t.id);
    assert.ok(['dark', 'light'].includes(t.mode), t.id);
    assert.ok(GROUPS[t.group], `${t.id} has unknown group ${t.group}`);
    for (const [k, v] of Object.entries(t.accents)) {
      assert.ok(ACCENT_KEYS.includes(k), `${t.id}.${k}`);
      assert.ok(isHex(v), `${t.id}.${k}`);
    }
    assert.ok(Object.keys(t.accents).length >= 6, `${t.id} has too few accents`);
  }
});

test('text is WCAG AA or better in every theme', () => {
  for (const t of THEMES) assert.ok(contrast(t.fg, t.bg) >= 4.5, `${t.id}: ${contrast(t.fg, t.bg).toFixed(2)}`);
});

test('mode matches the background', () => {
  for (const t of THEMES) {
    const darkBg = contrast(t.bg, '#000000') < contrast(t.bg, '#ffffff');
    assert.equal(t.mode === 'dark', darkBg, t.id);
  }
});

test('tinted backgrounds never read worse than the theme (or AA)', () => {
  for (const t of THEMES) {
    const floor = Math.min(4.5, contrast(t.fg, t.bg));
    for (const k of ACCENT_KEYS) {
      for (const strength of STRENGTHS) {
        const look = resolveLook({ theme: t.id, accentKey: k }, { strength });
        assert.ok(contrast(look.fg, look.bg) >= floor - 0.01, `${t.id}/${k}/${strength}: ${contrast(look.fg, look.bg).toFixed(2)}`);
      }
    }
  }
});

test('cursors are visible (3:1) and island dots readable on black (4:1)', () => {
  for (const t of THEMES) {
    for (const k of ACCENT_KEYS) {
      const look = resolveLook({ theme: t.id, accentKey: k }, { strength: 'bold' });
      assert.ok(contrast(look.cursor, look.bg) >= 3, `${t.id}/${k} cursor ${contrast(look.cursor, look.bg).toFixed(2)}`);
      assert.ok(contrast(look.dot, '#000000') >= 4, `${t.id}/${k} dot ${contrast(look.dot, '#000000').toFixed(2)}`);
    }
  }
});

test('audit + export carry contrast facts for the site and island', () => {
  const nord = audit(findTheme('nord'));
  assert.equal(nord.rating, 'AAA');
  assert.ok(nord.text > 9);
  const exp = themesExport('tabby');
  assert.equal(exp.themes.length, THEMES.length);
  const t = exp.themes.find((x) => x.id === 'ayu-light');
  assert.ok(t.contrast.lowAccents.length > 0, 'pale accents are reported');
  assert.ok(Object.values(t.dots).every((h) => contrast(h, '#000000') >= 4));
  assert.equal(Object.keys(t.tints).length, ACCENT_KEYS.length);
});

test('the default theme gives 6 distinct title markers', () => {
  const markers = new Set(['blue', 'green', 'purple', 'orange', 'yellow', 'red'].map((k) => markerFor(accentHex(findTheme('tabby'), k))));
  assert.equal(markers.size, 6);
});

test('theme lookup: ids, aliases, names, fuzzy', () => {
  assert.equal(findTheme('mocha').id, 'catppuccin-mocha');
  assert.equal(findTheme('macchiato').id, 'catppuccin-macchiato');
  assert.equal(findTheme('Tokyo Night').id, 'tokyo-night');
  assert.equal(findTheme('storm').id, 'tokyo-night-storm');
  assert.equal(findTheme('rose pine').id, 'rose-pine');
  assert.equal(findTheme("synthwave '84").id, 'synthwave-84');
  assert.equal(findTheme('tomorrow').id, 'tomorrow');
  assert.equal(findTheme('gruv').id, 'gruvbox');
  assert.equal(findTheme('nope-nope'), null);
  assert.equal(strictTheme('night'), null, 'strict lookup never guesses');
  assert.equal(strictTheme('nord').id, 'nord');
});

test('color words', () => {
  assert.equal(parseColor('cyan'), 'teal');
  assert.equal(parseColor('Teal'), 'teal');
  assert.equal(parseColor('#abc'), '#aabbcc');
  assert.equal(parseColor('pur'), 'purple');
  assert.equal(parseColor('banana'), null);
  assert.ok(accentHex(findTheme('rose-pine'), 'green'), 'missing keys fall back to nearest hue');
});
