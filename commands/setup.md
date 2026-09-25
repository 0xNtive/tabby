---
description: Turn tabby on — review and accept the terms, then one-time setup (short /tab, tab titles, status line, launch flags). /tabby:setup island builds the macOS island.
argument-hint: "[accept | island]"
allowed-tools: Bash(node:*)
---

tabby answers `/tabby:setup` instantly in its UserPromptSubmit hook, so this text only runs when that hook is not active in this session (for example right after installing, before /reload-plugins).

Tell the user, in one short paragraph, that tabby is installed but has to be turned on: they should run `/reload-plugins` (or start a new session) and then type `/tabby:setup` again to see the terms. Do not accept the terms on the user's behalf and do not run any setup command yourself.
