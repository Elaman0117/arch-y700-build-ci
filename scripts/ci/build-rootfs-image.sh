#!/usr/bin/env bash
# Build an Arch Linux ARM F2FS rootfs image for Lenovo Y700 (TB321FU / SM8650).
#
# This script mirrors the structure of the original Ubuntu build-rootfs-image.sh
# but replaces debootstrap + apt with the Arch Linux ARM generic armv8 tarball
# + pacman, and ext4 with F2FS.
#
# Key design choices vs. the Ubuntu version:
#   * Base rootfs comes from ArchLinuxARM-armv8-latest.tar.gz (pre-built by the
#     Arch Linux ARM project), not debootstrap. This is the closest analogue to
#     "pacstrap from scratch" that works in CI without a real Arch host.
#   * Root filesystem is F2FS, not ext4. F2FS is read/written by GRUB via the
#     `f2fs` module added in scripts/lib/y700-direct-grub.sh.
#   * The kernel lives in /boot on the rootfs (rolling, upgraded by pacman).
#     A frozen copy is also written to the FAT boot image by build-grub-image.sh
#     as a rescue fallback.
#   * mkinitcpio is configured with F2FS + Qualcomm block modules so the
#     initramfs can mount the root partition.
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
. "$SCRIPT_DIR/common.sh"

