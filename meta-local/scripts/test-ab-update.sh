#!/bin/bash
# End-to-end A/B update verification against a live Orange Pi 3 over SSH.
#
# 1) Apply a good bundle → expect slot switch + ab-confirm
# 2) Apply a bad-rootfs bundle (valid FIT, corrupt rootfs) → expect rollback
# 3) Apply a bad-FIT bundle (valid rootfs, corrupt FIT) → expect rollback
#    (boot.scr must reset on bootm failure while upgrade_available=1)
#
# SSH wait after each reboot is capped (default 300s).
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)

TARGET="${TARGET:-root@192.168.3.71}"
SSH_KEY="${SSH_KEY:-$ROOT/meta-local/recipes-core/root-ssh-keys/files/id_ed25519}"
REMOTE_DIR="${REMOTE_DIR:-/data/update}"
DEPLOY="${DEPLOY:-$ROOT/build-orangepi3/tmp/deploy/images/orange-pi-3}"
SSH_WAIT_SEC="${SSH_WAIT_SEC:-300}"
SKIP_GOOD="${SKIP_GOOD:-0}"
SKIP_BAD_ROOTFS="${SKIP_BAD_ROOTFS:-0}"
SKIP_BAD_FIT="${SKIP_BAD_FIT:-0}"

TOOLS_SRC="$ROOT/meta-local/recipes-support/ab-update/files"
MAKE_BUNDLE="$ROOT/meta-local/scripts/make-ab-update-bundle.sh"

SSH=(ssh -i "$SSH_KEY" -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new
	-o ConnectTimeout=10 -o BatchMode=yes
	-o ServerAliveInterval=5 -o ServerAliveCountMax=2 "$TARGET")
SCP=(scp -i "$SSH_KEY" -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new
	-o ConnectTimeout=10 -o BatchMode=yes)

usage() {
	cat <<'EOF'
Usage: test-ab-update.sh

  Run good, bad-rootfs, and bad-FIT A/B tests over SSH.

Environment:
  TARGET         SSH target (default root@192.168.3.71)
  SSH_KEY        Private key for root
  REMOTE_DIR     Remote work dir (default /data/update)
  DEPLOY         Yocto deploy images dir
  SSH_WAIT_SEC   Max seconds to wait for SSH after reboot (default 300)
  SKIP_GOOD=1    Skip the good-bundle test
  SKIP_BAD_ROOTFS=1     Skip the bad-rootfs rollback test
  SKIP_BAD_FIT=1 Skip the bad-FIT rollback test
EOF
}

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf '%s\n' "$*"; }

while [ $# -gt 0 ]; do
	case "$1" in
	-h|--help) usage; exit 0 ;;
	*) die "unknown argument: $1 (see --help)" ;;
	esac
done

[ -f "$SSH_KEY" ] || die "SSH key not found: $SSH_KEY"
[ -x "$MAKE_BUNDLE" ] || die "missing $MAKE_BUNDLE"
command -v ssh >/dev/null && command -v scp >/dev/null || die "ssh/scp required"

