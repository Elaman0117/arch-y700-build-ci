#!/usr/bin/env bash
# Stage the verified TB321FU camera userspace stack for the Y700 Arch rootfs.
#
# Arch equivalent of the original build-tb321fu-camera-stack-deb.sh. The camera
# overlay is binary-identical to the Ubuntu version (libcamera is built once
# from source and verified on-device; the resulting .so files are not
# distro-specific). We just repackage it as a stage directory tree instead of
# a .deb.
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
. "$SCRIPT_DIR/common.sh"

usage() {
  cat <<USAGE
Usage: $(basename "$0")

Stage the live-verified Lenovo TB321FU camera userspace stack.

Environment inputs:
  OUTPUT_DIR                 default: out/tb321fu-camera-stack-stage
  ARCH                       default: aarch64
  CAMERA_STACK_STAGE_VERSION default: 20260627.4
  CAMERA_STACK_ARCHIVE       optional archive containing y700-camera-rootfs-overlay
  CAMERA_STACK_DIR           optional directory containing y700-camera-rootfs-overlay

If CAMERA_STACK_ARCHIVE and CAMERA_STACK_DIR are empty, the script uses the
repository copy at source/tb321fu-camera-rootfs-overlay.
USAGE
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  usage
  exit 0
fi

ci_require_cmd rsync
ci_require_cmd sha256sum
ci_require_cmd strings

OUTPUT_DIR=${OUTPUT_DIR:-out/tb321fu-camera-stack-stage}
ARCH=${ARCH:-aarch64}
CAMERA_STACK_STAGE_VERSION=${CAMERA_STACK_STAGE_VERSION:-20260627.4}
CAMERA_STACK_ARCHIVE=${CAMERA_STACK_ARCHIVE:-}
CAMERA_STACK_DIR=${CAMERA_STACK_DIR:-}

[ "$ARCH" = aarch64 ] || [ "$ARCH" = armv8 ] || ci_die "unsupported ARCH=$ARCH; only aarch64/armv8 is supported"

mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR=$(ci_abs_path "$OUTPUT_DIR")
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/tb321fu-camera-stack-stage.XXXXXX")
cleanup() { rm -rf "$work_dir"; }
trap cleanup EXIT

find_camera_source_root() {
  local root=$1 found
  if [ -d "$root/rootfs-overlay/opt/libcamera-y700" ] && \
     [ -f "$root/rootfs-overlay/usr/lib/aarch64-linux-gnu/spa-0.2/libcamera/libspa-libcamera.so" ]; then
    printf '%s\n' "$root"; return 0
  fi
  found=$(find "$root" -type f -path '*/rootfs-overlay/usr/lib/aarch64-linux-gnu/spa-0.2/libcamera/libspa-libcamera.so' -print -quit)
  if [ -n "$found" ]; then
    found=${found%/rootfs-overlay/usr/lib/aarch64-linux-gnu/spa-0.2/libcamera/libspa-libcamera.so}
    [ -d "$found/rootfs-overlay/opt/libcamera-y700" ] || return 1
    printf '%s\n' "$found"; return 0
  fi
  if [ -d "$root/opt/libcamera-y700" ] && \
     [ -f "$root/usr/lib/aarch64-linux-gnu/spa-0.2/libcamera/libspa-libcamera.so" ]; then
    printf '%s\n' "$root"; return 0
  fi
  return 1
}

prepare_inputs() {
  local archive extract default_dir
  default_dir="$SCRIPT_DIR/../../source/tb321fu-camera-rootfs-overlay"

  if [ -n "$CAMERA_STACK_DIR" ]; then
    camera_source_root=$(find_camera_source_root "$CAMERA_STACK_DIR") || ci_die "CAMERA_STACK_DIR does not contain the verified camera overlay"
  elif [ -n "$CAMERA_STACK_ARCHIVE" ]; then
    archive="$work_dir/camera-stack.archive"
    extract="$work_dir/camera-stack"
    ci_download "$CAMERA_STACK_ARCHIVE" "$archive"
    ci_extract_archive "$archive" "$extract"
    camera_source_root=$(find_camera_source_root "$extract") || ci_die "CAMERA_STACK_ARCHIVE does not contain the verified camera overlay"
  else
    camera_source_root=$(find_camera_source_root "$default_dir") || ci_die "repository camera overlay is missing: $default_dir"
  fi

  if [ -d "$camera_source_root/rootfs-overlay" ]; then
    camera_overlay_root="$camera_source_root/rootfs-overlay"
    camera_checksums="$camera_source_root/SHA256SUMS"
  else
    camera_overlay_root="$camera_source_root"
    camera_checksums=""
  fi

  ci_log "camera source root: $camera_source_root"
  ci_log "camera overlay root: $camera_overlay_root"
}

validate_camera_payload() {
  local root=$1 checksums=${2:-}
  local plugin="$root/usr/lib/aarch64-linux-gnu/spa-0.2/libcamera/libspa-libcamera.so"
  local cam="$root/opt/libcamera-y700/bin/cam"
  local libcamera="$root/opt/libcamera-y700/lib/aarch64-linux-gnu/libcamera.so.0.7.1"
  local libcamera_base="$root/opt/libcamera-y700/lib/aarch64-linux-gnu/libcamera-base.so.0.7.1"
  local soft_ipa="$root/opt/libcamera-y700/lib/aarch64-linux-gnu/libcamera/ipa/ipa_soft_simple.so"
  local soft_proxy="$root/opt/libcamera-y700/libexec/libcamera/soft_ipa_proxy"
  local gst_plugin="$root/opt/libcamera-y700/lib/aarch64-linux-gnu/gstreamer-1.0/libgstlibcamera.so"
  local gst_system_plugin="$root/usr/lib/aarch64-linux-gnu/gstreamer-1.0/libgstlibcamera.so"

  [ -x "$cam" ] || ci_die "camera payload missing executable /opt/libcamera-y700/bin/cam"
  [ -f "$libcamera" ] || ci_die "camera payload missing libcamera.so.0.7.1"
  [ -f "$libcamera_base" ] || ci_die "camera payload missing libcamera-base.so.0.7.1"
  [ -f "$soft_ipa" ] || ci_die "camera payload missing ipa_soft_simple.so"
  [ -x "$soft_proxy" ] || ci_die "camera payload missing executable soft_ipa_proxy"
  [ -f "$gst_plugin" ] || ci_die "camera payload missing GStreamer libcamera plugin"
  [ -L "$gst_system_plugin" ] || ci_die "camera payload missing system GStreamer libcamera symlink"
  [ "$(readlink "$gst_system_plugin")" = "/opt/libcamera-y700/lib/aarch64-linux-gnu/gstreamer-1.0/libgstlibcamera.so" ] || ci_die "system GStreamer libcamera symlink points at wrong target"
  [ -f "$plugin" ] || ci_die "camera payload missing PipeWire SPA libcamera plugin"
  [ -f "$root/opt/libcamera-y700/share/libcamera/ipa/simple/gc13a0.yaml" ] || ci_die "camera payload missing gc13a0 tuning"
  [ -f "$root/opt/libcamera-y700/share/libcamera/ipa/simple/sc202cs.yaml" ] || ci_die "camera payload missing sc202cs tuning"
  [ -f "$root/opt/libcamera-y700/share/libcamera/ipa/simple/sc820cs.yaml" ] || ci_die "camera payload missing sc820cs tuning"
  [ -f "$root/etc/systemd/user/pipewire.service.d/50-y700-libcamera-ipa.conf" ] || ci_die "camera payload missing PipeWire namespace drop-in"
  [ -f "$root/etc/systemd/user/pipewire.service.d/60-y700-libcamera-paths.conf" ] || ci_die "camera payload missing PipeWire libcamera paths drop-in"
  [ -f "$root/etc/systemd/user/wireplumber.service.d/60-y700-libcamera-paths.conf" ] || ci_die "camera payload missing WirePlumber libcamera paths drop-in"
  [ -f "$root/etc/udev/rules.d/70-y700-camera-dma-heap.rules" ] || ci_die "camera payload missing DMA heap udev rule"
  [ -f "$root/etc/ld.so.conf.d/y700-libcamera.conf" ] || ci_die "camera payload missing libcamera ldconfig path"

  if [ -n "$checksums" ] && [ -f "$checksums" ]; then
    ( cd "$root" && sha256sum -c "$checksums" >/dev/null )
  fi

  if strings "$plugin" "$cam" "$soft_ipa" "$soft_proxy" "$gst_plugin" | grep -F 'libcamera-y700-test' >/dev/null; then
    ci_die "camera payload still references rejected libcamera-y700-test app-chain"
  fi

  grep -q '^/opt/libcamera-y700/lib/aarch64-linux-gnu$' "$root/etc/ld.so.conf.d/y700-libcamera.conf" || ci_die "camera ldconfig path does not point at /opt/libcamera-y700"
}

build_camera_stage() {
  local pkg="$OUTPUT_DIR/tree"

  validate_camera_payload "$camera_overlay_root" "$camera_checksums"

  rm -rf "$pkg"
  install -d -m 0755 "$pkg"
  rsync -aH --numeric-ids "$camera_overlay_root"/ "$pkg"/

  # Remove the same set of legacy experimental files as the original script.
  rm -f \
    "$pkg/etc/udev/rules.d/70-y700-dma-heap.rules" \
    "$pkg/etc/y700-camera-display-transform-mode" \
    "$pkg/etc/y700-camera-display-rotation-base" \
    "$pkg/etc/systemd/user/y700-display-rotation-update.path" \
    "$pkg/etc/systemd/user/y700-display-rotation-update.service" \
    "$pkg/etc/systemd/user/y700-display-rotation-dbus.service" \
    "$pkg/etc/systemd/user/y700-display-rotation-sync.service" \
    "$pkg/usr/local/libexec/y700-display-rotation-update" \
    "$pkg/usr/local/libexec/y700-display-rotation-dbus" \
    "$pkg/usr/local/bin/y700-display-rotation-sync" \
    "$pkg/run/y700-camera-display-rotation"

  find "$pkg/etc" -type f -exec chmod 0644 {} + 2>/dev/null || true
  find "$pkg/opt/libcamera-y700" "$pkg/usr/lib/aarch64-linux-gnu/spa-0.2/libcamera" -type f -name '*.so*' -exec chmod 0644 {} +
  chmod 0755 \
    "$pkg/opt/libcamera-y700/bin/cam" \
    "$pkg/opt/libcamera-y700/bin/libcamera-bug-report" \
    "$pkg/opt/libcamera-y700/libexec/libcamera/soft_ipa_proxy" \
    "$pkg/usr/local/bin/y700-camera-env" \
    "$pkg/usr/local/bin/y700-camera-cam" \
    "$pkg/usr/local/bin/y700-camera-preview"

  validate_camera_payload "$pkg" ""

  find "$pkg" -type d -exec chmod 0755 {} +

  cat > "$OUTPUT_DIR/stage-info.txt" <<INFO
stage=tb321fu-camera-stack-stage
version=$CAMERA_STACK_STAGE_VERSION
arch=$ARCH
camera_source_root=$camera_source_root
camera_overlay_root=$camera_overlay_root
generated=$(date -u -Iseconds)

== key hashes ==
$(sha256sum \
  "$pkg/opt/libcamera-y700/lib/aarch64-linux-gnu/libcamera.so.0.7.1" \
  "$pkg/opt/libcamera-y700/lib/aarch64-linux-gnu/libcamera-base.so.0.7.1" \
  "$pkg/opt/libcamera-y700/lib/aarch64-linux-gnu/libcamera/ipa/ipa_soft_simple.so" \
  "$pkg/opt/libcamera-y700/lib/aarch64-linux-gnu/gstreamer-1.0/libgstlibcamera.so" \
  "$pkg/usr/lib/aarch64-linux-gnu/spa-0.2/libcamera/libspa-libcamera.so")

== plugin markers ==
$(strings -a "$pkg/usr/lib/aarch64-linux-gnu/spa-0.2/libcamera/libspa-libcamera.so" | grep -E 'kwinoutputconfig|kscreen-doctor|y700_camera|spa_system_eventfd|camera-display-transform-mode|display-rotation-base|libcamera-y700-test|api.libcamera.rotation' | head -n 120 || true)
INFO

  cat "$OUTPUT_DIR/stage-info.txt"
}

prepare_inputs
build_camera_stage

ci_log "writing camera stage checksums"
( cd "$OUTPUT_DIR/tree" && find . -type f -print0 | sort -z | xargs -0 sha256sum ) > "$OUTPUT_DIR/SHA256SUMS-tb321fu-camera-stack-stage.txt"
ci_log "camera stage build complete: $OUTPUT_DIR"
