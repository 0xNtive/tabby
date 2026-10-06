# Changelog

## 0.4.1 — 2026-10-06

Tiling fixes:

- **Windows no longer overlap on a second display.** macOS reports a second display's usable area without its menu bar (every display has one when displays have separate Spaces), so the first row was placed under it and pushed down into the next. tabby now leaves the menu bar out itself.
- **A window Terminal rounds up fits its cell.** Terminal sizes windows in whole rows and columns, sometimes one more than asked; such a window overlapped the one below. tabby now asks for a little less until it fits.
- **No false "Allow Accessibility".** When sessions were left in place because their windows sit on another desktop or in full screen, the note mentioned Accessibility and the island read it as a missing permission, asking you to allow what was already allowed. The note now says what happened, and the island asks for Accessibility only when the permission is really missing.
- **Windows on another desktop come along more often.** Before Terminal is brought forward, the windows that aren't on screen are made its front windows, so macOS switches to their desktop rather than staying on one that already shows a Terminal window.

## 0.4.0 — 2026-10-05

tabby is now labeled **beta** (the website, the README, the island's Settings and About).

**Focus mode can stay on when it's your turn.** Tick **Stay covered when it's your turn** in Settings › Focus, or type `/tab focus-mode idle on`. When Claude is done, the window keeps its cover: the topic, one line saying it's done and how long ago, and a **Your turn** button in the session's color. Click it to open the window and reply.

- Windows where Claude asks a question or hits an error still open on their own, and the window you're typing in is never covered.
- The Settings preview shows both states in turn while the box is ticked.
- It's off by default: without it, Focus mode works as before.

**Privacy and security audit.** Every part was read for what it sends, stores and trusts. Nothing was sending your content anywhere it shouldn't, and these are fixed:

- **tabby's files are yours alone.** `~/.claude/tabby` (session names, the last few prompts, settings, the log) is now readable only by your account; existing folders are tightened the next time tabby runs.
- **The naming request sends less.** It no longer includes the folder's path, only its name, and the prompt is passed on stdin, so other accounts on the machine can't see it in the process list.
- **`namer heuristic` and `off` now always mean no model call.** `/tab auto` and `/tab reset` used to ask the model anyway; with `heuristic` they name the tab on your machine.
- **Names can't carry control characters into a terminal.** Titles and summaries from the model, folder names, `--tab` names and Claude's own session names are stripped of escape sequences and bidi overrides before they reach a title, the status line or `tabby ls`. In tmux, `#` in a name is no longer expanded.
- **A broken `settings.json` is left alone.** If it isn't valid JSON, setup no longer rewrites it. A symlinked `settings.json` stays a symlink and keeps its permissions.
- **`/tab` runs no shell when its hook is off.** The fallback command no longer pre-approves `sh`; it says how to turn tabby back on.
- **The installer** pins the Node.js it downloads (when a machine has none) to one version with its SHA-256 written in the script, and can't act on a download that was cut short.
- **Tabby Island** validates what it reads from session files before using it: a tty must be a device path, a transcript must be a regular file inside Claude's projects folder, and numbers of any size no longer crash it. It no longer writes command arguments to the system log, a hand-edited shortcut needs ⌃, ⌥ or ⌘, and it never falls back to running a CLI from `~/Dev/tabby`.
- **Releases** are built only from commits on `main`, their files are never replaced, and each zip has a build attestation: `gh attestation verify TabbyIsland.zip --repo 0xNtive/tabby`.
- **A test keeps it that way:** the build fails if network code appears anywhere but the updater and the island download, and the island has none at all.

Known and not fixed yet: Tabby Island isn't notarized (the project has no Apple Developer ID while in beta). [SECURITY.md](SECURITY.md) says what that means and what tabby trusts.

**Website.**

- A new social card, and a search pass: title, description, structured data, `robots.txt`, a sitemap and `llms.txt`.
- No third-party requests except the GitHub star count: fonts are served from the site, and a Content-Security-Policy blocks everything else.
- The pattern behind "Let Claude install it" no longer runs under the text.
- The answer to "What leaves my machine?" now lists exactly what the naming request contains.

## 0.3.2 — 2026-09-28

Tabby Island fixes from the adversarial review:

- **End Session can't be double-clicked through.** The red button in the confirmation waits a moment (longer than a double-click) before it takes a click, and looks dimmed until then.
- **Focus mode:**
  - covers stop below Terminal's tab bar, so tabs stay visible and clickable (it now knows which windows have tabs);
  - a full-screen window under the notch is recognized;
  - subagents that finished, hit an API error or were interrupted no longer show as running;
  - spinners only tick while a cover can be seen;
  - clicking a cover opens the session that window shows now, and only real session windows count as "the one you're typing in".
- **Nothing keeps running after Settings closes.** The Focus preview's spinner and the once-a-second permission check used to run on after the window closed. The status file is only written when something changes.
- **Permissions:**
  - "Ask Again" for Terminal, iTerm2 or System Events no longer resets every other Automation permission. It opens System Settings › Automation at the right switch.
  - "Allow All" only shows while there's something it can ask.
  - Background checks keep going, so a terminal opened later is noticed.
- **Quick launch** finds a recent folder typed as a full path (or with a trailing slash), and lists up to 200 folders.
- **A failed End Session is announced** in the island, not just shown in a card that can disappear.
- **The island follows `CLAUDE_CONFIG_DIR`** (setup records it), for sessions, its status file and updates.

## 0.3.1 — 2026-09-28

**Update from wherever you are.** When a new version is out, Tabby Island shows an **Update** button (also in its menu-bar menu and Settings › General › Updates), a new Claude session mentions it once a day, and `/tab update` or `tabby update` get it from Claude or a terminal. An update gets the plugin, refreshes the parts of setup you have (nothing you turned off comes back) and the island, which restarts on the new version. `tabby update --check` only looks. The check asks github.com for the latest release at most every 6 hours and sends nothing about you; `tabby config updateCheck false` turns it off.

**Fixes from an adversarial review of 0.3.0:**

- **The terms prompt couldn't be answered on a Mac.** With `curl … | bash` (and `tabby install` in a shell), it said "Nothing was changed" before you could type. It waits for your answer now, and CI answers it through a pipe on every change.
- **A `claude` alias broke every new terminal.** With `alias claude='claude --dangerously-skip-permissions'`, or Claude Code's old local installer, tabby's shell lines were a syntax error. They work alongside the alias now, and `tabby new --color/--theme` reach the new session.
- **Tabby Island installs are safe to run at once and never go backwards.** Before, an island that was ahead of its release could be re-downloaded and restarted on every session start, and two installs at the same time could corrupt it. Now it's one install at a time, the copy is made before the island quits, and an older download never replaces a newer island.
- **doctor respects your choices.** An island you skipped (`--no-island`), a login item you turned off, or an island you quit is reported, not "fixed". A missing island is a warning, not a failure.
- **Uninstall is honest.** It finds `claude` like the installer does and says when the plugin wasn't removed. It leaves `CLAUDE_CODE_DISABLE_TERMINAL_TITLE` alone if you had set it before tabby.
- **Installer:**
  - `CLAUDE_BIN` for a Claude Code in an unusual place;
  - every plugin error is shown, not just the last;
  - an install made without git switches to GitHub once git works, so it keeps updating;
  - Node found through a version manager is remembered as its real binary, so hooks keep working in projects pinned to an old Node.
- **`CLAUDE_CONFIG_DIR`:** the install guide, the "fix tabby" skill and the island follow it.
- **Safer launching.** `tabby new --dangerous` refuses a folder it only guessed from part of its name, and `--dangerous=false` means off. `tabby ls` numbers sessions (for `tabby focus 2` and `tabby tile --only 1,3`), `tabby tile active` and `/tab tile screens` work, and `tabby new --list --limit` shows more folders.
- `tabby island login --off` no longer stops the running island, and `tabby island stop` sticks until you start it again.

## 0.3.0 — 2026-09-28

**Install, fireproofed.** A fresh install could fail on a Mac that isn't set up like a developer's: Claude Code's own installer ships without Node.js, the island had to be compiled with Xcode's tools, and a failure printed one easy-to-miss line.

- **Let Claude install it.** Paste "Install tabby for me: run `curl -fsSL https://claude-tabby.vercel.app/install.md` and follow it." into Claude Code. Claude shows you the terms, runs the installer, checks every piece and walks you through the Mac permissions. Later, "fix tabby" does the same checks (a new `doctor` skill).
- **`tabby doctor`** checks every part of the install and gives the fix for each: a command to run, or what to do. `--json` is what Claude reads.
- **The installer** (`curl -fsSL https://claude-tabby.vercel.app/install | bash`):
  - finds Claude Code and Node.js wherever they're installed;
  - sets up a private, checksum-verified Node.js 22 when there's none;
  - installs without git when a Mac has no developer tools;
  - logs every step to `~/.claude/tabby/install.log` and never hides a failure;
  - ends with `tabby doctor`.
- **Node.js, found anywhere.** Hooks, the status line and the `tabby` command start through a small launcher that finds Node.js (Homebrew, nvm, Volta, mise, fnm, asdf or the private copy), so Claude started from the Dock or an editor works too. With no Node.js at all, hooks stay silent and a session start says how to fix it.
- **Tabby Island arrives ready to run.** It's downloaded from the GitHub release (universal, SHA-256 checked) into `~/Applications`, opens at login, and starts with your Claude sessions. When tabby updates, it fetches the matching island in the background. Building it locally is now only the fallback.
- **Permissions that always prompt.** macOS only asks about an app that's running, and the island never started Terminal first, so its Allow button could do nothing. Now it starts the app first. It also asks only for what your terminal needs (nothing for VS Code, Cursor, Ghostty or Warp; iTerm2 has its own card), has **Allow All**, and keeps checking in the background until everything is allowed.
- `/tabby:setup` also installs the island on a Mac, and `tabby uninstall` now removes the island, its login item and the private Node.js too. The terms prompt takes Enter for yes.

**Focus mode.** While Claude works, each Terminal window you're not in shows only its topic in a big box, with one line per running agent (Claude and its subagents): a spinner, what it's doing, and for how long. A window opens again when Claude needs you or it's your turn, and the one you're typing in is never covered. Settings › Focus, the menu-bar menu, or `/tab focus-mode on`.

**Hover a session for the full picture.** In every mode, resting on a session opens a dropdown with what it's doing or waiting for (and what to do about it), its current task, summary, your last prompt, tokens and cost, folder and terminal. Before, hovering changed little, and nothing for sessions tabby hadn't tracked yet.

**End a session from the island,** from its dropdown or right-click menu. It always asks first, names the session, and checks it's really that Claude process before stopping it. Then it closes the tab (iTerm2 by script, Terminal.app by a clean `exit`).

**Your screens, your choice.**

- Tiling knows every display: the screen you're on, all of them, or the ones you pick in Settings › Windows. Pick only a vertical monitor, for example, and your main screen stays free. Sessions spread by screen size, and a portrait screen stacks rows.
- Tile every session, only the active ones (working or waiting on you), or pick them: **Tile Active Sessions** and **Choose Sessions…** in the tile menu; `tabby tile --active`, `--only 1,3,auth`, `--screens`; `/tab tile active`.

**Quick launch.** ⌃⌥L (or **New Session…** in the menu-bar menu) opens your recent and most-used folders. Type to filter, add a name, press Enter, and a new window runs Claude there, on your chosen screen. **Skip permissions** (⌘D) adds `--dangerously-skip-permissions`; it's remembered and warns you while it's on. `tabby new <folder or recent name> [--dangerous]`, `tabby new --list`.

**Open source housekeeping.** A new README, issue and pull request templates (bug reports ask for `tabby doctor`), a security policy, a code of conduct, a contributor guide with the architecture and release steps, and CI that runs the whole installer on clean macOS and Linux machines.

## 0.2.13 — 2026-09-27

- **Working or idle, at a glance.** A working session's dot now turns inside a ring of its own color, a session waiting for your next prompt rests dimmed, and one that needs you keeps its amber ring. Every row says it in words too: "Working 3m", "Your turn", "Needs you" or "Error", each in its own color, in all three modes.
- **Progress, not context, gets the bar.** A working session shows how far along it probably is, and how long it has left:
  - "2 of 5 tasks · ~3m left" when Claude keeps a task list; Detailed mode (and hovering in Standard) shows the task it's on;
  - otherwise "~2m left · usually 6m", from how long that session's turns take;
  - "Longer than usual (6m)" once it runs past that.
- **How the estimate is made:**
  - tabby's hooks now time every turn, leaving out time spent waiting on you (a permission, a question), and keep the last 24;
  - until they've timed three, past turns come from the transcript's timestamps, read once and then only as it grows;
  - a brand-new session starts from every session's median.
- **Context used is a percentage** with a small ring: amber from 70%, red from 90%, with tokens and cost beside it in Detailed mode. Claude's status line and `tabby ls` show it as a number too, instead of a bar.

## 0.2.12 — 2026-09-27

- **The island's controls moved to the top,** right under the notch: the session count, the mode picker, tiling, the theme for every tab and the Settings cog. The island grows downward, and rows open up as you hover them, so a bar at the bottom moved while you reached for it. The top never moves, and it's where the pointer comes in.
- The keyboard hint still shows at the bottom while the island has keyboard focus.

## 0.2.11 — 2026-09-26

- **No surprise permission prompts.** The island talks to Terminal (tab titles, the watermark's windows) only once macOS allows it. Before, the first background read could pop up macOS's "control Terminal" prompt at launch, in the middle of the setup window. Now every prompt follows a click: Allow in the setup window, Settings › Permissions, the Watermark pane, or clicking a session.
- Once Terminal is allowed, the island reads its tabs right away, so watermarks appear within a second.

## 0.2.10 — 2026-09-26

- **A setup window, like installing a Mac app.** It's in tabby's colors and has three steps:
  - **Welcome:** what the island, tiling and the watermark do.
  - **Permissions:** Accessibility, Control Terminal, Control System Events and Open at login. Each has an Allow button, and its status updates live (Allowed, Waiting…, Not allowed) as you answer macOS.
  - **You're set:** the shortcuts to start with.
- **When it opens:**
  - The installer and `/tabby:setup island` open it.
  - It shows once on the island's first launch, without taking focus from what you're typing in.
  - `tabby island onboarding` and **Setup & Permissions…** in the island's menu open it again.
  - Closing it shows "tabby lives here" in the island.
- **Getting past a refused permission.** A denied permission offers Ask Again, which clears the island's old answers so macOS asks again, and Open System Settings. This also fixes permissions left over from builds before 0.2.5.
- **Settings › Permissions:** the same live checks, any time.
- **A Settings cog** in the expanded island's footer. In the narrow Minimal mode, the theme button shrinks to its icon to make room.
- The Automation prompt explains what the island does with Terminal: tabs, titles, the watermark and tiling.

## 0.2.9 — 2026-09-26

- **Watermark.** Tabby Island writes each Terminal.app session's topic in large, faint letters across its window, in the session's color.
  - Clicks and typing go straight through, and the island never takes focus.
  - It follows the window: it fades while you drag or resize, and comes back when you let go.
  - Background tabs, minimized windows and other desktops don't show it; full-screen windows get it on their own desktop.
  - Turn it on or off with ⌃⌥W, `/tab watermark on|off`, or the island's menu. Strength (18% by default), size, color and position are in Settings.
  - It asks Terminal which window shows which session, so macOS asks once to let Tabby Island control Terminal.
- **Settings window** (⌃⌥, or the menu-bar icon). It has three panes:
  - **General:** the island, mode, announcements, open at login, and tabby's own settings (theme for every tab, background tint, title marker, tab names, animation, Terminal.app titles);
  - **Watermark**, with a live preview;
  - **Shortcuts.**
- **Every shortcut can be changed.** Click one in Settings › Shortcuts and press the new keys. Delete removes it; Restore Defaults brings the originals back. New shortcuts: ⌃⌥W watermark and ⌃⌥, Settings; in the island, W and , do the same. They're saved as `islandShortcuts` in config.json.
- **Open at login** now runs the launcher, so it keeps working after an update. Before, it pointed at one version's folder.
- **Faster reads of Terminal's tabs.** Titles and windows come in three Apple events for all tabs, instead of a few per tab: about 6× faster, in the island and the CLI.

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
