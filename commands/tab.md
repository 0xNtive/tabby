---
description: Name, color or re-theme this terminal tab (tabby) — e.g. /tab Auth refactor · /tab color teal · /tab theme nord all
argument-hint: "[name] | color <c> | theme <t> [all] | auto | ls | themes | note <text> | reset | off | on"
allowed-tools: Bash(sh:*)
---

tabby normally handles `/tab` instantly in its UserPromptSubmit hook, so this text is only reached when that hook is disabled for this session.

Run this exact command once with the Bash tool and reply with its output verbatim, nothing else:

sh "${CLAUDE_PLUGIN_ROOT}/bin/tabby.sh" $ARGUMENTS
