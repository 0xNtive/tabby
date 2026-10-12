# Security

tabby runs on your machine and has no servers. This page says what it sends, what it trusts and how to report a problem. The plain-language version is in [TERMS.md](TERMS.md).

## What leaves your machine

- **The AI naming request**, and nothing else you typed: the session's last few prompts (each trimmed to 400 characters), up to 600 characters of Claude's last reply and the project folder's name go to Claude Haiku through your own Claude Code login (`claude -p --safe-mode --setting-sources user --strict-mcp-config --tools ""`: no tools, hooks, plugins or MCP, only your own Claude settings, since a project's `.claude/settings.json` could otherwise point the request elsewhere, no saved transcript, the prompt passed on stdin, run in `~/.claude/tabby`). It runs only while the namer is `ai`; `tabby config namer heuristic` names tabs on your machine, `off` not at all.
- **An update check**: one `HEAD` request to github.com for the latest release, every 6 hours at most, started by a Claude session (Tabby Island only reads what the last one found, or asks when you click Check Now). `tabby config updateCheck false` turns it off.
- **Downloads**, when you install or update: the plugin (through Claude Code's own plugin commands), Tabby Island's zip from this repository's GitHub releases, and Node.js from nodejs.org only if the machine has none.

None of these carries your prompts, paths or an identifier, apart from the naming request. Checking Tabby Island's download happens on your machine (see below): no `gh`, no login, no extra request. Tabby Island has no network code at all; `test/privacy.test.js` fails the build if network code appears anywhere outside the updater, the island download and the installer.

## What it reads and what it can stop

`tabby procs` and the island's Processes page list processes with `ps` and `lsof`. For each candidate they read a few environment variable names (`TERM_SESSION_ID`, `TERM_PROGRAM`, `CLAUDECODE`, `CLAUDE_CODE_SESSION_ID`, `CLAUDE_PID`, `XPC_SERVICE_NAME`) to tell a process a terminal or Claude started from a launchd service; no other variable is kept, and command lines never leave the CLI (the island gets a short name like "vite"). Only your own account's processes are listed, and never launchd services, apps, Claude or its MCP servers, interactive shells, `ssh-agent`, `tmux` or `screen`. Nothing is stopped unless you ask, and a stop goes only to processes whose start time matches the list you saw, so a reused process id is never hit.

## What it changes in Claude Code's settings

Setup adds tabby's status line (unless you have one), turns off Claude's own tab titles (`CLAUDE_CODE_DISABLE_TERMINAL_TITLE`), backs up `settings.json` first and keeps only those keys on uninstall. Claude Code loads a plugin's hooks only when a session starts, so for sessions that were already open when you set tabby up, setup also adds tabby's hooks to `settings.json`: each runs `~/.claude/tabby/bin/tabby hook <event> --bridge`, does nothing in any other session (it checks the Claude process against the list in `~/.claude/tabby/bridge.pids` before Node starts), and the hooks are taken out again once the last of those sessions has ended. `tabby uninstall` takes them out too.

## What it may change as administrator

Only if you use Awake (keep the Mac running with the lid closed). Keeping a Mac awake with the lid closed takes `pmset disablesleep`, which needs root. The first time, macOS asks for an administrator's password through its own prompt (`/usr/libexec/authopen`), and tabby writes `/etc/sudoers.d/tabby-awake` (owner root, mode `0440`, checked with `visudo` first) with one rule: your user may run `/usr/bin/pmset -a disablesleep 1` and `/usr/bin/pmset -a disablesleep 0` without a password. Nothing else runs as root, then or later. The consequence to weigh: any program running as you can then keep the Mac from sleeping, and nothing more. `tabby awake forget` empties the rule (the admin prompt again); `sudo rm /etc/sudoers.d/tabby-awake` removes the file.

## What stays on it

`~/.claude/tabby` holds tabby's state: one record per session (title, summary, the last 8 prompts trimmed to 400 characters, the working directory, status and context use), the color each working directory last had, your settings and a log. The folder is `0700` and its files `0600` (files an older version made more open are tightened the next time tabby runs): only your account can read them. The five newest backups of your Claude `settings.json` are kept. Records of ended sessions are removed after 30 days, and a working directory's color after 90 days without a session there. The log (`tabby.log`) notes when each session starts (with its folder's name), the names the AI gives tabs, Awake and update events, and errors; it is capped at 512 KB, with one older copy kept. `tabby uninstall` reverts the changes to your Claude settings, shell file and Terminal profiles and says what it leaves behind; `tabby uninstall --purge` also deletes `~/.claude/tabby`.

## What tabby trusts

- **GitHub and this repository.** The plugin, the installer and Tabby Island all come from `0xNtive/tabby`. The release workflow signs Tabby Island's zip with an Ed25519 key that only it holds (a repository secret), and tabby checks that signature against the public key in `lib/island.js` before unpacking anything: a zip without a valid signature is thrown away, and tabby builds the island from source instead when it can. The SHA-256 checksum next to the zip only catches a damaged download. Each zip also has a build provenance attestation that ties it to the workflow run that built it (`gh attestation verify TabbyIsland.zip --repo 0xNtive/tabby` checks one by hand). A zip of your own (`TABBY_ISLAND_URL`, for testing) skips the signature, so it's honored only in a terminal of your own, never inside Claude Code, where a project's settings can set environment variables. The release workflow builds only commits on `main` and never replaces a release's files: a fix is a new version.
- **The website**, for the one-line install: `https://claude-tabby.vercel.app/install` redirects to `install.sh` on this repository's `main`, so that path trusts the Vercel project as well as GitHub. `curl -fsSL https://raw.githubusercontent.com/0xNtive/tabby/main/install.sh | bash` skips the redirect.
- **Tabby Island is ad-hoc signed and not notarized yet** (the project has no Apple Developer ID while it is in beta). macOS ties the Accessibility and Automation permissions you grant to the app's bundle identifier, not to a developer certificate, so software already running under your account could present itself as Tabby Island and use those permissions. The island also runs tabby's own scripts from `~/.claude` (for tiling, colors, Awake and updates), and those run with its permissions too; it starts them only when you click something, plus one Awake check that turns sleep back on after a crash. Anything that can rewrite files in your home folder can change what those scripts do. Grant the permissions only on a machine whose other software you trust.
- **Your own account.** Files under `~/.claude` and environment variables such as `TABBY_ROOT` are taken at their word: anything that can change them can already run code as you. Text that comes from elsewhere is not trusted: names from the model, folder names and transcript content are stripped of control characters before they reach a terminal, and are passed to AppleScript and the shell as arguments, never as code.
- **The private Node.js** the installer downloads when a machine has none is one fixed version, checked against a SHA-256 written in `install.sh`.

## Reporting a vulnerability

Please report it privately through [GitHub's security advisories](https://github.com/0xNtive/tabby/security/advisories/new), not in a public issue. Include what an attacker could do and the steps to reproduce. You'll get an answer within a few days, and credit in the release notes if you'd like it.

## What's in scope

- The hooks, the CLI and the installer (`install.sh`): anything that runs code or changes files it shouldn't, or trusts input it shouldn't (session files, transcripts, terminal titles).
- Awake's sudoers rule (`/etc/sudoers.d/tabby-awake`): anything it allows beyond turning sleep off and on.
- Tabby Island: the macOS permissions it asks for (Accessibility, Automation) and what it does with them.
- The release download and the update path.
