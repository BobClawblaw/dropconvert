#!/bin/bash
# Builds build/DropConvert-<version>.dmg and its SHA-256 checksum.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(cat version.txt)"
APP="build/DropConvert.app"
DMG="build/DropConvert-$VERSION.dmg"

./scripts/build-app.sh

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT

cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

rm -f "$DMG" "$DMG.sha256"
hdiutil create -volname "DropConvert" -srcfolder "$STAGING" -ov -format UDZO "$DMG"

IDENTITY="${DEVELOPER_ID:-}"
if [ -z "$IDENTITY" ]; then
    IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*"\(Developer ID Application:.*\)"/\1/p' | head -1)"
fi
if [ -n "$IDENTITY" ]; then
    codesign --force --sign "$IDENTITY" "$DMG"
fi

if [ "${NOTARIZE:-0}" = "1" ]; then
    xcrun notarytool submit "$DMG" \
        --apple-id "${APPLE_ID:?APPLE_ID is required}" \
        --team-id "${APPLE_TEAM_ID:?APPLE_TEAM_ID is required}" \
        --password "${APPLE_APP_PASSWORD:?APPLE_APP_PASSWORD is required}" \
        --wait
    xcrun stapler staple "$DMG"
    echo "Notarized and stapled $DMG"
fi

shasum -a 256 "$DMG" > "$DMG.sha256"
echo "Built $DMG"
cat "$DMG.sha256"
