#!/bin/sh
# Record onboard AC200 MIC1, then play the WAV over HDMI (monitor speakers).
#
# info-panel holds hw:ac200audio exclusively; by default this script stops
# it for the capture and starts it again after playback.
set -eu

DURATION_SEC="${DURATION_SEC:-5}"
CAPTURE_DEV="${CAPTURE_DEV:-hw:CARD=ac200audio,DEV=0}"
PLAYBACK_DEV="${PLAYBACK_DEV:-plughw:CARD=allwinnerhdmi,DEV=0}"
RATE_HZ="${RATE_HZ:-48000}"
CHANNELS="${CHANNELS:-2}"
WAV="${WAV:-}"
KEEP_WAV="${KEEP_WAV:-0}"
STOP_INFO_PANEL="${STOP_INFO_PANEL:-1}"

usage() {
	cat <<EOF_USAGE
Usage: ${0##*/}

  Record AC200 MIC1, then play that WAV on HDMI.

Env:
  DURATION_SEC      capture length in seconds (default: 5)
  CAPTURE_DEV       ALSA capture (default: hw:CARD=ac200audio,DEV=0)
  PLAYBACK_DEV      ALSA playback (default: plughw:CARD=allwinnerhdmi,DEV=0)
  RATE_HZ           sample rate (default: 48000)
  CHANNELS          channels (default: 2)
  WAV               WAV path (default: temp under /tmp)
  KEEP_WAV          1=keep WAV after play (default: 0; always keep if WAV= set)
  STOP_INFO_PANEL   1=stop info-panel around capture (default: 1)
EOF_USAGE
}

log() { printf '%s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
	usage
	exit 0
fi

command -v arecord >/dev/null || die "arecord not found"
command -v aplay >/dev/null || die "aplay not found"
grep -q ac200audio /proc/asound/cards 2>/dev/null || \
	die "ALSA card ac200audio missing (is ac200-mic-setup ok?)"
grep -q allwinnerhdmi /proc/asound/cards 2>/dev/null || \
	die "ALSA card allwinnerhdmi missing (is weston up / dw_hdmi_i2s_audio loaded?)"

case "$DURATION_SEC" in
''|*[!0-9]*) die "DURATION_SEC must be a positive integer" ;;
0) die "DURATION_SEC must be > 0" ;;
esac

TMPWAV=""
INFO_PANEL_WAS_ACTIVE=0

cleanup() {
	if [ "$INFO_PANEL_WAS_ACTIVE" = "1" ]; then
		systemctl start info-panel 2>/dev/null || true
		INFO_PANEL_WAS_ACTIVE=0
	fi
	if [ -n "$TMPWAV" ] && [ -f "$TMPWAV" ]; then
		rm -f "$TMPWAV"
	fi
}
trap cleanup EXIT

USER_WAV=0
if [ -n "$WAV" ]; then
	OUT="$WAV"
	USER_WAV=1
else
	TMP=$(mktemp /tmp/ac200-mic-hdmi.XXXXXX)
	OUT="${TMP}.wav"
	mv "$TMP" "$OUT"
	if [ "$KEEP_WAV" = "1" ]; then
		TMPWAV=""
	else
		TMPWAV="$OUT"
	fi
fi

if [ "$STOP_INFO_PANEL" = "1" ] && command -v systemctl >/dev/null; then
	if systemctl is-active --quiet info-panel 2>/dev/null; then
		log "==> stop info-panel (exclusive PCM)"
		systemctl stop info-panel
		INFO_PANEL_WAS_ACTIVE=1
		sleep 0.3
	fi
fi

log "==> arecord -D ${CAPTURE_DEV} -d ${DURATION_SEC}s → ${OUT}"
arecord -D "$CAPTURE_DEV" -f S16_LE -r "$RATE_HZ" -c "$CHANNELS" \
	-d "$DURATION_SEC" "$OUT" || die "arecord failed"

BYTES=$(wc -c < "$OUT" | tr -d ' ')
log "==> recorded ${BYTES} bytes"

log "==> aplay -D ${PLAYBACK_DEV} ${OUT}"
aplay -D "$PLAYBACK_DEV" "$OUT" || die "aplay failed"

if [ "$USER_WAV" = "1" ] || [ "$KEEP_WAV" = "1" ]; then
	log "==> done (kept ${OUT})"
else
	log "==> done"
fi
