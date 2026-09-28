#!/bin/sh
# Ask the running info-panel-track to pan edge↔edge ×3, then park at center
# (same sequence as the post-video boot sweep). Safe anytime while the panel
# is up: SIGUSR2 pauses motion follow until the sweep finishes.
#
# Usage: servo-pan-sweep
# Env:   TIMEOUT_SEC=45
set -eu

STATUS_PATH="${STATUS_PATH:-/tmp/info-panel-track.sweep}"
TIMEOUT_SEC="${TIMEOUT_SEC:-45}"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf '%s\n' "$*"; }

usage() {
	cat <<'EOF'
Usage: servo-pan-sweep

  Signal info-panel-track (SIGUSR2) to run a full pan sweep:
  home to one edge, edge↔edge three times, then center. Motion
  detect / follow resume when the sweep status file is idle.

Environment:
  TIMEOUT_SEC=45
  STATUS_PATH=/tmp/info-panel-track.sweep
EOF
}

case "${1:-}" in
-h|--help)
	usage
	exit 0
	;;
esac

pid=$(pidof info-panel-track 2>/dev/null) || die "info-panel-track not running"
[ -n "$pid" ] || die "info-panel-track not running"

log "==> SIGUSR2 → info-panel-track pid=$pid (edge↔edge ×3 → center)"
kill -USR2 "$pid" || die "kill -USR2 failed"

# Wait for running → idle (or timeout).
deadline=$(( $(date +%s) + TIMEOUT_SEC ))
seen_busy=0
while [ "$(date +%s)" -lt "$deadline" ]; do
	st=missing
	if [ -r "$STATUS_PATH" ]; then
		st=$(head -n 1 "$STATUS_PATH" 2>/dev/null || echo missing)
		st=$(printf '%s' "$st" | tr -d '\r')
	fi
	case "$st" in
	idle)
		if [ "$seen_busy" -eq 1 ]; then
			log "RESULT: PASS (sweep idle)"
			exit 0
		fi
		;;
	running|home|center|wait)
		seen_busy=1
		;;
	sweep*)
		seen_busy=1
		;;
	esac
	sleep 1
done

die "timeout after ${TIMEOUT_SEC}s (last status=${st:-?}, seen_busy=$seen_busy)"
