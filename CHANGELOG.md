# Changelog

## 0.2.8 — 2026-09-26

- **Install in one line:** `curl -fsSL https://github.com/0xNtive/tabby/raw/main/install.sh | bash`.
  - It adds the plugin to Claude Code and runs setup, which shows the terms first.
  - On a Mac it also builds Tabby Island and asks macOS for Accessibility, which tiling needs.
  - `bash -s -- --yes` accepts the terms without a prompt, and `--no-island` skips the island.
- **`tabby island accessibility`** restarts the island and asks macOS for the permission again. Use it when tiling says Accessibility is missing but System Settings shows it on.
- **A new logo.** An orange tabby face whose forehead stripes are tabs, drawn as a vector. The island's cat and the app icon use the same shapes, and the cat still blinks.
- **A new website** at https://claude-tabby.vercel.app:
  - generated art: a wall of terminals that lights up under your cursor, with a short looping animation;
  - real Tabby Island renders, the tile grids and 18 of the themes;
  - the one-line install.
- `TABBY_SNAPSHOT_BACKDROP=none` renders island snapshots on a transparent background.
- The terms' website clause is worded more simply. Nothing in it changed, so there's nothing to accept again.

## 0.2.7 — 2026-09-26

- **Tiling handles full-screen windows.** A full-screen window lives on its own desktop, so it was never on screen next to the others, and resizing it only shrank it inside its own black desktop.
  - With Accessibility, tabby now takes each session window out of full screen, waits until it's back on the desktop, splits its tabs, then arranges them all.
  - Without Accessibility, full-screen windows are left alone, never shrunk.
  - Accessibility only lists the current desktop's windows, plus a title-bar strip in full screen, so tabby finds a window by its title or frame, not by position in that list.
- **`/tab tile` gets 60 s** in its hook. Switching desktops takes a moment per window, and at 10 s the hook was cut off.

## 0.2.6 — 2026-09-26

- **Tiling checks that Terminal really came to the front.** On current macOS, the app you were in can take the front back within a second, and then Terminal's windows can't be read or split. tabby now:
  - confirms Terminal's windows are on screen before touching anything, and asks for the front again if it's lost for a moment;
  - otherwise stops with "Terminal didn't stay in front", instead of skipping every session with a misleading note.
- The whole tile stays well inside the 10 s limit of `/tab tile`.
- **Bold text** copies each tab's actual text color, which Terminal keeps in its own color space, so bold is exactly as bright as normal text.

## 0.2.5 — 2026-09-26

- **Tiling from Tabby Island works again.** macOS tied the island's Accessibility and Automation permissions to the exact build that received them, and every rebuild changes an ad-hoc signature's hash. System Settings kept showing Tabby Island as allowed, but macOS silently refused it, so tabs were never split.
  - The island is now signed with a stable requirement (its bundle id), so permissions survive rebuilds.
  - "Allow Accessibility" clears the island's stale entries first, so macOS asks again and the new permission sticks.
- **Tiling never squeezes a tab again:**
  - tabby now waits until Terminal is really in front, which takes a moment when its windows are on another desktop, and until Accessibility sees the right window.
  - It counts a window's tabs directly and moves a session out of a tab group until it's alone.
  - Then only windows that are on screen are placed, never a background tab.
- **Without Accessibility, tiling still arranges every separate window.** Only background tabs stay put, with a note on what to allow. Before, two separate windows that happened to share a frame, both maximized for example, were mistaken for tabs and skipped, so nothing moved.
- **Bold text is readable in Terminal.app.** Terminal draws bold text in the profile's own bold color, which no escape code changes. A light profile such as Man Page, whose bold is black, made bold text vanish on a dark tabby background. tabby now sets each tab's bold color to its text color, and puts the profile's back when the session ends.

## 0.2.4 — 2026-09-26

- **Terminal.app windows and tabs finally show only the session name.** The 0.2.0 setting never took effect. Terminal reads its preferences only at launch, and rewrites them from memory, so they were lost.
  - Now each Claude tab switches, while its session runs, to a copy of its own profile named "<profile> · tabby". The copy has the same font and look, with the folder, process, arguments and size left out of the title.
  - The window reads `🟢 ✳ Stripe Webhook Retries`, not `wildcat — 🟢 ✳ Stripe Webhook Retries — caffeinate ◂ claude --dangerously-skip-permissions — 80×24`, and so does a tab in a tab group.
  - The tab goes back to its own profile when the session ends (not on `/clear`), or with `/tab off`.
  - The switch runs in the background. The first time a profile is used, Terminal opens and closes a window for a moment to import the copy, and focus goes straight back to your window.
  - `tabby terminal-titles off`, and uninstall, put every tab back and delete the copies. `tabby doctor` lists them.

## 0.2.3 — 2026-09-26

- **Tiling really separates tabs now.** In a macOS tab group each tab keeps its own window frame, and the window shows the selected tab's frame. Resizing a tab from outside only squeezed its terminal inside the shared window; that is the bug you saw.
  - Nothing is resized until every session has its own window. Each session's tab is brought forward and, if "Window › Move Tab to New Window" is enabled (it shares the window), it is moved out.
  - Detection no longer resizes anything, and only the sessions' own windows are ever touched.
  - Minimized session windows are restored and included.
  - Resizes go out in one batch.
- **Without Accessibility** (needed to split tabs), sessions that share a window as tabs are left untouched instead of half-moved, and tabby says what to enable.

## 0.2.2 — 2026-09-26

- **Contrast re-check, now including Claude Code's own UI.** Claude draws colored text (dim gray, suggestions, its orange, diff words) from its dark or light palette, designed for a black or white background.
  - The audit now scores every theme on how much of that contrast it keeps; 30 of 57 keep at least 80% (✓).
  - Tabby Dusk and Ember are slightly darker so they keep 84%, up from 78%.
  - Automatic theme variety now only picks Claude-friendly dark themes.
- **Mismatch warning:** picking a light tabby theme while Claude runs its dark theme (white text), or the reverse, warns in `/tab`, `tabby doctor` and the island's theme menu.
- **Status line:** the context meter's colors (accent, amber, red) now keep at least 3:1 contrast on every theme's background, including light ones.
- **Website:** theme cards show a "Claude ✓" badge.

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
