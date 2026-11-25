#!/bin/bash
# Builds Ferry and packages it as dist/Ferry-<version>.dmg: open it, drag Ferry onto Applications.
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/build-app.sh

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
STAGE=build/dmg
OUT=dist/Ferry-$VERSION.dmg

rm -rf "$STAGE"
mkdir -p "$STAGE" dist
cp -R build/Ferry.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"

rm -f "$OUT"
hdiutil create -volname "Ferry $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$OUT" >/dev/null
rm -rf "$STAGE"
echo "Created $OUT"
