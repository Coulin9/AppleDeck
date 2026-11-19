#!/bin/bash
# Wrap the existing app bundle in a drag-to-install disk image.
set -euo pipefail
source "$(cd "$(dirname "$0")/.." && pwd)/scripts/lib/common.sh"

[[ -d "$APP" ]] || die "missing build/AppleDeck.app; run ./build.sh first"
codesign --verify --deep --strict "$APP"

DMG="$ROOT/build/AppleDeck.dmg"
temp="$(mktemp -d "$ROOT/build/.dmg.XXXXXX")"
trap 'rm -rf "$temp"' EXIT

mkdir "$temp/volume"
ditto "$APP" "$temp/volume/AppleDeck.app"
ln -s /Applications "$temp/volume/Applications"
hdiutil create -fs HFS+ -volname AppleDeck -format UDZO \
    -srcfolder "$temp/volume" "$temp/AppleDeck.dmg"

# Replace the previous image only after the new one has been created.
mv -f "$temp/AppleDeck.dmg" "$DMG"
log "disk image: ${DMG#"$ROOT"/}"
