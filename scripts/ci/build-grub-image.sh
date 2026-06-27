#!/usr/bin/env bash
# Build a FAT32 boot image for Lenovo Y700 (TB321FU / SM8650) containing:
#   * BOOTAA64.EFI   - standard UEFI entry
#   * QCOMRAMP.EFI   - Qualcomm RamPartition direct-boot entry (rescue only,
#                      no initrd support)
#   * grub.cfg       - outer GRUB config that defers to the F2FS rootfs's
#                      /boot/grub/grub.cfg when present
#   * /dtb/$DTB_NAME - device tree blob
#   * /vmlinuz-fallback + /initramfs-fallback.img - frozen kernel copied from
#                      the freshly-built rootfs; survives pacman upgrades so
#                      the device can always boot even if linux-aarch64 is
#                      broken in the rolling rootfs.
#
# This script depends on:
#   * scripts/lib/y700-direct-grub.sh - GRUB config/EFI builder helpers
#   * The F2FS rootfs image built by build-rootfs-image.sh, from which the
#     fallback kernel and initramfs are extracted.
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
. "$SCRIPT_DIR/common.sh"

REPO_ROOT=$(cd -- "$SCRIPT_DIR/../.." && pwd -P)
. "$REPO_ROOT/scripts/lib/y700-direct-grub.sh"

log() { ci_log "$@"; }
die() { ci_die "$@"; }

