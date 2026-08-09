SUMMARY = "Fullscreen HDMI info panel (CPU temp/usage, memory, IP, WiFi) for Weston"
DESCRIPTION = "Wayland client that renders a real-time system dashboard on \
the HDMI output (CPU temperature and per-core usage, memory, IP, WiFi SSID). \
Weston composites via DRM/KMS using Mesa Lima (Mali-T720)."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = " \
    file://info-panel \
    file://info-panel.service \
"

S = "${WORKDIR}/info-panel"

DEPENDS = "wayland wayland-native wayland-protocols cairo"

inherit meson pkgconfig systemd features_check

REQUIRED_DISTRO_FEATURES = "wayland"

SYSTEMD_SERVICE:${PN} = "info-panel.service"
SYSTEMD_AUTO_ENABLE = "enable"

do_install:append() {
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/info-panel.service ${D}${systemd_system_unitdir}/
}

FILES:${PN} += "${systemd_system_unitdir}/info-panel.service"

RDEPENDS:${PN} += "weston-init liberation-fonts iw"
