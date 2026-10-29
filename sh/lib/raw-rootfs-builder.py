#!/usr/bin/env python3
"""Adapt a COPY of current device rootfs builder to a fixed-size GPT SD-card
disk image: one partition (name from ROOT_PARTITION_LABEL) starting at
1 MiB and spanning the whole filesystem.
Never touch the sources, kernel, firmware, USB, SSH or network configuration.
Reject unrecognized upstream versions rather than silently using old sizes.
Upstream builders on the rootfs branch already use fixed sizes and full
free-space metadata; this layer keeps them and only replaces the final raw
ext4/zstd output with the partitioned SD-card image.
"""
from pathlib import Path
import os
import re
import sys

if len(sys.argv) != 5:
    raise SystemExit('Usage: raw-rootfs-builder.py SOURCE DEST alpine|debian|ubuntu channel|sanders')
source, dest = Path(sys.argv[1]), Path(sys.argv[2])
distro, device = sys.argv[3:5]
if distro not in ('alpine', 'debian', 'ubuntu') or device not in ('channel', 'sanders'):
    raise SystemExit('Unknown distro/device')
partlabel = os.environ.get('ROOT_PARTITION_LABEL', '')
if not re.fullmatch(r'[A-Za-z0-9_.-]+', partlabel):
    raise SystemExit('Missing or invalid ROOT_PARTITION_LABEL environment value')
body = source.read_text()

SIZE_MIB = int(os.environ.get('IMAGE_SIZE_MB', '1024'))
if distro == 'alpine':
    originals = ('IMAGE_MB=1024', 'MIN_FREE_MB=32')
    free_mib, inodes, journal_mib = 32, 16384, 8
else:
    originals = ('IMAGE_MB=1024', 'MIN_FREE_MB=64')
    free_mib, inodes, journal_mib = 64, 32768, 16
free_mib = int(os.environ.get('IMAGE_FREE_MIN', free_mib))
for sentinel in originals:
    if body.count(sentinel) != 1:
        raise SystemExit(f'Unknown upstream image policy: {sentinel!r} in {source}')

for key in ('image_size_mib', 'image_free_mib', 'image_min_free_mib', 'staged_rootfs_mib'):
    if f'echo "{key}=$' not in body:
        raise SystemExit(f'Missing existing free-space metadata: {key}')

begin = "USED_MB=\"$(sudo du -sm \"$ROOTFS\" | awk '{print $1}')\""
compression = 'zstd -T0 -10 -f "$ROOTFS_IMG" -o "$ROOTFS_IMG.zst"\nrm -f "$ROOTFS_IMG"'
if body.count(begin) != 1 or body.count(compression) != 1:
    raise SystemExit('Cannot safely identify filesystem creation/compression section')
a = body.index(begin)
b = body.index(compression)
if b <= a:
    raise SystemExit('Unexpected rootfs builder order')

