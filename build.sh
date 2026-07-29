#!/bin/zsh
# Build (and optionally relaunch) ClaudeUsageBar.app.
#
#   ./build.sh          build and re-sign the bundle
#   ./build.sh --run    build, re-sign, and relaunch the app
#
# macOS keeps running the already-launched binary, so the app is stopped first.
# The ad hoc codesign step is required: replacing the executable invalidates the
# existing signature and an unsigned bundle will not launch.

set -eu
cd "$(dirname "$0")"

APP="ClaudeUsageBar.app"

pkill -x ClaudeUsageBar 2>/dev/null || true

mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"
swiftc -O main.swift -o "$APP/Contents/MacOS/ClaudeUsageBar"
codesign --force --sign - "$APP"

echo "Built $APP"

if [[ "${1:-}" == "--run" ]]; then
  open "$APP"
  echo "Launched — look for the gauge in the menu bar"
fi
