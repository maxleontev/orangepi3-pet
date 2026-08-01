#!/bin/bash
# Build an A/B update bundle, copy it to the Orange Pi 3 over SSH, run
# ab-update, wait for reboot, and verify the new slot booted cleanly.
#
# Defaults match this project's root key and board address; override via env:
#   TARGET=root@192.168.3.71  SSH_KEY=...  REMOTE_DIR=/data/update
#   SSH_WAIT_SEC=300
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)

TARGET="${TARGET:-root@192.168.3.71}"
SSH_KEY="${SSH_KEY:-$ROOT/meta-local/recipes-core/root-ssh-keys/files/id_ed25519}"
REMOTE_DIR="${REMOTE_DIR:-/data/update}"
BUNDLE_NAME="${BUNDLE_NAME:-khepri-ab-update.tar.gz}"
SSH_WAIT_SEC="${SSH_WAIT_SEC:-300}"

SSH_OPTS=(
	-i "$SSH_KEY"
	-o IdentitiesOnly=yes
	-o StrictHostKeyChecking=accept-new
	-o BatchMode=yes
	-o ConnectTimeout=10
	-o ServerAliveInterval=5
	-o ServerAliveCountMax=2
)

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf '%s\n' "$*"; }

ssh_try() { ssh "${SSH_OPTS[@]}" "$TARGET" "$@"; }

active_slot() {
	ssh_try 'lsblk -no PARTLABEL "$(readlink -f "$(findmnt -n -o SOURCE /)")"'
}

wait_ssh_up() {
	local label=$1
	local start elapsed=0
	start=$(date +%s)
	log "==> Waiting for SSH ($label), max ${SSH_WAIT_SEC}s"
	while true; do
		elapsed=$(( $(date +%s) - start ))
		if [ "$elapsed" -ge "$SSH_WAIT_SEC" ]; then
			return 1
		fi
		if ssh_try 'test -r /etc/os-release' >/dev/null 2>&1; then
			log "==> SSH up after ${elapsed}s ($label)"
			return 0
		fi
		sleep 5
	done
}

[ -f "$SSH_KEY" ] || die "SSH private key not found: $SSH_KEY"
command -v ssh >/dev/null || die "ssh not found"
command -v scp >/dev/null || die "scp not found"

# Drop stale host key (common after reflash; harmless otherwise).
host=${TARGET#*@}
ssh-keygen -f "${HOME}/.ssh/known_hosts" -R "$host" >/dev/null 2>&1 || true

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
BUNDLE="$STAGE/$BUNDLE_NAME"

log "==> Building bundle"
"$SCRIPT_DIR/make-ab-update-bundle.sh" "$BUNDLE"
[ -f "$BUNDLE" ] || die "bundle was not created"

log "==> Checking SSH to $TARGET"
ssh_try 'command -v ab-update >/dev/null' \
	|| die "ab-update not found on target (flash an image that includes ab-update)"

BEFORE=$(active_slot)
log "==> Active slot before update: $BEFORE"

log "==> Uploading $(du -h "$BUNDLE" | cut -f1) to $TARGET:$REMOTE_DIR/"
ssh_try "mkdir -p '$REMOTE_DIR'"
scp "${SSH_OPTS[@]}" "$BUNDLE" "$TARGET:$REMOTE_DIR/$BUNDLE_NAME"

log "==> Running ab-update (device will reboot)"
set +e
out=$(ssh_try "ab-update --yes '$REMOTE_DIR/$BUNDLE_NAME'" 2>&1)
rc=$?
set -e
printf '%s\n' "$out"

# 0 = finished before reboot; 255 = SSH dropped when the board rebooted.
if [ "$rc" -ne 0 ] && [ "$rc" -ne 255 ]; then
	die "ab-update via SSH failed (exit $rc)"
fi
log "==> ab-update triggered (ssh exit $rc)"

if ! wait_ssh_up after-update; then
	log "###### RESULT: FAIL (SSH unreachable) ######"
	log "Board did not come back over SSH within ${SSH_WAIT_SEC}s after update."
	log "Before slot was: $BEFORE — cannot verify whether the new slot booted."
	exit 2
fi

AFTER=$(active_slot)
ua=$(ssh_try 'fw_printenv -n upgrade_available' 2>/dev/null || echo NONE)
bc=$(ssh_try 'fw_printenv -n bootcount' 2>/dev/null || echo NONE)
bs=$(ssh_try 'fw_printenv -n bootslot' 2>/dev/null || echo NONE)

log "==> After reboot: PARTLABEL=$AFTER bootslot=$bs upgrade_available=$ua bootcount=$bc"

OK=1
if [ "$AFTER" = "$BEFORE" ]; then
	log "FAIL: slot did not switch (still $AFTER)"
	OK=0
fi
if [ "$ua" != "0" ] || [ "$bc" != "0" ]; then
	log "FAIL: expected upgrade_available=0 bootcount=0 (ab-confirm), got ua=$ua bc=$bc"
	OK=0
fi
if ! ssh_try 'test -r /etc/os-release' >/dev/null 2>&1; then
	log "FAIL: /etc/os-release not readable"
	OK=0
fi

if [ "$OK" -eq 1 ]; then
	log "###### RESULT: PASS ######"
	log "Update OK: $BEFORE -> $AFTER (bootslot=$bs, confirmed)."
	exit 0
fi

log "###### RESULT: FAIL (verification didn't pass) ######"
log "Board is reachable over SSH, but update checks failed (see FAIL lines above)."
exit 1
