#!/usr/bin/env bash

# Shared GRUB helpers for the daily direct-boot payload.
# shellcheck shell=bash

Y700_GRUB_BUILD_DIR=${Y700_GRUB_BUILD_DIR:-/home/guf296/tb321fu-current/grub2-ram-partition-ab/build-arm64-efi}
Y700_DIRECT_BOOT_EFI_NAME=${Y700_DIRECT_BOOT_EFI_NAME:-QCOMRAMP.EFI}
Y700_DIRECT_BOOT_RESERVED_MEMORY=${Y700_DIRECT_BOOT_RESERVED_MEMORY:-"/reserved-memory/qdss@82800000 /reserved-memory/splash-region /reserved-memory/trust-ui-vm@f3800000 /reserved-memory/oem-vm@f7c00000"}

y700_write_direct_grub_cfg() {
        local cfg=$1
        local dtb_name=$2
        local rootargs=$3
        local stableargs=$4
        local reserved_line="qcomfdtmem disable-reserved"
        local path

        for path in $Y700_DIRECT_BOOT_RESERVED_MEMORY; do
                reserved_line="$reserved_line $path"
        done

        cat > "$cfg" <<EOF
set timeout=0
set default=0
set gfxpayload=keep

menuentry "Qualcomm direct boot (RamPartition memory)" {
    search --no-floppy --file /Image --set=root
    devicetree /dtb/$dtb_name
    qcomfdtmem source rampartition
    $reserved_line
    linuxdirect /Image $rootargs $stableargs
}
EOF
}

y700_write_outer_grub_cfg() {
        local cfg=$1
        local timeout=$2
        local direct_efi_name=$3

        cat > "$cfg" <<EOF
set timeout=$timeout
set default=0
set gfxpayload=keep

search --no-floppy --file /Image --set=root

menuentry "Continue boot" {
    search --no-floppy --file /Image --set=root
    chainloader /EFI/BOOT/$direct_efi_name
    boot
}

menuentry "Reboot" {
    reboot
}

menuentry "Power off" {
    halt
}
EOF
}

y700_build_direct_grub_efi() {
        local embedded_cfg=$1
        local out_efi=$2

        [ -x "$Y700_GRUB_BUILD_DIR/grub-mkstandalone" ] ||
                die "missing GRUB direct-boot build: $Y700_GRUB_BUILD_DIR/grub-mkstandalone"
        [ -d "$Y700_GRUB_BUILD_DIR/grub-core" ] ||
                die "missing GRUB module directory: $Y700_GRUB_BUILD_DIR/grub-core"

        "$Y700_GRUB_BUILD_DIR/grub-mkstandalone" \
                -d "$Y700_GRUB_BUILD_DIR/grub-core" \
                -O arm64-efi \
                -o "$out_efi" \
                --locales= \
                --fonts= \
                --themes= \
                --modules="normal linux linuxdirect initrd fdt fat f2fs ext2 part_gpt search search_fs_file search_partlabel search_fs_uuid reboot halt sleep rampartition configfile ls cat echo test" \
                "/boot/grub/grub.cfg=$embedded_cfg"
}

y700_stage_direct_grub_payload() {
        local out_dir=$1
        local dtb_name=$2
        local timeout=$3
        local rootargs=$4
        local stableargs=$5
        local direct_cfg="$out_dir/.QCOMRAMP-grub.cfg.tmp"
        local outer_cfg="$out_dir/grub.cfg"
        local direct_efi="$out_dir/$Y700_DIRECT_BOOT_EFI_NAME"

        y700_write_direct_grub_cfg "$direct_cfg" "$dtb_name" "$rootargs" "$stableargs"
        y700_build_direct_grub_efi "$direct_cfg" "$direct_efi"
        rm -f "$direct_cfg"
        y700_write_outer_grub_cfg "$outer_cfg" "$timeout" "$Y700_DIRECT_BOOT_EFI_NAME"
}

