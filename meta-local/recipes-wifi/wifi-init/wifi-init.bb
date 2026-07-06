SUMMARY = "WiFi auto-connect systemd service"
LICENSE = "CLOSED"

SRC_URI = " \
    file://wifi.service \
"

do_install() {
    # Устанавливаем systemd-юнит
    install -d ${D}${systemd_unitdir}/system
    install -m 0644 ${WORKDIR}/wifi.service ${D}${systemd_unitdir}/system/
}

# Наследуем systemd для автоматической обработки юнитов
inherit systemd

# Указываем, какой сервис мы предоставляем
SYSTEMD_SERVICE:${PN} = "wifi.service"

# Включаем сервис при старте (по умолчанию)
SYSTEMD_AUTO_ENABLE = "enable"
