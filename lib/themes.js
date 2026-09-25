// Theme presets. Every theme maps the same accent names (red … pink) onto its own palette,
// so "/tab color teal" means the same thing in every theme. A session's look is the theme's
// background tinted toward its accent (lightness kept => text contrast kept), the theme's
// foreground, and the accent as cursor / tab color / title marker.
import { oklchToHex, tint, markerFor, isHex, normHex, hexToOklch, hueDistance, hueFamily, ensureContrast, contrast, rating, STRENGTHS } from './color.js';

export const ACCENT_KEYS = ['red', 'orange', 'yellow', 'green', 'teal', 'blue', 'purple', 'pink'];

// Calm hues first; ordering is only a tie-breaker for auto-assignment.
export const AUTO_ORDER = ['blue', 'green', 'purple', 'orange', 'teal', 'pink', 'yellow', 'red'];

// Menu / gallery sections, in display order.
export const GROUPS = {
  signature: 'Signature',
  calm: 'Calm',
  classic: 'Classic',
  vivid: 'Vivid',
  light: 'Light',
  contrast: 'High contrast',
};

const HUES = { red: 22, orange: 55, yellow: 95, green: 148, teal: 192, blue: 248, purple: 302, pink: 345 };
const designed = (L, C) => Object.fromEntries(Object.entries(HUES).map(([k, h]) => [k, oklchToHex(L, C, h)]));

const T = (id, name, mode, bg, fg, accents, extra = {}) => ({ id, name, mode, bg, fg, accents, group: 'classic', ...extra });
const calm = (extra = {}) => ({ group: 'calm', calm: true, ...extra });
const light = (extra = {}) => ({ group: 'light', ...extra });

