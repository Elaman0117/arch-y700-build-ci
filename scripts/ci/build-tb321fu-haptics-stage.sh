#!/usr/bin/env bash
# Stage the AW86937 haptics support for the Y700 Arch rootfs.
#
# Arch equivalent of the original build-tb321fu-haptics-deb.sh. Produces a
# stage directory tree that build-rootfs-image.sh rsyncs into the rootfs.
#
# The kernel module is built as a standalone .ko matched to the kernel that
# will be installed in the rootfs. For Arch, we strongly recommend wrapping
# this in a DKMS package on production systems so the module is rebuilt on
# kernel upgrade; in CI we just build against the exact kernel version that
# the rootfs will ship.
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
. "$SCRIPT_DIR/common.sh"

usage() {
  cat <<USAGE
Usage: $(basename "$0")

Stage the source-built AW86937 haptics module + userspace glue for Lenovo
TB321FU.

Environment inputs:
  OUTPUT_DIR                 default: out/tb321fu-haptics-stage
  ARCH                       default: aarch64
  HAPTICS_STAGE_VERSION      default: 20260627.1
  HAPTICS_SOURCE_ARCHIVE     source freeze archive containing haptics/daily-current
  HAPTICS_SOURCE_DIR         source freeze directory containing haptics/daily-current
  KERNEL_SOURCE_ARCHIVE      kernel source archive
  KERNEL_SOURCE_DIR          kernel source directory
  KERNEL_BUILD_ARCHIVE       kernel build output archive containing generated headers
  KERNEL_BUILD_DIR           kernel build output directory
  HAPTICS_STRIP              strip binaries/modules after build, default: 0
USAGE
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  usage
  exit 0
fi

ci_require_cmd make
ci_require_cmd rsync
ci_require_cmd aarch64-linux-gnu-gcc
ci_require_cmd aarch64-linux-gnu-strip
ci_require_cmd modinfo

OUTPUT_DIR=${OUTPUT_DIR:-out/tb321fu-haptics-stage}
ARCH=${ARCH:-aarch64}
HAPTICS_STAGE_VERSION=${HAPTICS_STAGE_VERSION:-20260627.1}
HAPTICS_SOURCE_ARCHIVE=${HAPTICS_SOURCE_ARCHIVE:-}
HAPTICS_SOURCE_DIR=${HAPTICS_SOURCE_DIR:-}
KERNEL_SOURCE_ARCHIVE=${KERNEL_SOURCE_ARCHIVE:-}
KERNEL_SOURCE_DIR=${KERNEL_SOURCE_DIR:-}
KERNEL_BUILD_ARCHIVE=${KERNEL_BUILD_ARCHIVE:-}
KERNEL_BUILD_DIR=${KERNEL_BUILD_DIR:-}
HAPTICS_STRIP=${HAPTICS_STRIP:-0}

[ "$ARCH" = aarch64 ] || [ "$ARCH" = armv8 ] || ci_die "unsupported ARCH=$ARCH; only aarch64/armv8 is supported"

mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR=$(ci_abs_path "$OUTPUT_DIR")
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/tb321fu-haptics-stage.XXXXXX")
cleanup() { rm -rf "$work_dir"; }
trap cleanup EXIT

find_haptics_source_root() {
  local root=$1 found
  if [ -f "$root/haptics/daily-current/linux/drivers/input/misc/aw86937-y700.c" ] && \
     [ -f "$root/haptics/rootfs-reference/usr/lib/firmware/haptic_ram.bin" ] && \
     [ -f "$root/haptics/rootfs-reference/usr/lib/firmware/haptic_click.bin" ]; then
    printf '%s\n' "$root"; return 0
  fi
  found=$(find "$root" -type f -path '*/haptics/daily-current/linux/drivers/input/misc/aw86937-y700.c' -print -quit)
  [ -n "$found" ] || return 1
  found=${found%/haptics/daily-current/linux/drivers/input/misc/aw86937-y700.c}
  [ -f "$found/haptics/rootfs-reference/usr/lib/firmware/haptic_ram.bin" ] || return 1
  [ -f "$found/haptics/rootfs-reference/usr/lib/firmware/haptic_click.bin" ] || return 1
  printf '%s\n' "$found"
}

find_kernel_source_root() {
  local root=$1 found
  if [ -f "$root/Makefile" ] && [ -d "$root/scripts" ] && [ -d "$root/drivers" ]; then
    printf '%s\n' "$root"; return 0
  fi
  found=$(find "$root" -type f -path '*/scripts/Makefile.build' -print -quit)
  [ -n "$found" ] || return 1
  found=${found%/scripts/Makefile.build}
  [ -f "$found/Makefile" ] || return 1
  [ -d "$found/drivers" ] || return 1
  printf '%s\n' "$found"
}

find_kernel_build_root() {
  local root=$1 found
  if [ -f "$root/.config" ] && \
     [ -f "$root/Module.symvers" ] && \
     [ -f "$root/include/generated/autoconf.h" ] && \
     [ -f "$root/include/config/kernel.release" ]; then
    printf '%s\n' "$root"; return 0
  fi
  found=$(find "$root" -type f -path '*/include/config/kernel.release' -print -quit)
  [ -n "$found" ] || return 1
  found=${found%/include/config/kernel.release}
  [ -f "$found/.config" ] || return 1
  [ -f "$found/Module.symvers" ] || return 1
  [ -f "$found/include/generated/autoconf.h" ] || return 1
  printf '%s\n' "$found"
}

prepare_inputs() {
  if [ -n "$HAPTICS_SOURCE_DIR" ]; then
    haptics_root=$(find_haptics_source_root "$HAPTICS_SOURCE_DIR") || ci_die "HAPTICS_SOURCE_DIR does not contain haptics source freeze"
  else
    [ -n "$HAPTICS_SOURCE_ARCHIVE" ] || ci_die "set HAPTICS_SOURCE_ARCHIVE or HAPTICS_SOURCE_DIR"
    archive="$work_dir/haptics-source.archive"
    extract="$work_dir/haptics-source"
    ci_download "$HAPTICS_SOURCE_ARCHIVE" "$archive"
    ci_extract_archive "$archive" "$extract"
    haptics_root=$(find_haptics_source_root "$extract") || ci_die "HAPTICS_SOURCE_ARCHIVE does not contain haptics source freeze"
  fi

  if [ -n "$KERNEL_SOURCE_DIR" ]; then
    kernel_source_root=$(find_kernel_source_root "$KERNEL_SOURCE_DIR") || ci_die "KERNEL_SOURCE_DIR does not contain kernel source"
  else
    [ -n "$KERNEL_SOURCE_ARCHIVE" ] || ci_die "set KERNEL_SOURCE_ARCHIVE or KERNEL_SOURCE_DIR"
    archive="$work_dir/kernel-source.archive"
    extract="$work_dir/kernel-source"
    ci_download "$KERNEL_SOURCE_ARCHIVE" "$archive"
    ci_extract_archive "$archive" "$extract"
    kernel_source_root=$(find_kernel_source_root "$extract") || ci_die "KERNEL_SOURCE_ARCHIVE does not contain kernel source"
  fi

  if [ -n "$KERNEL_BUILD_DIR" ]; then
    kernel_build_root=$(find_kernel_build_root "$KERNEL_BUILD_DIR") || ci_die "KERNEL_BUILD_DIR does not contain kernel build output"
  else
    [ -n "$KERNEL_BUILD_ARCHIVE" ] || ci_die "set KERNEL_BUILD_ARCHIVE or KERNEL_BUILD_DIR"
    archive="$work_dir/kernel-build.archive"
    extract="$work_dir/kernel-build"
    ci_download "$KERNEL_BUILD_ARCHIVE" "$archive"
    ci_extract_archive "$archive" "$extract"
    kernel_build_root=$(find_kernel_build_root "$extract") || ci_die "KERNEL_BUILD_ARCHIVE does not contain kernel build output"
  fi

  kernel_release=$(cat "$kernel_build_root/include/config/kernel.release")
  ci_log "haptics source root: $haptics_root"
  ci_log "kernel source root: $kernel_source_root"
  ci_log "kernel build root: $kernel_build_root"
  ci_log "kernel release: $kernel_release"
}

patch_source_for_standard_module_name() {
  local src=$1
  sed -i \
    -e 's/Lenovo Y700 AW86937 input force-feedback haptics driver/Lenovo TB321FU AW86937 input force-feedback haptics driver/g' \
    -e 's/\.name = "aw86937-y700"/.name = "aw86937-haptics"/g' \
    "$src"

  if ! grep -q '"aw86937_haptics"' "$src"; then
    sed -i '/{ "aw86937_y700" }/i\      { "aw86937_haptics" },' "$src"
  fi

  grep -q '\.name = "aw86937-haptics"' "$src" || ci_die "failed to patch i2c driver name"
  grep -q '"aw86937_haptics"' "$src" || ci_die "failed to add standard i2c id"
}

write_bind_script() {
  local dest=$1
  # The bind script is 100% distro-agnostic (it only touches /sys/bus/i2c).
  # Verbatim copy of the original Ubuntu version.
  cat > "$dest" <<'EOF_BIND'
#!/bin/sh
set -eu

find_haptic_adapter()
{
        for dev in /sys/bus/i2c/devices/i2c-*; do
                [ -e "$dev/name" ] || continue
                real=$(readlink -f "$dev" || true)
                case "$real" in
                        *a9c000.i2c*) basename "$dev" | sed 's/^i2c-//'; return 0 ;;
                esac
        done
        return 1
}

load_driver()
{
        if lsmod | awk '{print $1}' | grep -Eq '^(aw86937_haptics|aw86937_y700)$'; then
                return 0
        fi
        modprobe aw86937_haptics 2>/dev/null && return 0
        modprobe aw86937_y700 2>/dev/null && return 0

        krel=$(uname -r)
        for module_path in \
                "/lib/modules/$krel/extra/aw86937-haptics.ko" \
                "/lib/modules/$krel/extra/aw86937-y700.ko" \
                "/usr/lib/modules/$krel/extra/aw86937-haptics.ko" \
                "/usr/lib/modules/$krel/extra/aw86937-y700.ko"; do
                [ -f "$module_path" ] || continue
                insmod "$module_path" && return 0
        done

        echo "no AW86937 haptics module could be loaded" >&2
        return 1
}

is_known_haptic_name()
{
        case "$1" in
                aw86937_haptics|aw86937_y700|aw86937|haptic_hv|haptic_hv_r|haptic_hv_l|tb321fu-aw86937|y700-aw86937)
                        return 0
                        ;;
        esac
        return 1
}

