#!/bin/sh
# Configure AC200 onboard MIC1 capture path (Jernej mainline snd-soc-ac200).
# Defaults: ADC Volume 7, Master capture 62%, MIC1 Boost 4 (voice level without clip).
set -eu

CARD="${AC200_MIC_CARD:-0}"
MASTER_CAP="${AC200_MIC_MASTER_CAP:-62}"
MIC_BOOST="${AC200_MIC_BOOST:-4}"

usage() {
	cat <<EOF
Usage: ${0##*/}

Env:
  AC200_MIC_CARD       ALSA card index (default: 0)
  AC200_MIC_MASTER_CAP Master capture percent 0-100 (default: 62)
  AC200_MIC_BOOST      MIC1 Boost 0-7 (default: 4)
EOF
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
	usage
	exit 0
fi

if ! command -v amixer >/dev/null 2>&1; then
	echo "ac200-mic-setup: amixer not found" >&2
	exit 0
fi

i=0
while [ ! -d "/proc/asound/card${CARD}" ] && [ "$i" -lt 50 ]; do
	i=$((i + 1))
	sleep 0.2
done
[ -d "/proc/asound/card${CARD}" ] || {
	echo "ac200-mic-setup: card ${CARD} not found" >&2
	exit 0
}

# Full control names from snd-soc-ac200 (sset aliases are ambiguous).
amixer -c "$CARD" cset name='ADC Volume' 7 >/dev/null
amixer -c "$CARD" cset name='MIC1 Capture Switch' on,on >/dev/null
amixer -c "$CARD" cset name='MIC1 Playback Switch' off,off >/dev/null
amixer -c "$CARD" cset name='MIC2 Capture Switch' off,off >/dev/null
amixer -c "$CARD" cset name='I2S ADC Capture Switch' on,on >/dev/null
amixer -c "$CARD" cset name='I2S DAC Capture Switch' off,off >/dev/null
amixer -c "$CARD" cset name='Output Mixer Capture Switch' off,off >/dev/null
amixer -c "$CARD" cset name='Output Mixer Reverse Capture Switch' off,off >/dev/null
amixer -c "$CARD" sset 'MIC1 Boost' "$MIC_BOOST" >/dev/null
amixer -c "$CARD" sset Master "${MASTER_CAP}%" cap >/dev/null