usage() {
  cat <<USAGE
Usage: $(basename "$0")

Build a FAT boot image carrying the Y700 GRUB payload plus a frozen fallback
kernel + initramfs extracted from a freshly-built F2FS rootfs image.

Environment inputs:
  OUTPUT_DIR                 default: out/ci-grub
  OUTPUT_PREFIX              default: arch-y700-armv8
  BOOT_TEMPLATE_IMAGE        optional verified FAT image template path/URL
  BOOT_TEMPLATE_IMAGE_URL    optional verified FAT image template URL/path
  BOOT_IMAGE_SIZE            default: 512M (needs to hold fallback kernel+initramfs)
  BOOT_FAT_BITS              12|16|32, default: 32
  BOOT_FAT_LABEL             default: Y700GRUB
  BOOT_SECTOR_SIZE           default: 512
  BOOT_CLUSTER_SECTORS       optional mkfs.vfat -s value
  BOOT_PARTLABEL             default: ESP (used by GRUB search --partlabel)
  KERNEL_ARTIFACT_ARCHIVE    optional URL/local path with Image + DTB
  KERNEL_IMAGE               path to fallback kernel (defaults to rootfs /boot/vmlinuz-linux)
  FALLBACK_KERNEL_PATH       same as KERNEL_IMAGE; explicit alias
  FALLBACK_INITRAMFS_PATH    path to fallback initramfs (defaults to rootfs /boot/initramfs-linux.img)
  FALLBACK_KERNEL_VERSION    optional version string for BOOT-INFO
  BOOTAA64_EFI               required unless BOOTAA64_EFI_URL set; optional with BOOT_TEMPLATE_IMAGE
  BOOTAA64_EFI_URL           optional URL/local path
  QCOMRAMP_EFI               optional prebuilt direct GRUB EFI
  QCOMRAMP_EFI_URL           optional URL/local path for prebuilt direct GRUB EFI
  QCOMRAMP_CFG_NAME          external config name expected by prebuilt EFI, default: qcomramp.cfg
  GRUB_BUILD_ARCHIVE          optional archive containing grub-mkstandalone + grub-core
  Y700_GRUB_BUILD_DIR        directory containing grub-mkstandalone and grub-core
  GRUB_TIMEOUT               default: 3
  DTB_FILE                   path to DTB file
  DTB_NAME                   default: basename(DTB_FILE) or sm8650-lenovo-tb321fu.dtb
  KERNEL_CONFIG              optional kernel.config file
  ROOT_PARTLABEL             default: userdata (must match the F2FS rootfs)
  ROOT_UUID                  optional; used if ROOT_SELECTOR=uuid
  ROOT_SELECTOR              partlabel|uuid|raw, default: partlabel
  ROOTARGS                   optional full rootargs override
  ROOTARGS_EXTRA             appended to generated rootargs
  STABLEARGS                 default: drm_client_lib.active=none
  INCLUDE_FALLBACK_KERNEL    default: 1; copy kernel+initramfs into FAT
  ROOTFS_IMAGE               optional path to a built rootfs image; if set and
                             KERNEL_IMAGE/FALLBACK_INITRAMFS_PATH are empty,
                             the script will mount the rootfs and copy
                             /boot/vmlinuz-linux + /boot/initramfs-linux.img.
  BOOT_COMPRESS              none|zstd|xz|7z, default: 7z
  BOOT_CHUNK_SIZE            optional 7z volume size, default: 1500m
  KEEP_BOOT_IMAGE            keep uncompressed boot image, default: 0
USAGE
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  usage
  exit 0
fi

ci_require_cmd mkfs.vfat
ci_require_cmd mcopy
ci_require_cmd mmd
ci_require_cmd mdir
ci_require_cmd sha256sum

OUTPUT_DIR=${OUTPUT_DIR:-out/ci-grub}
OUTPUT_PREFIX=${OUTPUT_PREFIX:-arch-y700-armv8}
BOOT_TEMPLATE_IMAGE=${BOOT_TEMPLATE_IMAGE:-${BOOT_TEMPLATE_IMAGE_URL:-}}
BOOT_IMAGE_SIZE=${BOOT_IMAGE_SIZE:-512M}
BOOT_FAT_BITS=${BOOT_FAT_BITS:-32}
BOOT_FAT_LABEL=${BOOT_FAT_LABEL:-Y700GRUB}
BOOT_SECTOR_SIZE=${BOOT_SECTOR_SIZE:-512}
BOOT_CLUSTER_SECTORS=${BOOT_CLUSTER_SECTORS:-}
BOOT_PARTLABEL=${BOOT_PARTLABEL:-ESP}
GRUB_TIMEOUT=${GRUB_TIMEOUT:-3}
ROOT_PARTLABEL=${ROOT_PARTLABEL:-userdata}
ROOT_SELECTOR=${ROOT_SELECTOR:-partlabel}
STABLEARGS=${STABLEARGS:-drm_client_lib.active=none}
QCOMRAMP_CFG_NAME=${QCOMRAMP_CFG_NAME:-qcomramp.cfg}
INCLUDE_FALLBACK_KERNEL=${INCLUDE_FALLBACK_KERNEL:-1}
BOOT_COMPRESS=${BOOT_COMPRESS:-7z}
BOOT_CHUNK_SIZE=${BOOT_CHUNK_SIZE:-1500m}
KEEP_BOOT_IMAGE=${KEEP_BOOT_IMAGE:-0}
DTB_NAME=${DTB_NAME:-sm8650-lenovo-tb321fu.dtb}
ROOTFS_IMAGE=${ROOTFS_IMAGE:-}
FALLBACK_KERNEL_PATH=${FALLBACK_KERNEL_PATH:-${KERNEL_IMAGE:-}}
FALLBACK_INITRAMFS_PATH=${FALLBACK_INITRAMFS_PATH:-}
FALLBACK_KERNEL_VERSION=${FALLBACK_KERNEL_VERSION:-}

mkdir -p "$OUTPUT_DIR"
work_dir=$(mktemp -d "$OUTPUT_DIR/.grub-build.XXXXXX")
payload_dir="$work_dir/payload"
mkdir -p "$payload_dir/EFI/BOOT" "$payload_dir/dtb" "$payload_dir/boot/grub"
trap 'rm -rf "$work_dir"' EXIT

# --- Resolve GRUB build dir ------------------------------------------------
if [ -n "${GRUB_BUILD_ARCHIVE:-}" ]; then
  mkdir -p "$work_dir/grub-build"
  ci_download "$GRUB_BUILD_ARCHIVE" "$work_dir/grub-build.tar"
  if ! tar -C "$work_dir/grub-build" -xf "$work_dir/grub-build.tar"; then
    tar -C "$work_dir/grub-build" -xzf "$work_dir/grub-build.tar"
  fi
  found=$(find "$work_dir/grub-build" -type f -name grub-mkstandalone -perm -111 | head -n1)
  test -n "$found"
  Y700_GRUB_BUILD_DIR=$(dirname "$found")
  export Y700_GRUB_BUILD_DIR
elif [ -n "${QCOMRAMP_EFI_URL:-}" ]; then
  Y700_GRUB_BUILD_DIR=
elif [ -n "$BOOT_TEMPLATE_IMAGE" ]; then
  Y700_GRUB_BUILD_DIR=
else
  : # Y700_GRUB_BUILD_DIR may be inherited from the environment.
fi

# --- Resolve kernel artifact archive (provides Image + DTB) -----------------
if [ -n "${KERNEL_ARTIFACT_ARCHIVE:-}" ]; then
  archive="$work_dir/kernel-artifacts.archive"
  ci_download "$KERNEL_ARTIFACT_ARCHIVE" "$archive"
  ci_extract_archive "$archive" "$work_dir/kernel-artifacts"
  DTB_FILE=${DTB_FILE:-$(find "$work_dir/kernel-artifacts" -type f -name "$DTB_NAME" | head -n1 || true)}
  KERNEL_CONFIG=${KERNEL_CONFIG:-$(find "$work_dir/kernel-artifacts" -type f -name kernel.config | head -n1 || true)}
  if [ -z "$FALLBACK_KERNEL_PATH" ]; then
    FALLBACK_KERNEL_PATH=$(find "$work_dir/kernel-artifacts" -type f -name Image | head -n1 || true)
  fi
fi

if [ -n "${BOOTAA64_EFI_URL:-}" ]; then
  BOOTAA64_EFI="$work_dir/BOOTAA64.EFI"
  ci_download "$BOOTAA64_EFI_URL" "$BOOTAA64_EFI"
fi
if [ -n "${QCOMRAMP_EFI_URL:-}" ]; then
  QCOMRAMP_EFI="$work_dir/QCOMRAMP.EFI"
  ci_download "$QCOMRAMP_EFI_URL" "$QCOMRAMP_EFI"
fi

# --- Extract fallback kernel from rootfs image if not given explicitly ------
if ci_bool "$INCLUDE_FALLBACK_KERNEL"; then
  if [ -z "$FALLBACK_KERNEL_PATH" ] || [ -z "$FALLBACK_INITRAMFS_PATH" ]; then
    if [ -z "$ROOTFS_IMAGE" ]; then
      # Try the default location produced by build-rootfs-image.sh.
      ROOTFS_IMAGE="$OUTPUT_DIR/../ci-rootfs/${OUTPUT_PREFIX}-rootfs.img"
    fi
    if [ -f "$ROOTFS_IMAGE" ]; then
      log "mounting rootfs image to extract fallback kernel: $ROOTFS_IMAGE"
      rootfs_mount="$work_dir/rootfs-mount"
      mkdir -p "$rootfs_mount"
      # F2FS image - needs f2fs module on host.
      mount -o loop,ro "$ROOTFS_IMAGE" "$rootfs_mount"
      FALLBACK_KERNEL_PATH=${FALLBACK_KERNEL_PATH:-"$rootfs_mount/boot/vmlinuz-linux"}
      FALLBACK_INITRAMFS_PATH=${FALLBACK_INITRAMFS_PATH:-"$rootfs_mount/boot/initramfs-linux.img"}
      if [ -z "$FALLBACK_KERNEL_VERSION" ] && [ -f "$rootfs_mount/usr/lib/modules/"*/modules.dep ]; then
        FALLBACK_KERNEL_VERSION=$(basename "$(find "$rootfs_mount/usr/lib/modules" -maxdepth 1 -mindepth 1 -type d | head -n1)" 2>/dev/null || true)
      fi
      # Defer umount until after we've copied the files.
    else
      die "INCLUDE_FALLBACK_KERNEL=1 but no kernel source. Set KERNEL_ARTIFACT_ARCHIVE, FALLBACK_KERNEL_PATH, or ROOTFS_IMAGE."
    fi
  fi
fi

[ -n "${DTB_FILE:-}" ] && [ -f "$DTB_FILE" ] || die "DTB_FILE is required (set DTB_FILE or KERNEL_ARTIFACT_ARCHIVE)"
DTB_NAME=${DTB_NAME:-$(basename "$DTB_FILE")}
if [ -n "$BOOT_TEMPLATE_IMAGE" ]; then
  : # BOOTAA64_EFI may be optional with template
else
  [ -n "${BOOTAA64_EFI:-}" ] && [ -f "$BOOTAA64_EFI" ] || die "BOOTAA64_EFI or BOOTAA64_EFI_URL is required without BOOT_TEMPLATE_IMAGE"
fi

# --- Compute rootargs ------------------------------------------------------
case "$ROOT_SELECTOR" in
  partlabel)
    generated_rootargs="root=PARTLABEL=$ROOT_PARTLABEL rw rootwait"
    ;;
  uuid)
    [ -n "${ROOT_UUID:-}" ] || die "ROOT_SELECTOR=uuid requires ROOT_UUID"
    generated_rootargs="root=UUID=$ROOT_UUID rw rootwait"
    ;;
  raw)
    [ -n "${ROOTARGS:-}" ] || die "ROOT_SELECTOR=raw requires ROOTARGS"
    generated_rootargs="$ROOTARGS"
    ;;
  *) die "unsupported ROOT_SELECTOR=$ROOT_SELECTOR" ;;