find_driver_dir()
{
        for driver in aw86937-haptics aw86937-y700; do
                [ -d "/sys/bus/i2c/drivers/$driver" ] || continue
                printf '%s\n' "/sys/bus/i2c/drivers/$driver"
                return 0
        done
        return 1
}

bind_existing_client()
{
        dev="$1"
        name="$2"
        driver_dir="$3"
        busdev=$(basename "$dev")

        if ! is_known_haptic_name "$name"; then
                echo "$dev already exists as $name" >&2
                exit 1
        fi

        if [ -e "$dev/driver" ]; then
                driver=$(basename "$(readlink -f "$dev/driver")")
                case "$driver" in
                        aw86937-haptics|aw86937-y700) return 0 ;;
                esac
                echo "$dev is already bound to unexpected driver $driver" >&2
                exit 1
        fi

        printf '%s\n' "$busdev" > "$driver_dir/bind" 2>/dev/null || true

        for _ in $(seq 1 20); do
                if [ -e "$dev/driver" ]; then
                        driver=$(basename "$(readlink -f "$dev/driver")")
                        case "$driver" in
                                aw86937-haptics|aw86937-y700) return 0 ;;
                        esac
                fi
                sleep 0.1
        done

        echo "$dev did not bind to AW86937 haptics driver" >&2
        exit 1
}

