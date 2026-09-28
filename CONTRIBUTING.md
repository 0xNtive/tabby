# Contributing

Thanks for helping! tabby is small on purpose: zero runtime dependencies, plain Node ≥ 18 ESM, and a single-target SwiftUI app. Issues labeled `good first issue` are a good place to start, and ideas are welcome as issues before code.

## How it fits together

| Part | Where | What it does |
|---|---|---|
| Plugin | `.claude-plugin/`, `hooks/hooks.json`, `commands/`, `skills/` | Claude Code runs tabby's hooks on every session event; `/tab` and `/tabby:setup` are answered inside the hook, with no model call |
| CLI | `bin/tabby.js`, `lib/` | Everything the hooks and `tabby …` do: naming, colors, status, setup, tiling, `doctor` |
| Launcher | `bin/tabby.sh` | Finds a Node.js 18+ wherever it lives, so hooks work even when Claude's PATH has none |
| Island | `island/` | The macOS app (SwiftUI + AppKit). It reads `~/.claude/tabby` and Claude's session registry, and runs the CLI for anything that changes state |
| Installer | `install.sh`, `site/install.md` | The one-liner, and the guide Claude follows when someone asks it to install tabby |
| Site | `site/` | Static, served by Vercel from `main` |

## Working on it

- **Tests:** `npm test`. Hook flows run against a sandboxed `$HOME` and fake TTY files, with `TABBY_NO_TERMINAL_PROFILES=1` and `TABBY_NO_ISLAND=1`, so nothing touches your real setup.
- **Try a change in Claude:** `claude --plugin-dir .` loads your checkout for one session.
- **Try the installer against your checkout,** in a throwaway home:

  ```sh
  SB=$(mktemp -d); HOME=$SB CLAUDE_CONFIG_DIR=$SB/.claude TABBY_NO_TERMINAL_PROFILES=1 TABBY_ISLAND_SANDBOX=1 \
    TABBY_MARKETPLACE="$PWD" bash install.sh --yes
  ```

  Add `TABBY_NODE_DOWNLOAD=force` to test the private Node.js download, and `TABBY_ISLAND_URL=file:///path/TabbyIsland.zip` (with a `.sha256` next to it) to test the island download before a release exists.
- **Themes:** add them to `lib/themes.js` using the theme's *published* colors, and name accents by hue (red … pink). Then run `npm run export`, which updates `docs/contrast.md` and `site/themes.json`. Tests reject a theme whose text is below WCAG AA.
- **Island:** `bash island/build.sh` (this Mac) or `--universal`, then `bash island/test.sh`. Check the UI with `"island/build/Tabby Island.app/Contents/MacOS/TabbyIsland" --snapshot <dir>`: it renders every screen to PNGs, with no Screen Recording permission needed. Keep collapsed idle CPU under 1% (Core Animation for anything that loops).
- **Website:** static files in `site/`. Preview with `cd site && python3 -m http.server`.

Hooks must never break or slow a session. Catch everything, log to `~/.claude/tabby/tabby.log` and return quickly (async where possible).

## Releasing

1. Bump `version` in `package.json`, `.claude-plugin/plugin.json` and `.claude-plugin/marketplace.json`, and add a `CHANGELOG.md` entry (`## X.Y.Z — date`).
2. Push to `main`: CI runs the tests, and Vercel deploys the site and `/install`.
3. Tag it: `git tag vX.Y.Z && git push origin vX.Y.Z`. The release workflow builds the universal Tabby Island, checks its signature and version, and publishes `TabbyIsland.zip` with its `.sha256`. `tabby island install` and the installer download that, and fall back to building locally if it isn't there.

Commits: small and descriptive. Update `CHANGELOG.md` for anything users notice.