esac
if [ -n "${ROOTARGS:-}" ] && [ "$ROOT_SELECTOR" != raw ]; then
  generated_rootargs="$ROOTARGS"
fi
if [ -n "${ROOTARGS_EXTRA:-}" ]; then
  generated_rootargs="$generated_rootargs $ROOTARGS_EXTRA"
fi

# --- Assemble FAT payload --------------------------------------------------
if [ -n "${BOOTAA64_EFI:-}" ] && [ -f "$BOOTAA64_EFI" ]; then
  cp -a "$BOOTAA64_EFI" "$payload_dir/EFI/BOOT/BOOTAA64.EFI"
fi
cp -a "$DTB_FILE" "$payload_dir/dtb/$DTB_NAME"
# Some bootloader configurations expect a platform.dtb alias.
cp -a "$DTB_FILE" "$payload_dir/dtb/platform.dtb"
if [ -n "${KERNEL_CONFIG:-}" ] && [ -f "$KERNEL_CONFIG" ]; then
  cp -a "$KERNEL_CONFIG" "$payload_dir/kernel.config"
fi

# Stage the fallback kernel + initramfs into the FAT payload.
if ci_bool "$INCLUDE_FALLBACK_KERNEL"; then
  [ -n "$FALLBACK_KERNEL_PATH" ] && [ -f "$FALLBACK_KERNEL_PATH" ] || die "INCLUDE_FALLBACK_KERNEL=1 but FALLBACK_KERNEL_PATH is missing"
  [ -n "$FALLBACK_INITRAMFS_PATH" ] && [ -f "$FALLBACK_INITRAMFS_PATH" ] || die "INCLUDE_FALLBACK_KERNEL=1 but FALLBACK_INITRAMFS_PATH is missing"
  log "staging fallback kernel: $(basename "$FALLBACK_KERNEL_PATH") + $(basename "$FALLBACK_INITRAMFS_PATH")"
  cp -a "$FALLBACK_KERNEL_PATH" "$payload_dir/vmlinuz-fallback"
  cp -a "$FALLBACK_INITRAMFS_PATH" "$payload_dir/initramfs-fallback.img"
