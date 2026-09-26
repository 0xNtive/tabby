#!/usr/bin/env bash
# Checks for the island's model code (shortcuts, config, watermark). Usage: bash island/test.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

xcrun --sdk macosx swiftc -swift-version 5 -target "$(uname -m)-apple-macos14.0" -o "$OUT/checks" \
  "$HERE"/Sources/{Shortcuts,Models,Watermark,SessionStore,TerminalTitles,Permissions}.swift "$HERE/Tests/main.swift"
"$OUT/checks"
