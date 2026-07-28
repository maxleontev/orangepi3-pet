SUMMARY = "Orange Pi 3 image with WiFi and local user setup"
DESCRIPTION = "Console image based on core-image-base, plus AP6256 WiFi \
support, Midnight Commander, and a preconfigured local user."
LICENSE = "MIT"

IMAGE_FEATURES += "splash"

IMAGE_INSTALL:append = " fw-ap6256 wpa-supplicant iw wifi-init mc"

inherit core-image extrausers

EXTRA_USERS_PARAMS = " \
    useradd -d /home/max -m -s /bin/sh -p '\$5\$Uvx6JzQlgbPV\$LJMPCCUmmybpQOz/LAx5P5FzLC0NnkHqiTDZG1rtBL6' max; \
    groupadd -g 880 newgroup; \
    usermod -G newgroup max; \
"