fi

# Build or copy QCOMRAMP.EFI for the rescue-only direct boot path.
if [ -n "${QCOMRAMP_EFI:-}" ] && [ -f "$QCOMRAMP_EFI" ]; then
  cp -a "$QCOMRAMP_EFI" "$payload_dir/EFI/BOOT/$Y700_DIRECT_BOOT_EFI_NAME"
  y700_write_direct_grub_cfg "$payload_dir/EFI/BOOT/$QCOMRAMP_CFG_NAME" "$DTB_NAME" "$generated_rootargs" "$STABLEARGS"
elif [ -z "$BOOT_TEMPLATE_IMAGE" ] && [ -n "${Y700_GRUB_BUILD_DIR:-}" ] && [ -x "$Y700_GRUB_BUILD_DIR/grub-mkstandalone" ]; then
  y700_stage_direct_grub_payload "$payload_dir/EFI/BOOT" "$DTB_NAME" "$GRUB_TIMEOUT" "$generated_rootargs" "$STABLEARGS"
fi

# Write the dual-kernel outer grub.cfg into the FAT image. This is the config
# BOOTAA64.EFI will load first. It defers to the F2FS rootfs's inner grub.cfg
# when one exists (which build-rootfs-image.sh ensures it does).
y700_write_dual_kernel_grub_cfg \
  "$payload_dir/boot/grub/grub.cfg" \
  "$GRUB_TIMEOUT" \
  "$DTB_NAME" \
  "$generated_rootargs" \
  "$STABLEARGS" \
  "$BOOT_PARTLABEL" \
  "$ROOT_PARTLABEL"

