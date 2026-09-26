SUMMARY = "Fullscreen HDMI camera + servo track panel for Weston"
DESCRIPTION = "Wayland client for redesigned object-follow: USB UVC preview \
and pan-servo control. Selected into core-image-khepri when \
INFO_PANEL = \"track\" in local.conf. \
Weston composites via DRM/KMS using Mesa Lima (Mali-T720)."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

# Shared screenshot helper + UVC/PWM setup files from the camera recipe.
FILESEXTRAPATHS:prepend := "${THISDIR}/../files:${THISDIR}/../info-panel-camera/files:"

SRC_URI = " \
    file://info-panel-track \
    file://info-panel-track.service \
    file://hdmi-screenshot.sh \
    file://99-uvc-video.rules \
    file://usb-autosuspend.conf \
    file://uvcvideo.conf \
"

S = "${WORKDIR}/info-panel-track"

DEPENDS = "wayland wayland-native wayland-protocols cairo jpeg"

inherit meson pkgconfig systemd features_check

REQUIRED_DISTRO_FEATURES = "wayland"

SYSTEMD_SERVICE:${PN} = "info-panel-track.service"
SYSTEMD_AUTO_ENABLE = "enable"

do_install:append() {
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/info-panel-track.service ${D}${systemd_system_unitdir}/
    install -d ${D}${sbindir}
    install -m 0755 ${WORKDIR}/hdmi-screenshot.sh ${D}${sbindir}/hdmi-screenshot
    install -d ${D}${sysconfdir}/udev/rules.d
    install -m 0644 ${WORKDIR}/99-uvc-video.rules ${D}${sysconfdir}/udev/rules.d/
    install -d ${D}${sysconfdir}/modprobe.d
    install -m 0644 ${WORKDIR}/usb-autosuspend.conf ${D}${sysconfdir}/modprobe.d/
    install -m 0644 ${WORKDIR}/uvcvideo.conf ${D}${sysconfdir}/modprobe.d/
}

FILES:${PN} += " \
    ${systemd_system_unitdir}/info-panel-track.service \
    ${sbindir}/hdmi-screenshot \
    ${sysconfdir}/udev/rules.d/99-uvc-video.rules \
    ${sysconfdir}/modprobe.d/usb-autosuspend.conf \
    ${sysconfdir}/modprobe.d/uvcvideo.conf \
"

RDEPENDS:${PN} += "weston-init liberation-fonts"
