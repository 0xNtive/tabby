/* tabby — site behavior. Vanilla JS, no dependencies. */
(() => {
  'use strict';

  const $ = (sel, root = document) => root.querySelector(sel);
  const $$ = (sel, root = document) => Array.from(root.querySelectorAll(sel));
  const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);

  const reduceQuery = matchMedia('(prefers-reduced-motion: reduce)');
  let reduce = reduceQuery.matches;
  reduceQuery.addEventListener?.('change', (e) => { reduce = e.matches; });

  /* ------------------------------------------------------------------ */
  /* Demo data                                                            */
  /* ------------------------------------------------------------------ */

  const SESSIONS = [
    { id: 'stripe', color: 'green', status: 'idle', title: 'Stripe Webhook Retries', project: 'api', model: 'Opus 5.5', ago: '2m ago', pct: 58, tokens: '116k / 200k', cost: '$1.12',
      summary: 'Failed Stripe webhooks now retry with backoff and an idempotency key. Tests pass.',
      prompt: 'stripe webhooks fail silently when the db is slow. retry them with backoff' },
    { id: 'dark', color: 'blue', status: 'busy', title: 'Dark Mode Settings', project: 'web', model: 'Opus 5.5', ago: 'now', pct: 31, tokens: '62k / 200k', cost: '$0.42',
      summary: 'Adding a theme toggle to the settings page that follows the system setting and remembers your choice.',
      prompt: 'add a dark mode toggle to settings that follows the system theme' },
    { id: 'auth', color: 'purple', status: 'waiting', title: 'Flaky Auth Tests', project: 'auth', model: 'Opus 5.5', ago: '1m ago', pct: 72, tokens: '144k / 200k', cost: '$0.88',
      summary: 'Two tests shared one refresh token and raced in parallel runs. Waiting for permission to rerun the suite.',
      prompt: 'the auth tests fail about 1 in 10 runs in ci. find out why' },
    { id: 'notes', color: 'orange', status: 'idle', title: 'Release Notes', project: 'tabby', model: 'Opus 5.5', ago: '14m ago', pct: 12, tokens: '24k / 200k', cost: '$0.09',
      summary: 'Drafted notes for 0.2 from the changelog: themes, island modes and window tiling.',
      prompt: 'draft release notes for 0.2 from the changelog' },
  ];
  const byId = Object.fromEntries(SESSIONS.map((s) => [s.id, s]));
  // The island lists sessions by urgency: needs you, then working, then your turn.
  const ISLAND_ORDER = ['auth', 'dark', 'stripe', 'notes'];
  const STATUS = { busy: 'Working', idle: 'Your turn', waiting: 'Needs you' };
  const GLYPH = {
    busy: '<svg class="st st--busy" aria-hidden="true"><use href="#i-half"/></svg>',
    idle: '<svg class="st st--idle" aria-hidden="true"><use href="#i-star"/></svg>',
    waiting: '<svg class="st" aria-hidden="true"><use href="#i-bell"/></svg>',
  };
  const CAT = '<svg class="ifoot__cat" viewBox="0 0 64 64" aria-hidden="true"><path fill="currentColor" d="M10 24 13.5 8.6Q14 6.5 15.8 7.7L26.5 15.4Q32 13.7 37.5 15.4L48.2 7.7Q50 6.5 50.5 8.6L54 24Q57 30 57 37.5 57 57.5 32 57.5 7 57.5 7 37.5 7 30 10 24Z"/><rect x="22.4" y="19.2" width="4.2" height="10" rx="2.1" fill="#77b7f4" transform="rotate(-14 24.5 24.2)"/><rect x="29.9" y="17.6" width="4.2" height="11.4" rx="2.1" fill="#7fc489"/><rect x="37.4" y="19.2" width="4.2" height="10" rx="2.1" fill="#e79e6b" transform="rotate(14 39.5 24.2)"/><ellipse class="cat-eye" cx="23.2" cy="38.4" rx="3.6" ry="4" fill="#000"/><ellipse class="cat-eye" cx="40.8" cy="38.4" rx="3.6" ry="4" fill="#000"/><path fill="#e394c1" d="M29.6 43.4h4.8L32 46.2Z"/></svg>';

  /* ------------------------------------------------------------------ */
  /* Tiny store                                                           */
  /* ------------------------------------------------------------------ */

  const state = { active: 'dark', themeId: 'tabby', themeMap: null, groups: null };
  const subs = {};
  const on = (evt, fn) => (subs[evt] ||= []).push(fn);
  const emit = (evt, detail) => (subs[evt] || []).forEach((fn) => fn(detail));
  function setActive(id) {
    if (!byId[id] || state.active === id) return;
    state.active = id;
    emit('active');
  }

  const liveEl = $('.toast');
  function announce(msg) {
    if (!liveEl) return;
    liveEl.textContent = '';
    requestAnimationFrame(() => { liveEl.textContent = msg; });
  }

  /* ------------------------------------------------------------------ */
  /* Theme math (mirrors lib/themes.js: missing accents fall back by hue) */
  /* ------------------------------------------------------------------ */

  const KEYS = ['red', 'orange', 'yellow', 'green', 'teal', 'blue', 'purple', 'pink'];
  const HUES = { red: 22, orange: 55, yellow: 95, green: 148, teal: 192, blue: 248, purple: 302, pink: 345 };
  function oklchHue(hex) {
    const h = hex.replace('#', '');
    const lin = [0, 2, 4].map((i) => {
      const c = parseInt(h.slice(i, i + 2), 16) / 255;
      return c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4;
    });
    const [r, g, b] = lin;
    const l = Math.cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b);
    const m = Math.cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b);
    const s = Math.cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b);
    const A = 1.9779984951 * l - 2.428592205 * m + 0.4505937099 * s;
    const B = 0.0259040371 * l + 0.7827717662 * m - 0.808675766 * s;
    const deg = (Math.atan2(B, A) * 180) / Math.PI;
    return deg < 0 ? deg + 360 : deg;
  }
  function pick(map, key) {
    if (map[key]) return map[key];
    let best = null;
    let bestD = Infinity;
    for (const hex of Object.values(map)) {
      const d0 = Math.abs(oklchHue(hex) - HUES[key]) % 360;
      const d = d0 > 180 ? 360 - d0 : d0;
      if (d < bestD) { bestD = d; best = hex; }
    }
    return best;
  }
  const ratio = (x) => String(Math.round(x * 10) / 10);

  function applyTheme(id) {
    const t = state.themeMap?.get(id);
    if (!t) return;
    state.themeId = id;
    const vars = { '--th-bg': t.bg, '--th-fg': t.fg };
    for (const k of KEYS) {
      vars[`--tint-${k}`] = t.tints[k];
      vars[`--acc-${k}`] = pick(t.accents, k);
      vars[`--dot-${k}`] = pick(t.dots, k);
    }
    for (const el of $$('[data-themed]')) {
      for (const [k, v] of Object.entries(vars)) el.style.setProperty(k, v);
      el.dataset.thMode = t.mode;
    }
    emit('theme', t);
  }

  /* ------------------------------------------------------------------ */
  /* Hero terminal: tabs, screens, hover popover                          */
  /* ------------------------------------------------------------------ */

  function initTerminal() {
    const term = $('.term--hero');
    if (!term) return;
    const stage = $('#stage');
    const tabs = $$('.ttab[role="tab"]', term);
    const panel = $('#tpanel', term);
    const screens = $$('.scr', panel);
    const pop = $('#tpop', term);

    function render() {
      const s = byId[state.active];
      for (const t of tabs) {
        const onTab = t.dataset.session === s.id;
        t.setAttribute('aria-selected', String(onTab));
        t.tabIndex = onTab ? 0 : -1;
      }
      panel.setAttribute('aria-labelledby', `tt-${s.id}`);
      for (const sc of screens) {
        const show = sc.dataset.screen === s.id;
        if (show && sc.hidden) {
          sc.hidden = false;
          sc.classList.remove('is-entering');
          void sc.offsetWidth;
          sc.classList.add('is-entering');
        } else if (!show) {
          sc.hidden = true;
        }
      }
      term.dataset.active = s.id;
      term.style.setProperty('--body', `var(--tint-${s.color})`);
      stage.style.setProperty('--glow', `color-mix(in srgb, var(--acc-${s.color}) 26%, transparent)`);
    }
    on('active', render);

    for (const t of tabs) t.addEventListener('click', () => { hidePop(true); setActive(t.dataset.session); });
    $('[role="tablist"]', term).addEventListener('keydown', (e) => {
      const i = tabs.indexOf(document.activeElement);
      if (i < 0) return;
      const j = { ArrowRight: (i + 1) % tabs.length, ArrowLeft: (i - 1 + tabs.length) % tabs.length, Home: 0, End: tabs.length - 1 }[e.key];
      if (j === undefined) return;
      e.preventDefault();
      tabs[j].focus();
      setActive(tabs[j].dataset.session);
    });

    // Popover: a delay before the first one, then instant while you move across tabs.
    pop.hidden = false;
    let current = null;
    let showTimer = 0;
    let hideTimer = 0;
    let lastHidden = 0;
    function fill(s) {
      pop.innerHTML =
        `<div class="tpop__head"><i class="idot" data-color="${s.color}" data-status="${s.status}"></i>${esc(s.title)}</div>` +
        `<p class="tpop__meta">${esc(s.project)} · ${esc(s.model)} · ${esc(s.ago)}</p>` +
        `<p class="tpop__sum">${esc(s.summary)}</p>` +
        `<div class="ibar" data-color="${s.color}"><span class="ibar__track"><span class="ibar__fill${s.pct >= 70 ? ' is-warn' : ''}" style="width:${s.pct}%"></span></span><span class="ibar__pct">${s.pct}%</span></div>` +
        `<p class="tpop__st tpop__st--${s.status}">${STATUS[s.status]} · ${s.tokens} tokens · ${s.cost}</p>`;
    }
    function show(tab, instant) {
      clearTimeout(hideTimer);
      fill(byId[tab.dataset.session]);
      const tr = term.getBoundingClientRect();
      const r = tab.getBoundingClientRect();
      const w = pop.offsetWidth;
      const cx = r.left + r.width / 2 - tr.left;
      const left = Math.max(8, Math.min(tr.width - w - 8, cx - w / 2));
      pop.style.left = `${left}px`;
      pop.style.setProperty('--ox', `${cx - left}px`);
      pop.classList.toggle('is-instant', Boolean(instant) || reduce);
      pop.classList.add('is-on');
      if (current && current !== tab) current.removeAttribute('aria-describedby');
      current = tab;
      tab.setAttribute('aria-describedby', 'tpop');
    }
    function hidePop(instant) {
      clearTimeout(showTimer);
      if (!current) return;
      pop.classList.toggle('is-instant', Boolean(instant));
      pop.classList.remove('is-on');
      current.removeAttribute('aria-describedby');
      current = null;
      lastHidden = performance.now();
    }
    for (const t of tabs) {
      t.addEventListener('pointerenter', (e) => {
        if (e.pointerType !== 'mouse') return;
        clearTimeout(showTimer);
        clearTimeout(hideTimer);
        const warm = current || performance.now() - lastHidden < 450;
        if (warm) show(t, true);
        else showTimer = setTimeout(() => show(t, false), 380);
      });
      t.addEventListener('pointerleave', (e) => {
        if (e.pointerType !== 'mouse') return;
        clearTimeout(showTimer);
        hideTimer = setTimeout(() => hidePop(false), 90);
      });
      t.addEventListener('focus', () => { if (t.matches(':focus-visible')) show(t, true); });
      t.addEventListener('blur', () => hidePop(true));
    }
    term.addEventListener('keydown', (e) => { if (e.key === 'Escape') hidePop(true); });
  }

  /* ------------------------------------------------------------------ */
  /* Springs (Apple-style response / damping), one rAF loop for all       */
  /* ------------------------------------------------------------------ */

  class Spring {
    constructor(x) { this.x = x; this.v = 0; this.target = x; this.tune(0.4, 1); }
    tune(response, damping) {
      this.k = (2 * Math.PI / response) ** 2;
      this.c = (4 * Math.PI * damping) / response;
    }
    to(target, response, damping) { this.target = target; this.tune(response, damping); }
    snap(x) { this.x = this.target = x; this.v = 0; }
    step(dt) {
      const n = Math.max(1, Math.ceil(dt * 240));
      const h = dt / n;
      for (let i = 0; i < n; i++) {
        const a = -this.k * (this.x - this.target) - this.c * this.v;
        this.v += a * h;
        this.x += this.v * h;
      }
      if (Math.abs(this.v) < 2 && Math.abs(this.x - this.target) < 0.15) { this.snap(this.target); return true; }
      return false;
    }
  }
  const running = new Set();
  let rafId = 0;
  let lastT = 0;
  function frame(now) {
    const dt = Math.min(0.034, Math.max(0.001, (now - lastT) / 1000));
    lastT = now;
    for (const item of running) if (item.tick(dt)) running.delete(item);
    rafId = running.size ? requestAnimationFrame(frame) : 0;
  }
  function animate(item) {
    running.add(item);
    if (!rafId) { lastT = performance.now(); rafId = requestAnimationFrame(frame); }
  }

  /* ------------------------------------------------------------------ */
  /* Tabby Island                                                         */
  /* ------------------------------------------------------------------ */

  function islandBody() {
    const rows = ISLAND_ORDER.map((id) => {
      const s = byId[id];
      return `<li><button class="irow" type="button" data-session="${s.id}" aria-label="${esc(s.title)}, ${esc(s.project)}, ${STATUS[s.status].toLowerCase()}, ${s.pct}% context used. Jump to this tab.">` +
        `<i class="idot" data-color="${s.color}" data-status="${s.status}"></i>` +
        `<span class="irow__main">` +
        `<span class="irow__top"><span class="irow__title">${esc(s.title)}</span><span class="irow__glyph irow__glyph--${s.status}">${GLYPH[s.status]}</span></span>` +
        `<span class="irow__meta">${esc(s.project)} · ${esc(s.model)} · ${esc(s.ago)}</span>` +
        `<span class="ibar" data-color="${s.color}"><span class="ibar__track"><span class="ibar__fill${s.pct >= 70 ? ' is-warn' : ''}" style="width:${s.pct}%"></span></span><span class="ibar__pct">${s.pct}%</span></span>` +
        `<span class="irow__more"><span class="irow__sum">${esc(s.summary)}</span><span class="irow__prompt">“${esc(s.prompt)}”</span>` +
        `<span class="irow__st irow__st--${s.status}">${GLYPH[s.status]}${STATUS[s.status]} · ${s.tokens} tokens · ${s.cost}</span></span>` +
        `</span></button></li>`;
    }).join('');
    return `<div class="island__scroll"><ul class="irows">${rows}</ul></div>` +
      `<div class="ifoot"><span class="ifoot__count">${SESSIONS.length} sessions</span>${CAT}` +
      `<button class="ifoot__theme" type="button"><svg aria-hidden="true"><use href="#i-palette"/></svg><span>Theme · <span data-theme-name>Tabby Dusk</span></span></button></div>`;
  }

  class Island {
    constructor(root, { big = false } = {}) {
      this.root = root;
      this.big = big;
      this.shell = $('.island__shell', root);
      this.head = $('.island__head', root);
      this.body = $('.island__body', root);
      this.banner = $('.island__banner', root);
      this.screen = root.closest('.screen');
      this.mode = 'closed';
      this.by = null;
      this.hovering = false;
      this.body.innerHTML = islandBody();
      this.scroll = $('.island__scroll', this.body);
      this.measure();
      this.W = new Spring(this.dims.cw);
      this.H = new Spring(this.dims.ch);
      this.R = new Spring(this.dims.rc);
      this.apply();
      this.bind();
      new ResizeObserver(() => this.refit()).observe(this.body);
    }

    measure() {
      const cs = getComputedStyle(this.root);
      const px = (name) => parseFloat(cs.getPropertyValue(name)) || 0;
      const avail = this.screen.clientWidth - 16;
      this.dims = {
        ch: px('--ch'),
        cw: Math.min(px('--cw'), avail),
        xw: Math.min(px('--xw'), avail),
        rc: px('--rc'),
        rx: this.big ? 30 : 24,
        bw: Math.min(this.big ? 410 : 340, avail),
        bh: this.big ? 48 : 40,
      };
      this.body.style.width = `${this.dims.xw}px`;
      const foot = $('.ifoot', this.body);
      const maxRows = this.screen.clientHeight - this.dims.ch - (foot ? foot.offsetHeight : 0) - 24;
      this.scroll.style.setProperty('--maxh', `${Math.max(120, maxRows)}px`);
    }

    target() {
      const d = this.dims;
      if (this.mode === 'open') return [d.xw, d.ch + this.body.offsetHeight, d.rx];
      if (this.mode === 'banner') return [d.bw, d.bh, d.bh / 2.2];
      return [d.cw, d.ch, d.rc];
    }

    go(mode, { instant = false } = {}) {
      this.mode = mode;
      this.root.classList.toggle('is-open', mode === 'open');
      this.root.classList.toggle('is-banner', mode === 'banner');
      this.head.setAttribute('aria-expanded', String(mode === 'open'));
      const [w, h, r] = this.target();
      if (reduce || instant) {
        this.W.snap(w); this.H.snap(h); this.R.snap(r);
        running.delete(this);
        this.apply();
        return;
      }
      // Opening overshoots a little, like the real island; closing settles without bounce.
      const [resp, damp] = mode === 'open' ? [0.46, 0.74] : mode === 'banner' ? [0.5, 0.7] : [0.36, 0.92];
      this.W.to(w, resp, damp);
      this.H.to(h, resp, damp);
      this.R.to(r, resp, 1);
      animate(this);
    }

    tick(dt) {
      const a = this.W.step(dt);
      const b = this.H.step(dt);
      const c = this.R.step(dt);
      this.apply();
      return a && b && c;
    }

    apply() {
      const s = this.shell.style;
      s.width = `${Math.max(this.dims.cw * 0.9, this.W.x).toFixed(2)}px`;
      s.height = `${Math.max(this.dims.ch * 0.85, this.H.x).toFixed(2)}px`;
      const r = `${Math.max(4, this.R.x).toFixed(2)}px`;
      s.borderBottomLeftRadius = r;
      s.borderBottomRightRadius = r;
    }

    refit() {
      if (this.mode !== 'open') return;
      const [w, h, r] = this.target();
      if (reduce) { this.W.snap(w); this.H.snap(h); this.R.snap(r); this.apply(); return; }
      this.W.to(w, 0.42, 0.86);
      this.H.to(h, 0.42, 0.86);
      animate(this);
    }

    relayout() {
      this.measure();
      const [w, h, r] = this.target();
      this.W.snap(w); this.H.snap(h); this.R.snap(r);
      this.apply();
    }

    open(by) {
      clearTimeout(this.bannerEnd);
      this.by = by;
      if (this.mode !== 'open') this.go('open');
    }

    close() {
      if (this.mode === 'closed') return;
      this.by = null;
      this.go('closed');
    }

    bind() {
      const root = this.root;
      root.addEventListener('pointerenter', (e) => {
        if (e.pointerType !== 'mouse') return;
        this.hovering = true;
        clearTimeout(this.leaveTimer);
        if (this.mode !== 'open') this.enterTimer = setTimeout(() => this.open('hover'), 70);
      });
      root.addEventListener('pointerleave', (e) => {
        if (e.pointerType !== 'mouse') return;
        this.hovering = false;
        clearTimeout(this.enterTimer);
        if (this.mode === 'open' && this.by === 'hover') this.leaveTimer = setTimeout(() => this.close(), 260);
      });
      this.head.addEventListener('click', (e) => {
        const keyboard = e.detail === 0;
        if (this.mode === 'open') {
          // A click while hover has it open pins it; otherwise the click closes it.
          if (this.by === 'hover' && !keyboard) { this.by = 'click'; return; }
          this.close();
          return;
        }
        this.open(keyboard ? 'key' : 'click');
      });
      root.addEventListener('keydown', (e) => {
        if (e.key === 'Escape' && this.mode === 'open') {
          e.stopPropagation();
          this.close();
          this.head.focus();
        }
        if ((e.key === 'ArrowDown' || e.key === 'ArrowUp') && this.mode === 'open') {
          const rows = $$('.irow', this.body);
          const i = rows.indexOf(document.activeElement);
          const j = e.key === 'ArrowDown' ? (i + 1) % rows.length : (i <= 0 ? rows.length - 1 : i - 1);
          rows[j]?.focus();
          e.preventDefault();
        }
      });
      this.head.addEventListener('focus', () => {
        if (this.mode === 'banner') { clearTimeout(this.bannerEnd); this.go('closed'); }
      });
      root.addEventListener('focusout', () => {
        setTimeout(() => {
          if (this.mode === 'open' && !root.contains(document.activeElement) && this.by !== 'hover') this.close();
        }, 0);
      });
      document.addEventListener('pointerdown', (e) => {
        if (this.mode === 'open' && !root.contains(e.target) && this.by !== 'hover') this.close();
      });
      this.body.addEventListener('click', (e) => {
        const row = e.target.closest('.irow');
        if (row) {
          const s = byId[row.dataset.session];
          setActive(s.id);
          const fromKeyboard = e.detail === 0;
          this.close();
          if (fromKeyboard) this.head.focus();
          if (this.big) {
            announce(`Jumped to ${s.title}.`);
            if (!fromKeyboard) {
              setTimeout(() => this.flash({ kind: 'jump', color: s.color, html: `Jumped to <b>${esc(s.title)}</b>` }, { force: true }), reduce ? 0 : 380);
            }
          }
          return;
        }
        if (e.target.closest('.ifoot__theme')) {
          this.close();
          $('#themes')?.scrollIntoView({ behavior: reduce ? 'auto' : 'smooth' });
          setTimeout(() => $('.tcard[aria-pressed="true"]')?.focus({ preventScroll: true }), reduce ? 0 : 700);
        }
      });
    }

    flash({ kind, html, color }, { force = false } = {}) {
      if (!this.banner || this.mode === 'open' || this.hovering) return;
      // Never cover the head while it has keyboard focus (the ring would vanish under the banner).
      if (!force && this.root.contains(document.activeElement)) return;
      const icon = kind === 'ok'
        ? '<span class="ban__i ban__i--ok"><svg><use href="#i-check"/></svg></span>'
        : kind === 'bell'
          ? '<span class="ban__i ban__i--bell"><svg><use href="#i-bell"/></svg></span>'
          : `<span class="ban__i"><i class="idot" data-color="${color}" data-status="idle" style="width:.7em;height:.7em"></i></span>`;
      this.banner.innerHTML = `${icon}<span class="ban__t">${html}</span>`;
      this.go('banner');
      clearTimeout(this.bannerEnd);
      this.bannerEnd = setTimeout(() => { if (this.mode === 'banner') this.go('closed'); }, 3000);
    }

    startAnnouncements() {
      if (this.started || !this.banner) return;
      this.started = true;
      const messages = [
        { kind: 'ok', html: '<b>Stripe Webhook Retries</b> is done' },
        { kind: 'bell', html: '<b>Flaky Auth Tests</b> needs you' },
      ];
      let i = 0;
      const tick = () => {
        const visible = !document.hidden && !this.screen.classList.contains('is-offscreen');
        if (visible && this.mode === 'closed' && !this.hovering) this.flash(messages[i++ % messages.length]);
        this.loopTimer = setTimeout(tick, 8000);
      };
      this.loopTimer = setTimeout(tick, 1600);
    }
  }

  const islands = {};
  function initIslands() {
    const heroRoot = $('.island[data-island="hero"]');
    const bigRoot = $('.island[data-island="big"]');
    if (heroRoot) islands.hero = new Island(heroRoot);
    if (bigRoot) islands.big = new Island(bigRoot, { big: true });

    on('theme', (t) => { for (const el of $$('[data-theme-name]')) el.textContent = t.name; });

    const radios = $$('input[name="island-mode"]');
    for (const r of radios) r.addEventListener('change', () => { if (r.checked) setMode(r.value); });

    let resizeTimer = 0;
    addEventListener('resize', () => {
      clearTimeout(resizeTimer);
      resizeTimer = setTimeout(() => Object.values(islands).forEach((isl) => isl.relayout()), 120);
    });
    document.fonts?.ready.then(() => Object.values(islands).forEach((isl) => isl.relayout()));
  }
  const MODES = ['minimal', 'standard', 'detailed'];
  function setMode(mode) {
    const isl = islands.big;
    if (!isl) return;
    isl.root.dataset.mode = mode;
    for (const r of $$('input[name="island-mode"]')) r.checked = r.value === mode;
    isl.refit();
  }

  /* ------------------------------------------------------------------ */
  /* Theme gallery                                                        */
  /* ------------------------------------------------------------------ */

  async function initThemes() {
    const grid = $('#theme-grid');
    if (!grid) return;
    const note = $('#grid-note');
    let data;
    try {
      const res = await fetch('/themes.json', { credentials: 'same-origin' });
      if (!res.ok) throw new Error(String(res.status));
      data = await res.json();
    } catch {
      grid.innerHTML = '<p class="grid__loading">The theme list didn’t load. Every theme is also in <a class="textlink" href="https://github.com/0xNtive/tabby/blob/main/docs/contrast.md">the contrast audit</a>.</p>';
      return;
    }
    state.themeMap = new Map(data.themes.map((t) => [t.id, t]));
    state.groups = data.groups || {};
    state.themeId = data.default && state.themeMap.has(data.default) ? data.default : data.themes[0].id;

    const frag = document.createDocumentFragment();
    for (const t of data.themes) {
      const b = document.createElement('button');
      b.type = 'button';
      b.className = 'tcard';
      b.dataset.id = t.id;
      b.dataset.group = t.group;
      b.setAttribute('aria-pressed', String(t.id === state.themeId));
      b.setAttribute('aria-label', `${t.name}. ${t.contrast.rating}, ${ratio(t.contrast.text)} to 1 contrast${t.calm ? ', calm' : ''}${t.contrast.claudeFriendly ? ', keeps Claude Code readable' : ''}.`);
      b.style.setProperty('--c-bg', t.bg);
      b.style.setProperty('--c-fg', t.fg);
      const dots = KEYS.filter((k) => t.accents[k]).map((k) => `<i style="--d:${esc(t.accents[k])}"></i>`).join('');
      b.innerHTML =
        `<span class="tcard__top"><span class="tcard__name">${esc(t.name)}</span><svg class="tcard__check" aria-hidden="true"><use href="#i-check"/></svg></span>` +
        `<span class="tcard__id">${esc(t.id)}</span>` +
        `<span class="tcard__dots" aria-hidden="true">${dots}</span>` +
        `<span class="tcard__foot" aria-hidden="true"><span class="badge">${esc(t.contrast.rating)} · ${ratio(t.contrast.text)}:1</span>${t.calm ? '<span class="badge badge--calm">calm</span>' : ''}${t.contrast.claudeFriendly ? '<span class="badge badge--calm" title="Claude Code keeps at least 80% of its contrast on this theme">Claude ✓</span>' : ''}</span>`;
      frag.append(b);
    }
    grid.replaceChildren(frag);
    const cards = Array.from(grid.children);

    // Keep the chip counts honest if themes.json changes.
    const counts = data.themes.reduce((acc, t) => ((acc[t.group] = (acc[t.group] || 0) + 1), acc), {});
    for (const chip of $$('.chip')) {
      const g = chip.dataset.group;
      const span = $('span', chip);
      if (span) span.textContent = g === 'all' ? data.themes.length : counts[g] || 0;
      if (g !== 'all' && !counts[g]) chip.hidden = true;
    }
    const title = $('#themes-title');
    if (title) title.textContent = `${data.themes.length} themes, all of them readable`;
    note.textContent = 'Pick a theme to try it here and on the demo terminal up top.';

    $('.chips').addEventListener('click', (e) => {
      const chip = e.target.closest('.chip');
      if (!chip) return;
      const g = chip.dataset.group;
      for (const c of $$('.chip')) c.setAttribute('aria-pressed', String(c === chip));
      let n = 0;
      for (const card of cards) {
        const show = g === 'all' || card.dataset.group === g;
        card.hidden = !show;
        if (show) n += 1;
      }
      const label = g === 'all' ? '' : `${(state.groups[g] || g).toLowerCase()} `;
      note.textContent = `Showing ${n} ${label}theme${n === 1 ? '' : 's'}.`;
    });

    grid.addEventListener('click', (e) => {
      const card = e.target.closest('.tcard');
      if (card) applyTheme(card.dataset.id);
    });

    on('theme', (t) => {
      for (const card of cards) card.setAttribute('aria-pressed', String(card.dataset.id === t.id));
      $('#pv-name').textContent = t.name;
      const mode = t.mode === 'light' ? 'Light' : 'Dark';
      $('#pv-blurb').textContent = t.blurb || `${mode} theme from the ${state.groups[t.group] || t.group} set`;
      $('#pv-facts').textContent = `Text ${ratio(t.contrast.text)}:1 (${t.contrast.rating}). Tinted tabs never drop below ${ratio(t.contrast.tintedText)}:1. Claude Code's own colors keep ${Math.round(t.contrast.claudeKeep * 100)}% of their contrast here${t.mode === 'light' ? '; set Claude to a light theme with /theme' : ''}.${t.calm ? ' Tagged calm.' : ''}`;
      const cmd = `/tab theme ${t.id} all`;
      $('#pv-cmd').textContent = cmd;
      $('#pv-copy').dataset.copy = cmd;
    });

    if (state.themeId !== 'tabby') applyTheme(state.themeId);
  }

  /* ------------------------------------------------------------------ */
  /* Tile windows demo                                                    */
  /* ------------------------------------------------------------------ */

  const LAYOUTS = { 2: [2, 1], 3: [3, 1], 4: [2, 2], 6: [3, 2], 8: [4, 2] };
  let tileTo = null;
  function initTiles() {
    const box = $('.tiles');
    if (!box) return;
    const wins = $$('.tw', box);
    const buttons = $$('.seg--tile button');
    tileTo = (n) => {
      const [cols, rows] = LAYOUTS[n];
      wins.forEach((w, i) => {
        if (i < n) {
          const place = () => {
            w.style.left = `${((i % cols) * 100) / cols}%`;
            w.style.top = `${(Math.floor(i / cols) * 100) / rows}%`;
            w.style.width = `${100 / cols}%`;
            w.style.height = `${100 / rows}%`;
          };
          const wasOff = w.classList.contains('is-off') || (!w.classList.contains('is-on') && i >= 4);
          if (wasOff) {
            // Appear in place instead of flying in from a stale position.
            w.style.transition = 'none';
            place();
            void w.offsetWidth;
            w.style.transition = '';
          } else {
            place();
          }
          w.classList.add('is-on');
          w.classList.remove('is-off');
        } else {
          w.classList.add('is-off');
          w.classList.remove('is-on');
        }
      });
      box.dataset.n = String(n);
      for (const b of buttons) b.setAttribute('aria-pressed', String(Number(b.dataset.n) === n));
    };
    for (const b of buttons) b.addEventListener('click', () => tileTo(Number(b.dataset.n)));
  }
  function nextTile() {
    const box = $('.tiles');
    if (!box || !tileTo) return;
    const ns = [2, 3, 4, 6, 8];
    tileTo(ns[(ns.indexOf(Number(box.dataset.n)) + 1) % ns.length]);
  }

  /* ------------------------------------------------------------------ */
  /* Copy buttons                                                         */
  /* ------------------------------------------------------------------ */

  async function copyText(text) {
    try {
      await navigator.clipboard.writeText(text);
      return true;
    } catch {
      const ta = document.createElement('textarea');
      ta.value = text;
      ta.setAttribute('readonly', '');
      ta.style.position = 'fixed';
      ta.style.opacity = '0';
      document.body.append(ta);
      ta.select();
      let ok = false;
      try { ok = document.execCommand('copy'); } catch { ok = false; }
      ta.remove();
      return ok;
    }
  }
  function initCopy() {
    document.addEventListener('click', async (e) => {
      const btn = e.target.closest('.copy');
      if (!btn) return;
      const text = btn.dataset.copy;
      const ok = await copyText(text);
      const label = $('.sr-only', btn);
      btn.dataset.state = ok ? 'ok' : 'err';
      if (label) label.textContent = ok ? 'Copied' : 'Copy command';
      announce(ok ? `Copied: ${text}` : 'Couldn’t copy. Select the command and copy it instead.');
      clearTimeout(btn.resetTimer);
      btn.resetTimer = setTimeout(() => {
        delete btn.dataset.state;
        if (label) label.textContent = 'Copy command';
      }, 1600);
    });
  }

  /* ------------------------------------------------------------------ */
  /* How it works: one sequence when the steps scroll into view          */
  /* ------------------------------------------------------------------ */

  function initHow() {
    const how = $('#how');
    const steps = how && $('.steps', how);
    if (!steps || reduce || !('IntersectionObserver' in window)) return;
    if (steps.getBoundingClientRect().top < innerHeight * 0.8) return; // already on screen: leave the finished state
    how.classList.add('is-armed');
    // Each step plays when it reaches the lower third of the viewport: together on wide screens,
    // one after another on phones where the steps stack.
    const io = new IntersectionObserver((entries) => {
      for (const entry of entries) {
        if (!entry.isIntersecting) continue;
        entry.target.classList.add('is-playing');
        io.unobserve(entry.target);
      }
    }, { rootMargin: '0px 0px -30% 0px' });
    for (const step of $$('.step', steps)) io.observe(step);
  }

  /* ------------------------------------------------------------------ */
  /* Pause looping animations offscreen; start island announcements      */
  /* ------------------------------------------------------------------ */

  function initVisibility() {
    if (!('IntersectionObserver' in window)) return;
    const io = new IntersectionObserver((entries) => {
      for (const entry of entries) {
        entry.target.classList.toggle('is-offscreen', !entry.isIntersecting);
        if (entry.isIntersecting && entry.target.id === 'island-stage') islands.big?.startAnnouncements();
      }
    }, { rootMargin: '60px 0px' });
    for (const sel of ['#stage', '#how', '#features', '#island-stage', '.preview']) {
      const el = $(sel);
      if (el) io.observe(el);
    }
  }

  /* ------------------------------------------------------------------ */
  /* The island's keyboard shortcuts work on the page too                */
  /* ------------------------------------------------------------------ */

  function initShortcuts() {
    document.addEventListener('keydown', (e) => {
      if (!e.ctrlKey || !e.altKey || e.metaKey) return;
      if (e.target.closest?.('textarea, [contenteditable="true"], input:not([type="radio"])')) return;
      const code = e.code;
      if (code === 'Space') {
        e.preventDefault();
        const visible = (isl) => isl && !isl.screen.classList.contains('is-offscreen');
        let isl = visible(islands.big) ? islands.big : visible(islands.hero) ? islands.hero : null;
        if (!isl && islands.big) {
          isl = islands.big;
          $('#island')?.scrollIntoView({ behavior: reduce ? 'auto' : 'smooth' });
        }
        if (!isl) return;
        if (isl.mode === 'open') { isl.close(); return; }
        isl.open('key');
        isl.head.focus({ preventScroll: true });
      } else if (code === 'KeyN') {
        e.preventDefault();
        const next = SESSIONS.find((s) => s.status === 'waiting' && s.id !== state.active) || SESSIONS.find((s) => s.status === 'waiting');
        if (next) {
          setActive(next.id);
          announce(`${next.title} needs you.`);
        }
      } else if (code === 'KeyM') {
        e.preventDefault();
        const current = islands.big?.root.dataset.mode || 'standard';
        const mode = MODES[(MODES.indexOf(current) + 1) % MODES.length];
        setMode(mode);
        announce(`Island mode: ${mode}.`);
      } else if (code === 'KeyG') {
        e.preventDefault();
        nextTile();
      } else if (/^Digit[1-9]$/.test(code)) {
        const s = SESSIONS[Number(code.slice(5)) - 1];
        if (s) {
          e.preventDefault();
          setActive(s.id);
          announce(`Switched to ${s.title}.`);
        }
      }
    });
  }

  /* ------------------------------------------------------------------ */

  function init() {
    initTerminal();
    initIslands();
    initTiles();
    initCopy();
    initHow();
    initVisibility();
    initShortcuts();
    // The gallery sits far below the fold: build it when the main thread is idle.
    const idle = window.requestIdleCallback || ((fn) => setTimeout(fn, 60));
    idle(() => { initThemes(); }, { timeout: 1500 });
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init);
  else init();
})();
