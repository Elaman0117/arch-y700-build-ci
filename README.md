# Arch Linux ARM Y700 Build CI

GitHub Actions CI for building **Arch Linux ARM** (generic armv8) F2FS rootfs and GRUB/FAT boot images for the **Lenovo Legion Y700 2025 (TB321FU / Qualcomm SM8650)** tablet.

This is a re-implementation of the [Ubuntu Y700 Build CI](https://github.com/Elaman0117/Arch-Linux-ARM-for-Y700-2025) project, ported from Ubuntu/debootstrap to Arch Linux ARM, with the following architectural changes:

| Aspect | Original (Ubuntu) | This project (Arch) |
|--------|-------------------|---------------------|
| Base rootfs | `debootstrap noble` | `ArchLinuxARM-armv8-latest.tar.gz` |
| Root filesystem | ext4 | **F2FS** |
| Package manager | apt / dpkg | pacman |
| Kernel location | FAT partition only | **Dual**: rolling in F2FS + frozen fallback in FAT |
| Device packages | `.deb` | Stage directories (DKMS-ready source for haptics) |
| Initramfs | initramfs-tools (auto) | mkinitcpio (explicit F2FS + Qualcomm modules) |

## Workflow

Primary workflow: `.github/workflows/build-rootfs-and-grub.yml`

It has four dispatch inputs:

- `release_tag`: optional release tag to upload artifacts to.
- `output_prefix`: output filename prefix.
- `rootfs_config`: rootfs settings as `KEY=value` lines.
- `boot_config`: GRUB/FAT boot settings as `KEY=value` lines.
- `source_config`: input artifact URLs as `KEY=value` lines.

This avoids GitHub's workflow input count limit while still allowing all build-time parameters to be changed from the Actions UI or `gh workflow run`.

## Dual-Kernel Boot Strategy

This is the key architectural difference from the Ubuntu version. The device can always boot, even if `pacman -Syu` breaks the rolling kernel.

```
GPT disk:
├── Partition 1: ESP, FAT32, 512MB, partlabel=ESP, type=EF00
│   ├── /EFI/BOOT/BOOTAA64.EFI          # Standard UEFI entry
│   ├── /EFI/BOOT/QCOMRAMP.EFI          # Qualcomm RamPartition direct boot (rescue)
│   ├── /EFI/BOOT/grub.cfg              # Outer GRUB config
│   ├── /boot/grub/grub.cfg             # Same outer config, alternate path
│   ├── /dtb/sm8650-lenovo-tb321fu.dtb  # Device tree
│   ├── /vmlinuz-fallback               # Frozen kernel (build-time snapshot)
│   └── /initramfs-fallback.img         # Matching initramfs
│
└── Partition 2: Linux, F2FS, 20GB, partlabel=userdata, type=8300
    ├── /boot/vmlinuz-linux             # Rolling kernel (pacman -Syu upgrades)
    ├── /boot/initramfs-linux.img       # Matching initramfs
    ├── /boot/grub/grub.cfg             # Inner GRUB config (rewritten by pacman hook)
    └── (full Arch rootfs)
```

### Boot flow

1. UEFI firmware loads `BOOTAA64.EFI` from the FAT ESP.
2. GRUB reads the outer `grub.cfg` from FAT.
3. The outer config searches for both partitions by partlabel:
   - `search --partlabel --set=boot ESP` (FAT)
   - `search --partlabel --set=rootfs userdata` (F2FS)
4. If the F2FS rootfs has `/boot/grub/grub.cfg`, GRUB defers to it (inner config).
5. The inner config offers four menu entries:
   - **Arch Y700 daily** — rolling kernel from F2FS rootfs
   - **Arch Y700 verbose** — rolling kernel, verbose boot
   - **Arch Y700 fallback** — frozen kernel from FAT (rescue)
   - **Arch Y700 no-DRM SSH rescue** — frozen kernel, no DRM, for SSH debugging

### GRUB module requirements

The QCOMRAMP.EFI built by `y700-direct-grub.sh` now embeds these modules (updated from the original):

```
normal linux linuxdirect initrd fdt fat f2fs ext2 part_gpt
search search_fs_file search_partlabel search_fs_uuid
reboot halt sleep rampartition configfile ls cat echo test
```

Key additions vs. the original Ubuntu version:
- `f2fs` — read the F2FS rootfs partition
- `ext2` — fallback for ext4 (in case someone reverts to ext4)
- `search_partlabel`, `search_fs_uuid` — locate partitions by partlabel/UUID
- `configfile` — defer to the inner grub.cfg on F2FS
- `ls`, `cat`, `echo`, `test` — enable GRUB shell debugging and conditionals

## Rootfs Config

Example:

```text
ARCH=aarch64
ROOTFS_TARBALL_URL=http://os.archlinuxarm.org/os/ArchLinuxARM-armv8-latest.tar.gz
PACMAN_MIRROR=http://mirror.archlinuxarm.org
ARCH_LINUXARM_REPO=$repo/$arch
ROOTFS_IMAGE_SIZE=20G
ROOTFS_FSTYPE=f2fs
ROOTFS_F2FS_OPTIONS=-O extra_attr,inode_checksum,sb_checksum,compression
ROOTFS_UUID=
ROOTFS_LABEL=Y700ARCH
ROOTFS_PARTLABEL=userdata
HOSTNAME_NAME=y700
DEFAULT_USER_NAME=y700
DEFAULT_USER_PASSWORD=1234
ROOT_PASSWORD_MODE=locked
ROOT_PASSWORD=
USER_SUDO_MODE=password
TZ_REGION=Asia/Shanghai
LANG_NAME=zh_CN.UTF-8
LOCALES=en_US.UTF-8 UTF-8
PACKAGE_LIST=
DESKTOP_ENV=plasma-desktop sddm
OVERLAY_ARCHIVE=
PKG_ARCHIVE=
BUILD_Y700_SENSOR_STAGE=1
BUILD_TB321FU_HAPTICS_STAGE=1
BUILD_TB321FU_CAMERA_STACK=1
BUILD_TB321FU_GPU_SENSOR=1
INSTALL_GNOME_SNAPSHOT=1
APPLY_Y700_FIRMWARE_FIXES=1
APPLY_Y700_AUDIO_POLICY_FIXES=1
MKINITCPIO_PRESETS=default
MKINITCPIO_MODULES=f2fs ext4 qcom_qmp_phy qcom_snps_femto_v2
MKINITCPIO_HOOKS=base udev block autodetect keyboard keymap modconf filesystems fsck
CLEAN_PACMAN_CACHE=1
COMPRESS=7z
CHUNK_SIZE=1500m
KEEP_RAW_IMAGE=0
```

## Boot Config

Example:

```text
BOOT_IMAGE_SIZE=512M
BOOT_FAT_BITS=32
BOOT_FAT_LABEL=Y700GRUB
BOOT_SECTOR_SIZE=512
BOOT_CLUSTER_SECTORS=
BOOT_PARTLABEL=ESP
ROOT_SELECTOR=partlabel
ROOT_PARTLABEL=userdata
ROOT_UUID=
ROOTARGS=
ROOTARGS_EXTRA=
STABLEARGS=drm_client_lib.active=none
GRUB_TIMEOUT=3
INCLUDE_FALLBACK_KERNEL=1
FALLBACK_KERNEL_VERSION=
BOOT_COMPRESS=7z
BOOT_CHUNK_SIZE=1500m
KEEP_BOOT_IMAGE=0
```

## Source Config

Example:

```text
KERNEL_ARTIFACT_ARCHIVE=https://example.com/y700-kernel-artifacts.tar.gz
BOOTAA64_EFI_URL=https://example.com/BOOTAA64.EFI
QCOMRAMP_EFI_URL=https://example.com/QCOMRAMP-CONFIGFILE.EFI
QCOMRAMP_CFG_NAME=qcomramp.cfg
GRUB_BUILD_ARCHIVE=
DTB_NAME=sm8650-lenovo-tb321fu.dtb
```

## Scripts

- `scripts/ci/build-rootfs-image.sh`: builds an F2FS rootfs image from the Arch Linux ARM armv8 tarball plus declared stages/overlays.
- `scripts/ci/build-grub-image.sh`: builds a FAT boot image containing BOOTAA64.EFI, QCOMRAMP.EFI, Image, DTB, fallback kernel+initramfs, and the dual-kernel GRUB config.
- `scripts/ci/build-y700-sensor-stage.sh`: stages the source-built Qualcomm SSC sensor stack (libssc, hexagonrpc, iio-sensor-proxy, tb321fu-sensors data).
- `scripts/ci/build-tb321fu-haptics-stage.sh`: stages the AW86937 haptics kernel module + bind script + systemd unit + DKMS source.
- `scripts/ci/build-tb321fu-camera-stack-stage.sh`: stages the live-verified TB321FU camera stack from `source/tb321fu-camera-rootfs-overlay`.
- `scripts/ci/pack-disk-image.sh`: optional GPT disk image packer for a FAT boot image plus F2FS rootfs image.
- `scripts/ci/apply-workflow-config.sh`: validates dispatch config blocks and exports allowed keys into the workflow environment.
- `scripts/lib/y700-direct-grub.sh`: shared GRUB helpers including the dual-kernel config writers.

## What is reused verbatim from the Ubuntu project

These components are **100% distro-agnostic** and were copied without changes:

- `scripts/lib/y700-direct-grub.sh` — Qualcomm RamPartition direct-boot GRUB logic (only the `--modules` list was extended to include `f2fs`).
- `source/tb321fu-camera-rootfs-overlay/` — the entire pre-built libcamera 0.7.1 app-chain, PipeWire SPA plugin, IPA tuning YAMLs, and the PipeWire/WirePlumber systemd drop-ins. libcamera binaries are not distro-specific.
- `source/tb321fu-ksystemstats-adreno-freq/` — the KDE Plasma Adreno GPU frequency monitor C++ source.
- The `bind-aw86937` shell script (inside `build-tb321fu-haptics-stage.sh`) — operates purely on `/sys/bus/i2c/`, distro-agnostic.
- The `qcom-sns-init` shell script (inside `build-y700-sensor-stage.sh`) — operates on `/dev/fastrpc-adsp` + `hexagonrpcd`, distro-agnostic.
- The Y700 firmware path fixes (`apply_y700_firmware_fixes`) — pure file copy operations.
- The Y700 WirePlumber ALSA policy fix (`apply_y700_audio_policy_fixes`) — WirePlumber config is distro-agnostic.
- The Plasma skeleton configs (`plasmakeyboardrc`, `kwinoutputconfig.json`) — KDE config format is distro-agnostic.

## What was rewritten for Arch

- `build-rootfs-image.sh`: replaced debootstrap with Arch Linux ARM tarball extraction, apt with pacman, ext4 with F2FS, initramfs-tools with mkinitcpio.
- `apply-workflow-config.sh`: replaced DEB_* keys with PKG_* / STAGE_* keys, added F2FS and mkinitcpio knobs.
- `build-*-stage.sh` (formerly `build-*-deb.sh`): replaced dpkg-deb packaging with stage directory trees.
- `build-grub-image.sh`: added dual-kernel FAT strategy, F2FS rootfs mounting for fallback kernel extraction, inner grub.cfg writing.
- The haptics stage now ships a DKMS source tree at `/usr/src/aw86937-haptics-$VERSION/` so the module survives `pacman -Syu linux-aarch64` upgrades on production systems.

## Policy Boundary

Same as the original Ubuntu project: the rootfs builder does not hardcode one historical verified Y700 state. Use `OVERLAY_ARCHIVE`, `PKG_ARCHIVE`, `SENSOR_SOURCE_ARCHIVE`, `HAPTICS_SOURCE_ARCHIVE`, `KERNEL_*_ARCHIVE`, and the source artifact inputs to select the device payload for each build.

## Local reproduction

```bash
# Clone
git clone https://github.com/<your-fork>/arch-y700-build-ci.git
cd arch-y700-build-ci

# On an aarch64 Linux host (or an x86 host with qemu-user-static):
sudo apt install f2fs-tools dosfstools mtools arch-install-scripts \
  meson ninja-build pkg-config protobuf-c-compiler gcc-aarch64-linux-gnu \
  libglib2.0-dev:arm64 libqmi-glib-dev:arm64 libgudev-1.0-dev:arm64 \
  libpolkit-gobject-1-dev:arm64 libprotobuf-c-dev:arm64

# Build the camera stack stage (uses repo source; no external inputs)
env OUTPUT_DIR=out/camera-stage bash scripts/ci/build-tb321fu-camera-stack-stage.sh

# Build the rootfs (requires kernel artifacts and DTB from elsewhere)
sudo env OUTPUT_DIR=out/ci-rootfs \
  ROOTFS_IMAGE_SIZE=20G \
  SENSOR_STAGE_DIR= \
  HAPTICS_STAGE_DIR= \
  CAMERA_STACK_STAGE_DIR=out/camera-stage \
  bash scripts/ci/build-rootfs-image.sh

# Build the GRUB boot image (extracts fallback kernel from the rootfs)
env OUTPUT_DIR=out/ci-grub \
  ROOTFS_IMAGE=out/ci-rootfs/arch-y700-armv8-rootfs.img \
  DTB_FILE=/path/to/sm8650-lenovo-tb321fu.dtb \
  Y700_GRUB_BUILD_DIR=/path/to/grub-build \
  bash scripts/ci/build-grub-image.sh

# Optionally pack into a single GPT image
bash scripts/ci/pack-disk-image.sh \
  out/ci-grub/arch-y700-armv8-grub-fat.img \
  out/ci-rootfs/arch-y700-armv8-rootfs.img \
  out/arch-y700-armv8-disk.img
```
