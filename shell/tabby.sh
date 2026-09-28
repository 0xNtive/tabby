# tabby — launch flags for Claude Code (installed by `tabby install` into ~/.claude/tabby/shell/)
#
#   claude --tab "Auth refactor"     name this tab (same as claude --name)
#   claude --color teal              accent: red orange yellow green teal blue purple pink, or #hex
#   claude --theme nord              theme for this tab (`tabby themes` to preview)
#   claude --tabby                   load tabby for this launch only (when the plugin isn't installed)
#   claude --no-tabby                leave this tab alone
#
# Everything else is passed to claude unchanged. `tabby` runs the newest installed copy.

_TABBY_HOME="${TABBY_HOME:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/tabby}"

# `function name {`, not `name() {`: an alias named claude (claude='claude --dangerously-…', or
# Claude's old ~/.claude/local/claude) would otherwise make this a syntax error.
function tabby { sh "$_TABBY_HOME/bin/tabby" "$@"; }

function claude {
  local -a _tabby_args
  local _tabby_color="${TABBY_COLOR:-}" _tabby_theme="${TABBY_THEME:-}" _tabby_off="${TABBY_OFF:-}" _tabby_load=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --color|--tab-color) _tabby_color="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
      --color=*|--tab-color=*) _tabby_color="${1#*=}"; shift ;;
      --theme|--tab-theme) _tabby_theme="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
      --theme=*|--tab-theme=*) _tabby_theme="${1#*=}"; shift ;;
      --tab) _tabby_args+=(--name "${2:-}"); shift; [ $# -gt 0 ] && shift ;;
      --tab=*) _tabby_args+=(--name "${1#*=}"); shift ;;
      --no-tabby) _tabby_off=1; shift ;;
      --tabby) _tabby_load=1; shift ;;
      --) _tabby_args+=("$@"); break ;;
      *) _tabby_args+=("$1"); shift ;;
    esac
  done
  if [ -n "$_tabby_load" ]; then
    TABBY_COLOR="$_tabby_color" TABBY_THEME="$_tabby_theme" TABBY_OFF="$_tabby_off" \
      CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1 command claude --plugin-dir "$(tabby root)" "${_tabby_args[@]}"
  else
    TABBY_COLOR="$_tabby_color" TABBY_THEME="$_tabby_theme" TABBY_OFF="$_tabby_off" \
      command claude "${_tabby_args[@]}"
  fi
}
