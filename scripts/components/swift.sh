#!/bin/bash
# Build the Swift products against the locally built libkrun.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/lib/common.sh"

NAME=swift
OUTDIR="$OUT/$NAME"
INPUT="$(swift_input_digest)"

if component_should_reuse "$NAME" "$INPUT" "$OUTDIR/AppleDeck" "$OUTDIR/appledeck-vm" "$OUTDIR/appledeck-diagnostics"; then
    exit 0
fi

mkdir -p "$OUTDIR"
export APPLEDECK_LIBKRUN_DIR="$OUT/libkrun"
export APPLEDECK_LIBKRUN_INCLUDE="$ROOT/../libkrun/include"
swift build --disable-sandbox --package-path "$ROOT" -c release --product AppleDeck
swift build --disable-sandbox --package-path "$ROOT" -c release --product appledeck-vm
swift build --disable-sandbox --package-path "$ROOT" -c release --product appledeck-diagnostics
BIN="$(swift build --disable-sandbox --package-path "$ROOT" -c release --show-bin-path)"
cp "$BIN/AppleDeck" "$BIN/appledeck-vm" "$BIN/appledeck-diagnostics" "$OUTDIR/"
stamp_write "$NAME" "$INPUT" "$OUTDIR/AppleDeck" "$OUTDIR/appledeck-vm" "$OUTDIR/appledeck-diagnostics"
