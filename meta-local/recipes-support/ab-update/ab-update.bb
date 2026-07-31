SUMMARY = "Custom A/B rootfs+FIT update tools"
DESCRIPTION = "Installs ab-update (apply local rootfs.ext4+fitImage bundle to \
the inactive slot), ab-confirm (clear upgrade_available after a good boot), \
and fw_env.config for the FAT uboot.env on /boot."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = " \
    file://ab-update.sh \
    file://ab-confirm.sh \
    file://ab-fixenv.sh \
    file://ab-confirm.service \
    file://fw_env.config \
"

S = "${WORKDIR}"

inherit systemd

RDEPENDS:${PN} = " \
    libubootenv-bin \
    u-boot-default-env \
    util-linux-findmnt \
    util-linux-lsblk \
    util-linux-blockdev \
"

SYSTEMD_SERVICE:${PN} = "ab-confirm.service"

do_install() {
    install -d ${D}${sbindir}
    install -m 0755 ${WORKDIR}/ab-update.sh ${D}${sbindir}/ab-update
    install -m 0755 ${WORKDIR}/ab-confirm.sh ${D}${sbindir}/ab-confirm
    install -m 0755 ${WORKDIR}/ab-fixenv.sh ${D}${sbindir}/ab-fixenv

    install -d ${D}${sysconfdir}
    install -m 0644 ${WORKDIR}/fw_env.config ${D}${sysconfdir}/fw_env.config

    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/ab-confirm.service ${D}${systemd_system_unitdir}/ab-confirm.service
}

FILES:${PN} += "${systemd_system_unitdir}/ab-confirm.service"
