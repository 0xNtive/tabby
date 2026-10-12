import { test } from 'node:test';
import assert from 'node:assert/strict';
import { hexToOklch, oklchToHex, contrast, tint, markerFor, hueFamily, normHex, ansiFg, ansiBg, xterm256 } from '../lib/color.js';

test('oklch round-trips within one 8-bit step', () => {
  for (const hex of ['#1b1e23', '#ef9491', '#48c7c3', '#fdf6e3', '#002b36', '#ffffff', '#000000']) {
    const { L, C, h } = hexToOklch(hex);
    assert.equal(oklchToHex(L, C, h), normHex(hex));
  }
});

test('WCAG contrast', () => {
  assert.ok(Math.abs(contrast('#000000', '#ffffff') - 21) < 0.01);
  assert.equal(contrast('#777777', '#777777'), 1);
});

test('tint keeps lightness (and so text contrast) while shifting hue', () => {
  const bg = '#1b1e23';
  const fg = '#d1d4da';
  for (const accent of ['#ef9491', '#7fc489', '#77b7f4', '#bea0eb']) {
    const t = tint(bg, accent);
    assert.ok(Math.abs(hexToOklch(t).L - hexToOklch(bg).L) < 0.01, `L drift for ${accent}`);
    assert.ok(Math.abs(contrast(fg, t) - contrast(fg, bg)) < 0.4, `contrast drift for ${accent}`);
    assert.ok(hexToOklch(t).C > hexToOklch(bg).C, 'tint adds chroma');
  }
  assert.equal(tint(bg, '#808080'), bg, 'neutral accent leaves bg alone');
});

test('emoji markers follow hue', () => {
  assert.equal(markerFor('#e5484d'), '🔴');
  assert.equal(markerFor('#f5a524'), '🟠');
  assert.equal(markerFor('#f0d43a'), '🟡');
  assert.equal(markerFor('#30a46c'), '🟢');
  assert.equal(markerFor('#3e8ef7'), '🔵');
  assert.equal(markerFor('#8e4ec6'), '🟣');
  assert.equal(markerFor('#8b5a3c'), '🟤');
  assert.equal(markerFor('#e8e8e8'), '⚪');
  assert.equal(markerFor('#30a46c', 'heart'), '💚');
  assert.equal(markerFor('#30a46c', 'none'), '');
  assert.equal(hueFamily('#48c7c3'), 'teal');
});

test('Terminal.app before macOS 26 gets 256 colors; everything else 24-bit', () => {
  const saved = { TERM_PROGRAM: process.env.TERM_PROGRAM, COLORTERM: process.env.COLORTERM };
  const set = (k, v) => (v === undefined ? delete process.env[k] : (process.env[k] = v));
  try {
    set('TERM_PROGRAM', 'Apple_Terminal');
    set('COLORTERM', undefined);
    assert.equal(ansiFg('#ff0000'), '\x1b[38;5;196m');
    assert.equal(ansiBg('#808080'), '\x1b[48;5;244m', 'grays use the gray ramp');
    set('COLORTERM', 'truecolor');
    assert.equal(ansiFg('#ff0000'), '\x1b[38;2;255;0;0m', 'Terminal 2.15 says truecolor');
    set('COLORTERM', '24bit');
    assert.equal(ansiBg('#1b1e23'), '\x1b[48;2;27;30;35m');
    set('TERM_PROGRAM', 'iTerm.app');
    set('COLORTERM', undefined);
    assert.equal(ansiFg('#ff0000'), '\x1b[38;2;255;0;0m');
  } finally {
    set('TERM_PROGRAM', saved.TERM_PROGRAM);
    set('COLORTERM', saved.COLORTERM);
  }
  assert.deepEqual(['#000000', '#ffffff', '#5f87af', '#eeeeee'].map(xterm256), [16, 231, 67, 255]);
});
