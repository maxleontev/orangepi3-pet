SUMMARY = "Firmware for AP6256 WiFi/Bluetooth module"
LICENSE = "CLOSED"

# Откуда брать файлы
SRC_URI = " \
    file://brcmfmac43456-sdio.bin \
    file://brcmfmac43456-sdio.txt \
"

# Куда устанавливать
do_install() {
    install -d ${D}${base_libdir}/firmware/brcm
    install -m 0644 ${WORKDIR}/brcmfmac43456-sdio.bin ${D}${base_libdir}/firmware/brcm/
    install -m 0644 ${WORKDIR}/brcmfmac43456-sdio.txt ${D}${base_libdir}/firmware/brcm/
    ln -sf brcmfmac43456-sdio.bin ${D}${base_libdir}/firmware/brcm/brcmfmac43456-sdio.xunlong,orangepi-3-lts.bin
}

FILES:${PN} = "${base_libdir}/firmware/brcm/*"