SUMMARY = "WiFi auto-connect with setup AP fallback and web configuration"
LICENSE = "CLOSED"

SRC_URI = " \
    file://wifi.service \
    file://wifi-roam.service \
    file://wifi-connect.sh \
    file://wifi-roam.sh \
    file://wifi-ap-start.sh \
    file://wifi-ap-stop.sh \
    file://wifi-write-config.sh \
    file://wifi-scan.sh \
    file://wifi-test-connect.sh \
    file://wifi-conf-lib.sh \
    file://lighttpd.conf \
    file://www/index.html \
    file://www/cgi-bin/form-parse.sh \
    file://www/cgi-bin/save \
    file://www/cgi-bin/scan \
    file://www/cgi-bin/test \
    file://www/cgi-bin/test-status \
"

inherit systemd

do_install() {
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/wifi.service ${D}${systemd_system_unitdir}/
    install -m 0644 ${WORKDIR}/wifi-roam.service ${D}${systemd_system_unitdir}/

    install -d ${D}${sbindir}
    install -m 0755 ${WORKDIR}/wifi-connect.sh ${D}${sbindir}/wifi-connect
    install -m 0755 ${WORKDIR}/wifi-roam.sh ${D}${sbindir}/wifi-roam
    install -m 0755 ${WORKDIR}/wifi-ap-start.sh ${D}${sbindir}/wifi-ap-start
    install -m 0755 ${WORKDIR}/wifi-ap-stop.sh ${D}${sbindir}/wifi-ap-stop
    install -m 0755 ${WORKDIR}/wifi-write-config.sh ${D}${sbindir}/wifi-write-config
    install -m 0755 ${WORKDIR}/wifi-scan.sh ${D}${sbindir}/wifi-scan
    install -m 0755 ${WORKDIR}/wifi-test-connect.sh ${D}${sbindir}/wifi-test-connect

    install -d ${D}${datadir}/wifi-setup
    install -m 0644 ${WORKDIR}/wifi-conf-lib.sh ${D}${datadir}/wifi-setup/
    install -m 0644 ${WORKDIR}/lighttpd.conf ${D}${datadir}/wifi-setup/

    install -d ${D}${datadir}/wifi-setup/www/cgi-bin
    install -m 0644 ${WORKDIR}/www/index.html ${D}${datadir}/wifi-setup/www/
    install -m 0755 ${WORKDIR}/www/cgi-bin/form-parse.sh ${D}${datadir}/wifi-setup/www/cgi-bin/
    install -m 0755 ${WORKDIR}/www/cgi-bin/save ${D}${datadir}/wifi-setup/www/cgi-bin/
    install -m 0755 ${WORKDIR}/www/cgi-bin/scan ${D}${datadir}/wifi-setup/www/cgi-bin/
    install -m 0755 ${WORKDIR}/www/cgi-bin/test ${D}${datadir}/wifi-setup/www/cgi-bin/
    install -m 0755 ${WORKDIR}/www/cgi-bin/test-status ${D}${datadir}/wifi-setup/www/cgi-bin/
}

SYSTEMD_SERVICE:${PN} = "wifi.service wifi-roam.service"
SYSTEMD_AUTO_ENABLE = "enable"

RDEPENDS:${PN} += "wpa-supplicant iw hostapd dnsmasq lighttpd lighttpd-module-cgi"

FILES:${PN} += "${datadir}/wifi-setup"
