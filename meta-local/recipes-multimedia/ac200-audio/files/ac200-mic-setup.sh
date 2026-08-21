#!/bin/sh
# Configure AC200 onboard MIC1 capture path (Jernej/Armbian snd-soc-ac200).
#
# The kernel driver leaves analog capture in a barely usable state. On Orange
# Pi 3 we hit all of the following until this script ran at boot:
#
#   * ADC Volume defaulted to ~3/7 — recordings were almost silent.
#     `amixer sset ADC 100%` changes a playback control, not this one.
#     Use:  amixer cset name='ADC Volume' 7
#
#   * Short sset names are ambiguous (`I2S ADC` matches several widgets).
#     Always cset the full control name from `amixer controls`.
#
#   * MIC1 Playback Switch must be off. Capture is:
#       MIC1 Capture Switch on, I2S ADC Capture Switch on,
#       MIC2 / I2S DAC / Output Mixer capture off.
#
#   * Master capture 85% + MIC1 Boost 4 rail-clipped (±32768, g440=0).
#     Voice without clip: Master cap 62%, ADC Volume 7. Boost defaults to 3
#     (was 4): onboard MIC1 also picks up ~50 Hz mains/rumble; Boost 3 keeps
#     speech usable while cutting that floor ~a few dB. Override with
#     AC200_MIC_BOOST if you need more sensitivity.
#
# Image must ship alsa-utils-amixer; BusyBox has no amixer.
set -eu

# Prefer the card name: index 0 exists in /proc/asound before amixer can use it.
CARD="${AC200_MIC_CARD:-ac200audio}"
MASTER_CAP="${AC200_MIC_MASTER_CAP:-62}"
MIC_BOOST="${AC200_MIC_BOOST:-3}"

usage() {
	cat <<EOF
Usage: ${0##*/}

Env:
  AC200_MIC_CARD       ALSA card name or index (default: ac200audio)
  AC200_MIC_MASTER_CAP Master capture percent 0-100 (default: 62)
  AC200_MIC_BOOST      MIC1 Boost 0-7 (default: 3)
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

# /proc/asound/card0 can appear before the mixer is usable ("Invalid card number").
i=0
while [ "$i" -lt 100 ]; do
	if amixer -c "$CARD" cget name='ADC Volume' >/dev/null 2>&1; then
		break
	fi
	i=$((i + 1))
	sleep 0.2
done
amixer -c "$CARD" cget name='ADC Volume' >/dev/null 2>&1 || {
	echo "ac200-mic-setup: card ${CARD} mixer not ready" >&2
	exit 1
}

# Full control names from snd-soc-ac200 (sset aliases are ambiguous).
# Order: analog ADC gain, MIC1 capture (not playback), I2S ADC to CPU, mute loops.
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