usage() {
  cat <<USAGE
Usage: $(basename "$0")

Build an Arch Linux ARM F2FS rootfs image for Lenovo Y700 TB321FU.

Required host tools: pacman (or chroot into the extracted tarball), mount,
chroot, mkfs (f2fs or ext4 depending on ROOTFS_FSTYPE), rsync, curl, sha256sum.

Environment inputs:
  OUTPUT_DIR                 default: out/ci-rootfs
  OUTPUT_PREFIX              default: arch-y700-armv8
  ARCH                       default: aarch64 (matches Arch Linux ARM armv8)
  ROOTFS_TARBALL_URL         default: https://archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz
  ROOTFS_TARBALL_PATH        optional local path; overrides URL
  PACMAN_MIRROR              default: http://mirror.archlinuxarm.org
  ARCH_LINUXARM_REPO         default: \$arch/\$repo (ALA mirror path layout)
  ROOTFS_IMAGE_SIZE          default: 20G
  ROOTFS_FSTYPE              default: ext4 (GitHub-hosted runners do not ship
                             f2fs kernel modules; use f2fs only on self-hosted
                             runners or locally). Supported: ext4, f2fs.
  ROOTFS_F2FS_OPTIONS        extra mkfs.f2fs options, default: -O extra_attr,inode_checksum,sb_checksum,compression
  ROOTFS_UUID                optional F2FS UUID
  ROOTFS_LABEL               default: Y700ARCH
  ROOTFS_PARTLABEL           metadata only, default: userdata
  HOSTNAME_NAME              default: y700
  DEFAULT_USER_NAME          default: y700
  DEFAULT_USER_PASSWORD      default: 1234
  ROOT_PASSWORD_MODE         locked|set|empty, default: locked
  ROOT_PASSWORD              used when ROOT_PASSWORD_MODE=set
  USER_SUDO_MODE             password|nopasswd|none, default: password
  TZ_REGION                  default: Asia/Shanghai
  LOCALES                    default: en_US.UTF-8 UTF-8\nzh_CN.UTF-8 UTF-8
  LANG_NAME                  default: zh_CN.UTF-8
  PACKAGE_LIST               extra pacman packages (space/newline separated)
  DESKTOP_ENV                optional package group appended to PACKAGE_LIST
  OVERLAY_ARCHIVE            optional local path or URL; extracted into rootfs
  OVERLAY_DIR                optional directory copied into rootfs
  PKG_ARCHIVE                optional archive of .pkg.tar.zst files
  PKG_DIR                    optional directory of .pkg.tar.zst files
  SENSOR_STAGE_DIR           optional directory staged by build-y700-sensor-stage.sh
  HAPTICS_STAGE_DIR          optional directory staged by build-tb321fu-haptics-stage.sh
  CAMERA_STACK_STAGE_DIR     optional directory staged by build-tb321fu-camera-stage.sh
  BUILD_TB321FU_GPU_SENSOR   build/install TB321FU KSystemStats Adreno plugin, default: 1
  TB321FU_GPU_SENSOR_SOURCE_DIR
                             optional source dir; defaults to repo source/
  TB321FU_GPU_SENSOR_BUILD_JOBS
                             default: 2
  INSTALL_GNOME_SNAPSHOT     install GNOME Snapshot camera app, default: 1
  APPLY_Y700_FIRMWARE_FIXES  copy/verify Y700 firmware compatibility paths, default: 1
  APPLY_Y700_AUDIO_POLICY_FIXES
                             install Y700 WirePlumber ALSA policy, default: 1
  SDDM_AUTOLOGIN             enable SDDM autologin for DEFAULT_USER_NAME, default: 0
  SDDM_AUTOLOGIN_SESSION     SDDM session desktop name, default: plasma
  MKINITCPIO_PRESETS         default: linux (matches /etc/mkinitcpio.d/linux.preset)
  MKINITCPIO_MODULES         default: "f2fs ext4 qcom_qmp_phy qcom_snps_femto_v2"
  MKINITCPIO_HOOKS           default: "base udev block autodetect keyboard keymap modconf filesystems fsck"
  CLEAN_PACMAN_CACHE         default: 1
  COMPRESS                   none|zstd|xz|7z, default: 7z
  CHUNK_SIZE                 optional 7z volume size, example: 1500m
  KEEP_RAW_IMAGE             keep uncompressed rootfs image, default: 0
USAGE
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  usage
  exit 0
fi

ci_require_cmd mount
ci_require_cmd umount
ci_require_cmd chroot
ci_require_cmd rsync
ci_require_cmd sha256sum
ci_require_cmd curl

# --- Defaults ---------------------------------------------------------------
ARCH=${ARCH:-aarch64}
ROOTFS_TARBALL_URL=${ROOTFS_TARBALL_URL:-https://archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz}
ROOTFS_TARBALL_PATH=${ROOTFS_TARBALL_PATH:-}
PACMAN_MIRROR=${PACMAN_MIRROR:-http://mirror.archlinuxarm.org}
ARCH_LINUXARM_REPO=${ARCH_LINUXARM_REPO:-'$arch/$repo'}
OUTPUT_PREFIX=${OUTPUT_PREFIX:-arch-y700-armv8}
OUTPUT_DIR=${OUTPUT_DIR:-out/ci-rootfs}
ROOTFS_IMAGE_SIZE=${ROOTFS_IMAGE_SIZE:-20G}
ROOTFS_FSTYPE=${ROOTFS_FSTYPE:-ext4}
ROOTFS_F2FS_OPTIONS=${ROOTFS_F2FS_OPTIONS:--O extra_attr,inode_checksum,sb_checksum,compression}
ROOTFS_UUID=${ROOTFS_UUID:-}
ROOTFS_LABEL=${ROOTFS_LABEL:-Y700ARCH}
ROOTFS_PARTLABEL=${ROOTFS_PARTLABEL:-userdata}
HOSTNAME_NAME=${HOSTNAME_NAME:-y700}
DEFAULT_USER_NAME=${DEFAULT_USER_NAME:-y700}
DEFAULT_USER_PASSWORD=${DEFAULT_USER_PASSWORD:-1234}
ROOT_PASSWORD_MODE=${ROOT_PASSWORD_MODE:-locked}
ROOT_PASSWORD=${ROOT_PASSWORD:-}
USER_SUDO_MODE=${USER_SUDO_MODE:-password}
TZ_REGION=${TZ_REGION:-Asia/Shanghai}
LANG_NAME=${LANG_NAME:-zh_CN.UTF-8}
LOCALES=${LOCALES:-$'en_US.UTF-8 UTF-8\nzh_CN.UTF-8 UTF-8'}
PACKAGE_LIST=${PACKAGE_LIST:-}
DESKTOP_ENV=${DESKTOP_ENV:-plasma-desktop}
INSTALL_GNOME_SNAPSHOT=${INSTALL_GNOME_SNAPSHOT:-1}
APPLY_Y700_FIRMWARE_FIXES=${APPLY_Y700_FIRMWARE_FIXES:-1}
APPLY_Y700_AUDIO_POLICY_FIXES=${APPLY_Y700_AUDIO_POLICY_FIXES:-1}
SDDM_AUTOLOGIN=${SDDM_AUTOLOGIN:-0}
SDDM_AUTOLOGIN_SESSION=${SDDM_AUTOLOGIN_SESSION:-plasma}
BUILD_TB321FU_GPU_SENSOR=${BUILD_TB321FU_GPU_SENSOR:-1}
TB321FU_GPU_SENSOR_SOURCE_DIR=${TB321FU_GPU_SENSOR_SOURCE_DIR:-}
TB321FU_GPU_SENSOR_BUILD_JOBS=${TB321FU_GPU_SENSOR_BUILD_JOBS:-2}
MKINITCPIO_PRESETS=${MKINITCPIO_PRESETS:-linux}
MKINITCPIO_MODULES=${MKINITCPIO_MODULES:-"f2fs ext4 qcom_qmp_phy qcom_snps_femto_v2"}
MKINITCPIO_HOOKS=${MKINITCPIO_HOOKS:-"base udev block autodetect keyboard keymap modconf filesystems fsck"}
CLEAN_PACMAN_CACHE=${CLEAN_PACMAN_CACHE:-1}
COMPRESS=${COMPRESS:-7z}
CHUNK_SIZE=${CHUNK_SIZE:-1500m}
KEEP_RAW_IMAGE=${KEEP_RAW_IMAGE:-0}

case "$ROOTFS_FSTYPE" in
  ext4|f2fs) ;;
  *) ci_die "unsupported ROOTFS_FSTYPE=$ROOTFS_FSTYPE; only ext4 and f2fs are supported" ;;
esac
[ "$ARCH" = aarch64 ] || [ "$ARCH" = armv8 ] || ci_die "Arch Linux ARM ships armv8 (= aarch64); got $ARCH"

# Default Arch packages. Deliberately smaller than the Ubuntu PACKAGE_LIST
# because the Arch base tarball already includes systemd, dbus, sudo, etc.
default_packages="linux-aarch64 linux-firmware base base-devel networkmanager openssh nano vim rsync f2fs-tools inetutils less which"
if [ -n "$DESKTOP_ENV" ]; then
  PACKAGE_LIST="$PACKAGE_LIST $DESKTOP_ENV"
fi
if ci_bool "$INSTALL_GNOME_SNAPSHOT"; then
  PACKAGE_LIST="$PACKAGE_LIST snapshot"
fi
PACKAGE_LIST="$default_packages $PACKAGE_LIST"

mkdir -p "$OUTPUT_DIR"
work_dir=$(mktemp -d "$OUTPUT_DIR/.rootfs-build.XXXXXX")
rootfs_dir="$work_dir/rootfs"
rootfs_img="$OUTPUT_DIR/${OUTPUT_PREFIX}-rootfs.img"
manifest="$OUTPUT_DIR/${OUTPUT_PREFIX}-rootfs.manifest"
mounted=0

# --- Y700 fix functions (FS-agnostic; operate on a path root) ---------------

apply_y700_firmware_fixes() {
  local root=$1
  ci_log "applying Y700 firmware path fixes"

  install -d -m 0755 "$root/lib/firmware/qcom" "$root/lib/firmware/qcom/sm8650" "$root/lib/firmware/qcom/vpu"

  copy_firmware_if_missing() {
    local source_rel=$1
    local dest_rel=$2
    [ -f "$root/$source_rel" ] || return 1
    if [ -e "$root/$dest_rel" ]; then
      return 0
    fi
    install -d -m 0755 "$(dirname "$root/$dest_rel")"
    install -m 0644 "$root/$source_rel" "$root/$dest_rel"
  }

  local src
  for src in \
    usr/lib/firmware/qcom/sm8650/lenovo/tb321fu/gen70900_zap.mbn \
    lib/firmware/qcom/sm8650/lenovo/tb321fu/gen70900_zap.mbn; do
    if copy_firmware_if_missing "$src" lib/firmware/qcom/gen70900_zap.mbn; then
      break
    fi
  done
  for src in \
    usr/lib/firmware/qcom-tb321fu/Lenovo-Y700-TB321FU-tplg.bin \
    lib/firmware/qcom-tb321fu/Lenovo-Y700-TB321FU-tplg.bin; do
    if copy_firmware_if_missing "$src" lib/firmware/qcom/sm8650/Lenovo-Y700-TB321FU-tplg.bin; then
      break
    fi
  done
  for src in \
    usr/lib/firmware/qcom/gen70900_aqe.fw \
    usr/lib/firmware/qcom/gen70900_sqe.fw \
    usr/lib/firmware/qcom/gmu_gen70900.bin \
    usr/lib/firmware/qcom/vpu/vpu33_p4.mbn; do
    local dst=${src#usr/}
    copy_firmware_if_missing "$src" "$dst" || true
  done

  local required=(
    lib/firmware/qcom/gen70900_aqe.fw
    lib/firmware/qcom/gen70900_sqe.fw
    lib/firmware/qcom/gen70900_zap.mbn
    lib/firmware/qcom/gmu_gen70900.bin
    lib/firmware/qcom/sm8650/Lenovo-Y700-TB321FU-tplg.bin
    lib/firmware/qcom/vpu/vpu33_p4.mbn
  )
  local rel
  for rel in "${required[@]}"; do
    [ -e "$root/$rel" ] || [ -L "$root/$rel" ] || ci_die "missing Y700 required compatibility file: $rel"
  done
}

apply_y700_audio_policy_fixes() {
  local root=$1
  local conf_dir="$root/etc/wireplumber/wireplumber.conf.d"
  local conf="$conf_dir/51-y700-alsa-auto.conf"
  ci_log "installing Y700 WirePlumber ALSA policy fix"

  install -d -m 0755 "$conf_dir"
  cat > "$conf" <<'CONF'
monitor.alsa.rules = [
  {
    matches = [
      {
        device.name = "alsa_card.platform-sound"
      }
    ]
    actions = {
      update-props = {
        api.alsa.use-acp = true
        api.alsa.use-ucm = true
        api.acp.auto-profile = true
        api.acp.auto-port = true
        api.alsa.split-enable = false
      }
    }
  }
]
CONF
  chmod 0644 "$conf"
  chown 0:0 "$conf" 2>/dev/null || true

  grep -q 'api.acp.auto-profile = true' "$conf" || ci_die "Y700 ALSA policy missing auto-profile=true"
  grep -q 'api.acp.auto-port = true' "$conf" || ci_die "Y700 ALSA policy missing auto-port=true"
  grep -q 'api.alsa.split-enable = false' "$conf" || ci_die "Y700 ALSA policy missing split-enable=false"
}

apply_sddm_autologin() {
  local root=$1
  local conf_dir="$root/etc/sddm.conf.d"
  local conf="$conf_dir/zz-tb321fu-autologin.conf"
  local session=${SDDM_AUTOLOGIN_SESSION%.desktop}

  rm -f "$conf" "$conf_dir/30-autologin.conf" "$conf_dir/10-y700-autologin.conf"

  if ! ci_bool "$SDDM_AUTOLOGIN"; then
    ci_log "SDDM autologin disabled"
    return 0
  fi

  ci_log "enabling SDDM autologin for $DEFAULT_USER_NAME"
  install -d -m 0755 "$conf_dir"
  cat > "$conf" <<CONF
[Autologin]
User=$DEFAULT_USER_NAME
Session=$session
Relogin=false
CONF
  chmod 0644 "$conf"
  chown 0:0 "$conf" 2>/dev/null || true

  grep -q "^User=$DEFAULT_USER_NAME$" "$conf" || ci_die "SDDM autologin user was not written"
  grep -q "^Session=$session$" "$conf" || ci_die "SDDM autologin session was not written"
}

apply_tb321fu_legacy_cleanup() {
  local root=$1

  ci_log "removing legacy y700 sensor and haptics glue that conflicts with TB321FU packages"
  rm -f \
    "$root/etc/systemd/system/iio-sensor-proxy.service.d/10-y700-ssc.conf" \
    "$root/etc/systemd/system/y700-sns-init.service" \
    "$root/etc/systemd/system/y700-aw86937-haptics.service" \
    "$root/etc/udev/rules.d/90-y700-haptics.rules" \
    "$root/usr/local/libexec/y700-iio-sensor-proxy" \
    "$root/usr/local/sbin/y700-aw86937-bind"
  rm -rf \
    "$root/usr/local/lib/y700-sns" \
    "$root/usr/local/share/y700-sns"

  if [ -d "$root/etc/systemd/system/multi-user.target.wants" ]; then
    rm -f \
      "$root/etc/systemd/system/multi-user.target.wants/y700-sns-init.service" \
      "$root/etc/systemd/system/multi-user.target.wants/y700-aw86937-haptics.service"
  fi

  if [ -f "$root/usr/lib/systemd/system/qcom-sns-init.service" ]; then
    install -d -m 0755 "$root/etc/systemd/system/multi-user.target.wants"
    ln -sfn /usr/lib/systemd/system/qcom-sns-init.service \
      "$root/etc/systemd/system/multi-user.target.wants/qcom-sns-init.service"
  fi
  if [ -f "$root/usr/lib/systemd/system/tb321fu-haptics.service" ]; then
    install -d -m 0755 "$root/etc/systemd/system/multi-user.target.wants"
    ln -sfn /usr/lib/systemd/system/tb321fu-haptics.service \
      "$root/etc/systemd/system/multi-user.target.wants/tb321fu-haptics.service"
  fi

  if [ -x "$root/usr/libexec/iio-sensor-proxy" ]; then
    install -d -m 0755 "$root/usr/share/dbus-1/system-services"
    cat > "$root/usr/share/dbus-1/system-services/net.hadess.SensorProxy.service" <<'DBUS_SERVICE'
[D-BUS Service]
Name=net.hadess.SensorProxy
Exec=/usr/libexec/iio-sensor-proxy
User=root
SystemdService=iio-sensor-proxy.service
DBUS_SERVICE
    chmod 0644 "$root/usr/share/dbus-1/system-services/net.hadess.SensorProxy.service"
  fi
}

# Build and install the TB321FU Adreno GPU KSystemStats plugin inside the
# rootfs chroot. Mirrors the original apply_tb321fu_gpu_sensor but uses pacman
# to fetch build deps and ninja instead of plain make.
apply_tb321fu_gpu_sensor() {
  local root=$1
  local source_dir=${TB321FU_GPU_SENSOR_SOURCE_DIR:-"$SCRIPT_DIR/../../source/tb321fu-ksystemstats-adreno-freq"}
  local rootfs_src=/tmp/tb321fu-ksystemstats-adreno-freq-src
  local rootfs_build=/tmp/tb321fu-ksystemstats-adreno-freq-build
  local plugin_rel=usr/lib/qt6/plugins/ksystemstats/ksystemstats_plugin_tb321fu_gpu.so
  local stock_plugin_rel=usr/lib/qt6/plugins/ksystemstats/ksystemstats_plugin_gpu.so
  local disabled_stock_plugin_rel=$stock_plugin_rel.disabled-tb321fu-adreno

  ci_log "building TB321FU KSystemStats Adreno GPU frequency plugin"

  [ -f "$source_dir/CMakeLists.txt" ] || ci_die "missing TB321FU GPU sensor source: $source_dir/CMakeLists.txt"
  [ -f "$source_dir/tb321fu_gpu.cpp" ] || ci_die "missing TB321FU GPU sensor source: $source_dir/tb321fu_gpu.cpp"
  [ -f "$source_dir/metadata.json" ] || ci_die "missing TB321FU GPU sensor source: $source_dir/metadata.json"

  rm -rf "$root$rootfs_src" "$root$rootfs_build"
  install -d -m 0755 "$root$rootfs_src"
  rsync -a --delete "$source_dir"/ "$root$rootfs_src"/

  cat > "$root/root/ci-build-tb321fu-gpu-sensor.sh" <<'GPU_SENSOR_BUILD'
#!/usr/bin/env bash
set -euo pipefail

src=/tmp/tb321fu-ksystemstats-adreno-freq-src
build=/tmp/tb321fu-ksystemstats-adreno-freq-build
plugin=/usr/lib/qt6/plugins/ksystemstats/ksystemstats_plugin_tb321fu_gpu.so
stock=/usr/lib/qt6/plugins/ksystemstats/ksystemstats_plugin_gpu.so
disabled=/usr/lib/qt6/plugins/ksystemstats/ksystemstats_plugin_gpu.so.disabled-tb321fu-adreno
build_deps="cmake extra-cmake-modules gcc make ksystemstats qt6-base kf6-coreaddons kf6-i18n"

pacman -Sy --noconfirm $build_deps

cmake -S "$src" -B "$build" -DCMAKE_BUILD_TYPE=RelWithDebInfo -DCMAKE_INSTALL_PREFIX=/usr
cmake --build "$build" -j"${TB321FU_GPU_SENSOR_BUILD_JOBS:-2}"
cmake --install "$build"

test -f "$plugin"
if [ -f "$stock" ]; then
  rm -f "$disabled"
  mv "$stock" "$disabled"
fi
test ! -e "$stock"

install -d -m 0755 /usr/share/tb321fu-ksystemstats-gpu
sha256sum "$plugin" > /usr/share/tb321fu-ksystemstats-gpu/ksystemstats_plugin_tb321fu_gpu.so.sha256

rm -rf "$src" "$build"
pacman -Rns --noconfirm $build_deps || true
pacman -Scc --noconfirm || true

test -f "$plugin"
test ! -e "$stock"
test ! -e "$src"
test ! -e "$build"
GPU_SENSOR_BUILD
  chmod +x "$root/root/ci-build-tb321fu-gpu-sensor.sh"

  chroot "$root" env -i \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    HOME=/root \
    LANG=C.UTF-8 \
    TB321FU_GPU_SENSOR_BUILD_JOBS="${TB321FU_GPU_SENSOR_BUILD_JOBS:-2}" \
    bash /root/ci-build-tb321fu-gpu-sensor.sh

  rm -f "$root/root/ci-build-tb321fu-gpu-sensor.sh"
  [ -f "$root/$plugin_rel" ] || ci_die "TB321FU GPU sensor plugin missing after build: /$plugin_rel"
  [ ! -e "$root/$stock_plugin_rel" ] || ci_die "stock KSystemStats GPU plugin still enabled: /$stock_plugin_rel"
  [ -f "$root/$disabled_stock_plugin_rel" ] || ci_die "disabled stock KSystemStats GPU plugin missing: /$disabled_stock_plugin_rel"
}

cleanup() {
  set +e
  if [ "$mounted" = 1 ]; then
    # Kill any processes still running inside the chroot before unmounting.
    fuser -k "$rootfs_dir" 2>/dev/null || true
    for p in dev/pts dev proc sys run; do
      mountpoint -q "$rootfs_dir/$p" && umount -l "$rootfs_dir/$p" 2>/dev/null
    done
    mountpoint -q "$rootfs_dir" && umount -l "$rootfs_dir" 2>/dev/null
  fi
  rm -rf "$work_dir" 2>/dev/null
}
trap cleanup EXIT

# --- Create the rootfs image ------------------------------------------------
ci_log "creating $ROOTFS_FSTYPE image: $rootfs_img"
rm -f "$rootfs_img"
truncate -s "$ROOTFS_IMAGE_SIZE" "$rootfs_img"
case "$ROOTFS_FSTYPE" in
  ext4)
    ci_require_cmd mkfs.ext4
    mkfs_args=(-F -L "$ROOTFS_LABEL")
    if [ -n "$ROOTFS_UUID" ]; then
      mkfs_args+=(-U "$ROOTFS_UUID")
    fi
    mkfs.ext4 "${mkfs_args[@]}" "$rootfs_img" >/dev/null
    ;;
  f2fs)
    ci_require_cmd mkfs.f2fs
    mkfs_args=(-f -l "$ROOTFS_LABEL")
    # f2fs-tools does not let us set UUID at mkfs time; ROOTFS_UUID is metadata-only.
    # shellcheck disable=SC2086
    mkfs.f2fs ${mkfs_args[@]} $ROOTFS_F2FS_OPTIONS "$rootfs_img" >/dev/null
    ;;
