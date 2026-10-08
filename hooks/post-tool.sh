#!/bin/sh
# PostToolUse fast path (runs after every tool call): only start node when this
# session is waiting on you (permission / question) and needs to flip back to "working".
input=$(cat)
# The first "session_id": the hook's own, never one inside a tool's input or output.
id=$(printf '%s' "$input" | grep -oE '"session_id" *: *"[^"]*"' | head -n 1 | sed 's/.*: *"//; s/"$//')
[ -n "$id" ] || exit 0
file="${TABBY_HOME:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/tabby}/sessions/$id.json"
[ -f "$file" ] || exit 0
grep -q '"status": "\(waiting\|error\)"' "$file" || exit 0
printf '%s' "$input" | exec sh "$(dirname "$0")/../bin/tabby.sh" hook PostToolUse
