#!/usr/bin/env bash
# Builds island/build/Tabby Island.app (ad-hoc signed). Usage: bash island/build.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="$HERE/build/Tabby Island.app"
ARCH="$(uname -m)"
MIN_MACOS="14.0"

if ! command -v xcrun >/dev/null 2>&1; then
  echo "error: Xcode command line tools are required (xcode-select --install)" >&2
  exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$HERE/Info.plist" "$APP/Contents/Info.plist"

xcrun --sdk macosx swiftc \
  -O -parse-as-library -swift-version 5 \
  -target "$ARCH-apple-macos$MIN_MACOS" \
  -module-name TabbyIsland \
  -framework AppKit -framework SwiftUI -framework QuartzCore -framework Combine \
  "$HERE"/Sources/*.swift \
  -o "$APP/Contents/MacOS/TabbyIsland"

codesign --force --sign - --timestamp=none "$APP" >/dev/null
echo "Built $APP"