policy = r'''USED_MB="$(sudo du -sm "$ROOTFS" | awk '{print $1}')"
IMAGE_MB=__SIZE__
MIN_FREE_MB=__FREE__
echo "__DISTRO__: staged ${USED_MB} MiB; target ${IMAGE_MB} MiB; required free ${MIN_FREE_MB} MiB"
# Build the filesystem first as a plain ext4 file, then wrap it as the
# single GPT partition (name __PARTLABEL__) of a microSD disk image. The
# partition starts at 1 MiB and spans exactly IMAGE_MB; the disk image adds
# a 1 MiB GPT head and a 1 MiB GPT tail on top. The kernel resolves the
# root with root=PARTLABEL=__PARTLABEL__, so the mmc index of the SD card
# does not matter.
ROOTFS_PART="$WORK_DIR/__DISTRO__-__DEVICE__-rootfs-fs.ext4"
ROOTFS_IMG="$OUT_DIR/__DISTRO__-__DEVICE__-rootfs.img"
rm -f "$ROOTFS_PART" "$ROOTFS_IMG"
truncate -s "${IMAGE_MB}M" "$ROOTFS_PART"
# Fixed inode budget and journal; mkfs -d populates from the real staged rootfs.
sudo mkfs.ext4 -F -m 0 -N __INODES__ -J size=__JOURNAL__ -L "$ROOTFS_LABEL" -U random -d "$ROOTFS" "$ROOTFS_PART"
test "$(stat -c %s "$ROOTFS_PART")" -eq $((IMAGE_MB * 1024 * 1024))
ROOTFS_EXT4_UUID="$(blkid -p -o value -s UUID "$ROOTFS_PART")"
test -n "$ROOTFS_EXT4_UUID"
sudo e2fsck -fn "$ROOTFS_PART"
test "$(blkid -p -o value -s LABEL "$ROOTFS_PART")" = "$ROOTFS_LABEL"
FS_STATS="$(sudo tune2fs -l "$ROOTFS_PART")"
FREE_BLOCKS="$(printf '%s\n' "$FS_STATS" | awk -F: '$1 == "Free blocks" {gsub(/[[:space:]]/, "", $2); print $2}')"
BLOCK_SIZE="$(printf '%s\n' "$FS_STATS" | awk -F: '$1 == "Block size" {gsub(/[[:space:]]/, "", $2); print $2}')"
[[ "$FREE_BLOCKS" =~ ^[0-9]+$ && "$BLOCK_SIZE" =~ ^[0-9]+$ ]] || {
  echo 'ERROR: Cannot inspect ext4 free-space metadata' >&2
  exit 1
}
FREE_MB=$((FREE_BLOCKS * BLOCK_SIZE / 1024 / 1024))
echo "__DISTRO__: ext4 ${IMAGE_MB} MiB total, ${FREE_MB} MiB free"
if [ "$FREE_MB" -lt "$MIN_FREE_MB" ]; then
  echo "ERROR: __DISTRO__ would leave only ${FREE_MB} MiB free; need ${MIN_FREE_MB} MiB." >&2
  echo 'Refusing to publish a nearly-full filesystem.' >&2
  exit 1
fi
# Wrap: GPT table plus the filesystem as the only partition (1 MiB in).
ROOTFS_PART_SECTORS="$((IMAGE_MB * 1024 * 1024 / 512))"
truncate -s "$((IMAGE_MB + 2))M" "$ROOTFS_IMG"
sudo sfdisk "$ROOTFS_IMG" <<SFDISK
label: gpt
start=2048, size=${ROOTFS_PART_SECTORS}, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name=__PARTLABEL__
SFDISK
sudo dd if="$ROOTFS_PART" of="$ROOTFS_IMG" bs=1M seek=1 conv=notrunc,fsync status=none
rm -f "$ROOTFS_PART"
test "$(stat -c %s "$ROOTFS_IMG")" -eq $(((IMAGE_MB + 2) * 1024 * 1024))
test "$(sudo sfdisk -d "$ROOTFS_IMG" | sed -n 's/.*name="\([^"]*\)".*/\1/p')" = "__PARTLABEL__"
test "$(sudo blkid -p -o value -s LABEL -O 1048576 "$ROOTFS_IMG")" = "$ROOTFS_LABEL"
test -s "$ROOTFS_IMG"

'''
for src, dst in [('__DISTRO__', distro), ('__DEVICE__', device), ('__SIZE__', str(SIZE_MIB)),
                 ('__FREE__', str(free_mib)), ('__INODES__', str(inodes)), ('__JOURNAL__', str(journal_mib)),
                 ('__PARTLABEL__', partlabel)]:
    policy = policy.replace(src, dst)
body = body[:a] + policy + body[b + len(compression):]

# The fixed-size check above replaces upstream's staging/free logic; the
# existing metadata echoes downstream stay as the authority for the checks
# performed by the local rootfs runner.
old_hash = f'sha256sum {distro}-{device}-rootfs.ext4.zst build-info.txt > SHA256SUMS.{distro}'
new_hash = f'sha256sum {distro}-{device}-rootfs.img build-info.txt > SHA256SUMS.{distro}'
if body.count(old_hash) != 1:
    raise SystemExit('Unexpected source SHA256SUMS layout in ' + str(source))
body = body.replace(old_hash, new_hash)
body = re.sub(r'echo "::group::Create[^\n"]*ext4[^\n"]*"',
              f'echo "::group::Create {SIZE_MIB} MiB {distro} SD-card GPT rootfs"', body, count=1)

dest.parent.mkdir(parents=True, exist_ok=True)
dest.write_text(body)
dest.chmod(0o755)
print(f'{device}/{distro}: {SIZE_MIB + 2} MiB GPT disk image ({SIZE_MIB} MiB ext4, partition name {partlabel}), minimum {free_mib} MiB free')
