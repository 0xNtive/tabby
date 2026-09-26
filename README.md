<p align="center">
  <img src="brand/logo.svg" width="112" alt="tabby: a geometric orange tabby cat whose forehead stripes are tabs">
</p>

<h1 align="center">tabby</h1>

<p align="center"><b>Every Claude Code tab, at a glance.</b><br>
An AI-written name, a calm color and a live status for every Claude Code session, right in your terminal's tab bar.<br>
Free, local and native to Claude.</p>

<p align="center"><a href="https://claude-tabby.vercel.app">Website</a> · <a href="#install">Install</a> · <a href="#use-it">Commands</a> · <a href="#tabby-island">Island</a> · <a href="docs/contrast.md">Contrast audit</a> · <a href="TERMS.md">Terms</a></p>

```
🟢 ✳ Stripe Webhook Retries    🔵 ◐ Dark Mode Settings    🟣 🔔 Flaky Auth Tests    🟠 ✳ Release Notes
```

Running five Claude sessions at once, every tab looks the same. tabby gives each tab:

- **a name** that Claude Haiku writes from what you're doing, in about 2 s;
- **a color**, and a background tinted to match, distinct from your other open sessions;
- **a live status** in the title: `◐` working (animated), `✳` your turn, `🔔` needs you (blinking);
- **a watermark**: the topic in large, faint letters over its Terminal window (macOS);
- **one-line control** with `/tab`, launch flags, keyboard shortcuts and a macOS island with its own Settings.

## Install

```sh
curl -fsSL https://github.com/0xNtive/tabby/raw/main/install.sh | bash
```

One command, about 20 seconds. It adds the plugin to Claude Code, shows the [terms](TERMS.md) (short version: local, free, no telemetry) and runs the setup below. On a Mac it also builds Tabby Island and asks macOS for Accessibility, which tiling needs to split tabs and bring full-screen windows back. Needs Node 18+ and Claude Code; add `-s -- --yes` after `bash` to accept the terms without a prompt.

Or inside Claude Code:

```
/plugin marketplace add 0xNtive/tabby
/plugin install tabby@tabby
/reload-plugins
/tabby:setup
```

Setup changes only these, backs up `settings.json` first, and `tabby uninstall` reverts all of it:

| What | Why |
|---|---|
| `CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1` | tabby draws the title (color marker, animated status) instead of Claude |
| a `statusLine`, only if you don't have one | name, color and context meter inside Claude |
| `~/.claude/commands/tab.md` | the short `/tab`; plugin commands are namespaced as `/tabby:tab` |
| a 3-line block in `~/.zshrc` / `~/.bashrc` | the `claude --tab --color --theme` flags and the `tabby` command |
| Terminal.app: each Claude tab uses a "<profile> · tabby" copy of its profile while it runs | windows and tabs read `🔵 ◐ Dark Mode Settings`, not `api — 🔵 ◐ Dark Mode Settings — caffeinate ◂ claude --dangerously-skip-permissions — 80×24` |
| `~/.claude/tabby/bin/tabby.mjs` | a launcher that always runs the newest installed copy |

Later, `tabby island accessibility` asks for the island's permission again, and `/tabby:setup island` builds the island from inside Claude (Xcode Command Line Tools).

Other ways to install:
- **From a checkout:** `git clone https://github.com/0xNtive/tabby && node tabby/bin/tabby.js install`.
- **One session only:** `claude --plugin-dir ./tabby`.

To remove it: `tabby uninstall`, or `/plugin uninstall tabby@tabby`.

## Use it

In Claude. `/tab` is answered by a hook: it's instant and never costs tokens.

```
/tab Auth refactor           rename (pauses AI naming)     /tab auto       back to AI names
/tab color teal              red orange yellow green teal blue purple pink · next · #hex
/tab theme nord              this tab                      /tab theme nord all   every tab
/tab ls                      every session: status, context, summary
/tab note waiting on design  a note shown in the island
/tab watermark off           hide the watermarks (on brings them back)
/tab reset · /tab off · /tab on · /tab themes · /tab colors
```

At launch:

```sh
claude --tab "Auth refactor" --color teal --theme nord
claude -n "Auth refactor"                       # Claude's own flag works too; so does /rename
tabby new ~/Dev/api -n "API" --color green      # open a new tab running claude
```

Anywhere:

```sh
tabby ls              # every running session: name, status, context %, summary
tabby next            # jump to the next session that needs you
tabby focus 2         # jump to session 2
tabby tile 4          # fill the screen with 2, 3, 4, 6 or 8 session windows (tabs and full-screen windows become windows)
tabby themes          # preview all 57 themes
tabby doctor          # what works in this terminal
```

## Tabby Island

A Dynamic-Island-style overlay at the top center of your Mac.

- **Collapsed:** one dot per session. Working dots ping and waiting ones ring; a short announcement pops up when a session finishes or needs you.
- **Hover to expand:** every session's name, status and context meter.
- **Actions:** click a row to jump to that terminal tab; right-click it to rename, recolor or re-theme.
- **Modes:** Minimal (one line per session), Standard, and Detailed (summary, last prompt, tokens and cost for every session).
- **Watermark:** each Terminal.app session's topic in large, faint letters over its window, in the session's color. Clicks and typing go straight through; it follows the window as you move it, and fades while you drag.
- **Settings** (⌃⌥, or the menu-bar icon): the island, tab names, tint, markers, theme for every tab, the watermark's strength, size, color and position, and every shortcut.
- **Shortcuts,** all changeable in Settings › Shortcuts:

  | Shortcut | Action |
  |---|---|
  | ⌃⌥Space | open with the keyboard (↑↓ ↩, esc) |
  | ⌃⌥N | next session that needs you |
  | ⌃⌥1–9 | jump to a session |
  | ⌃⌥G | tile windows |
  | ⌃⌥M | switch mode |
  | ⌃⌥W | watermark on or off |
  | ⌃⌥, | Settings |

