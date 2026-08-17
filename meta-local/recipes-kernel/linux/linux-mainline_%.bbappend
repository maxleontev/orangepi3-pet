# FIT packaging for the Khepri product image on orange-pi-3.
#
# These variables must live on the kernel recipe (not the image recipe):
# bitbake does not propagate image-recipe vars into virtual/kernel.
# IMAGE_BOOT_FILES is set in core-image-khepri.bb.

FILESEXTRAPATHS:prepend := "${THISDIR}/files:${THISDIR}/../../recipes-multimedia/ac200-audio/files:"

KERNEL_CLASSES:append:orange-pi-3 = " kernel-fitimage"
KERNEL_IMAGETYPES:append:orange-pi-3 = " fitImage"

# F2FS for the GPT data partition (LABEL=data).
SRC_URI:append:orange-pi-3 = " file://f2fs.cfg"

# Onboard analog microphone: kernel bits from recipe ac200-audio.
require recipes-multimedia/ac200-audio/ac200-audio-kernel.inc

# files/drm.cfg overrides meta-sunxi's fragment (same file://drm.cfg name)
# when MACHINEOVERRIDES includes use-mailine-graphics.

# Small initramfs that mounts root= and switch_root's — NOT the live/installer
# image (core-image-minimal-initramfs), which mounts partitions R/W first and
# then fails with "Can't mount, would change RO state" when root is requested ro.
INITRAMFS_IMAGE:orange-pi-3 = "core-image-initramfs-boot"
INITRAMFS_IMAGE_BUNDLE:orange-pi-3 = "0"
