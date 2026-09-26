# Changelog

## 0.2.1 — 2026-09-26

- **Tiling fixed:**
  - Tabs of one macOS tab group share a frame. tabby used to set every window's frame at once while tabs were still animating out, so macOS put them back and windows ended up half-tiled. Now tabby moves one window, sees which tabs move with it, pulls those out, waits until each has its own frame, then places every window.
  - Placement is verified with tolerance for Terminal's character-cell sizing and retried if macOS moves a window again.
  - Separate windows that merely share a frame are no longer mistaken for tabs.
  - Only one tile can run at a time.
- **Island:** "Allow Accessibility" now adds Tabby Island to the Accessibility list before opening the pane.

## 0.2.0 — 2026-09-25

- **Brand:** the tabby cat, whose three stripes are colored tabs. It appears in the logo, the app icon and the island.
- **Terms of use:** tabby does nothing until you accept them. `/tabby:setup` shows them and `/tabby:setup accept` finishes setup. The terms cover possible future sponsored messages in tabby's own UI (never in your conversations).
- **57 themes** (was 26), in six groups: Signature, Calm, Classic, Vivid, Light and High contrast. New: Ember, Mist, Catppuccin Macchiato, Tokyo Night Storm and Day, Rosé Pine Moon, Kanagawa Dragon and Lotus, Nightfox, Oxocarbon, Poimandres, Horizon, Iceberg (dark and light), Sonokai, Flexoki (dark and light), Selenized (dark, light and black), Gruvbox Material, Oceanic Next, Moonfly, Jellybeans, Synthwave '84, GitHub Light, One Light, Tomorrow, Ayu Light, Modus Vivendi and Modus Operandi.
- **Contrast guarantees**, enforced by tests and published in `docs/contrast.md`:
  - text is WCAG AA or better in every theme and at every tint;
  - cursors are darkened or lightened to at least 3:1;
  - island dots are at least 4:1 on black.
- **Animated tab titles:** a spinner while Claude works and a blinking bell when it needs you. On iTerm2 the tab color also pulses.
- **Terminal.app tab titles** show only the session name (`tabby terminal-titles on|off`).
- **`tabby tile [n]`** fills the screen with 2, 3, 4, 6 or 8 session windows, splitting tabs into windows where Accessibility allows. **`tabby next`** jumps to the next session that needs you. **`tabby focus <n>`** jumps to session n.
- **Tabby Island:**
  - three modes: Minimal, Standard and Detailed;
  - global shortcuts: ⌃⌥Space, ⌃⌥N, ⌃⌥1–9, ⌃⌥G and ⌃⌥M;
  - live "done" and "needs you" announcements, dot pops and a done sparkle;
  - grouped theme menus, a tile button and the app icon;
  - uses 4.5× less CPU.
- **Stable launcher** (`~/.claude/tabby/bin/tabby.mjs`), so the status line, shell flags, `/tab` and the island survive plugin updates and npx installs.
- **Sessions opened before install** can turn tabby on with `/reload-plugins`, and keep their Claude-written titles.

## 0.1.x — 2026-09-25

- First release:
  - Claude Code plugin hooks with AI tab names (Claude Haiku), OKLCH background tints, status markers and `/tab`;
  - launch flags, the status line and `tabby ls`;
  - Tabby Island.
