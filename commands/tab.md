---
description: Name, color or re-theme this terminal tab (tabby) — e.g. /tab Auth refactor · /tab color teal · /tab theme nord all
argument-hint: "[name] | color <c> | theme <t> [all] | auto | ls | themes | note <text> | reset | off | on"
---

tabby normally handles `/tab` instantly in its UserPromptSubmit hook, so this text is only reached when that hook isn't running in this session.

Don't run any command. Tell the user in one short sentence that tabby isn't active in this session: `/reload-plugins` (or a new session) turns it on, and `tabby doctor` in a terminal says what's wrong if `/tab` still doesn't answer.
