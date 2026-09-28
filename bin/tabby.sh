#!/bin/sh
# Runs tabby with a Node.js 18+ found wherever it lives. Claude Code's native installer ships
# without Node, and Claude started from the Dock or an editor often can't see nvm/Homebrew on
# its PATH, so hooks, the status line and the `tabby` command all start here.
#
#   sh bin/tabby.sh <args>        (next to bin/tabby.js, in the plugin)
#   sh ~/.claude/tabby/bin/tabby  (installed copy, next to the launcher tabby.mjs)
#
# The Node that worked is remembered in ~/.claude/tabby/node-path. The installer puts a private
# Node in ~/.claude/tabby/node when there's none at all.
home="${TABBY_HOME:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/tabby}"
here=$(cd "$(dirname "$0")" 2> /dev/null && pwd)
script="$here/tabby.js"
[ -f "$script" ] || script="$here/tabby.mjs"

new_enough() {
  [ -x "$1" ] && "$1" -e 'process.exit(+process.versions.node.split(".")[0] >= 18 ? 0 : 1)' > /dev/null 2>&1
}

find_node() {
  if [ -n "${TABBY_NODE:-}" ] && [ -x "$TABBY_NODE" ]; then
    echo "$TABBY_NODE"
    return 0
  fi
  if [ -f "$home/node-path" ]; then
    IFS= read -r cached < "$home/node-path" || true
    if [ -n "${cached:-}" ] && [ -x "$cached" ]; then
      echo "$cached"
      return 0
    fi
  fi
  for n in "$(command -v node 2> /dev/null)" "$home/node/bin/node" /opt/homebrew/bin/node /usr/local/bin/node \
    "$HOME/.volta/bin/node" "$HOME/.local/share/mise/shims/node" "$HOME/.asdf/shims/node" \
    "$HOME"/.nvm/versions/node/v*/bin/node "$HOME"/.local/share/fnm/node-versions/v*/installation/bin/node \
    /usr/bin/node; do
    if [ -n "$n" ] && new_enough "$n"; then
      mkdir -p "$home" 2> /dev/null && printf '%s\n' "$n" > "$home/node-path" 2> /dev/null
      echo "$n"
      return 0
    fi
  done
  return 1
}

if node=$(find_node); then
  exec "$node" "$script" "$@"
fi

# No Node: never break Claude. Hooks stay quiet, except one note when a session starts.
case "${1:-}" in
  hook)
    if [ "${2:-}" = SessionStart ]; then
      printf '%s' '{"systemMessage":"tabby needs Node.js 18 or newer and could not find it. Ask Claude: \"fix tabby\" (or run the installer again: curl -fsSL https://claude-tabby.vercel.app/install | bash)."}'
    fi
    exit 0
    ;;
  statusline | _*) exit 0 ;;
esac
echo "tabby needs Node.js 18 or newer and could not find it. Run the installer again, it sets one up: curl -fsSL https://claude-tabby.vercel.app/install | bash" >&2
exit 1
