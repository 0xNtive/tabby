import { test } from 'node:test';
import assert from 'node:assert/strict';
import { hexToOklch, oklchToHex, contrast, tint, markerFor, hueFamily, normHex } from '../lib/color.js';

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
