#!/bin/bash
# Create a fresh local SteamOS test image from the partitions of an existing
# SteamOS disk. The product build never reads this image.
#
#   ./scripts/test-image.sh [SOURCE_DISK]
#
# Output: build/test/AppleDeckTest.img (64 GiB sparse, fresh home, fresh
# /esp/appledeck boot state, no legacy boot state).
set -euo pipefail
source "$(cd "$(dirname "$0")/.." && pwd)/scripts/lib/common.sh"
require_builder
require_cmd qemu-img

SOURCE="${1:-${APPLEDECK_SOURCE_DISK:-/Volumes/Extreme SSD/SteamOS/steamos.img}}"
[[ -f "$SOURCE" ]] || die "source disk not found: $SOURCE"
TESTDIR="$ROOT/build/test"
IMAGE="$TESTDIR/AppleDeckTest.img"
mkdir -p "$TESTDIR"
if [[ -f "$IMAGE" ]]; then
    die "test image already exists: $IMAGE (remove it explicitly to recreate)"
fi

# 64 GiB = 134217728 sectors.
SECTORS=134217728
qemu-img create -f raw "$IMAGE" 64G >/dev/null

# Read the original PARTUUIDs so rootfs/partsets stay valid.
PARTUUIDS=()
while IFS= read -r line; do
    PARTUUIDS+=("$line")
done < <(python3 - "$SOURCE" <<'PY'
import struct, sys, uuid
p = sys.argv[1]
with open(p, 'rb') as f:
    f.seek(512)
    h = f.read(512)
    if h[:8] != b'EFI PART':
        raise SystemExit('no GPT')
    entries = struct.unpack_from('<Q', h, 72)[0]
    count = struct.unpack_from('<I', h, 80)[0]
    size = struct.unpack_from('<I', h, 84)[0]
    f.seek(entries * 512)
    data = f.read(count * size)
    for i in range(8):
        e = data[i*size:(i+1)*size]
        print(str(uuid.UUID(bytes_le=e[16:32])))
PY
)
[[ ${#PARTUUIDS[@]} -eq 8 ]] || die "cannot read 8 partition UUIDs from $SOURCE"

# Build the new GPT with the original partition offsets and UUIDs.
builder run --rm --privileged -v "$IMAGE:/image" appledeck-guest-builder bash -lc "
set -euo pipefail
sgdisk --zap-all /image
sgdisk \
  -n 1:2048:526335       -t 1:ef00 -c 1:esp       -u 1:${PARTUUIDS[0]} \
  -n 2:526336:657407     -t 2:ef00 -c 2:efi-A     -u 2:${PARTUUIDS[1]} \
  -n 3:657408:788479     -t 3:ef00 -c 3:efi-B     -u 3:${PARTUUIDS[2]} \
  -n 4:788480:21759999   -t 4:8300 -c 4:rootfs-A -u 4:${PARTUUIDS[3]} \
  -n 5:21760000:42731519 -t 5:8300 -c 5:rootfs-B -u 5:${PARTUUIDS[4]} \
  -n 6:42731520:44828671 -t 6:8300 -c 6:var-A    -u 6:${PARTUUIDS[5]} \
  -n 7:44828672:46925823 -t 7:8300 -c 7:var-B    -u 7:${PARTUUIDS[6]} \
  -n 8:46925824:$((SECTORS-34)) -t 8:8300 -c 8:home -u 8:${PARTUUIDS[7]} \
  /image
"

# Copy the original partitions byte-for-byte (all offsets are MiB-aligned).
copy_mib() { # source seek_mib count_mib
    dd if="$SOURCE" of="$IMAGE" bs=1048576 skip="$2" seek="$2" count="$3" conv=notrunc status=none
}
copy_mib "$SOURCE" 1 256        # esp
copy_mib "$SOURCE" 257 64       # efi-A
copy_mib "$SOURCE" 321 64       # efi-B
copy_mib "$SOURCE" 385 10240    # rootfs-A
copy_mib "$SOURCE" 10625 10240  # rootfs-B
copy_mib "$SOURCE" 20865 1024   # var-A
copy_mib "$SOURCE" 21889 1024   # var-B

# Fresh ext4 home on the new image's home partition. Formatting a temporary
# partition-sized file avoids requiring loop devices in the container.
HOME_START=46925824
HOME_SECTORS=$((SECTORS - 34 - HOME_START + 1))
HOME_BYTES=$((HOME_SECTORS * 512))
HOME_SEEK_MIB=$((HOME_START / 2048))
builder run --rm --privileged -v "$IMAGE:/image" appledeck-guest-builder bash -lc "
set -euo pipefail
truncate -s $HOME_BYTES /tmp/home.ext4
mkdir -p /tmp/roothome/steamos
chown 1000:1000 /tmp/roothome/steamos
mke2fs -t ext4 -q -F -L home -O casefold -T huge -m 0 -d /tmp/roothome /tmp/home.ext4
dd if=/tmp/home.ext4 of=/image bs=1048576 seek=$HOME_SEEK_MIB conv=notrunc,sparse status=none
rm -rf /tmp/home.ext4 /tmp/roothome
"

# Replace the legacy state directory with /esp/appledeck.
printf 'BOOT_ORDER=A B\nBOOT_A_LEFT=3\nBOOT_B_LEFT=3\n' > "$TESTDIR/bootenv"
builder run --rm --privileged -v "$IMAGE:/image" -v "$TESTDIR/bootenv:/bootenv:ro" \
    appledeck-guest-builder bash -lc '
set -euo pipefail
off=$((2048 * 512))
command -v mmd >/dev/null
mmd -i "/image@@\$off" ::/appledeck || true
mcopy -o -i "/image@@$off" /bootenv ::/appledeck/bootenv
mdeltree -i "/image@@$off" ::/steamac 2>/dev/null || true
'

log "test image: ${IMAGE#"$ROOT"/}"
qemu-img info "$IMAGE" | head -5
