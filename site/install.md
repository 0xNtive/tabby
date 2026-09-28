# Install tabby: instructions for Claude

You are Claude, in Claude Code, and the person you're helping asked you to install **tabby**. Follow these steps in order. Keep them posted in one short line per step, and do the work yourself: they shouldn't have to type commands.

tabby is a Claude Code plugin: every session's terminal tab gets an AI-written name, a calm color and a live status (working · your turn · needs you), `/tab` renames or re-themes a tab in one line, and on a Mac, **Tabby Island** lists every session in a Dynamic-Island-style overlay at the top of the screen. Open source (MIT): https://github.com/0xNtive/tabby

## Rules

- **Never accept the terms for them.** Show the summary, ask, and continue only after an explicit yes.
- No `sudo`, nothing outside their home folder. The installer only touches what `tabby uninstall` reverts.
- Give every Bash call a **10-minute timeout**: the installer may download Node.js and the island.
- `tabby` isn't a command in your shell yet. Once installed, run it as `sh ~/.claude/tabby/bin/tabby …` (written `T` below).
- Don't edit their Claude settings, shell files or Terminal profiles by hand. The installer does it and backs up `settings.json` first.

## 1. Look at the machine

```sh
uname -sm; sw_vers -productVersion 2>/dev/null; echo "terminal: ${TERM_PROGRAM:-unknown}"
```

- Windows outside WSL: tabby doesn't run there. Say so and stop.
- Remember the terminal (`Apple_Terminal`, `iTerm.app`, `vscode`, `ghostty`, `WarpTerminal`, …) for step 5.
- Tabby Island needs macOS 14 or newer. On older macOS and on Linux everything else still works.

## 2. The terms

Show them this, then ask whether they accept. Use your question tool if you have one, with the options "Accept and install", "Show the full terms" and "Cancel":

> **tabby Terms of Use (2026-09-25), the short version**
> - Runs locally. No servers, no telemetry. Tab names come from Claude Haiku through *your* Claude Code login.
> - Changes terminal titles/colors and a few Claude Code settings; `tabby uninstall` reverts them.
> - Free. Future versions may show clearly labeled sponsored messages in tabby's own UI (island, status line, CLI), never inside your prompts, conversations or the model's context, and never targeted using your code or prompts.
> - Provided as is, without warranty. Not affiliated with Anthropic.
>
> Full terms: https://claude-tabby.vercel.app/terms

If they want the full text, fetch https://claude-tabby.vercel.app/terms and summarize any section they ask about. If they decline, stop: nothing has been changed.

## 3. Run the installer

Only after they said yes (`--yes` records their acceptance):

```sh
curl -fsSL https://claude-tabby.vercel.app/install | bash -s -- --yes
```

It finds Claude Code and Node.js 18+, downloading a private Node.js if there's none. It adds the plugin, runs the one-time setup and, on a Mac, installs Tabby Island into `~/Applications` and opens its setup window. It ends with a `tabby doctor` report. If it fails, read `~/.claude/tabby/install.log` and use **Troubleshooting** below.

## 4. Check and fix

```sh
sh ~/.claude/tabby/bin/tabby doctor --json
```

It returns `{ ok, next, checks: [{ id, title, status, detail, fix }] }`, with status `ok | warn | fail | info | skip`. For each `fail`, then each `warn`, that has a `fix`:

- `fix.run`: run it. These are tabby's own commands.
- `fix.tell`: tell them what to do, in your own words, and wait for them.

Run doctor again until nothing is `fail`. Right after installing, a `warn` on **sessions** is expected: sessions that were already open (including this one) pick tabby up after `/reload-plugins` or a restart.

## 5. Tabby Island's permissions (macOS)

The island's setup window ("Welcome to tabby", dark teal) should be open. It asks only for what their terminal needs:

- **Terminal.app:** Accessibility, Control Terminal, Control System Events (for tiling, jumping to a tab and the watermark).
- **iTerm2:** Accessibility and Control iTerm2.
- **VS Code, Cursor, Ghostty, Warp and other terminals:** nothing. The window says so.

Tell them something like: "In the Tabby Island window, click **Get Started**, then **Allow All**. Click **Allow** or **OK** on each macOS prompt. For Accessibility, System Settings opens: switch on **Tabby Island** there."

Then check `T doctor --json` about every 10 s, for up to 2 minutes, and look at the `island-permissions` check. Its detail lists each permission as allowed, notAsked, waiting or denied. Tell them what's still missing.

- The window isn't there: `T island setup` opens it again.
- No prompt appeared: `T island permissions` reopens the permissions page, and **Allow** starts the app it asks about first, so macOS can prompt.
- `denied`: they clicked Don't Allow earlier, and macOS won't ask again by itself. **Ask Again** next to it resets that answer and asks.
- Accessibility stays off although the switch is on: have them remove Tabby Island from the list (the − button), then click Allow again in the island.

## 6. Finish

Tell them, briefly:

- Open a **new** Claude Code session, or type `/reload-plugins` in the ones already open. Each tab gets a name and a color after its first prompt.
- On a Mac, Tabby Island sits at the top center of the screen: hover it to see every session. Its menu-bar icon has Settings and the shortcuts.
- `/tab` shows the commands. "fix tabby" in Claude runs this check again. `tabby uninstall` removes everything.
- Updates: the island shows an **Update** button when a new version is out, or `/tab update` in Claude, or `tabby update` in a terminal.

## Troubleshooting

| What you see | Why | What to do |
|---|---|---|
| `Claude Code isn't installed (or not where a terminal can find it)` | The `claude` command isn't on PATH in a plain shell | Look for it: `ls ~/.local/bin/claude ~/.claude/local/claude /opt/homebrew/bin/claude`. If it's there, run the installer with that folder on PATH: `PATH="$HOME/.local/bin:$PATH" bash -c 'curl -fsSL https://claude-tabby.vercel.app/install \| bash -s -- --yes'` |
| `Couldn't download Node.js` | Offline, proxy or firewall | `brew install node`, or the installer from https://nodejs.org, then run the installer again |
| `The plugin didn't install` | No network to GitHub, or git broken | The log shows Claude's own error. Ask them to type `/plugin marketplace add 0xNtive/tabby`, then `/plugin install tabby@tabby` in Claude, then run the installer again |
| `Tabby Island could not be installed` | The download from github.com failed, and there are no Xcode Command Line Tools to build it | Check that `curl -sI https://github.com` works. Or `xcode-select --install` (they confirm a dialog; takes a few minutes), then `T island install` |
| `needs macOS 14` | Older macOS | Everything but the island works. Nothing to do |
| The island shows no sessions | Only sessions started after the install are tracked | Start a new Claude session. `T adopt` colors the ones already open |
| A tab has no name or color | That session started before tabby | `/reload-plugins` in it, or restart it: `claude --continue` keeps the conversation |
| Colors look wrong or text is hard to read | Light theme on a dark Claude, or the reverse | Follow the `theme` check's fix |
| Anything else | | Read `~/.claude/tabby/install.log` and `~/.claude/tabby/tabby.log`. Running the installer again is safe: it repairs in place |

To remove everything: `T uninstall`. It restores `settings.json` from its backup, removes the plugin, the island, the login item, the shell lines and the private Node.js, and keeps names and colors in `~/.claude/tabby` in case they come back.
