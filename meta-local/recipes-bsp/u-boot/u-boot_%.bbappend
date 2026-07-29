FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI:append = " file://0001-remove-allwinner-prefix-from-FDTFILE.patch"

SRC_URI:append = " file://0002-remove-allwinner-prefix-from-board.patch"

# Orange Pi 3 (non-LTS): override boot script with correct MMC device mapping.
# On this board Linux MMC numbering differs from U-Boot:
#   U-Boot mmc0 (SD) -> Linux mmcblk2
#   U-Boot mmc1 (eMMC) -> Linux mmcblk1
# Also switch to Image/booti (aarch64 — no zImage).
SRC_URI:append:orange-pi-3 = " file://boot-orangepi3.cmd"

do_compile:append:orange-pi-3() {
    ${B}/tools/mkimage -C none -A arm64 -T script \
        -d ${WORKDIR}/boot-orangepi3.cmd \
        ${WORKDIR}/${UBOOT_ENV_BINARY}
}