# Also drop a copy at /EFI/BOOT/grub.cfg for UEFI Boot Services that look there.
cp -a "$payload_dir/boot/grub/grub.cfg" "$payload_dir/EFI/BOOT/grub.cfg"

# --- BOOT-INFO.txt + SHA256SUMS.txt ----------------------------------------
cat > "$payload_dir/BOOT-INFO.txt" <<INFO
generated=$(date -u -Iseconds)
boot_template_image=${BOOT_TEMPLATE_IMAGE:-}
boot_image_size=$BOOT_IMAGE_SIZE
boot_fat_bits=$BOOT_FAT_BITS
boot_fat_label=$BOOT_FAT_LABEL
boot_partlabel=$BOOT_PARTLABEL
root_selector=$ROOT_SELECTOR
root_partlabel=$ROOT_PARTLABEL
root_uuid=${ROOT_UUID:-}
rootargs=$generated_rootargs
stableargs=$STABLEARGS
dtb_name=$DTB_NAME
include_fallback_kernel=$INCLUDE_FALLBACK_KERNEL
fallback_kernel_version=${FALLBACK_KERNEL_VERSION:-unknown}
fallback_kernel_source=${FALLBACK_KERNEL_PATH:-}
fallback_initramfs_source=${FALLBACK_INITRAMFS_PATH:-}
bootaa64_source=${BOOTAA64_EFI:-from-template}
qcomramp_source=${QCOMRAMP_EFI:-from-template}
qcomramp_cfg_name=$QCOMRAMP_CFG_NAME
grub_build_dir=${Y700_GRUB_BUILD_DIR:-none}
INFO

ci_write_sha256sums "$payload_dir" "$payload_dir/SHA256SUMS.txt"

# --- Build the FAT image ---------------------------------------------------
boot_img="$OUTPUT_DIR/${OUTPUT_PREFIX}-grub-fat.img"
rm -f "$boot_img"

