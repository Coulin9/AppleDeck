#!/bin/bash
# Build the static aarch64 guest PE classifier used by strict routing.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/lib/common.sh"

NAME=neptune-probe
SRC="$ROOT/runtime/guest/tools/appledeck-api-probe.c"
GPU_SRC="$ROOT/runtime/guest/tools/appledeck-gpu-probe.c"
OUTDIR="$OUT/$NAME"
[[ -f "$SRC" && -f "$GPU_SRC" ]] || die "missing guest probe source"
INPUT="$(input_digest "$NAME" source "$(sha256_file "$SRC")" gpu "$(sha256_file "$GPU_SRC")" image "$BUILDER_IMAGE" config static-aarch64-linux)"
if component_should_reuse "$NAME" "$INPUT" "$OUTDIR/appledeck-api-probe" "$OUTDIR/appledeck-gpu-probe"; then exit 0; fi

require_builder
BUILDER_IMAGE_TAG=appledeck-guest-builder
if ! builder image exists "$BUILDER_IMAGE_TAG" >/dev/null 2>&1; then
    builder build --tag "$BUILDER_IMAGE_TAG" -f "$ROOT/scripts/containers/guest.Dockerfile" "$ROOT/scripts/containers"
fi
rm -rf "$OUTDIR"
mkdir -p "$OUTDIR"
builder run --rm \
    -v "$ROOT/runtime/guest/tools:/src:ro" \
    -v "$OUTDIR:/out:rw" \
    "$BUILDER_IMAGE_TAG" \
    bash -lc 'gcc -O2 -static -Wall -Wextra -Werror -o /out/appledeck-api-probe /src/appledeck-api-probe.c && gcc -O2 -static -Wall -Wextra -Werror -o /out/appledeck-gpu-probe /src/appledeck-gpu-probe.c'
file "$OUTDIR/appledeck-api-probe" "$OUTDIR/appledeck-gpu-probe"
[[ "$(file -b "$OUTDIR/appledeck-api-probe")" == *"ARM aarch64"* ]] || die "api probe is not aarch64"
[[ "$(file -b "$OUTDIR/appledeck-gpu-probe")" == *"ARM aarch64"* ]] || die "gpu probe is not aarch64"
stamp_write "$NAME" "$INPUT" "$OUTDIR/appledeck-api-probe" "$OUTDIR/appledeck-gpu-probe"