esac

mkdir -p "$rootfs_dir"
mount -o loop "$rootfs_img" "$rootfs_dir"
mounted=1

# --- Fetch and extract the Arch Linux ARM generic armv8 tarball ------------
ci_log "fetching Arch Linux ARM $ARCH tarball"
tarball="$work_dir/rootfs.tar.gz"
if [ -n "$ROOTFS_TARBALL_PATH" ]; then
  cp -a "$ROOTFS_TARBALL_PATH" "$tarball"
elif [ -n "$ROOTFS_TARBALL_URL" ]; then
  ci_download "$ROOTFS_TARBALL_URL" "$tarball"
else
  ci_die "set ROOTFS_TARBALL_URL or ROOTFS_TARBALL_PATH"
fi

ci_log "extracting rootfs tarball into F2FS image"
tar -xzf "$tarball" -C "$rootfs_dir"

# Arch Linux ARM tarball ships with /etc/resolv.conf as a static file; replace
# it with a copy of the host resolver so chroot apt/pacman works.
rm -f "$rootfs_dir/etc/resolv.conf"
if [ -n "${RESOLV_CONF_CONTENT:-}" ]; then
  printf '%s\n' "$RESOLV_CONF_CONTENT" > "$rootfs_dir/etc/resolv.conf"
elif [ -f /run/systemd/resolve/resolv.conf ]; then
  cp /run/systemd/resolve/resolv.conf "$rootfs_dir/etc/resolv.conf"
