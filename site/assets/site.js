// tabby website: small, dependency-free behaviors. Everything works without JS except the
// spotlight, the numerals and the copy button, which degrade to their static state.
(() => {
  const reduce = matchMedia('(prefers-reduced-motion: reduce)').matches;
  const fine = matchMedia('(hover: hover) and (pointer: fine)').matches;

  // Hero: the wall of terminals starts dormant; tabby's colors follow the cursor with a
  // light spring and rest on the cat. Touch screens and reduced motion get it fully lit.
  const hero = document.querySelector('.hero');
  const art = hero && hero.querySelector('.hero-art');
  const still = art && art.querySelector('img.hero-lit');
  if (art && still) {
    const video = art.querySelector('.hero-video');
    if (video && !reduce && matchMedia('(min-width: 900px)').matches) {
      video.src = video.dataset.src;
      video.addEventListener('playing', () => video.classList.add('is-playing'), { once: true });
      video.play().catch(() => {});
    }
    if (!fine || reduce) {
      art.dataset.mode = 'full';
    } else {
      let x = 0, y = 0, r = 0, tx = 0, ty = 0, tr = 0, raf = 0;
      const home = () => {
        const b = still.getBoundingClientRect();
        tx = b.width * 0.866;
        ty = b.height * 0.16;
        tr = Math.max(220, b.height * 0.36);
      };
      const paint = () => {
        art.style.setProperty('--rx', `${x}px`);
        art.style.setProperty('--ry', `${y}px`);
        art.style.setProperty('--rr', `${r}px`);
      };
      const step = () => {
        x += (tx - x) * 0.14;
        y += (ty - y) * 0.14;
        r += (tr - r) * 0.1;
        paint();
        raf = Math.abs(tx - x) + Math.abs(ty - y) + Math.abs(tr - r) > 0.5 ? requestAnimationFrame(step) : 0;
      };
      const kick = () => { if (!raf) raf = requestAnimationFrame(step); };
      home();
      [x, y, r] = [tx, ty, tr];
      paint();
      hero.addEventListener('pointermove', (e) => {
        const b = still.getBoundingClientRect();
        tx = e.clientX - b.left;
        ty = e.clientY - b.top;
        tr = Math.max(240, b.height * 0.34);
        kick();
      });
      hero.addEventListener('pointerleave', () => { home(); kick(); });
      addEventListener('resize', () => { home(); kick(); });
    }
  }

  // Nav: the tab for the section most on screen is the selected tab.
  const tabs = [...document.querySelectorAll('.nav-tab')];
  const sections = tabs.map((t) => document.querySelector(t.getAttribute('href'))).filter(Boolean);
  if (sections.length && 'IntersectionObserver' in window) {
    const seen = new Map();
    const io = new IntersectionObserver((entries) => {
      for (const e of entries) seen.set(e.target, e.isIntersecting ? e.intersectionRatio : 0);
      let best = null, ratio = 0;
      for (const [el, v] of seen) if (v > ratio) [best, ratio] = [el, v];
      for (const t of tabs) {
        if (best && t.getAttribute('href') === `#${best.id}`) t.setAttribute('aria-current', 'true');
        else t.removeAttribute('aria-current');
      }
    }, { threshold: [0, 0.15, 0.3, 0.5, 0.75], rootMargin: '-64px 0px 0px 0px' });
    sections.forEach((s) => io.observe(s));
  }

  // Tile: pick a count; the diagram is tabby tile's real grid for it (lib/tile.js grid()).
  const GRIDS = { 2: [2, 1], 3: [3, 1], 4: [2, 2], 6: [3, 2], 8: [4, 2] };
  const numerals = [...document.querySelectorAll('.numeral')];
  const cells = document.querySelector('.grid-cells');
  const diagram = document.querySelector('.grid-diagram');
  const label = document.querySelector('.tile-n');
  const pick = (n) => {
    const [cols, rows] = GRIDS[n];
    const W = 160, H = 100, gap = 4;
    const cw = (W - gap * (cols + 1)) / cols, ch = (H - gap * (rows + 1)) / rows;
    let svg = '';
    for (let i = 0; i < n; i++) {
      const x = gap + (i % cols) * (cw + gap), y = gap + Math.floor(i / cols) * (ch + gap);
      svg += i === 0
        ? `<rect x="${x}" y="${y}" width="${cw}" height="${ch}" rx="3.5" fill="#f4913e"/>`
        : `<rect x="${x}" y="${y}" width="${cw}" height="${ch}" rx="3.5" fill="rgb(238 246 242 / 0.14)" stroke="rgb(238 246 242 / 0.6)"/>`;
    }
    if (cells) cells.innerHTML = svg;
    if (diagram) diagram.setAttribute('aria-label', `${n} windows in a ${cols} by ${rows} grid`);
    if (label) label.textContent = n;
    for (const b of numerals) b.setAttribute('aria-checked', String(Number(b.dataset.n) === n));
  };
  for (const b of numerals) {
    const n = Number(b.dataset.n);
    b.addEventListener('click', () => pick(n));
    b.addEventListener('focus', () => pick(n));
    if (fine) b.addEventListener('mouseenter', () => pick(n));
  }

  // Install: the copy stamp.
  for (const btn of document.querySelectorAll('[data-copy]')) {
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
    for (const chip of document.querySelectorAll('.chip')) {
      chip.addEventListener('click', () => {
        chip.dataset.flipped = chip.dataset.flipped === 'true' ? 'false' : 'true';
      });
    }
  }
})();
