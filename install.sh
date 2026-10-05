#!/usr/bin/env bash
# tabby installer: https://github.com/0xNtive/tabby
#
#   curl -fsSL https://claude-tabby.vercel.app/install | bash
#   curl -fsSL https://claude-tabby.vercel.app/install | bash -s -- --yes   # accept the terms, no questions
#
# Or let Claude do it: paste this into Claude Code
#   Install tabby for me: run `curl -fsSL https://claude-tabby.vercel.app/install.md` and follow it.
#
# What it does, each step checked (a log goes to ~/.claude/tabby/install.log):
#   1. finds Claude Code and Node.js 18+ (no Node? it puts a private copy in ~/.claude/tabby/node)
#   2. adds the tabby plugin to Claude Code
#   3. shows the terms and runs the one-time setup (tab titles, status line, /tab, shell flags)
#   4. on a Mac: downloads Tabby Island into ~/Applications, opens it at login, and opens its setup
#      window, which asks only for the permissions your terminal needs
#   5. runs `tabby doctor`
# Everything is reversible: tabby uninstall.
#
# Options: --yes (accept the terms) · --no-island · --no-node (never download Node) · plus any
# `tabby install` flag (--no-statusline, --no-shell, --no-title, --no-terminal-titles).
# CLAUDE_BIN=/path/to/claude when Claude Code lives somewhere unusual.
set -uo pipefail

{ # the whole script is read before any of it runs: a download cut short does nothing

REPO=0xNtive/tabby
YES=0
ISLAND=1
NODE_DOWNLOAD=1
PASS=()
for arg in "$@"; do
  case "$arg" in
    -y | --yes | --accept-terms) YES=1 ;;
    --no-island) ISLAND=0 ;;
    --no-node) NODE_DOWNLOAD=0 ;;
    --no-*) PASS+=("$arg") ;;
  esac
done

CLAUDE_HOME="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
TABBY_DIR="${TABBY_HOME:-$CLAUDE_HOME/tabby}"
mkdir -p "$TABBY_DIR" && chmod 700 "$TABBY_DIR" # session records live here: the owner's alone
LOG="$TABBY_DIR/install.log"
{ echo; echo "=== tabby install $(date '+%Y-%m-%d %H:%M:%S') · $(uname -sm) · args: $*"; } >> "$LOG"

if [ -t 1 ]; then B=$'\033[1m' D=$'\033[2m' G=$'\033[32m' Y=$'\033[33m' R=$'\033[31m' N=$'\033[0m'; else B= D= G= Y= R= N=; fi
step() { printf '%s▸%s %s\n' "$B" "$N" "$*"; echo "## $*" >> "$LOG"; }
ok() { printf '  %s✓%s %s\n' "$G" "$N" "$*"; echo "ok: $*" >> "$LOG"; }
warn() { printf '  %s!%s %s\n' "$Y" "$N" "$*"; echo "warn: $*" >> "$LOG"; }
die() {
  printf '  %s✗ %s%s\n' "$R" "$*" "$N" >&2
  echo "FAILED: $*" >> "$LOG"
  printf '\n  The full log is in %s.\n  Stuck? Paste this into Claude Code and it will sort it out:\n    %sInstall tabby for me: run `curl -fsSL https://claude-tabby.vercel.app/install.md` and follow it.%s\n' "$LOG" "$B" "$N" >&2
  exit 1
}
# Runs a command, its output to the log; failures are kept to show if the step fails.
ERRORS=""
quiet() {
  local out
  out=$("$@" 2>&1)
  local status=$?
  printf '$ %s\n%s\n' "$*" "$out" >> "$LOG"
  [ $status -eq 0 ] || ERRORS="${ERRORS}$(printf '%s' "$out" | tail -n 2 | sed "s|^|$(basename "$2" 2> /dev/null) $3 $4: |")
"
  return $status
}
has_tty() { { : > /dev/tty; } 2> /dev/null; }

printf '%stabby%s: every Claude Code tab, at a glance\n\n' "$B" "$N"

# ---------- 1. Claude Code and Node.js ----------
step "Checking this machine"
OS=$(uname -s)
case "$OS" in
  Darwin | Linux) ;;
  *) die "tabby runs on macOS and Linux (this is $OS). On Windows, use WSL." ;;
esac

CLAUDE=""
for c in "${CLAUDE_BIN:-}" "$(command -v claude 2> /dev/null)" "$HOME/.local/bin/claude" "$CLAUDE_HOME/local/claude" /opt/homebrew/bin/claude /usr/local/bin/claude; do
  if [ -n "$c" ] && [ -x "$c" ] && "$c" --version > /dev/null 2>&1; then
    CLAUDE="$c"
    break
  fi
done
[ -n "$CLAUDE" ] || die "Claude Code isn't installed (or not where a terminal can find it). Install it first: https://claude.com/claude-code"
ok "Claude Code $("$CLAUDE" --version 2> /dev/null | head -n 1 | sed 's/ (Claude Code)//') ($CLAUDE)"

