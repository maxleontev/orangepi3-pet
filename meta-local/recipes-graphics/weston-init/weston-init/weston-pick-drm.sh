#!/bin/sh
# Pick the DRM card that owns an HDMI connector (e.g. card0-HDMI-A-1 -> card0).
# Lives in /usr/libexec because systemd unit files treat "%%" as a single "%".
#
# Accept "connected" first; also accept "unknown" once /dev/dri/<card> exists —
# on H6 we have seen status=unknown after a deferred HDMI PHY bind even with
# a cable attached (EDID/hotplug race). Reject only "disconnected".
set -eu

pick() {
	want=$1
	for s in /sys/class/drm/card*-HDMI-A-*/status; do
		[ -f "$s" ] || continue
		st=$(cat "$s" 2>/dev/null || true)
		[ "$st" = "$want" ] || continue
		b=$(basename "$(dirname "$s")")
		card=$(printf '%s\n' "$b" | cut -d- -f1)
		[ -n "$card" ] || continue
		[ -e "/dev/dri/$card" ] || continue
		printf '%s\n' "$card" > /run/weston-drm-device
		echo "weston-pick-drm: using $card (HDMI status=$st)" >&2
		exit 0
	done
}

i=0
while [ "$i" -lt 60 ]; do
	pick connected
	pick unknown
	i=$((i + 1))
	sleep 1
done

echo "weston-pick-drm: HDMI DRM connector not ready" >&2
ls -l /dev/dri 2>&1 || true
ls /sys/class/drm 2>&1 || true
exit 1