# Drop stale host key after reflash (accept-new does not replace changed keys).
host=${TARGET#*@}
ssh-keygen -f "${HOME}/.ssh/known_hosts" -R "$host" >/dev/null 2>&1 || true

ssh_try() { "${SSH[@]}" "$@" 2>&1; }

wait_ssh_up() {
	local label=$1
	local start elapsed=0
	start=$(date +%s)
	log "===== WAIT SSH ($label), max ${SSH_WAIT_SEC}s ====="
	while true; do
		elapsed=$(( $(date +%s) - start ))
		if [ "$elapsed" -ge "$SSH_WAIT_SEC" ]; then
			log "FAIL: SSH not up within ${SSH_WAIT_SEC}s ($label)"
			return 1
		fi
		log "--- poll t=${elapsed}s ($(date +%H:%M:%S)) ---"
		if out=$(ssh_try 'echo UP; test -r /etc/os-release && echo OS_OK'); then
			printf '%s\n' "$out"
			if echo "$out" | grep -q OS_OK; then
				log "SSH UP after ${elapsed}s"
				return 0
			fi
		else
			log "(no ssh)"
			printf '%s\n' "$out" | tail -n 2
		fi
		sleep 10
	done
}

active_slot() {
	ssh_try 'lsblk -no PARTLABEL "$(readlink -f "$(findmnt -n -o SOURCE /)")"'
}

board_snapshot() {
	log "===== SNAPSHOT: $1 ====="
	ssh_try 'echo cmdline=$(cat /proc/cmdline)
ROOTDEV=$(readlink -f "$(findmnt -n -o SOURCE /)")
echo rootdev=$ROOTDEV
echo PARTLABEL=$(lsblk -no PARTLABEL "$ROOTDEV")
echo PARTUUID=$(lsblk -no PARTUUID "$ROOTDEV")
echo bootslot=$(fw_printenv -n bootslot 2>/dev/null || echo NONE)
echo upgrade_available=$(fw_printenv -n upgrade_available 2>/dev/null || echo NONE)
echo bootcount=$(fw_printenv -n bootcount 2>/dev/null || echo NONE)
echo bootlimit=$(fw_printenv -n bootlimit 2>/dev/null || echo NONE)
fw_printenv -n bootcmd 2>/dev/null | sed "s/^/bootcmd=/"
echo --- mounts ---
findmnt -n /
findmnt -n /boot
findmnt -n /data
echo --- lsblk ---
lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,PARTLABEL,MOUNTPOINT
echo --- boot artifacts ---
ls -lh /boot/boot.scr /boot/fitImage_a /boot/fitImage_b /boot/uboot.env 2>&1
echo --- boot.scr markers ---
strings /boot/boot.scr | grep -E "bootcount=|itest|bootlimit|fitImage_|PARTUUID|rolling|resetting to advance|boot failed for" || true
echo --- os-release ---
sed -n "1,2p" /etc/os-release'
}

resolve_fit() {
	local fit
	fit=$(ls -1 "$DEPLOY"/fitImage-core-image-initramfs-boot-orange-pi-3-orange-pi-3 2>/dev/null | head -n1 || true)
	[ -n "$fit" ] && [ -f "$fit" ] || fit=$(readlink -f "$DEPLOY/fitImage" 2>/dev/null || true)
	[ -n "$fit" ] && [ -f "$fit" ] || die "missing FIT in $DEPLOY"
	printf '%s\n' "$fit"
}

sync_tools() {
	ssh_try "mkdir -p '$REMOTE_DIR/tools'" >/dev/null
	"${SCP[@]}" "$TOOLS_SRC/ab-update.sh" "$TARGET:$REMOTE_DIR/tools/ab-update"
	ssh_try "chmod 755 '$REMOTE_DIR/tools/ab-update'" >/dev/null
}

run_ab_update_remote() {
	local bundle_local=$1 bundle_name=$2
	local remote_path="$REMOTE_DIR/$bundle_name"
	log "===== UPLOAD $bundle_local -> $remote_path ====="
	sync_tools
	"${SCP[@]}" "$bundle_local" "$TARGET:$remote_path"
	ssh_try "ls -lh '$remote_path' '$REMOTE_DIR/tools/ab-update'"
	log "===== RUN ab-update --yes ====="
	set +e
	out=$(ssh_try "'$REMOTE_DIR/tools/ab-update' --yes '$remote_path'")
	rc=$?
	set -e
	printf '%s\n' "$out"
	log "ab-update ssh exit=$rc (0 or 255 expected)"
}

# --- TEST 1: good bundle ---
GOOD_OK=1
BEFORE_GOOD=""
AFTER_GOOD=""

if [ "$SKIP_GOOD" != "1" ]; then
	log '######################################################################'
	log '# TEST 1: GOOD BUNDLE UPDATE'
	log '######################################################################'
	wait_ssh_up pre-test1 || exit 1
	board_snapshot BEFORE_GOOD
	BEFORE_GOOD=$(active_slot)
	log "BEFORE_SLOT=$BEFORE_GOOD"

	log '===== BUILD GOOD BUNDLE ====='
	"$MAKE_BUNDLE" /tmp/khepri-ab-GOOD.tar.gz
	ls -lh /tmp/khepri-ab-GOOD.tar.gz
	tar -tzvf /tmp/khepri-ab-GOOD.tar.gz

	run_ab_update_remote /tmp/khepri-ab-GOOD.tar.gz khepri-ab-GOOD.tar.gz
	wait_ssh_up after-good || die "TEST1 FAIL: board did not come back after good update"
	board_snapshot AFTER_GOOD
	AFTER_GOOD=$(active_slot)
	log "AFTER_GOOD_SLOT=$AFTER_GOOD (was $BEFORE_GOOD)"

	if [ "$AFTER_GOOD" = "$BEFORE_GOOD" ]; then
		log 'FAIL: slot did not switch after good update'
		GOOD_OK=0
	fi
	ua=$(ssh_try 'fw_printenv -n upgrade_available')
	bc=$(ssh_try 'fw_printenv -n bootcount')
	if [ "$ua" != "0" ] || [ "$bc" != "0" ]; then
		log "FAIL: expected upgrade_available=0 bootcount=0, got ua=$ua bc=$bc"
		GOOD_OK=0
	fi
	if ! ssh_try 'test -r /etc/os-release && test -f /boot/uboot.env' >/dev/null; then
		log 'FAIL: os-release or uboot.env missing'
		GOOD_OK=0
	fi
	case "$AFTER_GOOD" in
	rootfs_a) fit_expect=fitImage_a ;;
	rootfs_b) fit_expect=fitImage_b ;;
	*) fit_expect= ;;
	esac
	if [ -n "$fit_expect" ] && ! ssh_try "test -f /boot/$fit_expect" >/dev/null; then
		log "FAIL: missing /boot/$fit_expect"
		GOOD_OK=0
	fi
	if [ "$GOOD_OK" -eq 1 ]; then
		log '###### TEST1 PASS ######'
	else
		log '###### TEST1 FAIL ######'
		exit 1
	fi
