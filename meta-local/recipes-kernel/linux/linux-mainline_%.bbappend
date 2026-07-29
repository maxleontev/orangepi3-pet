# FIT packaging for the Khepri product image on orange-pi-3.
#
# These variables must live on the kernel recipe (not the image recipe):
# bitbake does not propagate image-recipe vars into virtual/kernel.
# IMAGE_BOOT_FILES = "fitImage boot.scr" is set in core-image-khepri.bb.

KERNEL_CLASSES:append:orange-pi-3 = " kernel-fitimage"
KERNEL_IMAGETYPES:append:orange-pi-3 = " fitImage"

# Minimal initramfs embedded in the FIT as a separate ramdisk section.
INITRAMFS_IMAGE:orange-pi-3 = "core-image-minimal-initramfs"
INITRAMFS_IMAGE_BUNDLE:orange-pi-3 = "0"
