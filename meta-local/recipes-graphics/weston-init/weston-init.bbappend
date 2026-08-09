# Override stock weston.ini + weston.service for Orange Pi 3 HDMI kiosk.
FILESEXTRAPATHS:prepend := "${THISDIR}/${PN}:"

SRC_URI:append = " \
    file://weston-pick-drm.sh \
    file://weston-prepare-drm.sh \
"

PACKAGECONFIG:append = " no-idle-timeout"

# Start after wifi.service (unit After=). DRM stays blacklisted until
# weston-prepare-drm modprobes so WiFi can associate first.
SYSTEMD_AUTO_ENABLE = "enable"

do_install:append() {
	install -d ${D}${libexecdir}
	install -m 0755 ${WORKDIR}/weston-pick-drm.sh ${D}${libexecdir}/weston-pick-drm.sh
	install -m 0755 ${WORKDIR}/weston-prepare-drm.sh ${D}${libexecdir}/weston-prepare-drm.sh
}

FILES:${PN} += "${libexecdir}/weston-pick-drm.sh ${libexecdir}/weston-prepare-drm.sh"