adapter=""
for _ in $(seq 1 80); do
        adapter=$(find_haptic_adapter 2>/dev/null || true)
        [ -n "$adapter" ] && break
        sleep 0.25
done

if [ -z "$adapter" ]; then
        echo "a9c000.i2c adapter not found" >&2
        exit 1
fi

load_driver
driver_dir=$(find_driver_dir) || { echo "AW86937 haptics i2c driver not registered" >&2; exit 1; }

for spec in "0x5a:right" "0x5b:left"; do
        addr=${spec%%:*}
        dev="/sys/bus/i2c/devices/${adapter}-00${addr#0x}"
        if [ -e "$dev/name" ]; then
                name=$(cat "$dev/name")
                bind_existing_client "$dev" "$name" "$driver_dir"
                continue
        fi
        printf 'aw86937_haptics %s\n' "$addr" > "/sys/bus/i2c/devices/i2c-$adapter/new_device" 2>/dev/null || \
                printf 'aw86937_y700 %s\n' "$addr" > "/sys/bus/i2c/devices/i2c-$adapter/new_device"
done
EOF_BIND
  chmod 0755 "$dest"
}

write_systemd_unit() {
  local dest=$1
  cat > "$dest" <<'EOF_SERVICE'
[Unit]
Description=Bind Lenovo TB321FU AW86937 haptics
DefaultDependencies=no
After=systemd-udevd.service local-fs.target
Wants=systemd-udevd.service
Conflicts=y700-aw86937-haptics.service

[Service]
Type=oneshot
ExecStart=/usr/lib/tb321fu-haptics/bind-aw86937
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF_SERVICE
  chmod 0644 "$dest"
}