node_ok() { [ -x "$1" ] && "$1" -e 'process.exit(+process.versions.node.split(".")[0] >= 18 ? 0 : 1)' > /dev/null 2>&1; }
NODE=""
for n in "$(command -v node 2> /dev/null)" "$TABBY_DIR/node/bin/node" /opt/homebrew/bin/node /usr/local/bin/node \
  "$HOME/.volta/bin/node" "$HOME/.local/share/mise/shims/node" "$HOME/.asdf/shims/node" \
  "$HOME"/.nvm/versions/node/v*/bin/node "$HOME"/.local/share/fnm/node-versions/v*/installation/bin/node /usr/bin/node; do
  if [ -n "$n" ] && node_ok "$n"; then NODE="$n"; fi
  [ -n "$NODE" ] && break
done

# No Node 18+: a private copy of Node 22 LTS, used only by tabby (nothing on your PATH changes).
# One fixed version, checked against the SHA-256 written here (from nodejs.org's SHASUMS256.txt for
# that version), so the download can't vouch for itself. tabby uninstall removes it.
NODE_VERSION=22.23.3
node_sha256() {
  case "$1" in
    darwin-arm64) echo 23b25245dcfb9af7262f8ff142e9e2e0af025368117329e7a7458a51e5922f53 ;;
    darwin-x64) echo 8a677b0219178efd6eb0e475457c4afb452b521a92f6e67845a73bd85727f2a8 ;;
    linux-arm64) echo 5ced2d48d1d7198739b7f86804de0171aefb6823b684b12341d3321afc3cb0b2 ;;
    linux-x64) echo 1084aa36196bba4c3a5e69a1ee388a6e4ff729dad09445fbcd434b28fe3c24af ;;
  esac
}
install_private_node() {
  local os arch file sum tmp
  case "$OS" in Darwin) os=darwin ;; Linux) os=linux ;; esac
  case "$(uname -m)" in arm64 | aarch64) arch=arm64 ;; x86_64 | amd64) arch=x64 ;; *) return 1 ;; esac
  file="node-v$NODE_VERSION-$os-$arch.tar.gz"
  sum=$(node_sha256 "$os-$arch")
  [ -n "$sum" ] || return 1
  tmp=$(mktemp -d)
  curl -fsSL --retry 2 --proto '=https' -o "$tmp/$file" "https://nodejs.org/dist/v$NODE_VERSION/$file" || { rm -rf "$tmp"; return 1; }
  local got
  got=$( (shasum -a 256 "$tmp/$file" 2> /dev/null || sha256sum "$tmp/$file") | awk '{print $1}')
  [ "$got" = "$sum" ] || { echo "checksum mismatch for $file" >> "$LOG"; rm -rf "$tmp"; return 1; }
  tar -xzf "$tmp/$file" -C "$tmp" || { rm -rf "$tmp"; return 1; }
  rm -rf "$TABBY_DIR/node"
  mv "$tmp/${file%.tar.gz}" "$TABBY_DIR/node" || { rm -rf "$tmp"; return 1; }
  rm -rf "$tmp"
  node_ok "$TABBY_DIR/node/bin/node"
}

[ "${TABBY_NODE_DOWNLOAD:-}" = force ] && NODE="" # testing the no-Node path
if [ -n "$NODE" ]; then
  ok "Node.js $("$NODE" -v) ($NODE)"
elif [ "$NODE_DOWNLOAD" = 1 ]; then
  printf '  %s…%s No Node.js 18+ here: getting a private copy for tabby (about 30 MB)\n' "$D" "$N"
  if install_private_node; then
    NODE="$TABBY_DIR/node/bin/node"
    ok "Node.js $("$NODE" -v) → $TABBY_DIR/node (only tabby uses it)"
  else
    die "Couldn't download Node.js from nodejs.org. Install Node 18 or newer (https://nodejs.org, or: brew install node), then run this again."
  fi
else
  die "tabby needs Node.js 18 or newer: https://nodejs.org (or: brew install node)"
fi
# The real binary behind a version manager's shim, so hooks keep a Node 18+ in every project.
REAL_NODE=$("$NODE" -p 'process.execPath' 2> /dev/null)
[ -n "$REAL_NODE" ] && [ -x "$REAL_NODE" ] && NODE="$REAL_NODE"
printf '%s\n' "$NODE" > "$TABBY_DIR/node-path"
export TABBY_NODE="$NODE"