// Palettes follow each theme's published colors; accents are named by hue so every theme
// answers to the same /tab color words.
export const THEMES = [
  // Signature — designed in OKLCH for tabby.
  T('tabby', 'Tabby Dusk', 'dark', oklchToHex(0.235, 0.01, 262), oklchToHex(0.87, 0.008, 262), designed(0.76, 0.11), { group: 'signature', calm: true, blurb: 'Soft slate, pastel accents (default)' }),
  T('midnight', 'Midnight', 'dark', oklchToHex(0.175, 0.008, 265), oklchToHex(0.8, 0.008, 265), designed(0.7, 0.095), { group: 'signature', calm: true, blurb: 'Deep and dim, for late nights' }),
  T('ember', 'Ember', 'dark', oklchToHex(0.225, 0.014, 55), oklchToHex(0.88, 0.02, 80), designed(0.76, 0.105), { group: 'signature', calm: true, blurb: 'Warm charcoal, candlelit accents' }),
  T('paper', 'Paper', 'light', oklchToHex(0.965, 0.012, 85), oklchToHex(0.33, 0.02, 60), designed(0.56, 0.12), { group: 'signature', calm: true, blurb: 'Warm off-white, no glare' }),
  T('mist', 'Mist', 'light', oklchToHex(0.935, 0.008, 250), oklchToHex(0.31, 0.02, 255), designed(0.54, 0.12), { group: 'signature', calm: true, blurb: 'Cool morning gray, soft ink' }),

  // Calm — low glare, muted accents.
  T('nord', 'Nord', 'dark', '#2e3440', '#d8dee9', { red: '#bf616a', orange: '#d08770', yellow: '#ebcb8b', green: '#a3be8c', teal: '#8fbcbb', blue: '#81a1c1', purple: '#b48ead' }, calm()),
  T('everforest', 'Everforest', 'dark', '#2d353b', '#d3c6aa', { red: '#e67e80', orange: '#e69875', yellow: '#dbbc7f', green: '#a7c080', teal: '#83c092', blue: '#7fbbb3', purple: '#d699b6' }, calm()),
  T('kanagawa', 'Kanagawa', 'dark', '#1f1f28', '#dcd7ba', { red: '#e46876', orange: '#ffa066', yellow: '#e6c384', green: '#98bb6c', teal: '#7aa89f', blue: '#7e9cd8', purple: '#957fb8', pink: '#d27e99' }, calm()),
  T('kanagawa-dragon', 'Kanagawa Dragon', 'dark', '#181616', '#c5c9c5', { red: '#c4746e', orange: '#b6927b', yellow: '#c4b28a', green: '#8a9a7b', teal: '#8ea4a2', blue: '#8ba4b0', purple: '#8992a7', pink: '#a292a3' }, calm()),
  T('rose-pine', 'Rosé Pine', 'dark', '#191724', '#e0def4', { red: '#eb6f92', yellow: '#f6c177', teal: '#9ccfd8', blue: '#31748f', purple: '#c4a7e7', pink: '#ebbcba' }, calm()),
  T('rose-pine-moon', 'Rosé Pine Moon', 'dark', '#232136', '#e0def4', { red: '#eb6f92', yellow: '#f6c177', teal: '#9ccfd8', blue: '#3e8fb0', purple: '#c4a7e7', pink: '#ea9a97' }, calm()),
  T('catppuccin-frappe', 'Catppuccin Frappé', 'dark', '#303446', '#c6d0f5', { red: '#e78284', orange: '#ef9f76', yellow: '#e5c890', green: '#a6d189', teal: '#81c8be', blue: '#8caaee', purple: '#ca9ee6', pink: '#f4b8e4' }, calm()),
  T('catppuccin-macchiato', 'Catppuccin Macchiato', 'dark', '#24273a', '#cad3f5', { red: '#ed8796', orange: '#f5a97f', yellow: '#eed49f', green: '#a6da95', teal: '#8bd5ca', blue: '#8aadf4', purple: '#c6a0f6', pink: '#f5bde6' }, calm()),
  T('tomorrow-night', 'Tomorrow Night', 'dark', '#1d1f21', '#c5c8c6', { red: '#cc6666', orange: '#de935f', yellow: '#f0c674', green: '#b5bd68', teal: '#8abeb7', blue: '#81a2be', purple: '#b294bb' }, calm()),
  T('zenburn', 'Zenburn', 'dark', '#3f3f3f', '#dcdccc', { red: '#cc9393', orange: '#dfaf8f', yellow: '#f0dfaf', green: '#7f9f7f', teal: '#93e0e3', blue: '#8cd0d3', purple: '#dc8cc3' }, calm({ blurb: 'Low contrast by design' })),
  T('github-dimmed', 'GitHub Dimmed', 'dark', '#22272e', '#adbac7', { red: '#f47067', orange: '#f69d50', yellow: '#c69026', green: '#57ab5a', teal: '#39c5cf', blue: '#539bf5', purple: '#b083f0', pink: '#e275ad' }, calm()),
  T('gruvbox-material', 'Gruvbox Material', 'dark', '#292828', '#d4be98', { red: '#ea6962', orange: '#e78a4e', yellow: '#d8a657', green: '#a9b665', teal: '#89b482', blue: '#7daea3', purple: '#d3869b' }, calm()),
  T('flexoki', 'Flexoki', 'dark', '#100f0f', '#cecdc3', { red: '#d14d41', orange: '#da702c', yellow: '#d0a215', green: '#879a39', teal: '#3aa99f', blue: '#4385be', purple: '#8b7ec8', pink: '#ce5d97' }, calm({ blurb: 'Inky, made for reading' })),
  T('iceberg', 'Iceberg', 'dark', '#161821', '#c6c8d1', { red: '#e27878', orange: '#e2a478', green: '#b4be82', teal: '#89b8c2', blue: '#84a0c6', purple: '#a093c7' }, calm()),
  T('selenized', 'Selenized', 'dark', '#103c48', '#adbcbc', { red: '#fa5750', orange: '#ed8649', yellow: '#dbb32d', green: '#75b938', teal: '#41c7b9', blue: '#4695f7', purple: '#af88eb', pink: '#f275be' }, calm({ blurb: 'Solarized, re-tuned for contrast' })),
  T('nightfox', 'Nightfox', 'dark', '#192330', '#cdcecf', { red: '#c94f6d', orange: '#f4a261', yellow: '#dbc074', green: '#81b29a', teal: '#63cdcf', blue: '#719cd6', purple: '#9d79d6', pink: '#d67ad2' }, calm()),
  T('oceanic-next', 'Oceanic Next', 'dark', '#1b2b34', '#cdd3de', { red: '#ec5f67', orange: '#f99157', yellow: '#fac863', green: '#99c794', teal: '#5fb3b3', blue: '#6699cc', purple: '#c594c5' }, calm()),

  // Classic — the popular editor themes.
  T('catppuccin-mocha', 'Catppuccin Mocha', 'dark', '#1e1e2e', '#cdd6f4', { red: '#f38ba8', orange: '#fab387', yellow: '#f9e2af', green: '#a6e3a1', teal: '#94e2d5', blue: '#89b4fa', purple: '#cba6f7', pink: '#f5c2e7' }),
  T('tokyo-night', 'Tokyo Night', 'dark', '#1a1b26', '#c0caf5', { red: '#f7768e', orange: '#ff9e64', yellow: '#e0af68', green: '#9ece6a', teal: '#73daca', blue: '#7aa2f7', purple: '#bb9af7' }),
  T('tokyo-night-storm', 'Tokyo Night Storm', 'dark', '#24283b', '#c0caf5', { red: '#f7768e', orange: '#ff9e64', yellow: '#e0af68', green: '#9ece6a', teal: '#73daca', blue: '#7aa2f7', purple: '#bb9af7' }),
  T('gruvbox', 'Gruvbox', 'dark', '#282828', '#ebdbb2', { red: '#fb4934', orange: '#fe8019', yellow: '#fabd2f', green: '#b8bb26', teal: '#8ec07c', blue: '#83a598', purple: '#d3869b' }),
  T('one-dark', 'One Dark', 'dark', '#282c34', '#abb2bf', { red: '#e06c75', orange: '#d19a66', yellow: '#e5c07b', green: '#98c379', teal: '#56b6c2', blue: '#61afef', purple: '#c678dd' }),
  T('palenight', 'Palenight', 'dark', '#292d3e', '#a6accd', { red: '#f07178', orange: '#f78c6c', yellow: '#ffcb6b', green: '#c3e88d', teal: '#89ddff', blue: '#82aaff', purple: '#c792ea' }),
  T('ayu-mirage', 'Ayu Mirage', 'dark', '#1f2430', '#cbccc6', { red: '#f28779', orange: '#ffa759', yellow: '#ffd580', green: '#bae67e', teal: '#95e6cb', blue: '#73d0ff', purple: '#d4bfff' }),
  T('night-owl', 'Night Owl', 'dark', '#011627', '#d6deeb', { red: '#ef5350', orange: '#f78c6c', yellow: '#ffeb95', green: '#addb67', teal: '#7fdbca', blue: '#82aaff', purple: '#c792ea' }),
  T('solarized-dark', 'Solarized Dark', 'dark', '#002b36', '#93a1a1', { red: '#dc322f', orange: '#cb4b16', yellow: '#b58900', green: '#859900', teal: '#2aa198', blue: '#268bd2', purple: '#6c71c4', pink: '#d33682' }),
  T('sonokai', 'Sonokai', 'dark', '#2c2e34', '#e2e2e3', { red: '#fc5d7c', orange: '#f39660', yellow: '#e7c664', green: '#9ed072', blue: '#76cce0', purple: '#b39df3' }),
  T('oxocarbon', 'Oxocarbon', 'dark', '#161616', '#dde1e6', { red: '#ee5396', green: '#42be65', teal: '#08bdba', blue: '#78a9ff', purple: '#be95ff', pink: '#ff7eb6' }),
  T('poimandres', 'Poimandres', 'dark', '#1b1e28', '#a6accd', { red: '#d0679d', yellow: '#fffac2', green: '#5de4c7', teal: '#89ddff', blue: '#add7ff', pink: '#fcc5e9' }),
  T('horizon', 'Horizon', 'dark', '#1c1e26', '#d5d8da', { red: '#e95678', orange: '#fab795', green: '#29d398', teal: '#59e1e3', blue: '#26bbd9', purple: '#b877db', pink: '#ee64ac' }),
  T('moonfly', 'Moonfly', 'dark', '#080808', '#c6c6c6', { red: '#ff5d5d', orange: '#de935f', yellow: '#e3c78a', green: '#8cc85f', teal: '#79dac8', blue: '#80a0ff', purple: '#ae81ff', pink: '#cf87e8' }),
  T('jellybeans', 'Jellybeans', 'dark', '#151515', '#e8e8d3', { red: '#cf6a4c', orange: '#ffb964', yellow: '#fad07a', green: '#99ad6a', teal: '#8fbfdc', blue: '#8197bf', purple: '#c6b6ee' }),
  T('selenized-black', 'Selenized Black', 'dark', '#181818', '#b9b9b9', { red: '#ed4a46', orange: '#e67f43', yellow: '#dbb32d', green: '#70b433', teal: '#3fc5b7', blue: '#368aeb', purple: '#a580e2', pink: '#eb6eb7' }),

  // Vivid — loud on purpose.
  T('dracula', 'Dracula', 'dark', '#282a36', '#f8f8f2', { red: '#ff5555', orange: '#ffb86c', yellow: '#f1fa8c', green: '#50fa7b', teal: '#8be9fd', purple: '#bd93f9', pink: '#ff79c6' }, { group: 'vivid' }),
  T('monokai-pro', 'Monokai Pro', 'dark', '#2d2a2e', '#fcfcfa', { red: '#ff6188', orange: '#fc9867', yellow: '#ffd866', green: '#a9dc76', teal: '#78dce8', purple: '#ab9df2' }, { group: 'vivid' }),
  T('synthwave-84', "Synthwave '84", 'dark', '#262335', '#f4eee4', { red: '#fe4450', orange: '#f97e72', yellow: '#fede5d', green: '#72f1b8', teal: '#36f9f6', purple: '#b893ce', pink: '#ff7edb' }, { group: 'vivid' }),

  // Light.
  T('catppuccin-latte', 'Catppuccin Latte', 'light', '#eff1f5', '#4c4f69', { red: '#d20f39', orange: '#fe640b', yellow: '#df8e1d', green: '#40a02b', teal: '#179299', blue: '#1e66f5', purple: '#8839ef', pink: '#ea76cb' }, light()),
  T('rose-pine-dawn', 'Rosé Pine Dawn', 'light', '#faf4ed', '#575279', { red: '#b4637a', yellow: '#ea9d34', teal: '#56949f', blue: '#286983', purple: '#907aa9', pink: '#d7827e' }, light({ calm: true })),
  T('everforest-light', 'Everforest Light', 'light', '#fdf6e3', '#5c6a72', { red: '#f85552', orange: '#f57d26', yellow: '#dfa000', green: '#8da101', teal: '#35a77c', blue: '#3a94c5', purple: '#df69ba' }, light({ calm: true })),
  T('flexoki-light', 'Flexoki Light', 'light', '#fffcf0', '#100f0f', { red: '#af3029', orange: '#bc5215', yellow: '#ad8301', green: '#66800b', teal: '#24837b', blue: '#205ea6', purple: '#5e409d', pink: '#a02f6f' }, light({ calm: true })),
  T('kanagawa-lotus', 'Kanagawa Lotus', 'light', '#f2ecbc', '#545464', { red: '#c84053', orange: '#cc6d00', yellow: '#77713f', green: '#6f894e', teal: '#597b75', blue: '#4d699b', purple: '#624c83', pink: '#b35b79' }, light({ calm: true })),
  T('selenized-light', 'Selenized Light', 'light', '#fbf3db', '#53676d', { red: '#d2212d', orange: '#c25d1e', yellow: '#ad8900', green: '#489100', teal: '#009c8f', blue: '#0072d4', purple: '#8762c6', pink: '#ca4898' }, light()),
  T('solarized-light', 'Solarized Light', 'light', '#fdf6e3', '#586e75', { red: '#dc322f', orange: '#cb4b16', yellow: '#b58900', green: '#859900', teal: '#2aa198', blue: '#268bd2', purple: '#6c71c4', pink: '#d33682' }, light()),
  T('gruvbox-light', 'Gruvbox Light', 'light', '#fbf1c7', '#3c3836', { red: '#9d0006', orange: '#af3a03', yellow: '#b57614', green: '#79740e', teal: '#427b58', blue: '#076678', purple: '#8f3f71' }, light()),
  T('iceberg-light', 'Iceberg Light', 'light', '#e8e9ec', '#33374c', { red: '#cc517a', orange: '#c57339', green: '#668e3d', teal: '#3f83a6', blue: '#2d539e', purple: '#7759b4' }, light()),
  T('tokyo-night-day', 'Tokyo Night Day', 'light', '#e1e2e7', '#3760bf', { red: '#f52a65', orange: '#b15c00', yellow: '#8c6c3e', green: '#587539', teal: '#118c74', blue: '#2e7de9', purple: '#9854f1' }, light()),
  T('github-light', 'GitHub Light', 'light', '#ffffff', '#1f2328', { red: '#cf222e', orange: '#bc4c00', yellow: '#9a6700', green: '#1a7f37', teal: '#1b7c83', blue: '#0969da', purple: '#8250df', pink: '#bf3989' }, light()),
  T('one-light', 'One Light', 'light', '#fafafa', '#383a42', { red: '#e45649', orange: '#986801', yellow: '#c18401', green: '#50a14f', teal: '#0184bc', blue: '#4078f2', purple: '#a626a4' }, light()),
  T('tomorrow', 'Tomorrow', 'light', '#ffffff', '#4d4d4c', { red: '#c82829', orange: '#f5871f', yellow: '#eab700', green: '#718c00', teal: '#3e999f', blue: '#4271ae', purple: '#8959a8' }, light()),
  T('ayu-light', 'Ayu Light', 'light', '#fcfcfc', '#5c6166', { red: '#f07171', orange: '#fa8d3e', yellow: '#f2ae49', green: '#86b300', teal: '#4cbf99', blue: '#399ee6', purple: '#a37acc' }, light()),

  // High contrast — WCAG AAA everywhere (Modus themes target 7:1 for every color).
  T('modus-vivendi', 'Modus Vivendi', 'dark', '#000000', '#ffffff', { red: '#ff5f59', yellow: '#d0bc00', green: '#44bc44', teal: '#00d3d0', blue: '#2fafff', purple: '#b6a0ff', pink: '#feacd0' }, { group: 'contrast', blurb: 'Maximum legibility' }),
  T('modus-operandi', 'Modus Operandi', 'light', '#ffffff', '#000000', { red: '#a60000', yellow: '#6f5500', green: '#006800', teal: '#005e8b', blue: '#0031a9', purple: '#531ab6', pink: '#721045' }, { group: 'contrast', blurb: 'Maximum legibility' }),
];