else
  cp /etc/resolv.conf "$rootfs_dir/etc/resolv.conf"
fi
if ! awk '
  /^[[:space:]]*nameserver[[:space:]]+/ {
    ns=$2
    if (ns !~ /^(127\.|::1$|0\.0\.0\.0$)/) good=1
  }
  END { exit good ? 0 : 1 }
' "$rootfs_dir/etc/resolv.conf"; then
  printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > "$rootfs_dir/etc/resolv.conf"
fi

# Configure pacman mirror.
mkdir -p "$rootfs_dir/etc/pacman.d"
cat > "$rootfs_dir/etc/pacman.d/mirrorlist" <<EOF
# Arch Linux ARM mirror used by this Y700 build
Server = $PACMAN_MIRROR/$ARCH_LINUXARM_REPO
EOF

# Bootloaders/keyring: the Arch Linux ARM tarball ships archlinuxarm-keyring.
# Run pacman-key --init + populate inside the chroot the first time.
ci_log "preparing chroot mounts"
mount --bind /dev "$rootfs_dir/dev"
mount --bind /dev/pts "$rootfs_dir/dev/pts"
mount -t proc proc "$rootfs_dir/proc"
mount -t sysfs sysfs "$rootfs_dir/sys"
mount -t tmpfs tmpfs "$rootfs_dir/run"