`tabby island` starts it; `tabby island login` (or Settings › Open at login) launches it at login. It idles under 1% CPU.

The watermark asks Terminal which window shows which session, so macOS asks once to let Tabby Island control Terminal.

Tiling from the island splits tabs into windows only with Accessibility for Tabby Island. If macOS shows it as allowed but tabs still don't split, click the island's "Allow Accessibility" notice: it clears permissions left over from an earlier build, and macOS asks again.

## Colors that don't hurt

- **Contrast stays fixed.** A session's background is its theme's background, shifted toward the session color in OKLCH at the same lightness, so text contrast doesn't move. tabby also never lets a tint make text less readable than the theme itself.
- **Every theme is WCAG AA or better,** and cursors stay at 3:1 or more. Tests enforce both, and the numbers are in the [contrast audit](docs/contrast.md).
- **Claude's own UI stays legible.** Claude Code draws its own colored text (dim gray, suggestions, its orange, diffs). 30 themes keep at least 80% of its intended contrast, including all five of tabby's own; they're marked ✓ in the audit, and automatic theme variety only uses them.
- **Match the mode.** Claude's dark theme (the default) draws white text, and its light theme black. With a light tabby theme, switch Claude to light with `/theme`. tabby warns you if they don't match.
- **No two open sessions share a color.** A project gets its last color back when that color is free.
- **57 themes in six groups:**
  - **Signature:** Tabby Dusk, Midnight, Ember, Paper, Mist.
  - **Calm:** Nord, Everforest, Kanagawa, Rosé Pine, Catppuccin Frappé and Macchiato, Flexoki, Iceberg, Selenized, Gruvbox Material and more.
  - **Classic:** Catppuccin Mocha, Tokyo Night, Gruvbox, One Dark, Oxocarbon, Poimandres and more.
  - **Vivid**, **Light** and **High contrast** (Modus).

Tuning options:

| Command | Effect |
|---|---|
| `/tab strength subtle\|medium\|bold` | tint intensity |
| `tabby config auto themes` | a different theme per session |
| `tabby config animate false` | turn off the title spinner and bell |

## Terminal support

| | title | background | tab color | jump to tab | tile |
|---|---|---|---|---|---|
| Terminal.app | ✓ only the name ([how](#how-it-works)) | ✓ (bold text too) | emoji marker | ✓ | ✓ (tabs → windows with Accessibility) |
| iTerm2 | ✓ | ✓ | ✓ native, pulses when waiting | ✓ | ✓ |
| Ghostty, WezTerm, kitty, Alacritty | ✓ | ✓ | emoji marker | – | – |
| VS Code / Cursor | ✓ with `"terminal.integrated.tabs.title": "${sequence}"` | ✓ | emoji marker | – | – |
| tmux | window name | pane style | status-bar color | ✓ | – |

## How it works

- **Hooks.** `SessionStart`, `UserPromptSubmit`, `Stop`, `Notification`, `PermissionRequest`, `PostToolUse` and `SessionEnd` keep `~/.claude/tabby/sessions/<id>.json` up to date. They write OSC escape codes straight to the session's TTY. Everything after the prompt is an async hook; the per-tool fast path is a ~10 ms shell script.
- **Names.** A background `claude -p --safe-mode --model haiku` call (thinking off, no hooks, plugins or MCP) returns a 2–4 word title and a one-line summary. It's handed back to Claude via the hook `sessionTitle` field, so `/resume` shows it too. `tabby config namer heuristic` names tabs with no model call.
- **Animation.** While a session works or waits, one small background process redraws those titles about 6 times a second, then exits a minute after everything is idle.
- **Status** comes from the hooks, plus Claude's own session registry. **Context** comes from the status line, or else from the transcript.
- **Terminal.app titles.** Terminal adds the folder, process, arguments and size to every title, and reads its title settings only at launch. So while a session runs, its tab uses a copy of its own profile ("Basic · tabby") with just those title parts turned off. The copy is imported once per profile, which opens and closes a Terminal window for a moment. `tabby terminal-titles off` puts the tabs back and deletes the copies.
- **Exit.** On exit a tab gets its profile colors back (`OSC 110/111/112`), and in Terminal.app its own profile; `/clear` keeps its identity.

State lives in `~/.claude/tabby`; the log is `~/.claude/tabby/tabby.log`.

## Privacy, cost and terms

- **Nothing leaves your machine except the naming request,** which goes to Claude Haiku through your own Claude Code login: about 500 tokens (roughly $0.001), covered by Pro and Max.
- **No servers, no telemetry.**
- tabby is free. Future versions may show clearly labeled sponsored messages in tabby's own UI, never in your prompts, conversations or model context. See the [Terms of Use](TERMS.md), which setup asks you to accept.
- tabby is an independent project, **not affiliated with Anthropic**. Claude is a trademark of Anthropic.

## Develop

```sh
npm test                 # node --test, zero dependencies
npm run export           # regenerate docs/contrast.md and site/themes.json from lib/themes.js
bash island/build.sh     # build the island (Xcode Command Line Tools)
"island/build/Tabby Island.app/Contents/MacOS/TabbyIsland" --snapshot /tmp/snaps   # render the island to PNGs
claude --plugin-dir .    # try local changes in one session
```

The website lives in `site/` (static, deployed to Vercel). See [CONTRIBUTING.md](CONTRIBUTING.md) and the [changelog](CHANGELOG.md).

MIT © 2026 tabby contributors
