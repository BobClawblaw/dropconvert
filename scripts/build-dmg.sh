#!/bin/bash
# Builds build/DropConvert-<version>.dmg from the release app.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(sed -n 's/^VERSION="\(.*\)"$/\1/p' scripts/build-app.sh)"
APP="build/DropConvert.app"
DMG="build/DropConvert-$VERSION.dmg"

./scripts/build-app.sh

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT

cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

rm -f "$DMG"
hdiutil create -volname "DropConvert" -srcfolder "$STAGING" -ov -format UDZO "$DMG"
echo "Built $DMG"
