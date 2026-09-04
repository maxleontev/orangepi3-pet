SUMMARY = "Fullscreen HDMI info panel (CPU, memory, IP, WiFi) for Weston"
DESCRIPTION = "Wayland client that renders a real-time system dashboard on \
the HDMI output (CPU temperature and per-core usage, memory, IP, WiFi SSID) \
plus a live AC200 microphone spectrum (ALSA capture). \
Weston composites via DRM/KMS using Mesa Lima (Mali-T720)."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

# Shared hdmi-screenshot.sh (also used by info-panel-camera).
FILESEXTRAPATHS:prepend := "${THISDIR}/../files:"

SRC_URI = " \
    file://info-panel \
    file://info-panel.service \
    file://hdmi-screenshot.sh \
"

S = "${WORKDIR}/info-panel"

DEPENDS = "wayland wayland-native wayland-protocols cairo alsa-lib"

inherit meson pkgconfig systemd features_check

REQUIRED_DISTRO_FEATURES = "wayland"

SYSTEMD_SERVICE:${PN} = "info-panel.service"
SYSTEMD_AUTO_ENABLE = "enable"

do_install:append() {
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/info-panel.service ${D}${systemd_system_unitdir}/
    install -d ${D}${sbindir}
    install -m 0755 ${WORKDIR}/hdmi-screenshot.sh ${D}${sbindir}/hdmi-screenshot
}

FILES:${PN} += "${systemd_system_unitdir}/info-panel.service ${sbindir}/hdmi-screenshot"

RDEPENDS:${PN} += "weston-init liberation-fonts iw alsa-lib ac200-audio"
