# Kernel half of recipe ac200-audio: AC200 MFD + codec, H6/OPi3 DTS, audio.cfg.
# Required from linux-mainline_%.bbappend. Patches sit in this recipe's files/.
# Userspace mixer is ac200-audio.bb — do not duplicate mixer logic in the kernel.

SRC_URI:append:orange-pi-3 = " \
    file://audio.cfg \
    file://0001-mfd-Add-support-for-X-Powers-AC200.patch \
    file://0002-arm64-dts-sun50i-h6-add-AC200-analog-codec-nodes.patch \
    file://0003-arm64-dts-sun50i-h6-orangepi-3-enable-AC200-codec.patch \
    file://0004-ASoC-AC200-Initial-driver.patch \
    file://0005-arm64-dts-sun50i-h6-orangepi-3-enable-HDMI-audio.patch \
"