# --- Provisioning script (runs inside chroot) ------------------------------
# We keep the script heredoc-style for parity with the original Ubuntu builder.
cat > "$rootfs_dir/root/ci-provision.sh" <<'PROVISION'
#!/usr/bin/env bash
set -euo pipefail

# Initialize pacman keyring if not already done.
if ! pacman-key --list-keys archlinuxarm >/dev/null 2>&1; then
  pacman-key --init
  pacman-key --populate archlinuxarm
fi

pacman -Syu --noconfirm --needed $PACKAGE_LIST

# --- Plasma Mobile / desktop skeleton config (same content as Ubuntu build) ---
install -d -m 0755 /etc/skel/.config
cat > /etc/skel/.config/plasmakeyboardrc <<'PLASMAKEYBOARDRC'
[General]
enabledLocales=en_US
soundEnabled=true
vibrationEnabled=true
vibrationMs=20
PLASMAKEYBOARDRC
chmod 0644 /etc/skel/.config/plasmakeyboardrc

cat > /etc/skel/.config/kwinoutputconfig.json <<'KWINOUTPUTCONFIG'
[
    {
        "data": [
            {
                "allowDdcCi": true,
                "allowSdrSoftwareBrightness": false,
                "autoBrightnessCurve": [
                    0,
                    200,
                    2500,
                    12000,
                    40000,
                    100000
                ],
                "autoRotation": "InTabletMode",
                "automaticBrightness": true,
                "brightness": 0.35,
                "colorPowerTradeoff": "PreferEfficiency",
                "colorProfileSource": "sRGB",
                "connectorName": "DSI-1",
                "detectedDdcCi": false,
                "edrPolicy": "always",
                "highDynamicRange": false,
                "iccProfilePath": "",
                "maxBitsPerColor": 0,
                "mode": {
                    "height": 2560,
                    "refreshRate": 120000,
                    "width": 1600
                },
                "overscan": 0,
                "rgbRange": "Automatic",
                "scale": 2.3,
                "sdrBrightness": 200,
                "sdrGamutWideness": 0,
                "sharpness": 0,
                "transform": "Rotated180",
                "vrrPolicy": "Never",
                "wideColorGamut": false
            }
        ],
        "name": "outputs"
    }
]
KWINOUTPUTCONFIG
chmod 0644 /etc/skel/.config/kwinoutputconfig.json

# --- System services -------------------------------------------------------
systemctl enable NetworkManager || true
systemctl enable sshd || true
# sddm is only available when a desktop environment is installed.
systemctl enable sddm 2>/dev/null || true

# --- User / password / sudo ------------------------------------------------
if ! id -u "$DEFAULT_USER_NAME" >/dev/null 2>&1; then
  useradd -m -G wheel -s /bin/bash "$DEFAULT_USER_NAME"