# Write an outer GRUB config that supports both FAT-resident fallback kernel
# and F2FS-resident rolling kernel. Used by build-grub-image.sh.
#
# Args: cfg_path  timeout  dtb_name  rootargs  stableargs  boot_partlabel  root_partlabel
y700_write_dual_kernel_grub_cfg() {
        local cfg=$1
        local timeout=$2
        local dtb_name=$3
        local rootargs=$4
        local stableargs=$5
        local boot_partlabel=$6
        local root_partlabel=$7

        cat > "$cfg" <<EOF
set timeout=$timeout
set default=0
set gfxpayload=keep

# Locate the FAT boot partition (carries DTB + frozen fallback kernel)
search --no-floppy --partlabel --set=boot $boot_partlabel
# Locate the F2FS rootfs partition (carries the rolling kernel + inner grub.cfg)
search --no-floppy --partlabel --set=rootfs $root_partlabel

set rootargs="$rootargs"
set stableargs="$stableargs"

# If the rootfs ships its own grub.cfg, defer to it. This lets the rolling
# kernel's pacman hook rewrite /boot/grub/grub.cfg without touching FAT.
if [ -f "(\$rootfs)/boot/grub/grub.cfg" ]; then
    configfile (\$rootfs)/boot/grub/grub.cfg
fi

# Otherwise fall back to the frozen kernel shipped in the FAT image itself.
menuentry "Arch Y700 fallback (frozen kernel)" {
    set root=(\$boot)
    devicetree /dtb/$dtb_name
    linux /vmlinuz-fallback \${rootargs} \${stableargs} -- quiet splash
    initrd /initramfs-fallback.img
}

menuentry "Arch Y700 fallback verbose" {
    set root=(\$boot)
    devicetree /dtb/$dtb_name
    linux /vmlinuz-fallback \${rootargs} \${stableargs} -- printk.time=1 loglevel=6 systemd.show_status=1
    initrd /initramfs-fallback.img
}

menuentry "Arch Y700 no-DRM SSH rescue (frozen kernel)" {
    set root=(\$boot)
    devicetree /dtb/$dtb_name
    linux /vmlinuz-fallback video=efifb:off panic=10 efi=novamap \${rootargs} \${stableargs} -- ignore_loglevel loglevel=8 printk.time=1 systemd.show_status=1
    initrd /initramfs-fallback.img
}

menuentry "Reboot" {
    reboot
}

menuentry "Power off" {
    halt
}
EOF
}

# Write the inner grub.cfg that lives on the F2FS rootfs. This is the file
# pacman hooks will rewrite whenever linux-aarch64 is upgraded.
#
# Args: cfg_path  dtb_name  rootargs  stableargs  boot_partlabel
y700_write_inner_grub_cfg() {
        local cfg=$1
        local dtb_name=$2
        local rootargs=$3
        local stableargs=$4
        local boot_partlabel=$5

        cat > "$cfg" <<EOF
set timeout=3
set default=0
set gfxpayload=keep

search --no-floppy --partlabel --set=boot $boot_partlabel

set rootargs="$rootargs"
set stableargs="$stableargs"

menuentry "Arch Y700 daily (rolling kernel)" {
    devicetree (\$boot)/dtb/$dtb_name
    linux /boot/vmlinuz-linux \${rootargs} \${stableargs} -- quiet splash
    initrd /boot/initramfs-linux.img
}

menuentry "Arch Y700 verbose" {
    devicetree (\$boot)/dtb/$dtb_name
    linux /boot/vmlinuz-linux \${rootargs} \${stableargs} -- printk.time=1 loglevel=6 systemd.show_status=1
    initrd /boot/initramfs-linux.img
}

menuentry "Arch Y700 fallback (frozen kernel from FAT)" {
    set root=(\$boot)
    devicetree /dtb/$dtb_name
    linux /vmlinuz-fallback \${rootargs} \${stableargs} -- quiet splash
    initrd /initramfs-fallback.img
}

menuentry "Arch Y700 no-DRM SSH rescue (frozen kernel)" {
    set root=(\$boot)
    devicetree /dtb/$dtb_name
    linux /vmlinuz-fallback video=efifb:off panic=10 efi=novamap \${rootargs} \${stableargs} -- ignore_loglevel loglevel=8 printk.time=1 systemd.show_status=1
    initrd /initramfs-fallback.img
}
EOF
}
