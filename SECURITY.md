# Security

tabby runs on your machine and has no servers. This page says what it sends, what it trusts and how to report a problem. The plain-language version is in [TERMS.md](TERMS.md).

## What leaves your machine

- **The AI naming request**, and nothing else you typed: the session's last few prompts (each trimmed to 400 characters), up to 600 characters of Claude's last reply and the project folder's name go to Claude Haiku through your own Claude Code login (`claude -p --safe-mode --setting-sources user --strict-mcp-config --tools ""`: no tools, hooks, plugins or MCP, only your own Claude settings, since a project's `.claude/settings.json` could otherwise point the request elsewhere, no saved transcript, the prompt passed on stdin, run in `~/.claude/tabby`). It runs only while the namer is `ai`; `tabby config namer heuristic` names tabs on your machine, `off` not at all.
- **An update check**: one `HEAD` request to github.com for the latest release, every 6 hours at most. `tabby config updateCheck false` turns it off.
- **Downloads**, when you install or update: the plugin (through Claude Code's own plugin commands), Tabby Island's zip from this repository's GitHub releases, and Node.js from nodejs.org only if the machine has none.

None of these carries your prompts, paths or an identifier, apart from the naming request. Tabby Island has no network code at all; `test/privacy.test.js` fails the build if network code appears anywhere outside the updater, the island download and the installer.

## What stays on it

`~/.claude/tabby` holds tabby's state: one record per session (title, summary, the last 8 prompts trimmed to 400 characters, the working directory, status and context use), your settings and a log. The folder is `0700` and its files `0600` (files an older version made more open are tightened the next time tabby runs): only your account can read them. The five newest backups of your Claude `settings.json` are kept. Records of ended sessions are removed after 30 days. `tabby uninstall` reverts the changes to your Claude settings, shell file and Terminal profiles and says what it leaves behind.

## What tabby trusts

- **GitHub and this repository.** The plugin, the installer and Tabby Island all come from `0xNtive/tabby`. Tabby Island's zip has a SHA-256 checksum next to it, which catches a damaged download, and a build provenance attestation that ties it to the workflow run that built it. `tabby island install` checks that attestation with GitHub's `gh` when it's installed (`gh attestation verify`, with whatever login gh has; `TABBY_NO_ATTEST=1` skips it) and throws away a zip that fails; without `gh` only the checksum is checked, and `gh attestation verify TabbyIsland.zip --repo 0xNtive/tabby` checks one by hand. The release workflow builds only commits on `main` and never replaces a release's files: a fix is a new version.
- **The website**, for the one-line install: `https://claude-tabby.vercel.app/install` redirects to `install.sh` on this repository's `main`, so that path trusts the Vercel project as well as GitHub. `curl -fsSL https://raw.githubusercontent.com/0xNtive/tabby/main/install.sh | bash` skips the redirect.
- **Tabby Island is ad-hoc signed and not notarized yet** (the project has no Apple Developer ID while it is in beta). macOS ties the Accessibility and Automation permissions you grant to the app's bundle identifier, not to a developer certificate, so software already running under your account could present itself as Tabby Island and use those permissions. Grant them only on a machine whose other software you trust.
- **Your own account.** Files under `~/.claude` and environment variables such as `TABBY_ROOT` are taken at their word: anything that can change them can already run code as you. Text that comes from elsewhere is not trusted: names from the model, folder names and transcript content are stripped of control characters before they reach a terminal, and are passed to AppleScript and the shell as arguments, never as code.
- **The private Node.js** the installer downloads when a machine has none is one fixed version, checked against a SHA-256 written in `install.sh`.

## Reporting a vulnerability

Please report it privately through [GitHub's security advisories](https://github.com/0xNtive/tabby/security/advisories/new), not in a public issue. Include what an attacker could do and the steps to reproduce. You'll get an answer within a few days, and credit in the release notes if you'd like it.

## What's in scope

- The hooks, the CLI and the installer (`install.sh`): anything that runs code or changes files it shouldn't, or trusts input it shouldn't (session files, transcripts, terminal titles).
- Tabby Island: the macOS permissions it asks for (Accessibility, Automation) and what it does with them.
- The release download and the update path.
