#!/bin/bash
# Builds the DMG and publishes a GitHub release for the version in version.txt.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(cat version.txt)"
TAG="v$VERSION"

./scripts/build-dmg.sh

NOTES="$(awk -v version="$VERSION" '
    $0 ~ "^## \\[" version "\\]" { flag = 1; next }
    flag && $0 ~ "^## \\[" { flag = 0 }
    flag { print }
' CHANGELOG.md)"

if [ -z "$NOTES" ]; then
    NOTES="DropConvert $VERSION"
fi

if gh release view "$TAG" >/dev/null 2>&1; then
    gh release upload "$TAG" \
        "build/DropConvert-$VERSION.dmg" \
        "build/DropConvert-$VERSION.dmg.sha256" --clobber
else
    gh release create "$TAG" \
        "build/DropConvert-$VERSION.dmg" \
        "build/DropConvert-$VERSION.dmg.sha256" \
        --title "DropConvert $VERSION" \
        --notes "$NOTES"
fi

echo "Published $TAG"
