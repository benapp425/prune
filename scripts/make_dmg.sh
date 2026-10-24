#!/bin/sh
# Builds dist/Prune-<version>.dmg: Prune.app beside a shortcut to Applications, ready to drag and install.
# Run scripts/build.sh first.
set -e
cd "$(dirname "$0")/.."
VERSION=$(cat VERSION)
STAGE=dist/dmg-stage
DMG=dist/Prune-$VERSION.dmg

[ -d dist/Prune.app ] || { echo "Run scripts/build.sh first"; exit 1; }
# A signature whose requirement names only the identifier would let any program claim the Full Disk Access
# people give Prune, and the launch hooks don't belong in a release.
if codesign -d -r- dist/Prune.app 2>/dev/null | grep -qx 'designated => identifier "app.prune.Prune"'; then
    echo "dist/Prune.app has an unsafe signature. Rebuild it with scripts/build.sh."
    exit 1
fi
if strings -a dist/Prune.app/Contents/MacOS/Prune | grep -q PRUNE_TRASH_TEST; then
    echo "dist/Prune.app has the launch hooks. Rebuild it without PRUNE_HOOKS."
    exit 1
fi
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
ditto --norsrc --noextattr dist/Prune.app "$STAGE/Prune.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Prune $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG" >/dev/null
rm -rf "$STAGE"
echo "Built $DMG ($(du -h "$DMG" | cut -f1))"
