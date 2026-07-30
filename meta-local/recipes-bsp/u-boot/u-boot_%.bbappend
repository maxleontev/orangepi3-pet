FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI:append = " file://0001-remove-allwinner-prefix-from-FDTFILE.patch"

SRC_URI:append = " file://0002-remove-allwinner-prefix-from-board.patch"

# Orange Pi 3 (non-LTS): GPT-friendly SPL@128K sector fix, FIT support,
# and boot script resolving partitions by GPT name.
SRC_URI:append:orange-pi-3 = " \
    file://0004-enable-fit-orangepi3-defconfig.patch \
    file://0005-sunxi-always-high-spl-uboot-sector.patch \
    file://boot-orangepi3.cmd \
"

do_compile:append:orange-pi-3() {
    ${B}/tools/mkimage -C none -A arm64 -T script \
        -d ${WORKDIR}/boot-orangepi3.cmd \
        ${WORKDIR}/${UBOOT_ENV_BINARY}
}
