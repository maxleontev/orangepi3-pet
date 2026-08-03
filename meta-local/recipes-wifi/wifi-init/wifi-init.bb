SUMMARY = "WiFi auto-connect systemd service"
LICENSE = "CLOSED"

SRC_URI = " \
    file://wifi.service \
    file://wifi-roam.service \
    file://wifi-connect.sh \
    file://wifi-roam.sh \
"

inherit systemd

do_install() {
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/wifi.service ${D}${systemd_system_unitdir}/
    install -m 0644 ${WORKDIR}/wifi-roam.service ${D}${systemd_system_unitdir}/

    install -d ${D}${sbindir}
    install -m 0755 ${WORKDIR}/wifi-connect.sh ${D}${sbindir}/wifi-connect
    install -m 0755 ${WORKDIR}/wifi-roam.sh ${D}${sbindir}/wifi-roam
}

SYSTEMD_SERVICE:${PN} = "wifi.service wifi-roam.service"
SYSTEMD_AUTO_ENABLE = "enable"

RDEPENDS:${PN} += "wpa-supplicant iw"