// Themes rotated through when config.auto === 'themes' (each session gets its own theme).
export const VARIETY_POOL = ['tabby', 'nord', 'everforest', 'kanagawa', 'rose-pine', 'catppuccin-frappe', 'tomorrow-night', 'github-dimmed', 'gruvbox-material', 'nightfox', 'ember', 'oceanic-next'];

const ALIASES = {
  default: 'tabby', dusk: 'tabby', mocha: 'catppuccin-mocha', frappe: 'catppuccin-frappe', 'frappé': 'catppuccin-frappe',
  macchiato: 'catppuccin-macchiato', latte: 'catppuccin-latte', catppuccin: 'catppuccin-mocha', tokyo: 'tokyo-night',
  tokyonight: 'tokyo-night', storm: 'tokyo-night-storm', rosepine: 'rose-pine', 'rosé-pine': 'rose-pine', moon: 'rose-pine-moon',
  dawn: 'rose-pine-dawn', dragon: 'kanagawa-dragon', lotus: 'kanagawa-lotus', solarized: 'solarized-dark', onedark: 'one-dark',
  one: 'one-dark', monokai: 'monokai-pro', ayu: 'ayu-mirage', github: 'github-dimmed', nightowl: 'night-owl', owl: 'night-owl',
  light: 'paper', dark: 'tabby', synthwave: 'synthwave-84', modus: 'modus-vivendi',
  vivendi: 'modus-vivendi', operandi: 'modus-operandi', material: 'gruvbox-material', fox: 'nightfox',
};

