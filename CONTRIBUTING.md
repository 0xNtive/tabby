# Contributing

Thanks for helping! tabby is small on purpose: zero runtime dependencies, plain Node ≥ 18 ESM, and a single-target SwiftUI app.

- **Run the tests:** `npm test`. Hook flows run against a sandboxed `$HOME` and fake TTY files; nothing touches your real setup.
- **Try a change in Claude:** `claude --plugin-dir .` loads your checkout for one session.
- **Themes:** add them to `lib/themes.js` using the theme's *published* colors, and name accents by hue (red … pink). Then run `npm run export`, which updates `docs/contrast.md` and `site/themes.json`. Tests reject a theme whose text is below WCAG AA.
- **Island:** `bash island/build.sh`. Check your UI with `TabbyIsland --snapshot <dir>` and keep collapsed idle CPU under 1% (Core Animation for anything that loops).
- **Website:** static files in `site/`. Preview with `cd site && python3 -m http.server`.
- **Commits:** small and descriptive. Update `CHANGELOG.md` for anything users notice.

Hooks must never break or slow a session. Catch everything, log to `~/.claude/tabby/tabby.log` and return quickly (async where possible).
