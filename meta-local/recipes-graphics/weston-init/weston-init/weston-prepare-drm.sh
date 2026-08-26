#!/bin/sh
# Load Orange Pi 3 display stack that is blacklisted at boot (WiFi-first),
# wait for the DRM device node, then pick the HDMI KMS card for Weston.
#
# Why a helper (not bare "modprobe sun4i-drm"):
# - weston.service runs as User=weston; module load /dev setup must be root ("+").
# - blacklist-display-wifi.conf blocks udev autoload of sun8i_drm_hdmi and
#   friends; loading only sun4i-drm is not enough for an HDMI connector.
# - sun4i-drm probe is deferred ("Couldn't get the HDMI PHY" then bind) so
#   /dev/dri/card* may appear several seconds after modprobe returns.
# - display_connector must load BEFORE HDMI: it drives ddc-en (PH2). Without
#   that, EDID is empty and HDMI audio has no ELD / stays silent.
# - dw_hdmi_i2s_audio is blacklisted at boot; load it with DRM for ALSA
#   card allwinner-hdmi (ac200-mic-hdmi-play / monitor speakers).
set -eu

modprobe display_connector || true

for m in sun4i-drm sun8i-mixer sun8i-drm-hdmi dw_hdmi_i2s_audio lima; do
	modprobe "$m" || true
done

i=0
while [ "$i" -lt 45 ]; do
	if [ -e /dev/dri/card0 ] || [ -e /dev/dri/card1 ]; then
		break
	fi
	i=$((i + 1))
	sleep 1
done

exec /usr/libexec/weston-pick-drm.sh
