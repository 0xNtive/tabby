#!/bin/sh
# PostToolUse fast path (runs after every tool call): only start node when this
# session is waiting on you (permission / question) and needs to flip back to "working".
input=$(cat)
id=$(printf '%s' "$input" | sed -n 's/.*"session_id" *: *"\([^"]*\)".*/\1/p' | head -n 1)
[ -n "$id" ] || exit 0
file="${TABBY_HOME:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/tabby}/sessions/$id.json"
[ -f "$file" ] || exit 0
grep -q '"status": "\(waiting\|error\)"' "$file" || exit 0
printf '%s' "$input" | exec node "$(dirname "$0")/../bin/tabby.js" hook PostToolUse
