# tabby Terms of Use

**Version 2026-09-25.** Plain-language terms for the tabby plugin, command-line tool, macOS island app and website ("tabby"). tabby asks you to accept these terms once, during setup, before it does anything. If a later version changes them materially, tabby asks again.

> The source code is licensed separately under the MIT License (see `LICENSE`). These terms cover your use of tabby as distributed by the tabby project, not your rights to the code.

## 1. What tabby does

tabby names, colors and tracks the terminal tabs of your Claude Code sessions. It runs on your computer. It reads Claude Code's local session files and writes to your terminal, your Claude Code settings (only the changes `tabby install` lists) and `~/.claude/tabby`.

## 2. Your data

- **tabby has no servers and collects nothing.** No telemetry, analytics or tracking. Your prompts, code, file names and session data stay on your machine, in files only your account can read, with the one exception below.
- **AI names.** To name a tab, tabby sends your recent prompts in that session (up to about 6, each trimmed), a short excerpt of Claude's last reply and the name of the project's folder (not its path) to the Claude Haiku model, using *your own* Claude Code login. This goes to the same provider and account you already use with Claude Code (Anthropic, unless you have set Claude Code up with another), and that provider's terms and privacy policy apply to those requests. The request can use no tools and returns only a name. Turn it off with `tabby config namer heuristic`, which names tabs locally, or `off`.
- **Updates.** tabby asks github.com which release is the latest (every 6 hours at most; `tabby config updateCheck false` turns that off) and downloads Tabby Island and its updates from this project's GitHub releases. These are plain downloads that send nothing about you or your sessions. Tabby Island itself makes no network requests.
- **The website** sets no cookies and runs no analytics, unless a future version of these terms says so. Its home page asks GitHub's public API for the project's star count.

## 3. Sponsored content

tabby is free. To keep it that way, **future versions may show sponsored messages or ads inside tabby's own interface**: the island, the status line, the CLI, or messages tabby prints in your terminal.

If that happens:

- sponsored content will be clearly labeled as sponsored;
- it will **never** be inserted into your prompts, your Claude conversations or the model's context, and will never change what Claude does;
- it will never be targeted using the content of your prompts, code or files;
- the change will be announced in the release notes before it ships.

You can stop at any time with `tabby uninstall`.

## 4. Acceptable use

Use tabby lawfully, and within the terms of the services it connects to, including Anthropic's terms for Claude Code. Don't use tabby to hide what software is doing on a machine you don't own.

## 5. No warranty

tabby is provided **"as is"**, without warranties of any kind, express or implied, including merchantability, fitness for a particular purpose and non-infringement. It changes terminal titles, colors and your Claude Code settings; `tabby install` backs up `settings.json` first, and `tabby uninstall` reverts its changes.

## 6. Limitation of liability

To the maximum extent the law allows, the tabby authors and contributors are not liable for indirect, incidental, special, consequential or punitive damages, or for lost data, profits or work, arising from your use of tabby. Their total liability for any claim is limited to the amount you paid for tabby, which is zero.

## 7. Trademarks

Claude and Claude Code are trademarks of Anthropic. tabby is an independent project and is **not affiliated with, endorsed by or sponsored by Anthropic**. Other theme names belong to their respective authors; tabby only reproduces their published color values.

## 8. Changes and ending

We may update these terms. Material changes are announced in the release notes, and tabby asks you to accept them again before it continues. You can stop using tabby at any time. These terms end for you when you uninstall it, except sections 5, 6 and 7.

## 9. Contact

Questions: open an issue at https://github.com/0xNtive/tabby/issues.
