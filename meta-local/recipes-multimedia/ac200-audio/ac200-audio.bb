SUMMARY = "Orange Pi 3 AC200 analog microphone (userspace)"
DESCRIPTION = "Boot-time mixer route for the onboard AC200 MIC1 plus ALSA \
tools (amixer, arecord, aplay) and ac200-mic-hdmi-play (MIC1 → HDMI). \
Kernel driver, DTS and audio.cfg live in ac200-audio-kernel.inc \
(included from linux-mainline). Driver defaults are too quiet or clip; \
see files/ac200-mic-setup.sh."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = " \
    file://ac200-mic-setup.sh \
    file://ac200-mic-setup.service \
    file://ac200-mic-hdmi-play.sh \
"

inherit systemd

SYSTEMD_SERVICE:${PN} = "ac200-mic-setup.service"
SYSTEMD_AUTO_ENABLE = "enable"

# Former package name from recipes-support/ac200-mic-setup.
RPROVIDES:${PN} += "ac200-mic-setup"

do_install() {
	install -d ${D}${sbindir} ${D}${systemd_system_unitdir}
	install -m 0755 ${WORKDIR}/ac200-mic-setup.sh ${D}${sbindir}/ac200-mic-setup.sh
	install -m 0755 ${WORKDIR}/ac200-mic-hdmi-play.sh ${D}${sbindir}/ac200-mic-hdmi-play
	install -m 0644 ${WORKDIR}/ac200-mic-setup.service ${D}${systemd_system_unitdir}/
}

FILES:${PN} += " \
    ${systemd_system_unitdir}/ac200-mic-setup.service \
    ${sbindir}/ac200-mic-hdmi-play \
"

# amixer is required by the boot script. arecord lives in alsa-utils-aplay
# (there is no alsa-utils-arecord package).
RDEPENDS:${PN} += "alsa-utils-amixer alsa-utils-aplay"