const byId = new Map(THEMES.map((t) => [t.id, t]));
const slug = (s) => String(s || '').trim().toLowerCase().replace(/[\s_]+/g, '-').replace(/'/g, '');

export function findTheme(query) {
  const q = slug(query);
  if (!q) return null;
  if (byId.has(q)) return byId.get(q);
  if (ALIASES[q] || ALIASES[q.replace(/-/g, '')]) return byId.get(ALIASES[q] || ALIASES[q.replace(/-/g, '')]);
  // Prefer the shortest match: "gruv" means Gruvbox, not Gruvbox Material.
  const shortest = (list) => list.sort((a, b) => a.id.length - b.id.length)[0];
  return (
    shortest(THEMES.filter((t) => t.id.startsWith(q) || slug(t.name).startsWith(q))) ||
    shortest(THEMES.filter((t) => t.id.includes(q) || slug(t.name).includes(q))) ||
    null
  );
}

// Exact id or alias only — used for "/tab <word>" shortcuts so names aren't mistaken for themes.
export function strictTheme(query) {
  const q = slug(query);
  return byId.get(q) || byId.get(ALIASES[q] || ALIASES[q.replace(/-/g, '')]) || null;
}

export function getTheme(id) {
  return findTheme(id) || byId.get('tabby');
}

export const COLOR_ALIASES = {
  cyan: 'teal', aqua: 'teal', mint: 'teal', sky: 'blue', navy: 'blue', indigo: 'blue', violet: 'purple',
  mauve: 'purple', lavender: 'purple', magenta: 'pink', rose: 'pink', coral: 'orange', peach: 'orange',
  amber: 'yellow', gold: 'yellow', sand: 'yellow', sage: 'green', lime: 'green', olive: 'green', crimson: 'red', wine: 'red',
};

// Resolve a user color word ("teal", "cyan", "#88c0d0") to an accent key or hex.
export function parseColor(word) {
  const w = slug(word);
  if (!w) return null;
  if (isHex(w)) return normHex(w);
  if (ACCENT_KEYS.includes(w)) return w;
  if (COLOR_ALIASES[w]) return COLOR_ALIASES[w];
  const k = ACCENT_KEYS.find((a) => a.startsWith(w));
  return k || null;
}

// Hex for an accent key in a theme; falls back to the theme accent nearest in hue.
export function accentHex(theme, key) {
  if (!key) return null;
  if (isHex(key)) return normHex(key);
  if (theme.accents[key]) return theme.accents[key];
  const target = HUES[key];
  if (target === undefined) return null;
  let best = null;
  let bestD = Infinity;
  for (const hex of Object.values(theme.accents)) {
    const d = hueDistance(hexToOklch(hex).h, target);
    if (d < bestD) [best, bestD] = [hex, d];
  }
  return best;
}

// A dot/label color that stays visible on the island's black background.
export const onBlack = (hex) => ensureContrast(hex, '#000000', 4);

// The concrete colors applied to a terminal tab.
export function resolveLook({ theme: themeId, accentKey }, cfg = {}) {
  const theme = getTheme(themeId || cfg.theme);
  const key = accentKey || AUTO_ORDER.find((k) => theme.accents[k]) || Object.keys(theme.accents)[0];
  const accent = accentHex(theme, key);
  const strength = cfg.strength || 'medium';
  let bg = tint(theme.bg, accent, strength);
  // Tints keep lightness, so contrast barely moves — but never let a tint make text harder
  // to read than the theme itself (or AA, whichever is lower): shrink the tint instead.
  const floor = Math.min(4.5, contrast(theme.fg, theme.bg));
  for (const k of [0.75, 0.5, 0.25, 0]) {
    if (contrast(theme.fg, bg) >= floor) break;
    bg = tint(theme.bg, accent, (STRENGTHS[strength] ?? STRENGTHS.medium) * k);
  }
  return {
    theme: theme.id,
    themeName: theme.name,
    accentKey: key,
    accent,
    family: hueFamily(accent),
    bg,
    fg: theme.fg,
    cursor: ensureContrast(accent, bg, 3),
    dot: onBlack(accent),
    marker: markerFor(accent, cfg.marker || 'circle'),
  };
}

// Contrast facts for one theme (docs, site gallery, tests).
export function audit(theme) {
  const text = contrast(theme.fg, theme.bg);
  const accents = Object.entries(theme.accents).map(([key, hex]) => ({ key, hex, raw: contrast(hex, theme.bg) }));
  const minAccent = Math.min(...accents.map((a) => a.raw));
  const tintedText = Math.min(...ACCENT_KEYS.map((k) => {
    const look = resolveLook({ theme: theme.id, accentKey: k }, { strength: 'bold' });
    return contrast(look.fg, look.bg);
  }));
  return {
    text: +text.toFixed(2),
    rating: rating(text),
    tintedText: +tintedText.toFixed(2),
    minAccent: +minAccent.toFixed(2),
    lowAccents: accents.filter((a) => a.raw < 3).map((a) => a.key),
    harsh: text > 15,
  };
}

// Serialized for the macOS island and the website (neither duplicates theme data).
export function themesExport(defaultTheme = 'tabby') {
  return {
    default: defaultTheme,
    accentKeys: ACCENT_KEYS,
    groups: GROUPS,
    themes: THEMES.map((theme) => ({ theme, ...theme })).map(({ theme, id, name, mode, bg, fg, accents, calm, blurb, group }) => ({
      id,
      name,
      mode,
      group,
      bg,
      fg,
      accents,
      dots: Object.fromEntries(Object.entries(accents).map(([k, hex]) => [k, onBlack(hex)])),
      tints: Object.fromEntries(ACCENT_KEYS.map((k) => [k, tint(bg, accentHex({ accents }, k))])),
      calm: !!calm,
      blurb: blurb || '',
      contrast: audit(theme),
    })),
  };
}