fi
printf '%s:%s\n' "$DEFAULT_USER_NAME" "$DEFAULT_USER_PASSWORD" | chpasswd

case "$ROOT_PASSWORD_MODE" in
  locked)
    passwd -l root || true
    ;;
  set)
    [ -n "$ROOT_PASSWORD" ] || { echo 'ROOT_PASSWORD_MODE=set requires ROOT_PASSWORD' >&2; exit 1; }
    printf 'root:%s\n' "$ROOT_PASSWORD" | chpasswd
    ;;
  empty)
    passwd -d root || true
    ;;
  *)
    echo "unsupported ROOT_PASSWORD_MODE=$ROOT_PASSWORD_MODE" >&2
    exit 1
    ;;
esac

case "$USER_SUDO_MODE" in
  password)
    # wheel group with password is already enabled by default in /etc/sudoers
    rm -f "/etc/sudoers.d/010_${DEFAULT_USER_NAME}-nopasswd"
    ;;
  nopasswd)
    mkdir -p /etc/sudoers.d
    printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$DEFAULT_USER_NAME" > "/etc/sudoers.d/010_${DEFAULT_USER_NAME}-nopasswd"
    chmod 0440 "/etc/sudoers.d/010_${DEFAULT_USER_NAME}-nopasswd"
    visudo -cf "/etc/sudoers.d/010_${DEFAULT_USER_NAME}-nopasswd"
    ;;
  none)
    gpasswd -d "$DEFAULT_USER_NAME" wheel >/dev/null 2>&1 || true
    rm -f "/etc/sudoers.d/010_${DEFAULT_USER_NAME}-nopasswd"
    ;;
  *)
    echo "unsupported USER_SUDO_MODE=$USER_SUDO_MODE" >&2
    exit 1
    ;;
esac

# --- Timezone / locale -----------------------------------------------------
if [ -n "$TZ_REGION" ] && [ -f "/usr/share/zoneinfo/$TZ_REGION" ]; then
  ln -sf "/usr/share/zoneinfo/$TZ_REGION" /etc/localtime
  printf '%s\n' "$TZ_REGION" > /etc/timezone
fi

while IFS= read -r locale_line; do
  [ -n "$locale_line" ] || continue
  if grep -q "^#${locale_line}\$" /etc/locale.gen 2>/dev/null; then
    sed -i "s/^#\(${locale_line}\)$/\1/" /etc/locale.gen
  elif ! grep -q "^${locale_line}\$" /etc/locale.gen 2>/dev/null; then
    printf '%s\n' "$locale_line" >> /etc/locale.gen
  fi
done <<LOCALES_EOF
$LOCALES
LOCALES_EOF
locale-gen || true
printf 'LANG=%s\n' "$LANG_NAME" > /etc/locale.conf

# --- Hostname --------------------------------------------------------------
printf '%s\n' "$HOSTNAME_NAME" > /etc/hostname
sed -i '/^127\.0\.1\.1\b/d' /etc/hosts
printf '127.0.1.1 %s\n' "$HOSTNAME_NAME" >> /etc/hosts

# --- mkinitcpio configuration ----------------------------------------------
# Build an initramfs that can mount the root filesystem on Qualcomm SM8650.
# We rewrite /etc/mkinitcpio.conf directly because ALA's mkinitcpio may not
# support the mkinitcpio.conf.d/ drop-in directory.
mkdir -p /etc
if [ -f /etc/mkinitcpio.conf ]; then
  cp -a /etc/mkinitcpio.conf /etc/mkinitcpio.conf.orig
fi
cat > /etc/mkinitcpio.conf <<MKINITCPIO_EOF
MODULES=($MKINITCPIO_MODULES)
BINARIES=()
FILES=()
HOOKS=($MKINITCPIO_HOOKS)
MKINITCPIO_EOF
chmod 0644 /etc/mkinitcpio.conf

