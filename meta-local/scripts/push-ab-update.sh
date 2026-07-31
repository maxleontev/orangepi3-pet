#!/bin/bash
# Build an A/B update bundle, copy it to the Orange Pi 3 over SSH, and run
# ab-update (which switches the inactive slot and reboots by default).
#
# Defaults match this project's root key and board address; override via env:
#   TARGET=root@192.168.3.71  SSH_KEY=...  REMOTE_DIR=/data/update
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)

TARGET="${TARGET:-root@192.168.3.71}"
SSH_KEY="${SSH_KEY:-$ROOT/meta-local/recipes-core/root-ssh-keys/files/id_ed25519}"
REMOTE_DIR="${REMOTE_DIR:-/data/update}"
BUNDLE_NAME="${BUNDLE_NAME:-khepri-ab-update.tar.gz}"

SSH_OPTS=(
	-i "$SSH_KEY"
	-o IdentitiesOnly=yes
	-o StrictHostKeyChecking=accept-new
	-o BatchMode=yes
	-o ConnectTimeout=15
)

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[ -f "$SSH_KEY" ] || die "SSH private key not found: $SSH_KEY"
command -v ssh >/dev/null || die "ssh not found"
command -v scp >/dev/null || die "scp not found"

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
BUNDLE="$STAGE/$BUNDLE_NAME"

echo "==> Building bundle"
"$SCRIPT_DIR/make-ab-update-bundle.sh" "$BUNDLE"
[ -f "$BUNDLE" ] || die "bundle was not created"

echo "==> Checking SSH to $TARGET"
ssh "${SSH_OPTS[@]}" "$TARGET" 'command -v ab-update >/dev/null' \
	|| die "ab-update not found on target (flash an image that includes ab-update)"

# Deploy newest scripts under /data (rootfs is often read-only until reflash).
AB_FILES="$ROOT/meta-local/recipes-support/ab-update/files"
TOOLS_DIR="$REMOTE_DIR/tools"
echo "==> Syncing ab-update tools to $TARGET:$TOOLS_DIR"
ssh "${SSH_OPTS[@]}" "$TARGET" "mkdir -p '$TOOLS_DIR'"
scp "${SSH_OPTS[@]}" \
	"$AB_FILES/ab-update.sh" "$TARGET:$TOOLS_DIR/ab-update"
scp "${SSH_OPTS[@]}" \
	"$AB_FILES/ab-confirm.sh" "$TARGET:$TOOLS_DIR/ab-confirm"
scp "${SSH_OPTS[@]}" \
	"$AB_FILES/ab-fixenv.sh" "$TARGET:$TOOLS_DIR/ab-fixenv"
ssh "${SSH_OPTS[@]}" "$TARGET" "chmod 755 '$TOOLS_DIR/ab-update' '$TOOLS_DIR/ab-confirm' '$TOOLS_DIR/ab-fixenv'"

echo "==> Uploading $(du -h "$BUNDLE" | cut -f1) to $TARGET:$REMOTE_DIR/"
ssh "${SSH_OPTS[@]}" "$TARGET" "mkdir -p '$REMOTE_DIR'"
scp "${SSH_OPTS[@]}" "$BUNDLE" "$TARGET:$REMOTE_DIR/$BUNDLE_NAME"

echo "==> Running ab-update (device will reboot)"
# Connection drop on reboot is expected — do not treat as failure.
set +e
ssh "${SSH_OPTS[@]}" "$TARGET" \
	"'$TOOLS_DIR/ab-update' --yes '$REMOTE_DIR/$BUNDLE_NAME'"
rc=$?
set -e

# 0 = success before reboot; 255 = SSH dropped when the board rebooted.
if [ "$rc" -eq 0 ] || [ "$rc" -eq 255 ]; then
	echo "==> Update triggered (ssh exit $rc). Board should reboot into the new slot."
	echo "    After boot, ab-confirm.service clears upgrade_available."
	exit 0
fi

die "ab-update via SSH failed (exit $rc)"
