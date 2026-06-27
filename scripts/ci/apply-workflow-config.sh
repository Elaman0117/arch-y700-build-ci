#!/usr/bin/env bash
# Validate KEY=value workflow dispatch config blocks and emit them to GITHUB_ENV.
#
# The allow-list is the only place that defines which keys the workflow accepts.
# Adding a new build knob requires extending the allow-list here; everything else
# (workflow YAML, build scripts) reads keys through the environment.
set -euo pipefail

usage() {
  cat <<USAGE
Usage: $(basename "$0") CONFIG_FILE

Read KEY=value lines from CONFIG_FILE and append allowed keys to GITHUB_ENV.
Blank lines and lines starting with # are ignored.
USAGE
}

[ "${1:-}" != "--help" ] || { usage; exit 0; }
[ "$#" -eq 1 ] || { usage >&2; exit 2; }
[ -n "${GITHUB_ENV:-}" ] || { echo 'GITHUB_ENV is not set' >&2; exit 1; }

config_file=$1
[ -f "$config_file" ] || { echo "missing config file: $config_file" >&2; exit 1; }

# Arch-specific allow-list. Replaces the Ubuntu DEB_* keys with PKG_* / STAGE_*
# equivalents, and adds F2FS / fallback-kernel knobs.
allowed=' ARCH ROOTFS_TARBALL_URL ROOTFS_TARBALL_PATH PACMAN_MIRROR PACMAN_ARCH ARCH_LINUXARM_REPO ROOTFS_IMAGE_SIZE ROOTFS_FSTYPE ROOTFS_UUID ROOTFS_LABEL ROOTFS_PARTLABEL ROOTFS_F2FS_OPTIONS HOSTNAME_NAME DEFAULT_USER_NAME DEFAULT_USER_PASSWORD ROOT_PASSWORD_MODE ROOT_PASSWORD USER_SUDO_MODE TZ_REGION LOCALES LANG_NAME PACKAGE_LIST DESKTOP_ENV OVERLAY_ARCHIVE OVERLAY_DIR PKG_ARCHIVE PKG_DIR SENSOR_STAGE_DIR HAPTICS_STAGE_DIR CAMERA_STACK_STAGE_DIR BUILD_Y700_SENSOR_STAGE BUILD_TB321FU_HAPTICS_STAGE BUILD_TB321FU_CAMERA_STACK BUILD_TB321FU_GPU_SENSOR TB321FU_GPU_SENSOR_SOURCE_DIR TB321FU_GPU_SENSOR_BUILD_JOBS SENSOR_SOURCE_ARCHIVE SENSOR_SOURCE_DIR SENSOR_BASELINE_OVERLAY_ARCHIVE SENSOR_BASELINE_OVERLAY_DIR SENSOR_STAGE_VERSION SENSOR_STRIP HAPTICS_SOURCE_ARCHIVE HAPTICS_SOURCE_DIR HAPTICS_STAGE_VERSION HAPTICS_STRIP KERNEL_SOURCE_ARCHIVE KERNEL_SOURCE_DIR KERNEL_BUILD_ARCHIVE KERNEL_BUILD_DIR CAMERA_STACK_ARCHIVE CAMERA_STACK_DIR CAMERA_STACK_STAGE_VERSION INSTALL_GNOME_SNAPSHOT APPLY_Y700_FIRMWARE_FIXES APPLY_Y700_AUDIO_POLICY_FIXES SDDM_AUTOLOGIN SDDM_AUTOLOGIN_SESSION MKINITCPIO_PRESETS MKINITCPIO_MODULES MKINITCPIO_HOOKS CLEAN_PACMAN_CACHE COMPRESS CHUNK_SIZE KEEP_RAW_IMAGE OUTPUT_DIR OUTPUT_PREFIX BOOT_TEMPLATE_IMAGE BOOT_TEMPLATE_IMAGE_URL BOOT_IMAGE_SIZE BOOT_FAT_BITS BOOT_FAT_LABEL BOOT_SECTOR_SIZE BOOT_CLUSTER_SECTORS KERNEL_ARTIFACT_ARCHIVE BOOTAA64_EFI BOOTAA64_EFI_URL QCOMRAMP_EFI QCOMRAMP_EFI_URL QCOMRAMP_CFG_NAME GRUB_BUILD_ARCHIVE GRUB_BUILD_DIR DTB_NAME DTB_FILE ROOT_SELECTOR ROOT_PARTLABEL ROOT_UUID ROOTARGS ROOTARGS_EXTRA STABLEARGS GRUB_TIMEOUT INCLUDE_FALLBACK_KERNEL FALLBACK_KERNEL_VERSION FALLBACK_INITRAMFS_PATH FALLBACK_KERNEL_PATH BOOT_COMPRESS BOOT_CHUNK_SIZE KEEP_BOOT_IMAGE BOOT_PARTLABEL Y700_GRUB_BUILD_DIR '

emit_env() {
  local key=$1
  local value=$2
  local delim="EOF_${key}_$$_$(date +%s%N)"
  {
    printf '%s<<%s\n' "$key" "$delim"
    printf '%s\n' "$value"
    printf '%s\n' "$delim"
  } >> "$GITHUB_ENV"
}

while IFS= read -r line || [ -n "$line" ]; do
  line=${line%$'\r'}
  case "$line" in
    ''|'#'*) continue ;;
  esac
  case "$line" in
    *=*) ;;
    *) echo "invalid config line, expected KEY=value: $line" >&2; exit 1 ;;
  esac
  key=${line%%=*}
  value=${line#*=}
  case "$key" in
    *[!A-Z0-9_]*) echo "invalid config key: $key" >&2; exit 1 ;;
  esac
  case "$allowed" in
    *" $key "*) emit_env "$key" "$value" ;;
    *) echo "unsupported config key: $key" >&2; exit 1 ;;
  esac
done < "$config_file"
