// tabby website: small, dependency-free behaviors. The page reads without JS; the demos, the
// reveal-on-scroll, the switchers and the copy button are additions.
(() => {
  const html = document.documentElement;
  html.classList.add('js');
  const reduce = matchMedia('(prefers-reduced-motion: reduce)').matches;
  const fine = matchMedia('(hover: hover) and (pointer: fine)').matches;
  const $ = (s, r = document) => r.querySelector(s);
  const $$ = (s, r = document) => [...r.querySelectorAll(s)];
  const io = 'IntersectionObserver' in window;

  // Colors for the Terminal mock-ups: three of tabby's themes (from lib/themes.js), each with the tint
  // its background takes for every accent.
  const THEMES = {
    tabby: { name: 'Tabby Dusk', bg: '#15171c', fg: '#ced1d6', accents: { red: '#ef9491', orange: '#e79e6b', yellow: '#c7b05a', green: '#7fc489', teal: '#48c7c3', blue: '#77b7f4', purple: '#bea0eb', pink: '#e394c1' }, tints: { red: '#241013', orange: '#23130a', yellow: '#1b1706', green: '#091c11', teal: '#001c1e', blue: '#071829', purple: '#191327', pink: '#22101d' } },
    nord: { name: 'Nord', bg: '#2e3440', fg: '#d8dee9', accents: { red: '#bf616a', orange: '#d08770', yellow: '#ebcb8b', green: '#a3be8c', teal: '#8fbcbb', blue: '#81a1c1', purple: '#b48ead', pink: '#b48ead' }, tints: { red: '#422d35', orange: '#422e2e', yellow: '#3a3326', green: '#2a382c', teal: '#163a40', blue: '#21354c', purple: '#3d2d42', pink: '#3d2d42' } },
    ember: { name: 'Ember', bg: '#1c1611', fg: '#dbd3c6', accents: { red: '#ec9693', orange: '#e59f6f', yellow: '#c6b05f', green: '#82c48b', teal: '#51c6c2', blue: '#7ab7f1', purple: '#bda1e9', pink: '#e196c0' }, tints: { red: '#280f0c', orange: '#261103', yellow: '#1f1600', green: '#0f1b09', teal: '#041c18', blue: '#0d1824', purple: '#1d1322', pink: '#250f18' } },
  };
  const GLYPH = { busy: '◐', idle: '✳', waiting: '🔔', error: '⚠', new: '' };
  const SPIN = ['◐', '◓', '◑', '◒'];

  // One ticker animates every status glyph on the page, the way tabby's own ticker redraws titles: spinner
  // frames while working, a bell lit two thirds of the time while a session needs you. It runs only while
  // something that uses it is on screen.
  let tick = 0, ticker = 0, watchers = 0;
  const paintGlyphs = () => {
    for (const g of $$('.mglyph')) {
      const s = g.dataset.status;
      if (s === 'busy') g.textContent = SPIN[tick % 4];
      else if (s === 'waiting') g.classList.toggle('is-blink', tick % 6 >= 4);
    }
  };
  const wantTicker = (on) => {
    watchers += on ? 1 : -1;
    if (watchers > 0 && !ticker && !reduce) ticker = setInterval(() => { tick++; paintGlyphs(); }, 166);
    if (watchers <= 0 && ticker) { clearInterval(ticker); ticker = 0; }
  };
  const onScreen = (el, enter, leave, threshold = 0.15) => {
    if (!io) { enter(); return; }
    let visible = false;
    new IntersectionObserver(([e]) => {
      if (e.isIntersecting === visible) return;
      visible = e.isIntersecting;
      visible ? enter() : leave();
    }, { threshold }).observe(el);
  };
  const watch = (el) => el && onScreen(el, () => wantTicker(true), () => wantTicker(false));

  // A tab in a mock Terminal tab bar: a colored dot, a status glyph and a name.
  class Tab {
    constructor(el) {
      this.el = el;
      this.dot = $('.mdot', el);
      this.glyph = $('.mglyph', el);
      this.name = $('.mname', el);
      this.state = { title: '', color: null, status: 'new', theme: 'tabby' };
    }
    set(patch) { Object.assign(this.state, patch); this.render(); }
    render() {
      const { title, color, status, theme } = this.state;
      const th = THEMES[theme];
      this.name.textContent = title;
      this.dot.style.background = color ? th.accents[color] : 'transparent';
      this.dot.classList.toggle('is-off', !color);
      this.glyph.dataset.status = status;
      this.glyph.textContent = status === 'busy' ? SPIN[tick % 4] : GLYPH[status];
      this.glyph.classList.remove('is-blink');
    }
  }
  // The terminal body takes the active tab's look: the theme's background tinted toward the accent.
  const paint = (body, tab) => {
    const th = THEMES[tab.state.theme];
    const c = tab.state.color;
    body.style.background = c ? th.tints[c] : th.bg;
    body.style.color = th.fg;
    body.style.setProperty('--accent', c ? th.accents[c] : th.fg);
  };
  const pillSwitcher = (root) => (state) => { for (const img of $$('.pill img', root)) img.classList.toggle('is-on', img.dataset.state === state); };

  // A looping, scrubbable script of timed steps that runs only while its root is on screen.
  // build({ at, type }) schedules everything from 0; the loop restarts after the last step.
  function timeline(root, build, final) {
    if (reduce || !io) { final && final(); return { restart() {}, stop() {} }; }
    let timers = [], end = 0, visible = false;
    const at = (ms, fn) => { end = Math.max(end, ms); timers.push(setTimeout(fn, ms)); };
    const type = (ms, el, text, speed = 34) => {
      for (let i = 1; i <= text.length; i++) at(ms + i * speed, () => { el.textContent = text.slice(0, i); });
      return ms + text.length * speed;
    };
    const stop = () => { timers.forEach(clearTimeout); timers = []; };
    const start = () => { stop(); end = 0; build({ at, type }); timers.push(setTimeout(start, end + 250)); };
    onScreen(root, () => { visible = true; wantTicker(true); start(); }, () => { visible = false; wantTicker(false); stop(); });
    return { restart: () => { if (visible) start(); }, stop };
  }

  // Hero: a new Claude tab gets its name and color after the first prompt, while the island announces
  // the sessions that need you or finished.
  const hero = $('#hero-scene');
  if (hero) {
    const tabs = Object.fromEntries($$('.mtab', hero).map((el) => [el.dataset.tab, new Tab(el)]));
    const body = $('.mac-body', hero);
    const lines = $$('.term .tline', hero);
    const prompt = $('.tprompt-text', hero);
    const echo = $('.t-echo', hero), echoText = $('.t-echo-text', hero);
    const status = $('.term-status', hero);
    const title = $('.mac-title', hero);
    const pill = pillSwitcher(hero);
    const PROMPT = 'write the 2.0 release notes, mention the new keyboard shortcuts first';
    const reset = () => {
      tabs.auth.set({ title: 'Refactor auth middleware', color: 'blue', status: 'busy' });
      tabs.web.set({ title: 'Fix flaky checkout e2e test', color: 'green', status: 'busy' });
      tabs.billing.set({ title: 'Migrate billing to Stripe v3', color: 'orange', status: 'busy' });
      tabs.docs.set({ title: 'docs', color: null, status: 'new' });
      tabs.docs.el.classList.remove('is-named');
      prompt.textContent = '';
      lines.slice(2, 7).forEach((l) => l.classList.remove('is-on'));
      status.classList.remove('is-on');
      title.textContent = 'docs';
      paint(body, tabs.docs);
      pill('collapsed');
    };
    const named = () => {
      tabs.docs.set({ title: 'Write the 2.0 release notes', color: 'purple', status: 'busy' });
      tabs.docs.el.classList.add('is-named');
      title.textContent = 'Write the 2.0 release notes';
      paint(body, tabs.docs);
      status.classList.add('is-on');
    };
    timeline(hero, ({ at, type }) => {
      at(0, reset);
      const typed = type(900, prompt, PROMPT);
      at(typed + 500, () => { echoText.textContent = PROMPT; prompt.textContent = ''; echo.classList.add('is-on'); lines[3].classList.add('is-on'); tabs.docs.set({ status: 'busy' }); });
      at(typed + 2300, named);
      at(typed + 2900, () => lines[4].classList.add('is-on'));
      at(typed + 3600, () => lines[5].classList.add('is-on'));
      at(typed + 4300, () => lines[6].classList.add('is-on'));
      at(typed + 5000, () => { tabs.auth.set({ status: 'waiting' }); pill('waiting'); });
      at(typed + 8000, () => { tabs.web.set({ status: 'idle' }); pill('done'); });
      at(typed + 10800, () => pill('collapsed'));
      at(typed + 12200, () => {});
    }, () => {
      reset();
      echoText.textContent = PROMPT;
      lines.forEach((l) => l.classList.add('is-on'));
      named();
      tabs.auth.set({ status: 'waiting' });
      pill('waiting');
    });
  }

  // Hero: the screen tilts a few degrees toward the pointer.
  const heroSection = $('.hero');
  const screen = $('#hero-scene .screen');
  if (heroSection && screen && fine && !reduce) {
    let rx = 0, ry = 0, tx = 0, ty = 0, raf = 0;
    const step = () => {
      rx += (tx - rx) * 0.1; ry += (ty - ry) * 0.1;
      screen.style.setProperty('--rx', `${rx.toFixed(3)}deg`);
      screen.style.setProperty('--ry', `${ry.toFixed(3)}deg`);
      raf = Math.abs(tx - rx) + Math.abs(ty - ry) > 0.005 ? requestAnimationFrame(step) : 0;
    };
    const kick = () => { if (!raf) raf = requestAnimationFrame(step); };
    heroSection.addEventListener('pointermove', (e) => {
      const b = screen.getBoundingClientRect();
      const px = (e.clientX - b.left) / b.width - 0.5, py = (e.clientY - b.top) / b.height - 0.5;
      tx = Math.max(-1, Math.min(1, -py)) * 5; ty = Math.max(-1, Math.min(1, px)) * 6;
      kick();
    });
    heroSection.addEventListener('pointerleave', () => { tx = 0; ty = 0; kick(); });
  }

  // GitHub stars: fetched once an hour (shared through localStorage); the count ticks up when it arrives.
  const starEls = $$('[data-stars]');
  if (starEls.length) {
    const KEY = 'tabby:stars';
    const fmt = (n) => (n >= 1000 ? `${(n / 1000).toFixed(n >= 10000 ? 0 : 1)}k` : String(n));
    const show = (n, animate) => {
      if (!(n > 0)) return;
      for (const el of starEls) {
        el.hidden = false;
        if (!animate || reduce) { el.textContent = fmt(n); continue; }
        const t0 = performance.now();
        const tickUp = (t) => { const p = Math.min(1, (t - t0) / 900); el.textContent = fmt(Math.round(n * (1 - (1 - p) ** 3))); if (p < 1) requestAnimationFrame(tickUp); };
        requestAnimationFrame(tickUp);
      }
    };
    let cached = null;
    try { cached = JSON.parse(localStorage.getItem(KEY)); } catch {}
    if (cached && Date.now() - cached.at < 3600e3) show(cached.n, false);
    else {
      fetch('https://api.github.com/repos/0xNtive/tabby', { headers: { Accept: 'application/vnd.github+json' } })
        .then((r) => (r.ok ? r.json() : null))
        .then((d) => { if (!d) return; const n = Number(d.stargazers_count) || 0; try { localStorage.setItem(KEY, JSON.stringify({ n, at: Date.now() })); } catch {} show(n, true); })
        .catch(() => {});
    }
  }

  // Tabs: the zoomed-in tab cycles through its states; the status row and the status line just tick.
  const big = $('.bigtab-tab');
  if (big) {
    const tab = new Tab(big);
    tab.set({ title: 'Write the 2.0 release notes', color: 'purple', status: 'busy' });
    timeline($('.bigtab'), ({ at }) => {
      at(0, () => tab.set({ status: 'busy' }));
      at(5200, () => tab.set({ status: 'idle' }));
      at(8200, () => tab.set({ status: 'waiting' }));
      at(11600, () => {});
    }, () => tab.set({ status: 'busy' }));
  }
  watch($('.status-row'));
  watch($('.statusline-note'));

  // Island: the collapsed pill speaks up; the mode switcher crossfades the real renders.
  const pillrow = $('.pillrow');
  if (pillrow) {
    const pill = pillSwitcher(pillrow);
    timeline(pillrow, ({ at }) => {
      at(0, () => pill('collapsed'));
      at(2600, () => pill('waiting'));
      at(5800, () => pill('done'));
      at(9000, () => pill('collapsed'));
      at(9800, () => {});
    }, () => pill('waiting'));
  }

  // A segmented control that crossfades a set of images; auto-advances until the visitor picks one.
  function switcher({ root, attr, segs, imgs, captions = [], every = 0, fit }) {
    if (!root || !segs.length) return;
    let userAt = 0;
    const keys = segs.map((s) => s.dataset[attr]);
    let current = keys.find((k, i) => segs[i].classList.contains('is-on')) || keys[0];
    const set = (k) => {
      current = k;
      segs.forEach((s) => { const on = s.dataset[attr] === k; s.classList.toggle('is-on', on); s.setAttribute('aria-selected', String(on)); });
      imgs.forEach((i) => i.classList.toggle('is-on', i.dataset[attr] === k));
      captions.forEach((c) => c.classList.toggle('is-on', c.dataset.for === k));
      fit && fit(k);
    };
    segs.forEach((s) => s.addEventListener('click', () => { userAt = Date.now(); set(s.dataset[attr]); }));
    set(current);
    if (every) {
      timeline(root, ({ at }) => {
        at(every, () => { if (Date.now() - userAt > 12000) set(keys[(keys.indexOf(current) + 1) % keys.length]); });
      });
    }
    return set;
  }

  const modes = $('.modes');
  if (modes) {
    const frame = $('.mode-frame', modes);
    const imgs = $$('img', frame);
    const fit = (k) => {
      const img = imgs.find((i) => i.dataset.mode === k);
      if (!img) return;
      const pct = parseFloat(getComputedStyle(img).width) / frame.clientWidth || 1;
      frame.classList.add('is-js');
      frame.style.height = `${frame.clientWidth * pct * (Number(img.getAttribute('height')) / Number(img.getAttribute('width')))}px`;
    };
    const set = switcher({ root: modes, attr: 'mode', segs: $$('.seg', modes), imgs, captions: $$('.mode-caption', modes), every: 4500, fit });
    addEventListener('resize', () => fit($('.seg.is-on', modes)?.dataset.mode));
  }

  const settings = $('.settings-demo');
  if (settings) switcher({ root: settings, attr: 'pane', segs: $$('.seg', settings), imgs: $$('.settings-frame img', settings), every: 3800 });

  // Focus mode: the window fills with Claude's output, then the real cover slides over it.
  const focus = $('#focus-demo');
  if (focus) {
    const lines = $$('.tline', focus);
    const cover = $('.focus-cover', focus);
    const reset = () => { lines.forEach((l) => l.classList.remove('is-on')); cover.classList.remove('is-on'); };
    timeline(focus, ({ at }) => {
      at(0, reset);
      lines.forEach((l, i) => at(400 + i * 330, () => l.classList.add('is-on')));
      at(4600, () => cover.classList.add('is-on'));
      at(9400, () => cover.classList.remove('is-on'));
      at(9800, () => {});
    }, () => { lines.forEach((l) => l.classList.add('is-on')); cover.classList.add('is-on'); });
  }

  // Windows: pick a count; the windows fly from a messy pile into tabby tile's real grid (lib/tile.js grid()).
  const GRIDS = { 2: [2, 1], 3: [3, 1], 4: [2, 2], 6: [3, 2], 8: [4, 2] };
  const ORDER = [2, 3, 4, 6, 8];
  const stage = $('#tile-stage');
  if (stage) {
    const screen = $('.tile-screen', stage);
    const wins = $$('.twin', stage);
    const label = $('.tile-n', stage);
    const numerals = $$('.numeral');
    let current = 4, userAt = 0, pending = 0;
    const layout = (n, messy) => {
      const [cols, rows] = GRIDS[n];
      const gap = 2.2;
      const cw = (100 - gap * (cols + 1)) / cols, ch = (100 - gap * (rows + 1)) / rows;
      wins.forEach((w, i) => {
        if (i >= n) { w.classList.remove('is-on'); return; }
        w.classList.add('is-on');
        if (messy) {
          w.style.left = `${6 + i * 6.5}%`; w.style.top = `${8 + (i % 3) * 9 + i * 2}%`; w.style.width = '52%'; w.style.height = '56%';
        } else {
          w.style.left = `${gap + (i % cols) * (cw + gap)}%`; w.style.top = `${gap + Math.floor(i / cols) * (ch + gap)}%`; w.style.width = `${cw}%`; w.style.height = `${ch}%`;
        }
      });
      screen.setAttribute('aria-label', `${n} session windows tiled in a ${cols} by ${rows} grid`);
    };
    const pick = (n, animate = true) => {
      current = n;
      label.textContent = n;
      numerals.forEach((b) => b.setAttribute('aria-checked', String(Number(b.dataset.n) === n)));
      clearTimeout(pending);
      if (!animate || reduce) { layout(n, false); return; }
      screen.classList.add('no-anim');
      layout(n, true);
      void screen.offsetWidth;
      screen.classList.remove('no-anim');
      void screen.offsetWidth;
      pending = setTimeout(() => layout(n, false), 420);
    };
    pick(4, false);
    numerals.forEach((b) => {
      const n = Number(b.dataset.n);
      const choose = () => { userAt = Date.now(); if (n !== current) pick(n); };
      b.addEventListener('click', () => { userAt = Date.now(); pick(n); });
      b.addEventListener('focus', choose);
      if (fine) b.addEventListener('mouseenter', choose);
    });
    let first = true;
    timeline(stage, ({ at }) => {
      at(0, () => { if (first) { first = false; pick(current); } else if (Date.now() - userAt > 10000) pick(ORDER[(ORDER.indexOf(current) + 1) % ORDER.length]); });
      at(4600, () => {});
    });
  }

  // Commands: a /tab command is typed, tabby answers, and the tabs react.
  const cmd = $('#cmd-window');
  if (cmd) {
    const tabs = Object.fromEntries($$('.mtab', cmd).map((el) => [el.dataset.tab, new Tab(el)]));
    const all = [tabs.auth, tabs.docs, tabs.web];
    const body = $('.mac-body', cmd);
    const typed = $('.cmd-typed', cmd);
    const promptMarks = $$('.t-prompt', cmd);
    const echo = $('.t-echo', cmd), echoText = $('.cmd-echo', cmd);
    const out = $('.cmd-out', cmd);
    const title = $('.mac-title', cmd);
    const tsTitle = $('.ts-title', cmd);
    const tsTail = $('.ts-tail', cmd);
    const items = $$('.cmd-item');
    let active = tabs.docs;
    const dot = (hex) => `<span style="color:${hex}">●</span>`;
    const accent = (t) => THEMES[t.state.theme].accents[t.state.color];
    const sync = () => { paint(body, active); title.textContent = active.state.title; tsTitle.textContent = active.state.title; };
    const activate = (t) => { all.forEach((x) => x.el.classList.remove('is-active')); tabs.api.el.classList.remove('is-active'); t.el.classList.add('is-active'); active = t; sync(); };
    const reset = () => {
      tabs.auth.set({ title: 'Refactor auth middleware', color: 'blue', status: 'waiting', theme: 'tabby' });
      tabs.docs.set({ title: 'Write the 2.0 release notes', color: 'purple', status: 'busy', theme: 'tabby' });
      tabs.web.set({ title: 'Fix flaky checkout e2e test', color: 'green', status: 'idle', theme: 'tabby' });
      tabs.api.set({ title: 'API docs', color: 'blue', status: 'busy', theme: 'ember' });
      tabs.api.el.classList.remove('is-shown');
      tsTail.textContent = 'Sonnet 5 · $5.08 · docs';
      activate(tabs.docs);
      typed.textContent = ''; out.innerHTML = ''; out.classList.remove('is-on'); echo.classList.remove('is-on'); promptMarks.forEach((m) => { m.textContent = '>'; });
    };
    const STEPS = [
      { cmd: '/tab Auth refactor', out: () => `${dot(accent(active))} Renamed → Auth refactor   (AI naming paused · /tab auto to resume)`, fx: () => { active.set({ title: 'Auth refactor' }); sync(); } },
      { cmd: '/tab color teal', out: () => `${dot(THEMES[active.state.theme].accents.teal)} Color → teal (${THEMES[active.state.theme].accents.teal}) · ${THEMES[active.state.theme].name}`, fx: () => { active.set({ color: 'teal' }); sync(); } },
      { cmd: '/tab theme nord all', out: () => 'Theme → Nord for all 3 tabs (and new ones).', fx: () => { all.forEach((t) => t.set({ theme: 'nord' })); sync(); } },
      { cmd: '/tab auto', out: () => `${dot(accent(active))} AI naming on — a fresh name arrives in a few seconds.`, fx: null, later: () => { active.set({ title: 'Write the 2.0 release notes' }); active.el.classList.add('is-named'); sync(); } },
      { cmd: '/tab ls', out: () => ['3 Claude sessions:', `${dot(accent(tabs.auth))} 🔔 Refactor auth middleware — api · 34% ctx · needs you`, `${dot(accent(tabs.docs))} ◐ Write the 2.0 release notes — docs · 45% ctx · working`, `${dot(accent(tabs.web))} ✳ Fix flaky checkout e2e test — web · 18% ctx · your turn`].join('\n'), fx: null },
      { cmd: 'claude --tab "API docs" --color blue --theme ember', shell: true, out: () => '<span class="t-claude">✻</span> Welcome to Claude Code · ~/Dev/api · Opus 5.5', fx: () => { tabs.api.el.classList.add('is-shown'); tsTail.textContent = 'Opus 5.5 · $0.00 · api'; activate(tabs.api); } },
    ];
    let from = 0;
    const tl = timeline(cmd, ({ at, type }) => {
      let t = 0;
      at(0, () => { reset(); if (from >= 3) STEPS.slice(0, 3).forEach((s) => s.fx && s.fx()); if (from >= 4) STEPS[3].later(); });
      for (let i = from; i < STEPS.length; i++) {
        const step = STEPS[i];
        at(t, () => { typed.textContent = ''; out.classList.remove('is-on'); echo.classList.remove('is-on'); promptMarks.forEach((m) => { m.textContent = step.shell ? '$' : '>'; }); items.forEach((b) => b.classList.toggle('is-on', Number(b.dataset.step) === i)); if (step.shell) activate(tabs.web); });
        const done = type(t + 500, typed, step.cmd);
        at(done + 450, () => { echoText.textContent = step.cmd; typed.textContent = ''; echo.classList.add('is-on'); out.innerHTML = step.out(); out.classList.add('is-on'); step.fx && step.fx(); });
        if (step.later) at(done + 2200, step.later);
        t = done + (i === 4 ? 4200 : 3400);
      }
      at(t, () => { from = 0; });
    }, () => { reset(); echoText.textContent = STEPS[2].cmd; echo.classList.add('is-on'); out.innerHTML = STEPS[2].out(); out.classList.add('is-on'); STEPS[2].fx(); items.forEach((b) => b.classList.toggle('is-on', b.dataset.step === '2')); });
    reset();
    items.forEach((b) => b.addEventListener('click', () => { from = Number(b.dataset.step); tl.restart(); }));
  }

  // Nav: the tab for the section most on screen is the selected tab.
  const navTabs = $$('.nav-tab');
  const sections = navTabs.map((t) => $(t.getAttribute('href'))).filter(Boolean);
  if (sections.length && io) {
    const seen = new Map();
    const obs = new IntersectionObserver((entries) => {
      for (const e of entries) seen.set(e.target, e.isIntersecting ? e.intersectionRatio : 0);
      let best = null, ratio = 0;
      for (const [el, v] of seen) if (v > ratio) [best, ratio] = [el, v];
      for (const t of navTabs) {
        if (best && t.getAttribute('href') === `#${best.id}`) t.setAttribute('aria-current', 'true');
        else t.removeAttribute('aria-current');
      }
    }, { threshold: [0, 0.15, 0.3, 0.5, 0.75], rootMargin: '-64px 0px 0px 0px' });
    sections.forEach((s) => obs.observe(s));
  }

  // Reveal on scroll.
  const reveals = $$('.reveal');
  if (reveals.length && io && !reduce) {
    const obs = new IntersectionObserver((entries) => {
      for (const e of entries) if (e.isIntersecting) { e.target.classList.add('is-in'); obs.unobserve(e.target); }
    }, { threshold: 0.12, rootMargin: '0px 0px -6% 0px' });
    reveals.forEach((el) => obs.observe(el));
  } else {
    reveals.forEach((el) => el.classList.add('is-in'));
  }

  // Install: the copy stamp.
  for (const btn of $$('[data-copy]')) {
    const text = btn.querySelector('span');
    btn.addEventListener('click', async () => {
      try {
        await navigator.clipboard.writeText(btn.dataset.copy);
        text.textContent = 'Copied';
        setTimeout(() => { text.textContent = 'Copy'; }, 1800);
      } catch {
        text.textContent = 'Select and copy';
      }
    });
  }

  // Themes: on touch screens a tap flips a chip (hover and focus do it elsewhere).
  if (!fine) {
    for (const chip of $$('.chip')) {
      chip.addEventListener('click', () => { chip.dataset.flipped = chip.dataset.flipped === 'true' ? 'false' : 'true'; });
    }
  }
})();
