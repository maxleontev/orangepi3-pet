SUMMARY = "Blacklist HDMI/DRM modules so WiFi can associate on Orange Pi 3"
DESCRIPTION = "Prevents udev from autoloading sun4i-drm/lima at boot. \
HDMI RF coexistence with AP6256 otherwise drops the 2.4 GHz link after \
an initially successful association."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "file://blacklist-display-wifi.conf"

do_install() {
    install -d ${D}${sysconfdir}/modprobe.d
    install -m 0644 ${WORKDIR}/blacklist-display-wifi.conf \
        ${D}${sysconfdir}/modprobe.d/blacklist-display-wifi.conf
}

FILES:${PN} = "${sysconfdir}/modprobe.d/blacklist-display-wifi.conf"
