#!/bin/bash
# Stage the AppleDeck guest integration tree and verify it is brand-free.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/lib/common.sh"

NAME=guest-integration
SRC="$ROOT/runtime/guest/rootfs"
OUTDIR="$OUT/$NAME"
DIGEST="$(cd "$SRC" && find . \( -type f -o -type l \) -print0 | sort -z | xargs -0 shasum -a 256 | shasum -a 256 | awk '{print $1}')"
INPUT="$(input_digest "$NAME" tree "$DIGEST")"
if component_should_reuse "$NAME" "$INPUT" "$OUTDIR/rootfs.tar"; then exit 0; fi

if grep -RIl 'steamac\|Steamac\|STEAMAC' "$SRC" 2>/dev/null | head -1 | grep -q .; then
    grep -RIl 'steamac\|Steamac\|STEAMAC' "$SRC" >&2 || true
    die "guest integration still contains steamac branding"
fi
rm -rf "$OUTDIR"
mkdir -p "$OUTDIR"
cp -R "$SRC" "$OUTDIR/rootfs"
tar -C "$OUTDIR/rootfs" -cf "$OUTDIR/rootfs.tar" .
stamp_write "$NAME" "$INPUT" "$OUTDIR/rootfs.tar"
