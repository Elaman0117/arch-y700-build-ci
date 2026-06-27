#!/usr/bin/env bash
# Compose a GPT disk image from an existing FAT boot image and an F2FS rootfs
# image.
#
# This is FS-agnostic: it just dd's the two images into a fresh GPT layout.
# Identical in behavior to the original Ubuntu version.
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
. "$SCRIPT_DIR/common.sh"

usage() {
  cat <<USAGE
Usage: $(basename "$0") BOOT_IMAGE ROOTFS_IMAGE OUTPUT_IMAGE

Compose a GPT disk image from an existing FAT boot image and F2FS rootfs image.

Environment inputs:
  BOOT_PARTLABEL            default: ESP
  ROOTFS_PARTLABEL          default: userdata
  ROOTFS_UUID               optional F2FS UUID (currently metadata-only; F2FS
                            UUIDs are set at mkfs time and not by tune2fs)
USAGE
}

[ $# -eq 3 ] || { usage >&2; exit 2; }

BOOT_IMAGE=$1
ROOTFS_IMAGE=$2
OUTPUT_IMAGE=$3
BOOT_PARTLABEL=${BOOT_PARTLABEL:-ESP}
ROOTFS_PARTLABEL=${ROOTFS_PARTLABEL:-userdata}

ci_require_cmd sgdisk
ci_require_cmd truncate
ci_require_cmd dd
ci_require_cmd stat

[ -f "$BOOT_IMAGE" ] || ci_die "missing boot image: $BOOT_IMAGE"
[ -f "$ROOTFS_IMAGE" ] || ci_die "missing rootfs image: $ROOTFS_IMAGE"

ceil_div() { echo $(( ($1 + $2 - 1) / $2 )); }
align_up() { echo $(( (($1 + $2 - 1) / $2) * $2 )); }

sector_size=512
first_sector=2048
align_sectors=2048
boot_size=$(stat -c%s "$BOOT_IMAGE")
root_size=$(stat -c%s "$ROOTFS_IMAGE")
boot_sectors=$(ceil_div "$boot_size" "$sector_size")
root_sectors=$(ceil_div "$root_size" "$sector_size")
boot_start=$first_sector
root_start=$(align_up $((boot_start + boot_sectors)) "$align_sectors")
root_end=$((root_start + root_sectors))
total_sectors=$(( $(align_up "$root_end" "$align_sectors") + 34 ))
total_bytes=$((total_sectors * sector_size))

tmp=$(mktemp "$(dirname "$OUTPUT_IMAGE")/.$(basename "$OUTPUT_IMAGE").XXXXXX")
trap 'rm -f "$tmp"' EXIT
truncate -s "$total_bytes" "$tmp"

sgdisk -o "$tmp" >/dev/null
sgdisk -n "1:${boot_start}:+${boot_sectors}" -t 1:ef00 -c 1:"$BOOT_PARTLABEL" -A 1:set:2 "$tmp" >/dev/null
sgdisk -n "2:${root_start}:+${root_sectors}" -t 2:8300 -c 2:"$ROOTFS_PARTLABEL" "$tmp" >/dev/null

dd if="$BOOT_IMAGE" of="$tmp" bs=4M conv=notrunc,fsync oflag=seek_bytes seek=$((boot_start * sector_size)) status=none

# Offline fsck before embedding. We don't know the FS type here, so try both.
# Whichever succeeds is fine; if neither exists, skip (the image was already
# fsck'd at the end of build-rootfs-image.sh).
if command -v fsck.f2fs >/dev/null 2>&1; then
  fsck.f2fs -p "$ROOTFS_IMAGE" || true
elif command -v e2fsck >/dev/null 2>&1; then
  e2fsck -f -y "$ROOTFS_IMAGE" || true
fi
dd if="$ROOTFS_IMAGE" of="$tmp" bs=4M conv=notrunc,fsync oflag=seek_bytes seek=$((root_start * sector_size)) status=none

mv "$tmp" "$OUTPUT_IMAGE"
trap - EXIT
sha256sum "$OUTPUT_IMAGE" > "$OUTPUT_IMAGE.sha256"