else
	log 'SKIP_GOOD=1 — skipping good-bundle test'
	wait_ssh_up pre-test2-only || exit 1
fi

# --- TEST 2: bad rootfs bundle ---
BAD_OK=1
BEFORE_BAD=""
AFTER_BAD=""

if [ "$SKIP_BAD_ROOTFS" != "1" ]; then
	log
	log '######################################################################'
	log '# TEST 2: BAD ROOTFS BUNDLE + ROLLBACK'
	log '######################################################################'
	wait_ssh_up pre-test2 || exit 1
	BEFORE_BAD=$(active_slot)
	log "BEFORE_BAD_SLOT=$BEFORE_BAD"

	log '===== BUILD BAD BUNDLE (valid FIT + corrupt rootfs) ====='
	STAGE=$(mktemp -d /tmp/bad-ab.XXXXXX)
	FIT=$(resolve_fit)
	cp -L "$FIT" "$STAGE/fitImage"
	dd if=/dev/urandom of="$STAGE/rootfs.ext4" bs=1M count=16 status=none
	printf 'BADROOTFS_FOR_AB_ROLLBACK_TEST\n' | dd of="$STAGE/rootfs.ext4" conv=notrunc status=none 2>/dev/null
	tar -C "$STAGE" -czf /tmp/khepri-ab-BAD.tar.gz rootfs.ext4 fitImage
	ls -lh /tmp/khepri-ab-BAD.tar.gz
	file "$STAGE/rootfs.ext4" "$STAGE/fitImage"
	rm -rf "$STAGE"

	run_ab_update_remote /tmp/khepri-ab-BAD.tar.gz khepri-ab-BAD.tar.gz
	wait_ssh_up after-bad-rootfs-rollback || die "TEST2 FAIL: board did not come back within ${SSH_WAIT_SEC}s after bad-rootfs update"
	board_snapshot AFTER_BAD
	AFTER_BAD=$(active_slot)
	ua=$(ssh_try 'fw_printenv -n upgrade_available')
	bc=$(ssh_try 'fw_printenv -n bootcount')
	bs=$(ssh_try 'fw_printenv -n bootslot')
	log "AFTER_BAD_SLOT=$AFTER_BAD BEFORE=$BEFORE_BAD bootslot=$bs ua=$ua bc=$bc"

	if [ "$AFTER_BAD" != "$BEFORE_BAD" ]; then
		log "FAIL: expected rollback to $BEFORE_BAD, got $AFTER_BAD"
		BAD_OK=0
	fi
	if [ "$ua" != "0" ]; then
		log "FAIL: upgrade_available=$ua expected 0"
		BAD_OK=0
	fi
	if ! ssh_try 'test -r /etc/os-release' >/dev/null; then
		log 'FAIL: no usable root after bad-rootfs update cycle'
		BAD_OK=0
	fi
	if [ "$BAD_OK" -eq 1 ]; then
		log '###### TEST2 PASS ######'
	else
		log '###### TEST2 FAIL ######'
		exit 1
	fi
else
	log 'SKIP_BAD_ROOTFS=1 — skipping bad-rootfs rollback test'
fi

# --- TEST 3: bad FIT bundle ---
BAD_FIT_OK=1
BEFORE_BAD_FIT=""
AFTER_BAD_FIT=""

