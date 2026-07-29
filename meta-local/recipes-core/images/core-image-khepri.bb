SUMMARY = "Khepri image for Orange Pi 3 with WiFi and local user setup"
DESCRIPTION = "Console image based on core-image-base, plus AP6256 WiFi \
support, Midnight Commander, and a preconfigured local user. Boots via a \
FIT image (kernel + DTB + minimal initramfs)."
LICENSE = "MIT"

IMAGE_FEATURES += "splash"

IMAGE_INSTALL:append = " fw-ap6256 wpa-supplicant iw wifi-init mc"

# Must match INITRAMFS_IMAGE in linux-mainline bbappend (kernel recipe scope).
# Deployed FIT with ramdisk is named fitImage-${INITRAMFS_IMAGE_NAME}-${MACHINE};
# copy it to the boot partition as plain "fitImage" for boot.scr.
INITRAMFS_IMAGE ?= "core-image-minimal-initramfs"
IMAGE_BOOT_FILES = "fitImage-${INITRAMFS_IMAGE_NAME}-${MACHINE};fitImage boot.scr"

inherit core-image extrausers

EXTRA_USERS_PARAMS = " \
    useradd -d /home/max -m -s /bin/sh -p '\$5\$Uvx6JzQlgbPV\$LJMPCCUmmybpQOz/LAx5P5FzLC0NnkHqiTDZG1rtBL6' max; \
    groupadd -g 880 newgroup; \
    usermod -G newgroup max; \
"