if [ -n "$BOOT_TEMPLATE_IMAGE" ]; then
  template_img="$work_dir/boot-template.img"
  log "using verified boot template image: $BOOT_TEMPLATE_IMAGE"
  ci_download "$BOOT_TEMPLATE_IMAGE" "$template_img"
  cp -a "$template_img" "$boot_img"

  mdir -i "$boot_img" ::/EFI/BOOT >/dev/null
  mdir -i "$boot_img" ::/dtb >/dev/null
  mdir -i "$boot_img" ::/boot/grub >/dev/null
  mcopy -o -i "$boot_img" "$payload_dir/dtb/$DTB_NAME" "::/dtb/$DTB_NAME"
  mcopy -o -i "$boot_img" "$payload_dir/dtb/platform.dtb" ::/dtb/platform.dtb
  if [ -f "$payload_dir/EFI/BOOT/BOOTAA64.EFI" ]; then
    mcopy -o -i "$boot_img" "$payload_dir/EFI/BOOT/BOOTAA64.EFI" ::/EFI/BOOT/BOOTAA64.EFI
  fi
  if [ -f "$payload_dir/EFI/BOOT/$Y700_DIRECT_BOOT_EFI_NAME" ]; then
    mcopy -o -i "$boot_img" "$payload_dir/EFI/BOOT/$Y700_DIRECT_BOOT_EFI_NAME" "::/EFI/BOOT/$Y700_DIRECT_BOOT_EFI_NAME"
  fi
  if [ -f "$payload_dir/EFI/BOOT/$QCOMRAMP_CFG_NAME" ]; then
    mcopy -o -i "$boot_img" "$payload_dir/EFI/BOOT/$QCOMRAMP_CFG_NAME" "::/EFI/BOOT/$QCOMRAMP_CFG_NAME"
  fi
  if ci_bool "$INCLUDE_FALLBACK_KERNEL"; then
    mcopy -o -i "$boot_img" "$payload_dir/vmlinuz-fallback" ::/vmlinuz-fallback
    mcopy -o -i "$boot_img" "$payload_dir/initramfs-fallback.img" ::/initramfs-fallback.img
  fi
  mcopy -o -i "$boot_img" "$payload_dir/boot/grub/grub.cfg" ::/boot/grub/grub.cfg
  mcopy -o -i "$boot_img" "$payload_dir/EFI/BOOT/grub.cfg" ::/EFI/BOOT/grub.cfg
  if [ -f "$payload_dir/kernel.config" ]; then
    mcopy -o -i "$boot_img" "$payload_dir/kernel.config" ::/kernel.config
  fi
  mcopy -o -i "$boot_img" "$payload_dir/BOOT-INFO.txt" "$payload_dir/SHA256SUMS.txt" ::/
else
  log "creating new FAT$BOOT_FAT_BITS image: $boot_img"
  truncate -s "$BOOT_IMAGE_SIZE" "$boot_img"
  mkfs_args=(-F "$BOOT_FAT_BITS" -S "$BOOT_SECTOR_SIZE" -n "$BOOT_FAT_LABEL")
  if [ -n "$BOOT_CLUSTER_SECTORS" ]; then
    mkfs_args+=(-s "$BOOT_CLUSTER_SECTORS")
  fi
  mkfs.vfat "${mkfs_args[@]}" "$boot_img"

  mmd -i "$boot_img" ::/EFI ::/EFI/BOOT ::/dtb ::/boot ::/boot/grub
  mcopy -i "$boot_img" \
    "$payload_dir/BOOT-INFO.txt" \
    "$payload_dir/SHA256SUMS.txt" \
    ::/
  mcopy -i "$boot_img" "$payload_dir/dtb/$DTB_NAME" "::/dtb/$DTB_NAME"
  mcopy -i "$boot_img" "$payload_dir/dtb/platform.dtb" ::/dtb/platform.dtb
  mcopy -i "$boot_img" "$payload_dir/EFI/BOOT/"* ::/EFI/BOOT/
  if ci_bool "$INCLUDE_FALLBACK_KERNEL"; then
    mcopy -i "$boot_img" "$payload_dir/vmlinuz-fallback" ::/vmlinuz-fallback
    mcopy -i "$boot_img" "$payload_dir/initramfs-fallback.img" ::/initramfs-fallback.img
  fi
  mcopy -i "$boot_img" "$payload_dir/boot/grub/grub.cfg" ::/boot/grub/grub.cfg
  if [ -f "$payload_dir/kernel.config" ]; then
    mcopy -i "$boot_img" "$payload_dir/kernel.config" ::/kernel.config
  fi