# ---------- 2. The plugin ----------
step "Adding the tabby plugin to Claude Code"
# Git clones the plugin. A Mac without the Command Line Tools has only a stub git that pops up an
# installer, so there tabby comes as a download instead.
git_works() {
  command -v git > /dev/null 2>&1 || return 1
  if [ "$OS" = Darwin ] && [ "$(command -v git)" = /usr/bin/git ]; then xcode-select -p > /dev/null 2>&1 || return 1; fi
  git --version > /dev/null 2>&1
}
# Where the tabby marketplace comes from now, if it's already added: a GitHub repo, or a folder.
MARKET_DIR=$("$NODE" -e '
try {
  const m = require(require("path").join(process.argv[1], "plugins/known_marketplaces.json")).tabby;
  if (m && m.source && m.source.source === "directory") process.stdout.write(m.source.path);
} catch {}
' "$CLAUDE_HOME")
if [ -n "${TABBY_MARKETPLACE:-}" ]; then # a checkout, for testing
  quiet "$CLAUDE" plugin marketplace add "$TABBY_MARKETPLACE" || quiet "$CLAUDE" plugin marketplace update tabby || true
elif git_works; then
  # Installed earlier without git (a downloaded folder): switch to GitHub, which updates.
  case "$MARKET_DIR" in "$TABBY_DIR"/src/*) quiet "$CLAUDE" plugin marketplace remove tabby || true ;; esac
  quiet "$CLAUDE" plugin marketplace add "$REPO" || quiet "$CLAUDE" plugin marketplace update tabby || true
else
  SRC="$TABBY_DIR/src"
  rm -rf "$SRC" && mkdir -p "$SRC"
  fetch_source() { curl -fsSL --retry 2 --proto '=https' "https://codeload.github.com/$REPO/tar.gz/refs/heads/main" | tar -xz -C "$1"; }
  if quiet fetch_source "$SRC"; then
    quiet "$CLAUDE" plugin marketplace remove tabby || true
    quiet "$CLAUDE" plugin marketplace add "$SRC/tabby-main" || true
    warn "no git here, so tabby came as a download (updates: run this installer again)"
  fi
fi
quiet "$CLAUDE" plugin install tabby@tabby || true
quiet "$CLAUDE" plugin update tabby@tabby || true

# The newest installed copy of the plugin.
ROOT=$("$NODE" -e '
const fs = require("fs"), path = require("path");
const dir = path.join(process.argv[1], "plugins/cache/tabby/tabby");
const key = (v) => v.split(".").map((n) => n.padStart(6, "0")).join(".");
let best = "";
try { for (const v of fs.readdirSync(dir)) if (fs.existsSync(path.join(dir, v, "bin/tabby.js")) && key(v) > key(best || "0")) best = v; } catch {}
if (best) process.stdout.write(path.join(dir, best));
' "$CLAUDE_HOME")
if [ -z "$ROOT" ]; then
  [ -n "$ERRORS" ] && printf '%s' "$ERRORS" | sed 's/^/    /' >&2
  die "The plugin didn't install. Inside Claude Code, type: /plugin marketplace add $REPO  then  /plugin install tabby@tabby"
fi
tabby() { "$NODE" "$ROOT/bin/tabby.js" "$@"; }
ok "tabby $(tabby version) ($ROOT)"

# ---------- 3. Terms and setup ----------
step "Terms and setup"
if [ "$YES" = 1 ]; then
  tabby install --accept-terms "${PASS[@]+"${PASS[@]}"}" 2>&1 | tee -a "$LOG" | sed -e '/Installing tabby/d' -e '/^New Claude sessions/,$d' -e '/^$/d' -e 's/^/  /'
  status=${PIPESTATUS[0]}
elif has_tty; then
  tabby install "${PASS[@]+"${PASS[@]}"}" < /dev/tty
  status=$?
else
  die "No terminal to ask on, so the terms can't be shown. To accept them: curl -fsSL https://claude-tabby.vercel.app/install | bash -s -- --yes"
fi
if [ "$status" = 2 ]; then
  echo "Nothing else was changed: the plugin stays off until you accept. Run this again any time."
  exit 0
fi
[ "$status" = 0 ] || die "Setup failed (tabby install exited $status)."
ok "setup done"

# ---------- 4. Tabby Island (macOS) ----------
if [ "$OS" = Darwin ] && [ "$ISLAND" = 0 ]; then
  tabby config island false > /dev/null # doctor and updates leave it out
fi
if [ "$OS" = Darwin ] && [ "$ISLAND" = 1 ]; then
  step "Tabby Island"
  tabby config island true > /dev/null
  out=$(tabby island install 2>&1)
  status=$?
  printf '%s\n' "$out" >> "$LOG"
  if [ $status -eq 0 ]; then
    printf '%s\n' "$out" | sed 's/^/  /'
    ok "Its setup window is open: it asks only for what your terminal needs."
  else
    printf '%s\n' "$out" | sed 's/^/    /'
    warn "Everything else works without it. Try again later: tabby island install"
  fi
fi

# ---------- 5. Check ----------
step "Checking the install"
tabby doctor 2>&1 | tee -a "$LOG" | sed -n '2,$p'
printf '\n%sDone.%s Open a new Claude Code session (or type /reload-plugins in one that is open):\n' "$B" "$N"
printf '  its tab gets a name and a color after your first prompt'
[ "$OS" = Darwin ] && [ "$ISLAND" = 1 ] && printf ', and every session shows in the island at the top center of your screen'
printf '.\n  /tab in Claude for commands · tabby doctor to check · tabby uninstall to remove everything\n'

exit 0
} # the whole script is read before any of it runs
