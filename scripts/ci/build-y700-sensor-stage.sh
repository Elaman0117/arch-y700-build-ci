#!/usr/bin/env bash
# Stage the Qualcomm SSC sensor stack for the Y700 Arch rootfs.
#
# This is the Arch equivalent of the original build-y700-sensor-debs.sh. Instead
# of producing .deb packages, it produces a "stage directory" with two parts:
#
#   out/y700-sensor-stage/
#     tree/        - a file tree that build-rootfs-image.sh rsyncs into the
#                    rootfs verbatim (binaries, configs, systemd units, udev
#                    rules, sensor registry data)
#     stage.tar.zst- optional archive copied into /var/tmp/ci-pkgs/ so the
#                    provisioning script can run any pacman-level post-install
#                    hooks inside the chroot (currently unused; everything is
#                    file-based)
#
# The compiled binaries are cross-built with meson + aarch64-linux-gnu-gcc, the
# same as the original. The only difference is that we drop the dpkg-deb step.
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
. "$SCRIPT_DIR/common.sh"

usage() {
  cat <<USAGE
Usage: $(basename "$0")

Stage the source-built Qualcomm SSC sensor stack for Lenovo TB321FU.

Environment inputs:
  OUTPUT_DIR                       default: out/y700-sensor-stage
  ARCH                             default: aarch64
  SENSOR_STAGE_VERSION             default: 20260626.1
  SENSOR_SOURCE_ARCHIVE            source freeze archive containing sensor/daily-current
  SENSOR_SOURCE_DIR                source freeze directory containing sensor/daily-current
  SENSOR_BASELINE_OVERLAY_ARCHIVE  rootfs overlay archive extracted from the verified userdata image
  SENSOR_BASELINE_OVERLAY_DIR      rootfs overlay directory extracted from the verified userdata image
  SENSOR_STRIP                     strip binaries after build, default: 0
USAGE
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  usage
  exit 0
fi

ci_require_cmd meson
ci_require_cmd ninja
ci_require_cmd rsync
ci_require_cmd pkg-config
ci_require_cmd protoc
ci_require_cmd protoc-gen-c
ci_require_cmd aarch64-linux-gnu-gcc
ci_require_cmd aarch64-linux-gnu-ar
ci_require_cmd aarch64-linux-gnu-strip

OUTPUT_DIR=${OUTPUT_DIR:-out/y700-sensor-stage}
ARCH=${ARCH:-aarch64}
SENSOR_STAGE_VERSION=${SENSOR_STAGE_VERSION:-20260626.1}
SENSOR_SOURCE_ARCHIVE=${SENSOR_SOURCE_ARCHIVE:-}
SENSOR_SOURCE_DIR=${SENSOR_SOURCE_DIR:-}
SENSOR_BASELINE_OVERLAY_ARCHIVE=${SENSOR_BASELINE_OVERLAY_ARCHIVE:-}
SENSOR_BASELINE_OVERLAY_DIR=${SENSOR_BASELINE_OVERLAY_DIR:-}
SENSOR_STRIP=${SENSOR_STRIP:-0}

[ "$ARCH" = aarch64 ] || [ "$ARCH" = armv8 ] || ci_die "unsupported ARCH=$ARCH; only aarch64/armv8 is supported"

mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR=$(ci_abs_path "$OUTPUT_DIR")
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/y700-sensor-stage.XXXXXX")
cleanup() { rm -rf "$work_dir"; }
trap cleanup EXIT

copy_source() {
  local src=$1 dst=$2
  mkdir -p "$(dirname "$dst")"
  rsync -a --delete \
    --exclude 'build-arm64' \
    --exclude 'build-arm64-y700' \
    --exclude 'build-arm64-y700-ssc' \
    --exclude 'build-y700-aarch64' \
    --exclude 'build-native' \
    "$src/" "$dst/"
}

find_sensor_source_root() {
  local root=$1 found
  if [ -d "$root/sensor/daily-current/libssc" ] && \
     [ -d "$root/sensor/daily-current/iio-sensor-proxy" ] && \
     [ -d "$root/sensor/daily-current/hexagonrpc" ]; then
    printf '%s\n' "$root"; return 0
  fi
  found=$(find "$root" -type d -path '*/sensor/daily-current/libssc' -print -quit)
  [ -n "$found" ] || return 1
  found=${found%/sensor/daily-current/libssc}
  [ -d "$found/sensor/daily-current/iio-sensor-proxy" ] || return 1
  [ -d "$found/sensor/daily-current/hexagonrpc" ] || return 1
  printf '%s\n' "$found"
}

find_baseline_overlay_root() {
  local root=$1 found
  if [ -d "$root/usr/local/share/y700-sns/hexagonfs/sensors/registry" ] && \
     [ -d "$root/usr/local/share/y700-sns/hexagonfs/sensors/config" ]; then
    printf '%s\n' "$root"; return 0
  fi
  found=$(find "$root" -type d -path '*/rootfs-overlay/usr/local/share/y700-sns/hexagonfs/sensors/registry' -print -quit)
  [ -n "$found" ] || return 1
  found=${found%/usr/local/share/y700-sns/hexagonfs/sensors/registry}
  [ -d "$found/usr/local/share/y700-sns/hexagonfs/sensors/config" ] || return 1
  printf '%s\n' "$found"
}

prepare_inputs() {
  if [ -n "$SENSOR_SOURCE_DIR" ]; then
    source_root=$(find_sensor_source_root "$SENSOR_SOURCE_DIR") || ci_die "SENSOR_SOURCE_DIR does not contain sensor/daily-current sources"
  else
    [ -n "$SENSOR_SOURCE_ARCHIVE" ] || ci_die "set SENSOR_SOURCE_ARCHIVE or SENSOR_SOURCE_DIR"
    src_archive="$work_dir/sensor-source.archive"
    src_extract="$work_dir/sensor-source"
    ci_download "$SENSOR_SOURCE_ARCHIVE" "$src_archive"
    ci_extract_archive "$src_archive" "$src_extract"
    source_root=$(find_sensor_source_root "$src_extract") || ci_die "SENSOR_SOURCE_ARCHIVE does not contain sensor/daily-current sources"
  fi

  if [ -n "$SENSOR_BASELINE_OVERLAY_DIR" ]; then
    baseline_root=$(find_baseline_overlay_root "$SENSOR_BASELINE_OVERLAY_DIR") || ci_die "SENSOR_BASELINE_OVERLAY_DIR does not contain verified sensor overlay"
  else
    [ -n "$SENSOR_BASELINE_OVERLAY_ARCHIVE" ] || ci_die "set SENSOR_BASELINE_OVERLAY_ARCHIVE or SENSOR_BASELINE_OVERLAY_DIR"
    baseline_archive="$work_dir/sensor-baseline-overlay.archive"
    baseline_extract="$work_dir/sensor-baseline-overlay"
    ci_download "$SENSOR_BASELINE_OVERLAY_ARCHIVE" "$baseline_archive"
    ci_extract_archive "$baseline_archive" "$baseline_extract"
    baseline_root=$(find_baseline_overlay_root "$baseline_extract") || ci_die "SENSOR_BASELINE_OVERLAY_ARCHIVE does not contain verified sensor overlay"
  fi

  ci_log "sensor source root: $source_root"
  ci_log "sensor baseline overlay root: $baseline_root"
}

make_iio_cross_file() {
  local file=$1 libssc_prefix=$2
  cat > "$file" <<EOF_CROSS
[binaries]
c = 'aarch64-linux-gnu-gcc'
ar = 'aarch64-linux-gnu-ar'
strip = 'aarch64-linux-gnu-strip'
pkg-config = 'pkg-config'

[properties]
needs_exe_wrapper = true
pkg_config_libdir = ['$libssc_prefix/lib/aarch64-linux-gnu/pkgconfig', '/usr/lib/aarch64-linux-gnu/pkgconfig', '/usr/share/pkgconfig']

[host_machine]
system = 'linux'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'
EOF_CROSS
}

strip_if_requested() {
  [ "$SENSOR_STRIP" = 1 ] || return 0
  aarch64-linux-gnu-strip --strip-unneeded "$@"
}

patch_hexagonrpc_for_qcom_sns() {
  local src=$1/hexagonrpcd/apps_std.c
  grep -q 'Y700_REGISTRY_ROOT' "$src" || ci_die "hexagonrpc apps_std.c no longer contains expected registry root marker"
  sed -i \
    -e 's#Y700_REGISTRY_ROOT#QCOM_SNS_REGISTRY_ROOT#g' \
    -e 's#/var/lib/y700-sns/persist/sensors/registry#/var/lib/qcom-sns/persist/sensors/registry#g' \
    "$src"
  grep -q 'QCOM_SNS_REGISTRY_ROOT "/var/lib/qcom-sns/persist/sensors/registry"' "$src" || ci_die "failed to patch qcom-sns registry root"
}

build_libssc() {
  local src="$work_dir/src/libssc"
  local build="$src/build-qcom-sns-aarch64"
  local prefix="$work_dir/libssc-prefix"
  local pkg="$OUTPUT_DIR/tree/usr"

  ci_log "building libssc"
  copy_source "$source_root/sensor/daily-current/libssc" "$src"
  ( cd "$src" && meson setup "$build" \
    --cross-file "$src/cross-aarch64.txt" \
    --prefix="$prefix" \
    --libdir=lib/aarch64-linux-gnu \
    --buildtype=release \
    --wrap-mode=nodownload )
  ninja -C "$build"
  meson install -C "$build" --no-rebuild

  mkdir -p "$pkg"
  rsync -a "$prefix/" "$pkg/"
  sed -i 's#^prefix=.*#prefix=/usr#' "$pkg/lib/aarch64-linux-gnu/pkgconfig/libssc.pc"
  find "$pkg/include" -type f -exec chmod 0644 {} +
  find "$pkg/lib/aarch64-linux-gnu/pkgconfig" -type f -exec chmod 0644 {} +
  chmod 0644 "$pkg/lib/aarch64-linux-gnu/libssc.so.2"
  chmod 0755 "$pkg/bin/ssccli"
  strip_if_requested "$pkg/bin/ssccli" "$pkg/lib/aarch64-linux-gnu/libssc.so.2"

  libssc_pkg_prefix="$prefix"
}

build_hexagonrpc() {
  local src="$work_dir/src/hexagonrpc"
  local build="$src/build-qcom-sns-aarch64"
  local pkg="$OUTPUT_DIR/tree/usr"

  ci_log "building hexagonrpc"
  copy_source "$source_root/sensor/daily-current/hexagonrpc" "$src"
  patch_hexagonrpc_for_qcom_sns "$src"
  ( cd "$src" && meson setup "$build" \
    --cross-file "$src/cross-aarch64.txt" \
    --prefix=/usr \
    --libdir=lib/aarch64-linux-gnu \
    --buildtype=release \
    --wrap-mode=nodownload )
  ninja -C "$build" hexagonrpcd/hexagonrpcd libhexagonrpc/libhexagonrpc.so.0.4

  install -d -m 0755 "$pkg/bin" "$pkg/lib/aarch64-linux-gnu"
  install -m 0755 "$build/hexagonrpcd/hexagonrpcd" "$pkg/bin/hexagonrpcd"
  install -m 0644 "$build/libhexagonrpc/libhexagonrpc.so.0.4" "$pkg/lib/aarch64-linux-gnu/libhexagonrpc.so.0.4"
  ln -sf libhexagonrpc.so.0.4 "$pkg/lib/aarch64-linux-gnu/libhexagonrpc.so"
  chmod 0755 "$pkg/bin/hexagonrpcd"
  chmod 0644 "$pkg/lib/aarch64-linux-gnu/libhexagonrpc.so.0.4"
  strip_if_requested "$pkg/bin/hexagonrpcd" "$pkg/lib/aarch64-linux-gnu/libhexagonrpc.so.0.4"
}

build_iio_sensor_proxy() {
  local src="$work_dir/src/iio-sensor-proxy"
  local build="$src/build-qcom-sns-aarch64"
  local dest="$work_dir/stage/iio-sensor-proxy"
  local pkg="$OUTPUT_DIR/tree"
  local cross="$work_dir/iio-cross-aarch64-qcom-sns.txt"

  ci_log "building iio-sensor-proxy"
  copy_source "$source_root/sensor/daily-current/iio-sensor-proxy" "$src"
  make_iio_cross_file "$cross" "$libssc_pkg_prefix"
  export PKG_CONFIG_LIBDIR="$libssc_pkg_prefix/lib/aarch64-linux-gnu/pkgconfig:/usr/lib/aarch64-linux-gnu/pkgconfig:/usr/share/pkgconfig"
  ( cd "$src" && meson setup "$build" \
    --cross-file "$cross" \
    --prefix=/usr \
    --buildtype=release \
    -Dssc-support=enabled \
    -Dtests=false \
    -Dgtk-tests=false \
    -Dgtk_doc=false \
    --wrap-mode=nodownload )
  ninja -C "$build"
  DESTDIR="$dest" meson install -C "$build" --no-rebuild

  mkdir -p "$pkg"
  rsync -a "$dest/" "$pkg/"
  chmod 0755 "$pkg/usr/bin/monitor-sensor" "$pkg/usr/libexec/iio-sensor-proxy"
  chmod 0644 \
    "$pkg/usr/lib/systemd/system/iio-sensor-proxy.service" \
    "$pkg/usr/lib/udev/rules.d/80-iio-sensor-proxy.rules" \
    "$pkg/usr/share/dbus-1/system.d/net.hadess.SensorProxy.conf" \
    "$pkg/usr/share/polkit-1/actions/net.hadess.SensorProxy.policy"
  strip_if_requested "$pkg/usr/bin/monitor-sensor" "$pkg/usr/libexec/iio-sensor-proxy"
}

build_tb321fu_sensors_data() {
  local pkg="$OUTPUT_DIR/tree"
  local qcom_root="$pkg/usr/share/qcom/sm8650/Lenovo/tb321fu"
  local source_hexagonfs="$baseline_root/usr/local/share/y700-sns/hexagonfs"

  ci_log "staging tb321fu-sensors data"
  [ -d "$source_hexagonfs/sensors/registry" ] || ci_die "missing baseline sensors registry data"
  [ -d "$source_hexagonfs/sensors/config" ] || ci_die "missing baseline sensors config data"
  [ -d "$source_hexagonfs/socinfo" ] || ci_die "missing baseline socinfo data"

  install -d -m 0755 "$qcom_root"
  rsync -a "$source_hexagonfs/sensors" "$qcom_root/"
  rsync -a "$source_hexagonfs/socinfo" "$qcom_root/"
  find "$qcom_root" -type d -exec chmod 0755 {} +
  find "$qcom_root" -type f -exec chmod 0644 {} +

  install -d -m 0755 "$pkg/usr/share/qcom/conf.d"
  cat > "$pkg/usr/share/qcom/conf.d/tb321fu.yaml" <<'EOF_YAML'
machines:
  "Lenovo Legion Y700 (2025) / TB321FU":
    DSP_LIBRARY_PATH: "/sm8650/Lenovo/tb321fu/"
EOF_YAML

  install -d -m 0755 "$pkg/usr/libexec/qcom-sns"
  cat > "$pkg/usr/libexec/qcom-sns/qcom-sns-init" <<'EOF_INIT'
#!/bin/sh
set -eu

HEXAGONRPCD=/usr/bin/hexagonrpcd
ROOT=/usr/share/qcom/sm8650/Lenovo/tb321fu
PERSIST=/var/lib/qcom-sns/persist
REGISTRY="$PERSIST/sensors/registry/registry"
LOGDIR=/var/log/qcom-sns
LOG="$LOGDIR/hexagonrpcd-init.log"

mkdir -p "$REGISTRY" "$LOGDIR"

pre_count=$(find "$REGISTRY" -type f 2>/dev/null | wc -l)
if [ "$pre_count" -gt 0 ] && [ "$pre_count" -lt 200 ]; then
  echo "clearing partial registry_files=$pre_count before init" >>"$LOG"
  rm -rf "$PERSIST/sensors/registry"
  mkdir -p "$REGISTRY"
fi

waited=0
while [ ! -e /dev/fastrpc-adsp ] && [ "$waited" -lt 60 ]; do
  sleep 1
  waited=$((waited + 1))
done

if [ ! -e /dev/fastrpc-adsp ]; then
  echo "missing /dev/fastrpc-adsp after ${waited}s" >>"$LOG"
  exit 1
fi

if [ ! -x "$HEXAGONRPCD" ]; then
  echo "missing executable $HEXAGONRPCD" >>"$LOG"
  exit 1
fi

if [ ! -d "$ROOT/sensors/registry" ] || [ ! -d "$ROOT/sensors/config" ]; then
  echo "missing TB321FU sensor data under $ROOT" >>"$LOG"
  exit 1
fi

tmp_log="$LOG.tmp"
rm -f "$tmp_log"

rc=0
timeout 45 "$HEXAGONRPCD" \
  -f /dev/fastrpc-adsp \
  -d adsp \
  -s \
  -R "$ROOT" \
  >"$tmp_log" 2>&1 || rc=$?

count=$(find "$REGISTRY" -type f 2>/dev/null | wc -l)

if [ "$count" -lt 200 ]; then
  cat "$tmp_log" >>"$LOG"
  echo "registry_files=$count hexagonrpcd_rc=$rc" >>"$LOG"
  rm -f "$tmp_log"
  exit 1
fi

rm -f "$tmp_log"
exit 0
EOF_INIT
  chmod 0755 "$pkg/usr/libexec/qcom-sns/qcom-sns-init"

  install -d -m 0755 "$pkg/usr/lib/systemd/system"
  cat > "$pkg/usr/lib/systemd/system/qcom-sns-init.service" <<'EOF_SERVICE'
[Unit]
Description=Initialize Qualcomm SNS registry for Lenovo TB321FU
After=qrtr-ns.service dbus.service
Before=iio-sensor-proxy.service
Conflicts=y700-sns-init.service

[Service]
Type=oneshot
ExecStart=/usr/libexec/qcom-sns/qcom-sns-init
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF_SERVICE

  install -d -m 0755 "$pkg/etc/systemd/system/iio-sensor-proxy.service.d"
  cat > "$pkg/etc/systemd/system/iio-sensor-proxy.service.d/99-qcom-sns.conf" <<'EOF_DROPIN'
[Unit]
After=
After=qcom-sns-init.service
Requires=
Requires=qcom-sns-init.service

[Service]
ExecStart=
ExecStart=/usr/libexec/iio-sensor-proxy
Environment=
RestrictAddressFamilies=AF_UNIX AF_LOCAL AF_NETLINK AF_QIPCRTR
EOF_DROPIN

  install -d -m 0755 "$pkg/usr/lib/udev/rules.d"
  cat > "$pkg/usr/lib/udev/rules.d/80-tb321fu-qcom-sns.rules" <<'EOF_UDEV'
ACTION=="remove", GOTO="tb321fu_qcom_sns_end"
SUBSYSTEM=="misc", KERNEL=="fastrpc-adsp*", ENV{IIO_SENSOR_PROXY_TYPE}+="ssc-accel ssc-light ssc-proximity ssc-compass", ENV{ACCEL_MOUNT_MATRIX}="-1,0,0;0,-1,0;0,0,1", TAG+="systemd", ENV{SYSTEMD_WANTS}+="iio-sensor-proxy.service"
LABEL="tb321fu_qcom_sns_end"
EOF_UDEV

  # Enable the qcom-sns-init service by symlink (Arch-style systemd preset).
  install -d -m 0755 "$pkg/etc/systemd/system/multi-user.target.wants"
  ln -sf /usr/lib/systemd/system/qcom-sns-init.service \
    "$pkg/etc/systemd/system/multi-user.target.wants/qcom-sns-init.service"

  registry_count=$(find "$qcom_root/sensors/registry" -type f | wc -l)
  config_count=$(find "$qcom_root/sensors/config" -type f | wc -l)
  [ "$registry_count" -ge 200 ] || ci_die "unexpected TB321FU registry file count: $registry_count"
  [ "$config_count" -ge 50 ] || ci_die "unexpected TB321FU config file count: $config_count"
  ci_log "tb321fu registry_files=$registry_count config_files=$config_count"
}

write_stage_info() {
  cat > "$OUTPUT_DIR/stage-info.txt" <<INFO
stage=tb321fu-sensor-stage
version=$SENSOR_STAGE_VERSION
arch=$ARCH
sensor_source_root=$source_root
sensor_baseline_root=$baseline_root
strip=$SENSOR_STRIP
generated=$(date -u -Iseconds)
INFO
}

prepare_inputs
build_libssc
build_hexagonrpc
build_iio_sensor_proxy
build_tb321fu_sensors_data
write_stage_info

ci_log "writing sensor stage checksums"
( cd "$OUTPUT_DIR/tree" && find . -type f -print0 | sort -z | xargs -0 sha256sum ) > "$OUTPUT_DIR/SHA256SUMS-y700-sensor-stage.txt"
ci_log "sensor stage build complete: $OUTPUT_DIR"
