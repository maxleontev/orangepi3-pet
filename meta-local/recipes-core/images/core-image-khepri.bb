SUMMARY = "Khepri image for Orange Pi 3 with WiFi and local user setup"
DESCRIPTION = "Console image based on core-image-base, plus AP6256 WiFi \
support, Midnight Commander, and a preconfigured local user. Boots via a \
FIT image (kernel + DTB + minimal initramfs)."
LICENSE = "MIT"

# read-only-rootfs: fstab/cmdline tweaks + dropbear key dir defaults (we
# override the key dir onto /data below so host keys survive reboot).
IMAGE_FEATURES += "splash read-only-rootfs"

IMAGE_INSTALL:append = " fw-ap6256 wpa-supplicant iw wifi-init mc"

# Must match INITRAMFS_IMAGE in linux-mainline bbappend (kernel recipe scope).
# Deployed FIT with ramdisk is named fitImage-${INITRAMFS_IMAGE_NAME}-${MACHINE};
# copy it to the boot partition as plain "fitImage" for boot.scr.
INITRAMFS_IMAGE ?= "core-image-initramfs-boot"
IMAGE_BOOT_FILES = "fitImage-${INITRAMFS_IMAGE_NAME}-${MACHINE};fitImage boot.scr"

inherit core-image extrausers

EXTRA_USERS_PARAMS = " \
    useradd -d /home/max -m -s /bin/sh -p '\$5\$Uvx6JzQlgbPV\$LJMPCCUmmybpQOz/LAx5P5FzLC0NnkHqiTDZG1rtBL6' max; \
    groupadd -g 880 newgroup; \
    usermod -G newgroup max; \
"

# GPT layout: /data is F2FS R/W (empty-f2fs WIC plugin; fstab owned here so
# mount options are correct — WIC has no --fstype=f2fs). Persist dropbear
# host keys and (via volatile-binds OverlayFS) /var/lib,/var/log there.
# Run after read_only_rootfs_hook (append, not +=) so fstab tweaks stick.
ROOTFS_POSTPROCESS_COMMAND:append = " khepri_gpt_rootfs_layout;"
khepri_gpt_rootfs_layout() {
    mkdir -p ${IMAGE_ROOTFS}/data
    if grep -q '^/dev/root' ${IMAGE_ROOTFS}/etc/fstab; then
        sed -i 's|^\(/dev/root[[:space:]]\+/[[:space:]]\+auto[[:space:]]\+\)[^[:space:]]*|\1ro,noatime|' \
            ${IMAGE_ROOTFS}/etc/fstab
    fi
    # WIC does not emit /data (non-/ mountpoint); install the real entry.
    sed -i '/[[:space:]]\/data[[:space:]]/d' ${IMAGE_ROOTFS}/etc/fstab
    printf 'LABEL=data\t/data\tf2fs\trelatime,discard\t0\t0\n' \
        >> ${IMAGE_ROOTFS}/etc/fstab

    # /var/log must be a real RO directory for data-var-log.service overlay.
    if [ -L ${IMAGE_ROOTFS}/var/log ]; then
        rm -f ${IMAGE_ROOTFS}/var/log
        mkdir -p ${IMAGE_ROOTFS}/var/log
    fi
    # Drop any tmpfiles rule that would recreate log -> volatile/log.
    if [ -f ${IMAGE_ROOTFS}/usr/lib/tmpfiles.d/00-create-volatile.conf ]; then
        sed -i '\|[[:space:]]/var/log[[:space:]].*volatile/log|d' \
            ${IMAGE_ROOTFS}/usr/lib/tmpfiles.d/00-create-volatile.conf
    fi

    if [ -f ${IMAGE_ROOTFS}/etc/default/dropbear ]; then
        sed -i '/^DROPBEAR_RSAKEY_DIR=/d' ${IMAGE_ROOTFS}/etc/default/dropbear
        echo 'DROPBEAR_RSAKEY_DIR=/data/dropbear' >> ${IMAGE_ROOTFS}/etc/default/dropbear
    fi
    mkdir -p ${IMAGE_ROOTFS}/etc/systemd/system/dropbearkey.service.d
    cat > ${IMAGE_ROOTFS}/etc/systemd/system/dropbearkey.service.d/data-keys.conf << 'EOF'
[Unit]
RequiresMountsFor=/data
EOF
}
