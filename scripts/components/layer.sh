#!/bin/bash
# Pack the minimal guest layer: integration tree + Mesa + agent.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/lib/common.sh"

NAME=layer
OUTDIR="$OUT/$NAME"
GUEST="$OUT/guest-integration/rootfs"
MESA="$OUT/mesa/root"
AGENT="$OUT/agent/appledeck-agent"
CLIPBOARD="$OUT/agent/appledeck-clipboard"
MANGOAPP="$OUT/mangoapp/mangoapp"
MANGOAPP_LICENSE="$OUT/mangoapp/LICENSE"
PROBE="$OUT/neptune-probe/appledeck-api-probe"
GPU_PROBE="$OUT/neptune-probe/appledeck-gpu-probe"
NEPTUNE="$OUT/neptune/root.tar"
UU_RUNTIME="$OUT/uu-runtime/root.tar"
FEX_EAC="$OUT/fex-eac/root.tar"
for f in "$OUT/guest-integration/rootfs.tar" "$OUT/mesa/root.tar" "$AGENT" "$CLIPBOARD" "$MANGOAPP" "$MANGOAPP_LICENSE" "$PROBE" "$GPU_PROBE" "$NEPTUNE" "$UU_RUNTIME" "$FEX_EAC"; do
    [[ -f "$f" ]] || die "missing layer input: ${f#"$ROOT"/}"
done
INPUT="$(input_digest "$NAME" guest "$(sha256_file "$OUT/guest-integration/rootfs.tar")" mesa "$(sha256_file "$OUT/mesa/root.tar")" agent "$(sha256_file "$AGENT")" clipboard "$(sha256_file "$CLIPBOARD")" mangoapp "$(sha256_file "$MANGOAPP")" mangoapp_license "$(sha256_file "$MANGOAPP_LICENSE")" probe "$(sha256_file "$PROBE")" gpu_probe "$(sha256_file "$GPU_PROBE")" neptune "$(sha256_file "$NEPTUNE")" uu_runtime "$(sha256_file "$UU_RUNTIME")" fex_eac "$(sha256_file "$FEX_EAC")" erofs "$(mkfs.erofs --version | head -1)")"
if component_should_reuse "$NAME" "$INPUT" "$OUTDIR/appledeck-layer.img"; then exit 0; fi

rm -rf "$OUTDIR"
mkdir -p "$OUTDIR/rootfs"
cp -R "$GUEST/." "$OUTDIR/rootfs/"
cp -R "$MESA/." "$OUTDIR/rootfs/"
tar -C "$OUTDIR/rootfs" -xf "$NEPTUNE"
tar -C "$OUTDIR/rootfs" -xf "$UU_RUNTIME"
tar -C "$OUTDIR/rootfs" -xf "$FEX_EAC"
install -m 0755 "$AGENT" "$OUTDIR/rootfs/usr/bin/appledeck-agent"
# Podman volume exports may carry a Linux ACL that overrides the image's mode.
cp -X "$MANGOAPP" "$OUTDIR/rootfs/usr/bin/mangoapp"
chmod 0755 "$OUTDIR/rootfs/usr/bin/mangoapp"
mkdir -p "$OUTDIR/rootfs/usr/share/licenses/appledeck-mangoapp"
cp -X "$MANGOAPP_LICENSE" "$OUTDIR/rootfs/usr/share/licenses/appledeck-mangoapp/LICENSE"
chmod 0644 "$OUTDIR/rootfs/usr/share/licenses/appledeck-mangoapp/LICENSE"
mkdir -p "$OUTDIR/rootfs/usr/lib/appledeck"
install -m 0755 "$CLIPBOARD" "$OUTDIR/rootfs/usr/lib/appledeck/appledeck-clipboard"
install -m 0755 "$PROBE" "$OUTDIR/rootfs/usr/lib/appledeck/appledeck-api-probe"
install -m 0755 "$GPU_PROBE" "$OUTDIR/rootfs/usr/lib/appledeck/appledeck-gpu-probe"
if [[ ! -f "$OUTDIR/rootfs/usr/share/vulkan/icd.d/virtio_icd.aarch64.json" ]]; then
    die "Mesa install did not provide the virtio ICD JSON"
fi
printf 'appledeck-layer current-source-overlay standalone-runtime-components\n' \
    > "$OUTDIR/rootfs/usr/lib/appledeck/layer-release"
mkfs.erofs -b 4096 -zlz4 -T "$SOURCE_DATE_EPOCH" --all-root \
    -U 5fea1f2a-0c6b-4d5e-9a1e-0000000000a2 \
    "$OUTDIR/appledeck-layer.img" "$OUTDIR/rootfs" >/dev/null
fsck.erofs "$OUTDIR/appledeck-layer.img" >/dev/null
stamp_write "$NAME" "$INPUT" "$OUTDIR/appledeck-layer.img"
