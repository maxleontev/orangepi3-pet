#!/bin/bash
# SSH to the Orange Pi 3: record AC200 MIC1, play that WAV over HDMI.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)

TARGET="${TARGET:-root@192.168.3.71}"
SSH_KEY="${SSH_KEY:-$ROOT/meta-local/recipes-core/root-ssh-keys/files/id_ed25519}"
DURATION_SEC="${DURATION_SEC:-5}"
STOP_INFO_PANEL="${STOP_INFO_PANEL:-1}"
KEEP_WAV="${KEEP_WAV:-0}"

SSH_OPTS=(
	-i "$SSH_KEY"
	-o IdentitiesOnly=yes
	-o StrictHostKeyChecking=accept-new
	-o BatchMode=yes
	-o ConnectTimeout=10
	-o ServerAliveInterval=5
	-o ServerAliveCountMax=2
)
if [ -n "${SSH_BIND:-}" ]; then
	SSH_OPTS+=(-o "BindAddress=$SSH_BIND")
fi

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf '%s\n' "$*"; }

usage() {
	cat <<'EOF_USAGE'
Usage: run-ac200-mic-hdmi-play.sh

  On the board: record MIC1, then play the WAV over HDMI speakers.

Environment:
  TARGET=root@192.168.3.71
  SSH_KEY=meta-local/recipes-core/root-ssh-keys/files/id_ed25519
  SSH_BIND=192.168.3.6
  DURATION_SEC=5
  STOP_INFO_PANEL=1
  KEEP_WAV=0
EOF_USAGE
}

case "${1:-}" in
-h|--help)
	usage
	exit 0
	;;
esac

[ -f "$SSH_KEY" ] || die "SSH private key not found: $SSH_KEY"
command -v ssh >/dev/null || die "ssh not found"

# Record + playback wall time, plus slack for stop/start info-panel.
ssh_wait=$((DURATION_SEC * 2 + 60))
log "==> SSH $TARGET → ac200-mic-hdmi-play (record ${DURATION_SEC}s, then HDMI)"
set +e
ssh "${SSH_OPTS[@]}" -o "ServerAliveCountMax=$((ssh_wait / 5 + 2))" "$TARGET" \
	"command -v ac200-mic-hdmi-play >/dev/null || exit 127; \
	 DURATION_SEC=$DURATION_SEC STOP_INFO_PANEL=$STOP_INFO_PANEL \
	 KEEP_WAV=$KEEP_WAV ac200-mic-hdmi-play"
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
	[ "$rc" = "127" ] && die "ac200-mic-hdmi-play not found on target (rebuild/flash with ac200-audio)"
	die "ac200-mic-hdmi-play failed on $TARGET (exit $rc)"
fi
log "RESULT: PASS"
