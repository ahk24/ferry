#!/bin/bash
# Builds build/Ferry.app (release, ad-hoc signed). With --install, also copies it to ~/Applications.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product Ferry
BIN="$(swift build -c release --show-bin-path)"

APP=build/Ferry.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Ferry" "$APP/Contents/MacOS/Ferry"
cp Resources/Info.plist "$APP/Contents/Info.plist"

if [ ! -f build/AppIcon.icns ]; then
  rm -rf build/AppIcon.iconset
  swift scripts/make-icon.swift build/AppIcon.iconset
  iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc signature: enough to run locally. macOS treats each rebuild as a new app, so it may
# ask for Local Network access again after rebuilding.
codesign --force --sign - --timestamp=none "$APP"
echo "Built $APP"

if [ "${1:-}" = "--install" ]; then
  mkdir -p "$HOME/Applications"
  pkill -x Ferry 2>/dev/null || true
  rm -rf "$HOME/Applications/Ferry.app"
  cp -R "$APP" "$HOME/Applications/Ferry.app"
  echo "Installed to ~/Applications/Ferry.app"
fi