write_udev_rules() {
  local dest=$1
  cat > "$dest" <<'EOF_UDEV'
# TB321FU AW86937 haptics expose standard Linux input force-feedback devices.
ACTION=="remove", GOTO="tb321fu_haptics_end"
SUBSYSTEM=="input", KERNEL=="event*", ATTRS{name}=="aw86937-haptics-left", GROUP="input", MODE="0666", TAG+="uaccess", ENV{FEEDBACKD_TYPE}="vibra", SYMLINK+="input/tb321fu-haptics-left"
SUBSYSTEM=="input", KERNEL=="event*", ATTRS{name}=="aw86937-haptics-right", GROUP="input", MODE="0666", TAG+="uaccess", ENV{FEEDBACKD_TYPE}="vibra", SYMLINK+="input/tb321fu-haptics-right"
LABEL="tb321fu_haptics_end"
EOF_UDEV
  chmod 0644 "$dest"
}

write_plasma_keyboard_default() {
  local dest=$1
  cat > "$dest" <<'EOF_CONF'
[General]
enabledLocales=en_US
soundEnabled=true
vibrationEnabled=true
vibrationMs=20
EOF_CONF
  chmod 0644 "$dest"
}

write_dkms_conf() {
  local dest=$1
  cat > "$dest" <<EOF_DKMS
PACKAGE_NAME="aw86937-haptics"
PACKAGE_VERSION="$HAPTICS_STAGE_VERSION"
AUTOINSTALL="yes"
MAKE[0]="make -C \${kernel_source_dir} O=\${kernel_build_dir} ARCH=arm64 M=\${dkms_tree}/\${PACKAGE_NAME}/\${PACKAGE_VERSION}/build modules"
BUILT_MODULE_NAME[0]="aw86937-haptics"
DEST_MODULE_LOCATION[0]="/extra"
EOF_DKMS
  chmod 0644 "$dest"
}

strip_if_requested() {
  [ "$HAPTICS_STRIP" = 1 ] || return 0
  aarch64-linux-gnu-strip --strip-unneeded "$@"
}

