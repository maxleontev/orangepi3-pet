SUMMARY = "Authorized SSH key for root login on Orange Pi 3"
DESCRIPTION = "Installs /root/.ssh/authorized_keys so root can log in via \
Dropbear with a key. The matching private key stays in the recipe files/ \
directory for host clients and is not installed on the image."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "file://authorized_keys"

S = "${WORKDIR}"

FILES:${PN} = "${ROOT_HOME}/.ssh/authorized_keys"

do_install() {
    install -d -m 0700 ${D}${ROOT_HOME}/.ssh
    install -m 0600 ${WORKDIR}/authorized_keys ${D}${ROOT_HOME}/.ssh/authorized_keys
}

# read-only-rootfs + volatile-binds overlays /root; seed stays on the lowerdir.
pkg_postinst:${PN}() {
    #!/bin/sh
    if [ -z "$D" ]; then
        chmod 700 /root/.ssh 2>/dev/null || true
        chmod 600 /root/.ssh/authorized_keys 2>/dev/null || true
    fi
}
