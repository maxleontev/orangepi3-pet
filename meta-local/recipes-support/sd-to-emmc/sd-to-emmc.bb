SUMMARY = "Clone SD system image onto onboard eMMC"
DESCRIPTION = "Installs sd-to-emmc, a helper that copies the Orange Pi 3 GPT \
layout (SPL @ 128 KiB, boot/rootfs_a/rootfs_b/data) from the SD card to eMMC \
and optionally grows the F2FS data partition."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "file://sd-to-emmc.sh"

S = "${WORKDIR}"

RDEPENDS:${PN} = " \
    util-linux-blockdev \
    util-linux-findmnt \
    util-linux-lsblk \
    util-linux-partx \
    parted \
    gptfdisk \
    f2fs-tools \
"

do_install() {
    install -d ${D}${sbindir}
    install -m 0755 ${WORKDIR}/sd-to-emmc.sh ${D}${sbindir}/sd-to-emmc
}
