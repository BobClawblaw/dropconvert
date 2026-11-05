#!/bin/bash
# Builds build/DropConvert.app. Pass --install to copy it to /Applications and launch it.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(cat version.txt)"
APP="build/DropConvert.app"

swift build -c release --disable-sandbox --arch arm64 --arch x86_64
BIN="$(swift build -c release --disable-sandbox --arch arm64 --arch x86_64 --show-bin-path)/DropConvert"

[ -f Resources/AppIcon.icns ] || swift scripts/make-icon.swift Resources/AppIcon.icns

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/DropConvert"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
sed "s/@VERSION@/$VERSION/g" Resources/Info.plist > "$APP/Contents/Info.plist"

IDENTITY="${DEVELOPER_ID:-}"
if [ -z "$IDENTITY" ]; then
    IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*"\(Developer ID Application:.*\)"/\1/p' | head -1)"
fi

if [ -n "$IDENTITY" ]; then
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
    echo "Signed with $IDENTITY"
else
    codesign --force --sign - --timestamp=none "$APP"
    echo "Ad-hoc signed (no Developer ID identity found)"
fi

if [ "${NOTARIZE:-0}" = "1" ]; then
    if [ -z "$IDENTITY" ]; then
        echo "NOTARIZE=1 requires a Developer ID Application identity" >&2
        exit 1
    fi
    ZIP="build/DropConvert-$VERSION.zip"
    ditto -c -k --keepParent "$APP" "$ZIP"
    xcrun notarytool submit "$ZIP" \
        --apple-id "${APPLE_ID:?APPLE_ID is required}" \
        --team-id "${APPLE_TEAM_ID:?APPLE_TEAM_ID is required}" \
        --password "${APPLE_APP_PASSWORD:?APPLE_APP_PASSWORD is required}" \
        --wait
    xcrun stapler staple "$APP"
    rm -f "$ZIP"
    echo "Notarized and stapled $APP"
fi

echo "Built $APP"

if [ "${1:-}" = "--install" ]; then
    osascript -e 'quit app "DropConvert"' 2>/dev/null || true
    rm -rf /Applications/DropConvert.app
    cp -R "$APP" /Applications/
    open /Applications/DropConvert.app
    echo "Installed /Applications/DropConvert.app"
fi
