#!/bin/bash
# SSH to the Orange Pi 3 and run /usr/sbin/servo-pan-sweep (edge↔edge ×3 → center).
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)

TARGET="${TARGET:-root@192.168.3.73}"
SSH_KEY="${SSH_KEY:-$ROOT/meta-local/recipes-core/root-ssh-keys/files/id_ed25519}"
TIMEOUT_SEC="${TIMEOUT_SEC:-45}"

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
	cat <<'EOF'
Usage: run-servo-pan-sweep.sh

  On the board: signal info-panel-track to pan edge↔edge three times,
  then park the camera at center (same as the boot sweep).

Environment:
  TARGET=root@192.168.3.73
  SSH_KEY=meta-local/recipes-core/root-ssh-keys/files/id_ed25519
  SSH_BIND=192.168.3.6
  TIMEOUT_SEC=45
EOF
}

case "${1:-}" in
-h|--help)
	usage
	exit 0
	;;
esac

[ -f "$SSH_KEY" ] || die "SSH private key not found: $SSH_KEY"
command -v ssh >/dev/null || die "ssh not found"

ssh_wait=$((TIMEOUT_SEC + 30))
log "==> SSH $TARGET → servo-pan-sweep (timeout ${TIMEOUT_SEC}s)"
set +e
ssh "${SSH_OPTS[@]}" -o "ServerAliveCountMax=$((ssh_wait / 5 + 2))" "$TARGET" \
	"command -v servo-pan-sweep >/dev/null || exit 127; \
	 TIMEOUT_SEC=$TIMEOUT_SEC servo-pan-sweep"
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
	[ "$rc" = "127" ] && die "servo-pan-sweep not found on target (flash INFO_PANEL=track image)"
	die "servo-pan-sweep failed on $TARGET (exit $rc)"
fi
log "RESULT: PASS"
