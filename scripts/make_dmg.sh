#!/bin/sh
# Builds dist/Prune-<version>.dmg: Prune.app beside a shortcut to Applications, ready to drag and install.
# Run scripts/build.sh first.
set -e
cd "$(dirname "$0")/.."
VERSION=$(cat VERSION)
STAGE=dist/dmg-stage
DMG=dist/Prune-$VERSION.dmg

[ -d dist/Prune.app ] || { echo "Run scripts/build.sh first"; exit 1; }
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
ditto --norsrc --noextattr dist/Prune.app "$STAGE/Prune.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Prune $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG" >/dev/null
rm -rf "$STAGE"
echo "Built $DMG ($(du -h "$DMG" | cut -f1))"
