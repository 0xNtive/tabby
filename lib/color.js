// Color math: sRGB <-> OKLab/OKLCH (Björn Ottosson), WCAG contrast, background tints
// and the emoji "markers" that stand in for tab colors in terminals without them.

const clamp = (x, lo = 0, hi = 1) => Math.min(hi, Math.max(lo, x));

export function hexToRgb(hex) {
  const m = /^#?([0-9a-f]{3}|[0-9a-f]{6})$/i.exec(String(hex).trim());
  if (!m) throw new Error(`not a hex color: ${hex}`);
  let h = m[1];
  if (h.length === 3) h = [...h].map((c) => c + c).join('');
  return [0, 2, 4].map((i) => parseInt(h.slice(i, i + 2), 16) / 255);
}

export function isHex(s) {
  return /^#?([0-9a-f]{3}|[0-9a-f]{6})$/i.test(String(s || '').trim());
}

export function normHex(s) {
  return rgbToHex(hexToRgb(s));
}

export function rgbToHex(rgb) {
  return '#' + rgb.map((v) => Math.round(clamp(v) * 255).toString(16).padStart(2, '0')).join('');
}

const toLinear = (c) => (c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4);
const fromLinear = (c) => (c <= 0.0031308 ? 12.92 * c : 1.055 * c ** (1 / 2.4) - 0.055);

export function rgbToOklab([r, g, b]) {
  r = toLinear(r);
  g = toLinear(g);
  b = toLinear(b);
  const l = Math.cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b);
  const m = Math.cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b);
  const s = Math.cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b);
  return [
    0.2104542553 * l + 0.793617785 * m - 0.0040720468 * s,
    1.9779984951 * l - 2.428592205 * m + 0.4505937099 * s,
    0.0259040371 * l + 0.7827717662 * m - 0.808675766 * s,
  ];
}

function oklabToLinear([L, a, b]) {
  const l = (L + 0.3963377774 * a + 0.2158037573 * b) ** 3;
  const m = (L - 0.1055613458 * a - 0.0638541728 * b) ** 3;
  const s = (L - 0.0894841775 * a - 1.291485548 * b) ** 3;
  return [
    4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
    -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
    -0.0041960863 * l - 0.7034186147 * m + 1.707614701 * s,
  ];
}

const inGamut = (lin) => lin.every((v) => v >= -1e-4 && v <= 1 + 1e-4);

// OKLab -> hex, reducing chroma (keeping lightness and hue) until it fits sRGB.
export function oklabToHex([L, a, b]) {
  let lin = oklabToLinear([L, a, b]);
  if (!inGamut(lin)) {
    let lo = 0;
    let hi = 1;
    for (let i = 0; i < 24; i++) {
      const mid = (lo + hi) / 2;
      if (inGamut(oklabToLinear([L, a * mid, b * mid]))) lo = mid;
      else hi = mid;
    }
    lin = oklabToLinear([L, a * lo, b * lo]);
  }
  return rgbToHex(lin.map((v) => fromLinear(clamp(v))));
}

export function oklchToHex(L, C, h) {
  const rad = (h * Math.PI) / 180;
  return oklabToHex([L, C * Math.cos(rad), C * Math.sin(rad)]);
}

export function hexToOklch(hex) {
  const [L, a, b] = rgbToOklab(hexToRgb(hex));
  let h = (Math.atan2(b, a) * 180) / Math.PI;
  if (h < 0) h += 360;
  return { L, C: Math.hypot(a, b), h };
}

export function hueDistance(h1, h2) {
  const d = Math.abs(h1 - h2) % 360;
  return d > 180 ? 360 - d : d;
}

