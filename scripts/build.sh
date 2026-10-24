#!/bin/sh
# Builds Prune.app and installs it in ~/Applications.
# Usage: sh scripts/build.sh [destination folder]   (default ~/Applications)
#
# PRUNE_HOOKS=1 sh scripts/build.sh builds the version used for screenshots, which reads the PRUNE_* launch
# hooks (see SelfTest in PruneApp.swift). It goes to dist/hooks and is never installed or put in a disk image.
set -e
cd "$(dirname "$0")/.."
DEST="${1:-$HOME/Applications}"
VERSION=$(cat VERSION)
APP=dist/Prune.app
BIN=.build/release/Prune
FLAGS=""
if [ "$PRUNE_HOOKS" = 1 ]; then
    APP=dist/hooks/Prune.app
    BIN=.build/hooks/release/Prune
    FLAGS="--scratch-path .build/hooks -Xswiftc -DPRUNE_HOOKS"
fi

swift build -c release --product Prune $FLAGS

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Prune"
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

# Signed with the "Prune Signing" certificate in your keychain (create it once with
# scripts/make_signing_identity.sh). The signature's requirement names that certificate, so macOS
# permissions such as Full Disk Access carry over from one build to the next, and no other program
# can claim them. Without the certificate the app is signed ad hoc, and permissions have to be
# granted again after every build.
IDENTITY=$(security find-identity -p codesigning | awk '/"Prune Signing"/ { print $2; exit }')
if [ -n "$IDENTITY" ]; then
    codesign --force --sign "$IDENTITY" --options runtime --timestamp=none --identifier app.prune.Prune "$APP" >/dev/null
else
    echo "No \"Prune Signing\" certificate in your keychain, so the app is signed ad hoc."
    echo "Run scripts/make_signing_identity.sh once to keep permissions across builds."
    codesign --force --sign - --options runtime --identifier app.prune.Prune "$APP" >/dev/null
fi

if [ "$PRUNE_HOOKS" = 1 ]; then
    echo "Built $APP with launch hooks ($VERSION)"
    exit 0
fi

mkdir -p "$DEST"
if pgrep -xq Prune; then osascript -e 'tell application id "app.prune.Prune" to quit' >/dev/null 2>&1 || true; sleep 1; fi
rm -rf "$DEST/Prune.app"
ditto "$APP" "$DEST/Prune.app"
echo "Installed $DEST/Prune.app ($VERSION)"
