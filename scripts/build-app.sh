#!/bin/bash
# Builds build/DropConvert.app. Pass --install to copy it to /Applications and launch it.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="1.0.0"
APP="build/DropConvert.app"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/DropConvert"

[ -f Resources/AppIcon.icns ] || swift scripts/make-icon.swift Resources/AppIcon.icns

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/DropConvert"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
sed "s/@VERSION@/$VERSION/g" Resources/Info.plist > "$APP/Contents/Info.plist"
codesign --force --sign - --timestamp=none "$APP"
echo "Built $APP"

if [ "${1:-}" = "--install" ]; then
    osascript -e 'quit app "DropConvert"' 2>/dev/null || true
    rm -rf /Applications/DropConvert.app
    cp -R "$APP" /Applications/
    open /Applications/DropConvert.app
    echo "Installed /Applications/DropConvert.app"
fi