export function relLuminance(hex) {
  const [r, g, b] = hexToRgb(hex).map(toLinear);
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

export function contrast(a, b) {
  const [hi, lo] = [relLuminance(a), relLuminance(b)].sort((x, y) => y - x);
  return (hi + 0.05) / (lo + 0.05);
}

// Tint strengths are OKLab chroma added in the accent's hue direction.
export const STRENGTHS = { subtle: 0.022, medium: 0.036, bold: 0.055 };

// Shift a background toward an accent hue while keeping its lightness, so text contrast
// stays what the theme designed. The theme's own color cast is damped so the accent reads.
export function tint(bgHex, accentHex, strength = 'medium') {
  const k = typeof strength === 'number' ? strength : STRENGTHS[strength] ?? STRENGTHS.medium;
  const [L, a, b] = rgbToOklab(hexToRgb(bgHex));
  const { h, C } = hexToOklch(accentHex);
  if (C < 0.02) return normHex(bgHex); // neutral accent: leave the background alone
  const rad = (h * Math.PI) / 180;
  const damp = 0.55;
  return oklabToHex([L, a * damp + k * Math.cos(rad), b * damp + k * Math.sin(rad)]);
}

// Nudge a color's lightness (hue and chroma kept) until it reaches `min` contrast against
// `bgHex`: darker on light backgrounds, lighter on dark ones. Used for cursors and dots so a
// theme's pale yellow never disappears on a light background (WCAG 1.4.11 asks 3:1 for UI).
export function ensureContrast(fgHex, bgHex, min = 3) {
  if (contrast(fgHex, bgHex) >= min) return normHex(fgHex);
  const { L, C, h } = hexToOklch(fgHex);
  const dir = hexToOklch(bgHex).L > 0.6 ? -1 : 1;
  for (let i = 1; i <= 50; i++) {
    const hex = oklchToHex(clamp(L + dir * i * 0.02), C, h);
    if (contrast(hex, bgHex) >= min) return hex;
  }
  return dir > 0 ? '#ffffff' : '#000000';
}

export function rating(ratio) {
  return ratio >= 7 ? 'AAA' : ratio >= 4.5 ? 'AA' : ratio >= 3 ? 'AA large' : 'fail';
}

// Mix two colors in OKLab (t=0 -> a, t=1 -> b).
export function mix(aHex, bHex, t) {
  const a = rgbToOklab(hexToRgb(aHex));
  const b = rgbToOklab(hexToRgb(bHex));
  return oklabToHex(a.map((v, i) => v + (b[i] - v) * t));
}

// Emoji markers: the only way to put color into Terminal.app / Ghostty tab titles.
const MARKER_SETS = {
  circle: { red: '🔴', orange: '🟠', brown: '🟤', yellow: '🟡', green: '🟢', blue: '🔵', purple: '🟣', pink: '🟣', teal: '🔵', light: '⚪', dark: '⚫' },
  square: { red: '🟥', orange: '🟧', brown: '🟫', yellow: '🟨', green: '🟩', blue: '🟦', purple: '🟪', pink: '🟪', teal: '🟦', light: '⬜', dark: '⬛' },
  heart: { red: '❤️', orange: '🧡', brown: '🤎', yellow: '💛', green: '💚', blue: '💙', purple: '💜', pink: '🩷', teal: '🩵', light: '🤍', dark: '🩶' },
};

export const MARKER_STYLES = ['circle', 'square', 'heart', 'none'];

// Name the hue family of a color (used for markers and for human-readable labels).
export function hueFamily(hex) {
  const { L, C, h } = hexToOklch(hex);
  if (C < 0.035) return L > 0.6 ? 'light' : 'dark';
  if (h >= 345 || h < 12) return h >= 345 && L > 0.72 ? 'pink' : 'red';
  if (h < 35) return 'red';
  if (h < 75) return L < 0.62 && C < 0.13 ? 'brown' : 'orange';
  if (h < 118) return 'yellow';
  if (h < 178) return 'green';
  if (h < 215) return 'teal';
  if (h < 282) return 'blue';
  if (h < 330) return 'purple';
  return 'pink';
}

export function markerFor(hex, style = 'circle') {
  const set = MARKER_SETS[style];
  if (!set || !hex) return '';
  return set[hueFamily(hex)] || '';
}

// 24-bit ANSI helpers for previews in the CLI.
export function ansiFg(hex) {
  const [r, g, b] = hexToRgb(hex).map((v) => Math.round(v * 255));
  return `\x1b[38;2;${r};${g};${b}m`;
}
export function ansiBg(hex) {
  const [r, g, b] = hexToRgb(hex).map((v) => Math.round(v * 255));
  return `\x1b[48;2;${r};${g};${b}m`;
}