# Regenerate the initramfs for every installed kernel. We use -g + -k instead
# of -p because the preset files may not be set up correctly in the chroot.
for kver_dir in /usr/lib/modules/*; do
  [ -d "$kver_dir" ] || continue
  kver=$(basename "$kver_dir")
  echo "==> Building initramfs for kernel $kver"
  mkinitcpio -g /boot/initramfs-"$kver".img -k "$kver" -S autodetect 2>&1 || {
    echo "WARNING: mkinitcpio -g failed for $kver, trying with autodetect" >&2
    mkinitcpio -g /boot/initramfs-"$kver".img -k "$kver" 2>&1 || true
  }
  # Create the standard initramfs-linux.img symlink that GRUB expects.
  case "$kver" in
    linux-*) ln -sf "initramfs-$kver.img" /boot/initramfs-linux.img ;;
  esac
done

# Also try the preset-based approach as a fallback.
for preset in $MKINITCPIO_PRESETS; do
  if [ -f "/etc/mkinitcpio.d/$preset.preset" ]; then
    mkinitcpio -p "$preset" 2>&1 || true
  fi
done

# --- Stage-installed packages and overlays ---------------------------------
# PKG_DIR / PKG_ARCHIVE content is staged at /var/tmp/ci-pkgs/ by the outer
# script before this chroot runs.
if compgen -G "/var/tmp/ci-pkgs/*.pkg.tar.zst" >/dev/null; then
  pacman -U --noconfirm --overwrite '*' /var/tmp/ci-pkgs/*.pkg.tar.zst || true
fi

# Overlays staged as plain tarballs at /var/tmp/ci-pkgs/*.tar.*
for ci_overlay in /var/tmp/ci-pkgs/*.tar /var/tmp/ci-pkgs/*.tar.gz /var/tmp/ci-pkgs/*.tgz /var/tmp/ci-pkgs/*.tar.xz /var/tmp/ci-pkgs/*.tar.zst; do
  [ -e "$ci_overlay" ] || continue
  case "$ci_overlay" in
    *.tar) tar -C / -xf "$ci_overlay" ;;
    *.tar.gz|*.tgz) tar -C / -xzf "$ci_overlay" ;;
    *.tar.xz) tar -C / -xJf "$ci_overlay" ;;
    *.tar.zst) tar -C / --zstd -xf "$ci_overlay" ;;
  esac
done

# ldconfig refresh in case overlays dropped new .so files.
ldconfig || true

# --- Cleanup ---------------------------------------------------------------
if [ "$CLEAN_PACMAN_CACHE" = 1 ]; then
  pacman -Scc --noconfirm || true
fi
rm -rf /var/cache/pacman/pkg/*

rm -f /etc/machine-id
touch /etc/machine-id
rm -f /root/.bash_history "/home/${DEFAULT_USER_NAME}/.bash_history"
rm -rf /tmp/* /var/tmp/ci-pkgs /root/ci-provision.sh
PROVISION
chmod +x "$rootfs_dir/root/ci-provision.sh"

# --- Stage packages and overlays into the rootfs ---------------------------
if [ -n "${PKG_ARCHIVE:-}" ]; then
  tmp_archive="$work_dir/pkgs.archive"
  mkdir -p "$rootfs_dir/var/tmp/ci-pkgs"
  ci_download "$PKG_ARCHIVE" "$tmp_archive"
  ci_extract_archive "$tmp_archive" "$rootfs_dir/var/tmp/ci-pkgs"
fi
if [ -n "${PKG_DIR:-}" ]; then
  mkdir -p "$rootfs_dir/var/tmp/ci-pkgs"
  find "$PKG_DIR" -maxdepth 1 -type f -name '*.pkg.tar.zst' -exec cp -a {} "$rootfs_dir/var/tmp/ci-pkgs/" \;
fi

# Stage dirs produced by the stage-builder scripts. They are pre-laid-out
# directory trees that we rsync into the rootfs verbatim.
for stage_var in SENSOR_STAGE_DIR HAPTICS_STAGE_DIR CAMERA_STACK_STAGE_DIR; do
  stage_value=$(eval echo "\${${stage_var}:-}")
  if [ -n "$stage_value" ] && [ -d "$stage_value" ]; then
    ci_log "applying $stage_value into rootfs"
    # Stage dirs may ship a stage.tar.zst that should be unpacked inside the
    # chroot (for things that need post-install hooks). If no archive is
    # present, rsync the directory tree directly.
    if [ -f "$stage_value/stage.tar.zst" ]; then
      cp -a "$stage_value/stage.tar.zst" "$rootfs_dir/var/tmp/ci-pkgs/stage-$(printf '%s' "$stage_var" | tr A-Z a-z).tar.zst"
    fi
    if [ -d "$stage_value/tree" ]; then
      rsync -aH --numeric-ids "$stage_value/tree"/ "$rootfs_dir"/
    fi
  fi
done

ci_log "provisioning rootfs"
chroot "$rootfs_dir" env -i \
  PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  HOME=/root \
  LANG=C.UTF-8 \
  PACKAGE_LIST="$PACKAGE_LIST" \
  DEFAULT_USER_NAME="$DEFAULT_USER_NAME" \
  DEFAULT_USER_PASSWORD="$DEFAULT_USER_PASSWORD" \
  ROOT_PASSWORD_MODE="$ROOT_PASSWORD_MODE" \
  ROOT_PASSWORD="$ROOT_PASSWORD" \
  USER_SUDO_MODE="$USER_SUDO_MODE" \
  TZ_REGION="$TZ_REGION" \
  LOCALES="$LOCALES" \
  LANG_NAME="$LANG_NAME" \
  HOSTNAME_NAME="$HOSTNAME_NAME" \
  MKINITCPIO_MODULES="$MKINITCPIO_MODULES" \
  MKINITCPIO_HOOKS="$MKINITCPIO_HOOKS" \
  MKINITCPIO_PRESETS="$MKINITCPIO_PRESETS" \
  CLEAN_PACMAN_CACHE="$CLEAN_PACMAN_CACHE" \
  bash /root/ci-provision.sh

# Restore resolv.conf to the systemd-resolved default (Arch style).
rm -f "$rootfs_dir/etc/resolv.conf"
ln -s ../run/systemd/resolve/stub-resolv.conf "$rootfs_dir/etc/resolv.conf"

# --- User-provided overlays (applied AFTER provisioning) -------------------
if [ -n "${OVERLAY_ARCHIVE:-}" ]; then
  tmp_overlay="$work_dir/overlay.archive"
  ci_log "applying overlay archive: $OVERLAY_ARCHIVE"
  ci_download "$OVERLAY_ARCHIVE" "$tmp_overlay"
  ci_extract_archive "$tmp_overlay" "$rootfs_dir"
fi
if [ -n "${OVERLAY_DIR:-}" ]; then
  ci_log "applying overlay directory: $OVERLAY_DIR"
  rsync -aH --numeric-ids "$OVERLAY_DIR"/ "$rootfs_dir"/
fi

# --- Y700-specific fixes ---------------------------------------------------
apply_sddm_autologin "$rootfs_dir"
apply_tb321fu_legacy_cleanup "$rootfs_dir"
if ci_bool "$APPLY_Y700_FIRMWARE_FIXES"; then
  apply_y700_firmware_fixes "$rootfs_dir"
fi
if ci_bool "$APPLY_Y700_AUDIO_POLICY_FIXES"; then
  apply_y700_audio_policy_fixes "$rootfs_dir"
fi
if ci_bool "$BUILD_TB321FU_GPU_SENSOR"; then
  apply_tb321fu_gpu_sensor "$rootfs_dir"
fi

# --- Inner GRUB config (lives on F2FS, pacman hook can rewrite it) ---------
# We write a minimal default here; build-grub-image.sh overwrites it with the
# full dual-kernel config via y700_write_inner_grub_cfg if the boot image build
# runs after this step.
mkdir -p "$rootfs_dir/boot/grub"
cat > "$rootfs_dir/boot/grub/grub.cfg" <<'INNER_GRUB_PLACEHOLDER'
# Placeholder. build-grub-image.sh writes the real inner grub.cfg here
# after both the FAT boot image and the F2FS rootfs are built. If you flash
# only the rootfs image without re-running build-grub-image.sh, GRUB will
# fall back to the FAT-resident frozen kernel automatically.
set timeout=3
set default=0
menuentry "Arch Y700 (no inner grub.cfg; using FAT fallback)" {
    search --no-floppy --partlabel --set=boot ESP
    devicetree ($boot)/dtb/sm8650-lenovo-tb321fu.dtb
    linux /vmlinuz-fallback root=PARTLABEL=userdata rw rootwait -- quiet
    initrd /initramfs-fallback.img
}
INNER_GRUB_PLACEHOLDER

# --- Build info ------------------------------------------------------------
cat > "$rootfs_dir/BUILD-INFO.txt" <<INFO
generated=$(date -u -Iseconds)
distro=arch-linux-arm
arch=$ARCH
rootfs_fstype=$ROOTFS_FSTYPE
rootfs_label=$ROOTFS_LABEL
rootfs_uuid=${ROOTFS_UUID:-}
rootfs_partlabel=$ROOTFS_PARTLABEL
hostname=$HOSTNAME_NAME
default_user=$DEFAULT_USER_NAME
root_password_mode=$ROOT_PASSWORD_MODE
user_sudo_mode=$USER_SUDO_MODE
pacman_mirror=$PACMAN_MIRROR
overlay_archive=${OVERLAY_ARCHIVE:-}
overlay_dir=${OVERLAY_DIR:-}
pkg_archive=${PKG_ARCHIVE:-}
pkg_dir=${PKG_DIR:-}
sensor_stage_dir=${SENSOR_STAGE_DIR:-}
haptics_stage_dir=${HAPTICS_STAGE_DIR:-}
camera_stack_stage_dir=${CAMERA_STACK_STAGE_DIR:-}
build_tb321fu_gpu_sensor=$BUILD_TB321FU_GPU_SENSOR
install_gnome_snapshot=$INSTALL_GNOME_SNAPSHOT
apply_y700_firmware_fixes=$APPLY_Y700_FIRMWARE_FIXES
apply_y700_audio_policy_fixes=$APPLY_Y700_AUDIO_POLICY_FIXES
sddm_autologin=$SDDM_AUTOLOGIN
sddm_autologin_session=$SDDM_AUTOLOGIN_SESSION
mkinitcpio_presets=$MKINITCPIO_PRESETS
mkinitcpio_modules=$MKINITCPIO_MODULES
mkinitcpio_hooks=$MKINITCPIO_HOOKS
INFO

# --- Manifest --------------------------------------------------------------
ci_log "writing manifest"
( cd "$rootfs_dir" && find . -xdev -printf '%y\t%u\t%g\t%m\t%s\t%p\n' | sort ) > "$manifest"

# --- Unmount, fsck ---------------------------------------------------------
# Kill any processes still running inside the chroot (e.g. pacman's gpg-agent
# or leftover dbus-daemon) before unmounting.
fuser -k "$rootfs_dir" 2>/dev/null || true
sleep 2
for p in dev/pts dev proc sys run; do
  mountpoint -q "$rootfs_dir/$p" && umount -l "$rootfs_dir/$p" 2>/dev/null || true
done
umount -l "$rootfs_dir" 2>/dev/null || true
mounted=0

case "$ROOTFS_FSTYPE" in
  ext4)
    ci_log "running e2fsck on rootfs image"
    e2fsck -f -y "$rootfs_img" || true
    ;;
  f2fs)
    ci_log "running fsck.f2fs on rootfs image"
    fsck.f2fs -p "$rootfs_img" || true
    ;;
esac

# --- Checksums -------------------------------------------------------------
ci_log "checksumming rootfs image"
raw_sha_file="$OUTPUT_DIR/${OUTPUT_PREFIX}-rootfs.raw.sha256"
( cd "$OUTPUT_DIR" && sha256sum "$(basename "$rootfs_img")" > "$(basename "$raw_sha_file")" )

checksum_file="$OUTPUT_DIR/${OUTPUT_PREFIX}-rootfs.SHA256SUMS"
rm -f "$checksum_file"
( cd "$OUTPUT_DIR" && sha256sum "$(basename "$manifest")" "$(basename "$raw_sha_file")" > "$(basename "$checksum_file")" )

# --- Compression -----------------------------------------------------------
case "$COMPRESS" in
  none)
    ( cd "$OUTPUT_DIR" && sha256sum "$(basename "$rootfs_img")" >> "$(basename "$checksum_file")" )
    ;;
  zstd)
    ci_require_cmd zstd
    zstd -T0 -19 -f "$rootfs_img" -o "$rootfs_img.zst"
    ( cd "$OUTPUT_DIR" && sha256sum "$(basename "$rootfs_img").zst" >> "$(basename "$checksum_file")" )
    ;;
  xz)
    xz -T0 -k -f "$rootfs_img"
    ( cd "$OUTPUT_DIR" && sha256sum "$(basename "$rootfs_img").xz" >> "$(basename "$checksum_file")" )
    ;;
  7z)
    ci_require_cmd 7z
    sevenz_out="$rootfs_img.7z"
    rm -f "$sevenz_out" "$sevenz_out".*
    if [ -n "${CHUNK_SIZE:-}" ]; then
      7z a "$sevenz_out" "$rootfs_img" -t7z -m0=lzma2 -mx=9 -mmt=on "-v$CHUNK_SIZE" >/dev/null
      ( cd "$OUTPUT_DIR" && sha256sum "$(basename "$sevenz_out")".* >> "$(basename "$checksum_file")" )
    else
      7z a "$sevenz_out" "$rootfs_img" -t7z -m0=lzma2 -mx=9 -mmt=on >/dev/null
      ( cd "$OUTPUT_DIR" && sha256sum "$(basename "$sevenz_out")" >> "$(basename "$checksum_file")" )
    fi
    ;;
  *) ci_die "unsupported COMPRESS=$COMPRESS" ;;
esac

if [ "$COMPRESS" != none ] && [ "$KEEP_RAW_IMAGE" != 1 ]; then
  rm -f "$rootfs_img"
fi

ci_log "rootfs build complete: $OUTPUT_DIR"
