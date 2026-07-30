# FIT packaging for the Khepri product image on orange-pi-3.
#
# These variables must live on the kernel recipe (not the image recipe):
# bitbake does not propagate image-recipe vars into virtual/kernel.
# IMAGE_BOOT_FILES is set in core-image-khepri.bb.

KERNEL_CLASSES:append:orange-pi-3 = " kernel-fitimage"
KERNEL_IMAGETYPES:append:orange-pi-3 = " fitImage"

# Small initramfs that mounts root= and switch_root's — NOT the live/installer
# image (core-image-minimal-initramfs), which mounts partitions R/W first and
# then fails with "Can't mount, would change RO state" when root is requested ro.
INITRAMFS_IMAGE:orange-pi-3 = "core-image-initramfs-boot"
INITRAMFS_IMAGE_BUNDLE:orange-pi-3 = "0"
