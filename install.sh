#!/usr/bin/env bash
# tabby installer: https://github.com/0xNtive/tabby
#
#   curl -fsSL https://github.com/0xNtive/tabby/raw/main/install.sh | bash
#   curl -fsSL https://github.com/0xNtive/tabby/raw/main/install.sh | bash -s -- --yes   # accept the terms, no questions
#
# Adds the tabby plugin to Claude Code, runs its one-time setup (terms, Claude settings, the /tab
# command, shell flags, Terminal.app titles) and, on macOS, builds Tabby Island and opens its setup
# window, which walks through the permissions. Every step is reversible: tabby uninstall.
set -euo pipefail

YES=0
ISLAND=1
for arg in "$@"; do
  case "$arg" in
    -y | --yes | --accept-terms) YES=1 ;;
    --no-island) ISLAND=0 ;;
  esac
done

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
say() { printf '  %s\n' "$*"; }
die() { printf '\033[31m%s\033[0m\n' "$*" >&2; exit 1; }
has_tty() { { : > /dev/tty; } 2> /dev/null; }

bold "tabby: every Claude Code tab, at a glance"

command -v node > /dev/null || die "tabby needs Node.js 18 or newer: https://nodejs.org"
node -e 'process.exit(+process.versions.node.split(".")[0] >= 18 ? 0 : 1)' || die "tabby needs Node.js 18 or newer (this is $(node -v))."
command -v claude > /dev/null || die "tabby is a Claude Code plugin. Install Claude Code first: https://claude.com/claude-code"

say "Adding the plugin to Claude Code..."
claude plugin marketplace add 0xNtive/tabby > /dev/null 2>&1 || claude plugin marketplace update tabby > /dev/null 2>&1 || true
claude plugin install tabby@tabby > /dev/null 2>&1 || claude plugin update tabby@tabby > /dev/null 2>&1 || true

# The newest installed copy of the plugin.
ROOT=$(node -e '
const fs = require("fs"), path = require("path");
const dir = path.join(process.env.CLAUDE_CONFIG_DIR || path.join(process.env.HOME, ".claude"), "plugins/cache/tabby/tabby");
const key = (v) => v.split(".").map((n) => n.padStart(6, "0")).join(".");
let best = "";
try { for (const v of fs.readdirSync(dir)) if (fs.existsSync(path.join(dir, v, "bin/tabby.js")) && key(v) > key(best || "0")) best = v; } catch {}
if (best) process.stdout.write(path.join(dir, best));
')
[ -n "$ROOT" ] || die "The plugin didn't install. Inside Claude Code, run: /plugin marketplace add 0xNtive/tabby"
tabby() { node "$ROOT/bin/tabby.js" "$@"; }

# Setup shows the terms and asks on the terminal (this script itself arrives through a pipe).
if [ "$YES" = 1 ]; then
  tabby install --accept-terms
elif has_tty; then
  tabby install < /dev/tty
else
  die "No terminal to ask on. To accept the terms, run: curl -fsSL https://github.com/0xNtive/tabby/raw/main/install.sh | bash -s -- --yes"
fi

if [ "$(uname)" = Darwin ] && [ "$ISLAND" = 1 ]; then
  if xcode-select -p > /dev/null 2>&1; then
    say "Building Tabby Island (about 15 s)..."
    if tabby island build > /dev/null 2>&1; then
      tabby island onboarding > /dev/null
      say "Tabby Island is open: its setup window walks you through the permissions it needs."
    else
      say "Tabby Island didn't build. Try later with: tabby island build"
    fi
  else
    say "Skipped Tabby Island: it needs the Xcode Command Line Tools (xcode-select --install). Then run: tabby island"
  fi
fi

bold "Done."
say "Open a new Claude Code session (or type /reload-plugins in the ones already open)."
say "In Claude: /tab. In a new shell: tabby ls. To remove everything: tabby uninstall"
