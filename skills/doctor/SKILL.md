---
name: doctor
description: Diagnose and fix tabby when something about it isn't working — tab names or colors missing, /tab not responding, Tabby Island not showing or not listing sessions, no macOS permission prompt, tiling or the watermark doing nothing, "fix tabby", "tabby is broken". Runs `tabby doctor --json` and works through its fixes with the person.
---

# Fix tabby

1. Run the check (10-minute timeout on every Bash call):

   ```sh
   sh ~/.claude/tabby/bin/tabby doctor --json
   ```

   If that file doesn't exist, setup never ran: use `sh "<this skill's base directory>/../../bin/tabby.sh" doctor --json` instead.

2. It returns `{ ok, next, reinstall, checks: [{ id, title, status, detail, fix }] }`. Work through each `fail`, then each `warn`, that has a `fix`:
   - `fix.run`: run it (tabby's own commands; `sh ~/.claude/tabby/bin/tabby …`).
   - `fix.tell`: tell the person what to do, in your own words, and wait for them. Never accept tabby's terms for them: show the summary (`… tabby terms`) and ask first.

   Run it again until nothing is `fail`, and tell them in a line or two what was wrong and what changed.

3. When a piece is broken beyond a single fix, reinstalling is safe and repairs in place. Run the `reinstall` command from the JSON only after they've accepted the terms (`--yes` records acceptance). Its log is `~/.claude/tabby/install.log`; hooks log to `~/.claude/tabby/tabby.log`.

## Tabby Island (macOS)

- Not running: `… tabby island`. Not installed or outdated: `… tabby island install` (downloads the ready-made app, and builds it here if the download fails).
- Permissions: the `island-permissions` check lists each one (`allowed | notAsked | waiting | denied | notNeeded`). `… tabby island permissions` opens its setup window at the permissions. **Allow All** asks for each in turn, and **Ask Again** resets a "Don't Allow". The island asks only for what their terminal needs: nothing at all for VS Code, Cursor, Ghostty or Warp.
- Accessibility still off with the switch on: in System Settings › Privacy & Security › Accessibility, have them remove Tabby Island (−), then click Allow in the island again.
- No sessions in the island: only sessions started after tabby was installed are tracked. `/reload-plugins` in an open session, or `… tabby adopt` for colors now.

## Tabs

- A tab has no name or color: that session started before tabby. `/reload-plugins` there, or restart it (`claude --continue` keeps the conversation).
- `/tab` does nothing: the terms aren't accepted (the `terms` check), or the session predates the plugin (see above).
- Text hard to read: follow the `theme` check's fix.
