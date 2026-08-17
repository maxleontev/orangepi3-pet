SUMMARY = "Boot-time AC200 onboard microphone mixer setup"
DESCRIPTION = "Runs amixer once at boot to unmute MIC1, set ADC Volume, \
and apply sane capture gain on the Orange Pi 3 AC200 codec."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = " \
    file://ac200-mic-setup.sh \
    file://ac200-mic-setup.service \
"

inherit systemd

SYSTEMD_SERVICE:${PN} = "ac200-mic-setup.service"
SYSTEMD_AUTO_ENABLE = "enable"

do_install() {
	install -d ${D}${sbindir} ${D}${systemd_system_unitdir}
	install -m 0755 ${WORKDIR}/ac200-mic-setup.sh ${D}${sbindir}/ac200-mic-setup.sh
	install -m 0644 ${WORKDIR}/ac200-mic-setup.service ${D}${systemd_system_unitdir}/
}

FILES:${PN} += "${systemd_system_unitdir}/ac200-mic-setup.service"

RDEPENDS:${PN} += "alsa-utils-amixer"
