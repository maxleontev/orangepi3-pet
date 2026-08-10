SUMMARY = "Khepri image for Orange Pi 3 with WiFi and local user setup"
DESCRIPTION = "Image based on core-image-base, plus AP6256 WiFi, Midnight \
Commander, a preconfigured local user, and an HDMI Wayland/Weston info panel \
(CPU temperature, memory, IP) using Mesa Lima. Boots via a FIT image \
(kernel + DTB + minimal initramfs)."
LICENSE = "MIT"

# read-only-rootfs: fstab/cmdline tweaks + dropbear key dir defaults (we
# override the key dir onto /data below so host keys survive reboot).
IMAGE_FEATURES += "splash read-only-rootfs"

IMAGE_INSTALL:append = " fw-ap6256 wpa-supplicant iw wifi-init hostapd dnsmasq mc sd-to-emmc root-ssh-keys ab-update"
IMAGE_INSTALL:append = " weston weston-init info-panel kmscube display-rf-blacklist"


# Must match INITRAMFS_IMAGE in linux-mainline bbappend (kernel recipe scope).
# Deployed FIT with ramdisk is named fitImage-${INITRAMFS_IMAGE_NAME}-${MACHINE};
# install only as fitImage_a / fitImage_b (boot.scr selects by bootslot).
INITRAMFS_IMAGE ?= "core-image-initramfs-boot"
IMAGE_BOOT_FILES = "\
    fitImage-${INITRAMFS_IMAGE_NAME}-${MACHINE};fitImage_a \
    fitImage-${INITRAMFS_IMAGE_NAME}-${MACHINE};fitImage_b \
    boot.scr \
"

inherit core-image extrausers

# Root may SSH in with a key (allow-root-login); empty-password logins disabled.
# Dropbear -g (below) blocks root password auth over SSH. Console password for
# root matches user max (same crypt salt/hash).
IMAGE_FEATURES:remove = "empty-root-password allow-empty-password"
IMAGE_FEATURES += "allow-root-login"

KHEPRI_USER_PASSWD = "\$5\$Uvx6JzQlgbPV\$LJMPCCUmmybpQOz/LAx5P5FzLC0NnkHqiTDZG1rtBL6"

EXTRA_USERS_PARAMS = " \
    usermod -p '${KHEPRI_USER_PASSWD}' root; \
    useradd -d /home/max -m -s /bin/sh -p '${KHEPRI_USER_PASSWD}' max; \
    groupadd -g 880 newgroup; \
    usermod -G newgroup max; \
"

# GPT A/B layout: rootfs_a/rootfs_b (RO), shared boot (fitImage_a/b + uboot.env),
# /data F2FS R/W. Slot selected by U-Boot env bootslot; ab-update writes the
# inactive slot from a local rootfs.ext4+fitImage bundle; ab-confirm clears
# upgrade_available after a good boot (else U-Boot rolls back past bootlimit).
# Persist dropbear host keys and (via volatile-binds OverlayFS)
# /var/lib,/var/log,/home on /data.
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
    # /boot for uboot.env / fitImage_* (WIC may also add this).
    # LABEL=/PARTLABEL=boot are ambiguous when SD and eMMC both have the same
    # GPT layout; ab-update/ab-confirm remount boot from the live root disk.
    sed -i '/[[:space:]]\/boot[[:space:]]/d' ${IMAGE_ROOTFS}/etc/fstab
    printf 'LABEL=boot\t/boot\tvfat\tdefaults\t0\t0\n' \
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
        # allow-root-login clears -w; set -g so root SSH is key-only (no password).
        sed -i '/^DROPBEAR_EXTRA_ARGS=/d' ${IMAGE_ROOTFS}/etc/default/dropbear
        sed -i '/^# Disallow root/d' ${IMAGE_ROOTFS}/etc/default/dropbear
        printf 'DROPBEAR_EXTRA_ARGS="-g"\n' >> ${IMAGE_ROOTFS}/etc/default/dropbear
        sed -i '/^DROPBEAR_RSAKEY_DIR=/d' ${IMAGE_ROOTFS}/etc/default/dropbear
        echo 'DROPBEAR_RSAKEY_DIR=/data/dropbear' >> ${IMAGE_ROOTFS}/etc/default/dropbear
    fi
    mkdir -p ${IMAGE_ROOTFS}/etc/systemd/system/dropbearkey.service.d
    cat > ${IMAGE_ROOTFS}/etc/systemd/system/dropbearkey.service.d/data-keys.conf << 'EOF'
[Unit]
RequiresMountsFor=/data
EOF
    install -m 0600 ${THISDIR}/../../recipes-wifi/wifi-init/files/wifi.conf \
        ${IMAGE_ROOTFS}/data/wifi.conf
}
