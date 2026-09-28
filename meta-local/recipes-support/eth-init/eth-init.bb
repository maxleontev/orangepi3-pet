SUMMARY = "Onboard Ethernet bring-up (eth0 DHCP)"
LICENSE = "CLOSED"

SRC_URI = " \
    file://eth.service \
    file://eth-connect.sh \
"

inherit systemd

do_install() {
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/eth.service ${D}${systemd_system_unitdir}/

    install -d ${D}${sbindir}
    install -m 0755 ${WORKDIR}/eth-connect.sh ${D}${sbindir}/eth-connect
}

SYSTEMD_SERVICE:${PN} = "eth.service"
SYSTEMD_AUTO_ENABLE = "enable"

RDEPENDS:${PN} += "busybox"