fi

# --- If we mounted the rootfs image, write the inner grub.cfg now ----------
if [ -n "${rootfs_mount:-}" ] && mountpoint -q "$rootfs_mount" 2>/dev/null; then
  log "writing inner grub.cfg into F2FS rootfs"
  mkdir -p "$rootfs_mount/boot/grub"
  y700_write_inner_grub_cfg \
    "$rootfs_mount/boot/grub/grub.cfg" \
    "$DTB_NAME" \
    "$generated_rootargs" \
    "$STABLEARGS" \
    "$BOOT_PARTLABEL"
  umount "$rootfs_mount"
fi

# --- Checksums + compression ----------------------------------------------
raw_sha_file="$OUTPUT_DIR/${OUTPUT_PREFIX}-grub-fat.raw.sha256"
checksum_file="$OUTPUT_DIR/${OUTPUT_PREFIX}-grub-fat.SHA256SUMS"
( cd "$OUTPUT_DIR" && sha256sum "$(basename "$boot_img")" > "$(basename "$raw_sha_file")" )
rm -f "$checksum_file"
( cd "$OUTPUT_DIR" && sha256sum "$(basename "$raw_sha_file")" > "$(basename "$checksum_file")" )

case "$BOOT_COMPRESS" in
  none)
    ( cd "$OUTPUT_DIR" && sha256sum "$(basename "$boot_img")" >> "$(basename "$checksum_file")" )
    ;;
  zstd)
    ci_require_cmd zstd
    zstd -T0 -19 -f "$boot_img" -o "$boot_img.zst"
    ( cd "$OUTPUT_DIR" && sha256sum "$(basename "$boot_img").zst" >> "$(basename "$checksum_file")" )
    ;;
  xz)
    xz -T0 -k -f "$boot_img"
    ( cd "$OUTPUT_DIR" && sha256sum "$(basename "$boot_img").xz" >> "$(basename "$checksum_file")" )
    ;;
  7z)
    ci_require_cmd 7z
    sevenz_out="$boot_img.7z"
    rm -f "$sevenz_out" "$sevenz_out".*
    if [ -n "${BOOT_CHUNK_SIZE:-}" ]; then
      7z a "$sevenz_out" "$boot_img" -t7z -m0=lzma2 -mx=9 -mmt=on "-v$BOOT_CHUNK_SIZE" >/dev/null
      ( cd "$OUTPUT_DIR" && sha256sum "$(basename "$sevenz_out")".* >> "$(basename "$checksum_file")" )
    else
      7z a "$sevenz_out" "$boot_img" -t7z -m0=lzma2 -mx=9 -mmt=on >/dev/null
      ( cd "$OUTPUT_DIR" && sha256sum "$(basename "$sevenz_out")" >> "$(basename "$checksum_file")" )
    fi
    ;;
  *) die "unsupported BOOT_COMPRESS=$BOOT_COMPRESS" ;;
esac

if [ "$BOOT_COMPRESS" != none ] && [ "$KEEP_BOOT_IMAGE" != 1 ]; then
  rm -f "$boot_img"
fi

log "GRUB boot image complete: $OUTPUT_DIR"
