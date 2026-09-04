#!/bin/sh
# Capture the live HDMI info-panel frame (last committed wl_shm buffer) to PNG.
#
# Works with either info-panel (stats) or info-panel-camera: both dump to
# /tmp/info-panel-screenshot.png on SIGUSR1. This helper signals whichever
# is running, waits for the atomic rename, then copies to DEST or stdout.
set -eu

SHOT_PNG="/tmp/info-panel-screenshot.png"
SHOT_ERR="/tmp/info-panel-screenshot.err"
TIMEOUT_SEC="${TIMEOUT_SEC:-8}"

usage() {
	cat <<'EOF'
Usage: hdmi-screenshot [DEST]

  no DEST     write PNG to stdout (if stdout is a TTY, save to
              /tmp/hdmi-screenshot.png and print that path)
  DEST        write PNG to DEST (e.g. /data/hdmi.png)

Environment: TIMEOUT_SEC=8
EOF
}

log() { printf '%s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# Prefer camera if both somehow run; only one is in a given image.
# /proc/comm is 15 chars — "info-panel-camera" appears as "info-panel-came".
panel_pid() {
	pid=""
	name=""
	if command -v pidof >/dev/null 2>&1; then
		for n in info-panel-camera info-panel; do
			pid=$(pidof "$n" 2>/dev/null || true)
			pid=${pid%% *}
			if [ -n "$pid" ]; then
				name=$n
				break
			fi
		done
	fi
	if [ -z "$pid" ]; then
		for d in /proc/[0-9]*; do
			c=$(cat "$d/comm" 2>/dev/null || true)
			case "$c" in
			info-panel-came|info-panel-camera)
				name=info-panel-camera
				;;
			info-panel)
				name=info-panel
				;;
			*)
				continue
				;;
			esac
			pid=${d#/proc/}
			break
		done
	fi
	[ -n "$pid" ] || return 1
	printf '%s %s\n' "$pid" "$name"
}

DEST=""
TO_STDOUT=0
case "${1:-}" in
-h|--help)
	usage
	exit 0
	;;
"")
	if [ -t 1 ]; then
		DEST="${DEST_PATH:-/tmp/hdmi-screenshot.png}"
	else
		TO_STDOUT=1
	fi
	;;
*)
	DEST=$1
	;;
esac

info=$(panel_pid) || die "info-panel / info-panel-camera is not running"
pid=${info%% *}
panel=${info#* }

rm -f "$SHOT_PNG" "$SHOT_ERR" "${SHOT_PNG}.tmp"

kill -USR1 "$pid" || die "failed to signal $panel (pid $pid)"

i=0
while [ "$i" -lt "$TIMEOUT_SEC" ]; do
	if [ -f "$SHOT_ERR" ]; then
		die "$panel: $(cat "$SHOT_ERR")"
	fi
	if [ -f "$SHOT_PNG" ]; then
		break
	fi
	i=$((i + 1))
	sleep 1
done
[ -f "$SHOT_PNG" ] || die "timed out after ${TIMEOUT_SEC}s waiting for $SHOT_PNG"

if [ "$TO_STDOUT" = "1" ]; then
	cat "$SHOT_PNG"
	exit 0
fi

dir=$(dirname "$DEST")
[ -d "$dir" ] || die "directory does not exist: $dir"
cp -f "$SHOT_PNG" "$DEST" || die "failed to write $DEST"
if [ -t 1 ]; then
	printf '%s\n' "$DEST"
fi
