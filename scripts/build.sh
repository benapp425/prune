#!/bin/sh
# Builds Prune.app and installs it in ~/Applications.
# Usage: sh scripts/build.sh [destination folder]   (default ~/Applications)
set -e
cd "$(dirname "$0")/.."
DEST="${1:-$HOME/Applications}"
VERSION=$(cat VERSION)
APP=dist/Prune.app

swift build -c release --product Prune

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Prune "$APP/Contents/MacOS/Prune"
sed "s/__VERSION__/$VERSION/g" Resources/Info.plist > "$APP/Contents/Info.plist"

# Icon: drawn by a script, then cut into every size macOS asks for.
if [ ! -f dist/Prune.icns ] || [ scripts/make_icon.swift -nt dist/Prune.icns ]; then
    ICONSET=dist/Prune.iconset
    rm -rf "$ICONSET" && mkdir -p "$ICONSET"
    swift scripts/make_icon.swift dist/icon-1024.png >/dev/null
    for s in 16 32 128 256 512; do
        sips -z $s $s dist/icon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
        d=$((s * 2))
        sips -z $d $d dist/icon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o dist/Prune.icns
fi
cp dist/Prune.icns "$APP/Contents/Resources/Prune.icns"
cp CHANGELOG.md "$APP/Contents/Resources/CHANGELOG.md"

# Ad-hoc signature with a fixed designated requirement, so macOS privacy permissions
# (Full Disk Access, folder access) carry over from one build to the next.
codesign --force --sign - --options runtime --identifier app.prune.Prune \
    -r='designated => identifier "app.prune.Prune"' "$APP" >/dev/null

mkdir -p "$DEST"
if pgrep -xq Prune; then osascript -e 'tell application id "app.prune.Prune" to quit' >/dev/null 2>&1 || true; sleep 1; fi
rm -rf "$DEST/Prune.app"
ditto "$APP" "$DEST/Prune.app"
echo "Installed $DEST/Prune.app ($VERSION)"
