# Tabby Island

A Dynamic-Island-style overlay for Claude Code sessions: a black pill that hugs the notch
(or the top of the screen) and expands into a list of every running session. SwiftUI for
layout, AppKit for the window and hover tracking, and Core Animation for anything that
loops.

```sh
bash island/build.sh                                   # ~15 s; Xcode Command Line Tools
open "island/build/Tabby Island.app"                   # or: tabby island
"island/build/Tabby Island.app/Contents/MacOS/TabbyIsland" --dump        # what it would show, as JSON
"island/build/Tabby Island.app/Contents/MacOS/TabbyIsland" --snapshot /tmp/snaps   # render PNGs
```

`build.sh` copies `AppIcon.icns` into the bundle and stamps `CFBundleShortVersionString` with
the version in `package.json`, so the About panel shows tabby's version.

## What it shows

- **Collapsed:** one dot per session in start order (colored with the session's `dot`).
  Working dots ping, waiting dots get a blinking amber ring, errors a red ring. The right
  ear shows a bell and the waiting count, else a spinner and the busy count, else the
  session count.
- **Expanded (hover, or ⌃⌥Space):** the list, ordered needs-you → error → working → your
  turn. Click a row to focus its terminal tab; right-click or hover "…" to rename, recolor or
  re-theme. The footer has the cat, the "tabby" wordmark and the session count, then the
  mode picker, the tile button and the theme-for-all-tabs button.

### Modes (`islandMode` in `~/.claude/tabby/config.json`)

| Mode | Each session shows |
|---|---|
| Minimal | one 30 pt line: dot, title, context % |
| Standard (default) | title, project · model · time, context bar; hovering a row adds the summary, note, last prompt and status line |
| Detailed | everything, always: title and a status chip ("working 4m", "your turn", "needs you · permission"), project · model · time, context bar with "452k / 1M tokens · $3.20", summary (2 lines), note, last prompt (1 line); rows get separators |

Switch with the footer's three-icon picker, the status menu's **Mode** submenu, or ⌃⌥M. The
choice is written with `tabby config islandMode '"detailed"'` and applied at once (the island
keeps the new value until config.json agrees, so a slow or failed CLI never flips it back).

### Shortcuts (`islandHotkeys`, default on; `islandShortcuts`)

Global shortcuts use Carbon `RegisterEventHotKey`, which needs no Accessibility permission.
Every one can be changed or removed in Settings › Shortcuts (click it, press the new keys;
Delete removes it, Esc cancels). A new shortcut needs ⌃, ⌥ or ⌘ (F-keys excepted) and can't
collide with another of the island's.

| Default | Action (`islandShortcuts` key) |
|---|---|
| ⌃⌥Space | open the island with keyboard focus; again to close (`toggle`) |
| ⌃⌥N | next session that needs you: waiting (oldest first), then your turn and errors (most recent first); press again to cycle (`next`) |
| ⌃⌥1 … ⌃⌥9 | focus session N in list order; the status menu shows the numbers (`jump`: its modifiers apply to all nine digits) |
| ⌃⌥G | tile session windows, `tabby tile` (`tile`) |
| ⌃⌥M | cycle the mode; the pill says which one while collapsed (`mode`) |
| ⌃⌥W | watermark on or off (`watermark`) |
| ⌃⌥, | open Settings (`settings`) |

`islandShortcuts` holds only what differs from the defaults, as `"ctrl+opt+w"`-style specs
(`ctrl`, `opt`, `shift`, `cmd`, then a letter, digit, punctuation, `space`, `return`, `tab`,
an arrow or `f1`–`f12`); `""` turns one off:

```sh
tabby config islandShortcuts '{"watermark": "cmd+shift+w", "settings": ""}'
```

With keyboard focus the panel becomes key without activating the island (the terminal keeps
its menu bar), and a hint line appears in the footer:

| Key | Action |
|---|---|
| ↑ ↓ (Tab, ⇧Tab) | move the selection (the hover highlight) |
| ↩ | focus the selected session |
| 1–9 | focus that session |
| R | rename in place: ↩ saves, esc cancels, an empty name lets AI name it |
| C / T | color / theme menu for the selected session |
| M / G | cycle the mode / tile windows |
| W | watermark on or off |
| , | open Settings |
| esc | close and hand focus back to the previous app |

The status menu's **Keyboard Shortcuts** submenu lists all of this and has an **Enable Global
Shortcuts** toggle. A shortcut another app already registered is marked as in use there.
The keys are physical (ANSI) key codes. macOS also assigns ⌃⌥Space to "Select next source in
Input menu"; in testing the island's shortcut took precedence, but if pressing it switches your
keyboard layout instead, turn that shortcut off in System Settings › Keyboard › Keyboard
Shortcuts › Input Sources.

### Watermark (`watermark`, default on)

Each Terminal.app session's topic, large and faint, over its window: SF Rounded Heavy, as large
as fits in three lines without breaking a word, in the session's cursor color. It's a
transparent, click-through window that never becomes key, ordered directly above the session's
Terminal window with `order(.above, relativeTo:)`.

- **Which window is which:** the same AppleScript read that fetches tab titles also returns
  each tab's window id (on current macOS every Terminal tab is its own window, and Terminal's
  window ids are the window server's numbers). It's three Apple events for all tabs at once,
  every 6 s, or at once when a session's window isn't known yet (for its first 15 s) or an
  unknown Terminal window appears on screen (a tab tiling moved into its own window).
- **Following windows:** `CGWindowListCopyWindowInfo` (numbers, owners and bounds only: no
  Screen Recording permission) 4× a second while Terminal is in front, once a second
  otherwise, and at once on clicks, drags, app switches and desktop changes. A click that
  raises a Terminal window over its watermark puts the watermark back on top within ~20 ms.
- **Moving and resizing:** the watermark fades out while its window's frame changes and fades
  back 0.3 s after it settles (and the mouse is up).
- **Hidden windows:** a background tab, a minimized window or a hidden Terminal hides its
  watermark. A window on another desktop keeps its watermark there (overlays belong to the
  desktop they were ordered in, so switching back doesn't blink); a full-screen window gets its
  watermark on its own desktop.
- `/tab off` sessions get none.

| Setting | Values (default) |
|---|---|
| `watermarkOpacity` | 3–40 percent (18) |
| `watermarkSize` | `small`, `medium`, `large` (medium): the tallest line is 12, 19 or 28 % of the window |
| `watermarkColor` | `session` (the tab's cursor color) or `neutral` (the theme's text color) |
| `watermarkPosition` | `top`, `center`, `bottom` (center) |

Toggle it with ⌃⌥W, W with keyboard focus, the status menu's **Show Watermark**,
`/tab watermark on|off`, or Settings › Watermark (which also has a live preview).

### Settings

**Settings…** in the status menu (or ⌃⌥, or , with keyboard focus) opens a regular window with
three panes: **General** (show the island, mode, announcements, open at login, and tabby's own
settings: theme for every tab, background tint, title marker, tab names, animation and
Terminal.app titles), **Watermark** and **Shortcuts**. Like the menus, it writes through the CLI
(`tabby config …`, or the command that repaints every tab, such as `tabby strength subtle`), and
shows the new value at once. Open at login writes a LaunchAgent that runs the launcher
(`tabby island`), so it keeps working after updates.

### Announcements (`islandAnnounce`, default on)

While collapsed, when a session goes busy → idle the pill springs wider for about 4 s with
"✓ *title* is done" (green); when one starts waiting, "🔔 *title* needs you" (amber). Several
queue up (a newer one for the same session replaces the older one). Hovering the pill holds
the announcement and doesn't expand; clicking it focuses that session. Nothing is announced on
the first load or for sessions that just appeared, or while the list is expanded. Tiling
notices use the same pill; an Accessibility notice opens the right System Settings pane when
clicked. **Show Announcements** in the status menu toggles them.

### Motion

All of it respects Reduce Motion (springs become short fades; pops, sparkles, wiggles and
blinks are skipped).

- A collapsed dot pops (1 → 1.6 → 1) when its status changes, and a finished session gets a
  0.7 s ring-and-sparks burst in its color.
- The bell rings when the waiting count rises and wiggles gently every 6 s while anything
  waits.
- Rows fade and slide in with a small stagger; percentages and counts roll their digits.
- The footer cat blinks every 6–10 s (one Core Animation keyframe loop with random gaps),
  only while expanded.

### Themes and tiling

The per-session Theme menu and **Theme for All Tabs** have one submenu per group in
`themes.json` order (Signature, Calm, Classic, Vivid, Light, High contrast), with a swatch
chip (theme background plus four `dots`) and a checkmark on the current theme. The Color menu
uses `dots` swatches. Everything drawn on the black island uses `dot ?? accent`; a missing
`dot` is computed like tabby's `onBlack` (OKLCH lightness raised until 4:1 on #000).

The footer's grid button (and the status menu's **Tile Windows**) offers "Tile All Sessions
(N)" and 2 · 3 · 4 · 6 · 8 windows, running `tabby tile [n]`.

## Data it reads

- `~/.claude/sessions/<pid>.json`: Claude Code's live registry (status, waitingFor, times).
- `~/.claude/tabby/sessions/<sessionId>.json`: tabby's record (title, summary, note, theme,
  accent, `dot`, `cursor`, context, prompts, tty).