build_haptics_stage() {
  local src="$work_dir/module-src"
  local pkg="$OUTPUT_DIR/tree"
  local module="$src/aw86937-haptics.ko"
  local helper_src="$haptics_root/haptics/baseline-20260614-daily-clean/testing-tools/y700-haptic-test.c"

  ci_log "building aw86937-haptics external module for kernel $kernel_release"
  mkdir -p "$src"
  cp -a "$haptics_root/haptics/daily-current/linux/drivers/input/misc/aw86937-y700.c" "$src/aw86937-haptics.c"
  patch_source_for_standard_module_name "$src/aw86937-haptics.c"
  cat > "$src/Makefile" <<'EOF_MAKE'
obj-m := aw86937-haptics.o
EOF_MAKE

  make -C "$kernel_source_root" O="$kernel_build_root" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- M="$src" modules
  [ -f "$module" ] || ci_die "missing built module: $module"
  modinfo "$module" | tee "$work_dir/aw86937-haptics.modinfo"
  grep -q '^name:[[:space:]]*aw86937_haptics$' "$work_dir/aw86937-haptics.modinfo" || ci_die "unexpected module name"
  grep -q '^alias:[[:space:]]*i2c:aw86937_haptics$' "$work_dir/aw86937-haptics.modinfo" || ci_die "missing standard i2c alias"
  grep -q "^vermagic:[[:space:]]*$kernel_release " "$work_dir/aw86937-haptics.modinfo" || ci_die "module vermagic does not match $kernel_release"

  install -d -m 0755 \
    "$pkg/usr/lib/modules/$kernel_release/extra" \
    "$pkg/usr/lib/firmware" \
    "$pkg/usr/lib/tb321fu-haptics" \
    "$pkg/usr/lib/systemd/system" \
    "$pkg/usr/lib/udev/rules.d" \
    "$pkg/etc/skel/.config" \
    "$pkg/usr/bin" \
    "$pkg/usr/src/aw86937-haptics-$HAPTICS_STAGE_VERSION"

  install -m 0644 "$module" "$pkg/usr/lib/modules/$kernel_release/extra/aw86937-haptics.ko"
  install -m 0644 "$haptics_root/haptics/rootfs-reference/usr/lib/firmware/haptic_ram.bin" "$pkg/usr/lib/firmware/haptic_ram.bin"
  install -m 0644 "$haptics_root/haptics/rootfs-reference/usr/lib/firmware/haptic_click.bin" "$pkg/usr/lib/firmware/haptic_click.bin"
  write_bind_script "$pkg/usr/lib/tb321fu-haptics/bind-aw86937"
  write_systemd_unit "$pkg/usr/lib/systemd/system/tb321fu-haptics.service"
  write_udev_rules "$pkg/usr/lib/udev/rules.d/90-tb321fu-haptics.rules"
  write_plasma_keyboard_default "$pkg/etc/skel/.config/plasmakeyboardrc"

  # DKMS source tree for future kernel upgrades (Arch rolling model).
  cp -a "$src/aw86937-haptics.c" "$pkg/usr/src/aw86937-haptics-$HAPTICS_STAGE_VERSION/"
  cp -a "$src/Makefile" "$pkg/usr/src/aw86937-haptics-$HAPTICS_STAGE_VERSION/"
  write_dkms_conf "$pkg/usr/src/aw86937-haptics-$HAPTICS_STAGE_VERSION/dkms.conf"

  if [ -f "$helper_src" ]; then
    aarch64-linux-gnu-gcc -O2 -Wall -Wextra -o "$pkg/usr/bin/tb321fu-haptic-test" "$helper_src"
    chmod 0755 "$pkg/usr/bin/tb321fu-haptic-test"
    strip_if_requested "$pkg/usr/bin/tb321fu-haptic-test"
  fi

  strip_if_requested "$pkg/usr/lib/modules/$kernel_release/extra/aw86937-haptics.ko"

  # Enable the systemd unit by symlink (Arch-style preset).
  install -d -m 0755 "$pkg/etc/systemd/system/multi-user.target.wants"
  ln -sf /usr/lib/systemd/system/tb321fu-haptics.service \
    "$pkg/etc/systemd/system/multi-user.target.wants/tb321fu-haptics.service"

  # depmod must run inside the chroot during provisioning. We drop a marker
  # file so the provisioning script knows to invoke depmod after rsync.
  touch "$pkg/usr/lib/tb321fu-haptics/.needs-depmod"

  cat > "$OUTPUT_DIR/stage-info.txt" <<INFO
stage=tb321fu-haptics-stage
version=$HAPTICS_STAGE_VERSION
arch=$ARCH
kernel_release=$kernel_release
haptics_source_root=$haptics_root
strip=$HAPTICS_STRIP
generated=$(date -u -Iseconds)
INFO
}

prepare_inputs
build_haptics_stage

ci_log "writing haptics stage checksums"
( cd "$OUTPUT_DIR/tree" && find . -type f -print0 | sort -z | xargs -0 sha256sum ) > "$OUTPUT_DIR/SHA256SUMS-tb321fu-haptics-stage.txt"
ci_log "haptics stage build complete: $OUTPUT_DIR"
