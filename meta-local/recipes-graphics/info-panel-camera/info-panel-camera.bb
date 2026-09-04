SUMMARY = "Fullscreen HDMI USB camera panel for Weston"
DESCRIPTION = "Wayland client that shows a live USB UVC (Logitech etc.) \
preview on the HDMI output. Selected into core-image-khepri when \
INFO_PANEL = \"camera\" in local.conf. \
Weston composites via DRM/KMS using Mesa Lima (Mali-T720)."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

# Shared hdmi-screenshot.sh (also used by info-panel).
FILESEXTRAPATHS:prepend := "${THISDIR}/../files:"

SRC_URI = " \
    file://info-panel-camera \
    file://info-panel-camera.service \
    file://hdmi-screenshot.sh \
    file://99-uvc-video.rules \
    file://usb-autosuspend.conf \
    file://uvcvideo.conf \
"

S = "${WORKDIR}/info-panel-camera"

DEPENDS = "wayland wayland-native wayland-protocols cairo jpeg"

inherit meson pkgconfig systemd features_check

REQUIRED_DISTRO_FEATURES = "wayland"

SYSTEMD_SERVICE:${PN} = "info-panel-camera.service"
SYSTEMD_AUTO_ENABLE = "enable"

do_install:append() {
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/info-panel-camera.service ${D}${systemd_system_unitdir}/
    install -d ${D}${sbindir}
    install -m 0755 ${WORKDIR}/hdmi-screenshot.sh ${D}${sbindir}/hdmi-screenshot
    install -d ${D}${sysconfdir}/udev/rules.d
    install -m 0644 ${WORKDIR}/99-uvc-video.rules ${D}${sysconfdir}/udev/rules.d/
    install -d ${D}${sysconfdir}/modprobe.d
    install -m 0644 ${WORKDIR}/usb-autosuspend.conf ${D}${sysconfdir}/modprobe.d/
    install -m 0644 ${WORKDIR}/uvcvideo.conf ${D}${sysconfdir}/modprobe.d/
}

FILES:${PN} += " \
    ${systemd_system_unitdir}/info-panel-camera.service \
    ${sbindir}/hdmi-screenshot \
    ${sysconfdir}/udev/rules.d/99-uvc-video.rules \
    ${sysconfdir}/modprobe.d/usb-autosuspend.conf \
    ${sysconfdir}/modprobe.d/uvcvideo.conf \
"

RDEPENDS:${PN} += "weston-init liberation-fonts"