- `~/.claude/tabby/themes.json`: themes with `group`, `dots`, `tints`; parsed again only when
  its modification date or size changes.
- `~/.claude/tabby/config.json`: `theme`, `islandMode`, `islandAnnounce`, `islandHotkeys`,
  `islandShortcuts`, `watermark*`, and for Settings `namer`, `strength`, `marker`, `animate`,
  `terminalTabTitles`. The island writes only through `<node> <cli> …` (paths from
  `~/.claude/tabby/island.json`); a changed setting shows at once and is held until
  config.json agrees.

Missing files degrade gracefully: no themes means a fallback palette, no config means the
defaults, no CLI means settings apply in memory only.

## Snapshot QA

Screen Recording isn't needed: `--snapshot <dir>` renders the SwiftUI tree with
`cacheDisplay` over a sample wallpaper and writes cropped PNGs:

- `island-*.png`: live sessions, in these states: `collapsed`, `minimal`, `standard`,
  `detailed`, `hover` (standard, first row hovered), `keyboard` (detailed, second row
  selected), `keyboard-minimal`, `rename`, `announce-done`, `announce-waiting`, `announce-info`
- `demo-*.png`: the same states with five demo sessions covering waiting, error, working,
  your turn, notes and summaries
- `flat-*.png`: a display without a notch
- `brand-statusitem.png`, `brand-cat.png`, `brand-swatches.png`: the menu-bar template icon,
  the footer cat at 18/32/96 pt, and every theme swatch by group