if [ "$SKIP_BAD_FIT" != "1" ]; then
	log
	log '######################################################################'
	log '# TEST 3: BAD FIT BUNDLE + ROLLBACK'
	log '######################################################################'
	wait_ssh_up pre-test3 || exit 1
	BEFORE_BAD_FIT=$(active_slot)
	log "BEFORE_BAD_FIT_SLOT=$BEFORE_BAD_FIT"

	log '===== BUILD BAD-FIT BUNDLE (valid rootfs + corrupt FIT) ====='
	STAGE=$(mktemp -d /tmp/bad-fit.XXXXXX)
	EXT4="$DEPLOY/core-image-khepri-orange-pi-3.rootfs.ext4"
	[ -f "$EXT4" ] || die "missing $EXT4"
	FIT=$(resolve_fit)
	FIT_REAL=$(readlink -f "$FIT")
	FIT_SIZE=$(stat -c%s "$FIT_REAL")
	cp -L "$EXT4" "$STAGE/rootfs.ext4"
	dd if=/dev/urandom of="$STAGE/fitImage" bs=4096 count=$(( (FIT_SIZE + 4095) / 4096 )) status=none
	truncate -s "$FIT_SIZE" "$STAGE/fitImage"
	printf 'BADFIT_FOR_AB_ROLLBACK_TEST\n' | dd of="$STAGE/fitImage" conv=notrunc status=none
	tar -C "$STAGE" -czf /tmp/khepri-ab-BADFIT.tar.gz rootfs.ext4 fitImage
	ls -lh /tmp/khepri-ab-BADFIT.tar.gz
	file "$STAGE/rootfs.ext4" "$STAGE/fitImage"
	rm -rf "$STAGE"

	run_ab_update_remote /tmp/khepri-ab-BADFIT.tar.gz khepri-ab-BADFIT.tar.gz
	wait_ssh_up after-bad-fit-rollback || die "TEST3 FAIL: board did not come back within ${SSH_WAIT_SEC}s after bad-FIT update"
	board_snapshot AFTER_BAD_FIT
	AFTER_BAD_FIT=$(active_slot)
	ua=$(ssh_try 'fw_printenv -n upgrade_available')
	bc=$(ssh_try 'fw_printenv -n bootcount')
	bs=$(ssh_try 'fw_printenv -n bootslot')
	log "AFTER_BAD_FIT_SLOT=$AFTER_BAD_FIT BEFORE=$BEFORE_BAD_FIT bootslot=$bs ua=$ua bc=$bc"

	if [ "$AFTER_BAD_FIT" != "$BEFORE_BAD_FIT" ]; then
		log "FAIL: expected rollback to $BEFORE_BAD_FIT, got $AFTER_BAD_FIT"
		BAD_FIT_OK=0
	fi
	if [ "$ua" != "0" ]; then
		log "FAIL: upgrade_available=$ua expected 0"
		BAD_FIT_OK=0
	fi
	if ! ssh_try 'test -r /etc/os-release' >/dev/null; then
		log 'FAIL: no usable root after bad-FIT update cycle'
		BAD_FIT_OK=0
	fi
	if [ "$BAD_FIT_OK" -eq 1 ]; then
		log '###### TEST3 PASS ######'
	else
		log '###### TEST3 FAIL ######'
		exit 1
	fi
else
	log 'SKIP_BAD_FIT=1 — skipping bad-FIT rollback test'
fi

log
log '######################################################################'
log '# SUMMARY'
log '######################################################################'
if [ "$SKIP_GOOD" = "1" ]; then
	log 'TEST1 GOOD UPDATE: SKIPPED'
elif [ "$GOOD_OK" -eq 1 ]; then
	log "TEST1 GOOD UPDATE: PASS ($BEFORE_GOOD -> $AFTER_GOOD)"
else
	log 'TEST1 GOOD UPDATE: FAIL'
fi
if [ "$SKIP_BAD_ROOTFS" = "1" ]; then
	log 'TEST2 BAD ROOTFS ROLLBACK: SKIPPED'
elif [ "$BAD_OK" -eq 1 ]; then
	log "TEST2 BAD ROOTFS ROLLBACK: PASS (stayed/returned $BEFORE_BAD)"
else
	log 'TEST2 BAD ROOTFS ROLLBACK: FAIL'
fi
if [ "$SKIP_BAD_FIT" = "1" ]; then
	log 'TEST3 BAD FIT ROLLBACK: SKIPPED'
elif [ "$BAD_FIT_OK" -eq 1 ]; then
	log "TEST3 BAD FIT ROLLBACK: PASS (stayed/returned $BEFORE_BAD_FIT)"
else
	log 'TEST3 BAD FIT ROLLBACK: FAIL'
fi

[ "$SKIP_GOOD" = "1" ] || [ "$GOOD_OK" -eq 1 ] || exit 1
[ "$SKIP_BAD_ROOTFS" = "1" ] || [ "$BAD_OK" -eq 1 ] || exit 1
[ "$SKIP_BAD_FIT" = "1" ] || [ "$BAD_FIT_OK" -eq 1 ] || exit 1
exit 0