- `settings-<pane>-<light|dark>.png`: each Settings pane (drawn without the window's own
  background, so the tab bar is transparent)
- `watermark-*.png`: demo sessions' watermarks over a mock terminal, in each size and position

Core Animation (pings, pops, blinks) isn't captured; snapshots show the resting state.

## Debugging

`TABBY_ISLAND_DEBUG=1` (run the binary directly) logs hotkeys, keyboard focus, keys,
announcements and tile output to stderr, and accepts commands as `dev.tabby.island.debug`
distributed notifications (object = command): `state`, `menu` (dump the status menu),
`about`, `keyboard`, `next`, `mode`, `tile[:n]`, `jump:N`, `rename`,
`announce:done|waiting|info`, `watermark` (toggle), `watermark:state` (each overlay's frame,
and whether it's directly above its window), `settings[:general|watermark|shortcuts]`,
`record:<action>`, `toggle-island`, and `key:<keyCode>[:<chars>]` (posted to the island's own
event queue). Without the variable none of this is installed.

## Performance

Budget: under 1% CPU collapsed and idle with several busy sessions. Measured on an M-series
MacBook Pro with 3 busy sessions: 0.1–0.3% collapsed, about 0.2% expanded (a brief ~1% blip
during the expand spring).

- Everything that loops is Core Animation, which the render server plays without waking the
  app: the busy ping, the waiting ring, the spinner, the bell wiggle, the cat's blink. (A
  SwiftUI `ProgressView` in the pill once cost ~4.5% CPU.)
- No SwiftUI timers or `TimelineView` run while collapsed. Rows use a 15 s `TimelineView`
  for relative times, but rows only exist while expanded.
- The store polls every second on a background queue and publishes only when the snapshot
  changes; `themes.json` is cached by modification date and size.
- Announcements, the dot pop and the sparkle are event-driven: a status change starts them,
  and they end on their own.
- Hover tracking uses global and local mouse monitors, plus a 10 Hz poll only while the
  pointer is over the island or it's expanded.
- The watermark's window check costs ~1 ms (4× a second only while Terminal is in front); with
  four sessions and the watermark on, the island measured 0.6 % while idle.

## Files

| File | What's in it |
|---|---|
| `TabbyIslandApp.swift` | entry point, `--dump`, status item, status menu, About panel |
| `IslandPanel.swift` | the non-activating panel, geometry, UI state, the controller (hover, expand/collapse, keyboard focus, inline rename, announcements, settings, hotkey wiring, tiling) |
| `IslandView.swift` | root view: header ears, announcement label, list, footer (brand, mode picker, tile, theme), keyboard hint |
| `SessionRows.swift` | the row in all three modes, status chip, context bar, rename field, entrance stagger |
| `SessionStore.swift` | the 1 s poller and the loader that joins the registry, tabby records, transcripts, themes and config |
| `Models.swift` | data types, modes, announcements, palette, OKLab/contrast math, formatting |
| `Components.swift` | Core Animation views: status dot (pop and sparkle), spinner, bell; menu swatches |
| `Brand.swift` | the cat's geometry (from `brand/logo.svg`), the template menu-bar icon, the blinking footer cat |
| `Hotkeys.swift` | Carbon global hotkeys |
| `Shortcuts.swift` | key combos (parse, display, menu keys), the shortcut actions and their defaults |
| `Watermark.swift` | watermark settings, drawing, the overlay window and the controller that follows Terminal windows |
| `Settings.swift` | the Settings window: General, Watermark (with a live preview), Shortcuts (with a recorder) |
| `Actions.swift` | tabby CLI calls, tab focusing (AppleScript), menus |
| `TerminalTitles.swift` | reads Terminal/iTerm tab titles (for sessions without a tabby record) and Terminal's window of each tab |
| `Snapshot.swift` | `--snapshot` renders and demo data |
| `Debug.swift` | the `TABBY_ISLAND_DEBUG` channel |
