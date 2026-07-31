#!/bin/sh
# Apply a local A/B update (rootfs.ext4 + fitImage) to the inactive slot.
#
# Bundle layout (directory or .tar/.tar.gz):
#   rootfs.ext4   — ext4 image for the inactive rootfs slot (required)
#   fitImage      — FIT (kernel + DTB + initramfs) for that slot (required)
#
# After writing the inactive slot and fitImage_{a|b}, sets U-Boot env:
#   bootslot=<inactive>  upgrade_available=1  bootcount=0
# then reboots (unless --no-reboot). ab-confirm.service clears the pending
# flag after a successful boot; otherwise U-Boot rolls back past bootlimit.
set -eu

YES=0
REBOOT=1
ENV_CFG="${FW_ENV_CONFIG:-/etc/fw_env.config}"
BOOT_MNT="${BOOT_MNT:-/boot}"

usage() {
	cat <<'EOF'
Usage: ab-update [--yes] [--no-reboot] BUNDLE

  BUNDLE   directory, or .tar / .tar.gz / .tgz containing:
             rootfs.ext4   (required)
             fitImage      (required)

  --yes        skip confirmation prompt
  --no-reboot  do not reboot after switching bootslot

Environment: YES=1  REBOOT=0  FW_ENV_CONFIG=...  BOOT_MNT=...
EOF
}

log() { printf '%s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

need_cmd() {
	command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

confirm() {
	[ "$YES" = "1" ] && return 0
	printf 'Type YES to write inactive slot and switch boot: '
	read -r ans
	[ "$ans" = "YES" ] || die "aborted"
}

# Resolve the block device that backs the live root (mmcblkNpM → mmcblkN).
root_disk() {
	src=$(findmnt -n -o SOURCE / 2>/dev/null || true)
	[ -n "$src" ] || die "cannot determine root mount source"
	real=$(readlink -f "$src" 2>/dev/null || printf '%s' "$src")
	base=$(basename "$real")
	case "$base" in
	mmcblk*p*) printf '%s' "/dev/${base%p*}" ;;
	sd*[0-9]) printf '%s' "/dev/${base%%[0-9]*}" ;;
	*) die "unsupported root device: $real" ;;
	esac
}

# Active slot letter from the live root partition (same disk), not ambiguous
# global PARTLABEL= in cmdline when SD and eMMC both exist.
active_slot() {
	src=$(findmnt -n -o SOURCE / 2>/dev/null || true)
	if [ -n "$src" ]; then
		real=$(readlink -f "$src" 2>/dev/null || printf '%s' "$src")
		name=$(lsblk -no PARTLABEL "$real" 2>/dev/null || true)
		case "$name" in
		rootfs_a) printf 'a'; return 0 ;;
		rootfs_b) printf 'b'; return 0 ;;
		esac
	fi
	if [ -r /proc/cmdline ]; then
		for tok in $(cat /proc/cmdline); do
			case "$tok" in
			root=PARTLABEL=rootfs_a) printf 'a'; return 0 ;;
			root=PARTLABEL=rootfs_b) printf 'b'; return 0 ;;
			esac
		done
	fi
	if [ -e /boot/uboot.env ] && command -v fw_printenv >/dev/null 2>&1; then
		s=$(fw_printenv -c "$ENV_CFG" -n bootslot 2>/dev/null || true)
		case "$s" in
		a|b) printf '%s' "$s"; return 0 ;;
		esac
	fi
	printf 'a'
}

inactive_slot() {
	case "$1" in
	a) printf 'b' ;;
	b) printf 'a' ;;
	*) die "invalid slot: $1" ;;
	esac
}

# libubootenv refuses a missing env file. A zeroed file has a bad CRC so the
# next fw_setenv -f <defaults> can seed a full environment.
ensure_uboot_env() {
	envfile="$BOOT_MNT/uboot.env"
	envsize=65536
	if [ -r "$ENV_CFG" ]; then
		sz=$(awk '!/^#/ && NF >= 3 { print $3; exit }' "$ENV_CFG" 2>/dev/null || true)
		case "$sz" in
		0x*|0X*) envsize=$(printf '%d' "$sz") ;;
		[0-9]*) envsize=$sz ;;
		esac
	fi
	if [ ! -e "$envfile" ]; then
		log "Creating missing $envfile ($envsize bytes)"
		dd if=/dev/zero of="$envfile" bs="$envsize" count=1
		sync
	fi
}

default_env_file() {
	# Prefer the machine symlink from u-boot-env (RPROVIDES u-boot-default-env).
	for f in /etc/u-boot-initial-env /etc/u-boot-initial-env-*; do
		[ -f "$f" ] || continue
		# Skip dangling symlinks
		[ -r "$f" ] || continue
		printf '%s' "$f"
		return 0
	done
	return 1
}

env_has_bootcmd() {
	fw_printenv -c "$ENV_CFG" -n bootcmd >/dev/null 2>&1
}

# Seed/repair FAT uboot.env then set A/B slot vars. Never leave bootcmd unset:
# a sparse env (only A/B keys) makes U-Boot drop to the '=>' prompt.
fw_setenv_boot() {
	slot=$1
	defenv=$(default_env_file) || die "missing /etc/u-boot-initial-env (install u-boot-env)"

	ensure_uboot_env

	if ! env_has_bootcmd; then
		log "U-Boot env missing bootcmd — re-seeding from $defenv"
		rm -f "$BOOT_MNT/uboot.env"
		ensure_uboot_env
		# -f applies when CRC is invalid (zeroed file); writes full default + bootslot.
		fw_setenv -c "$ENV_CFG" -f "$defenv" bootslot "$slot"
	else
		fw_setenv -c "$ENV_CFG" bootslot "$slot"
	fi

	fw_setenv -c "$ENV_CFG" upgrade_available 1
	fw_setenv -c "$ENV_CFG" bootcount 0
	fw_setenv -c "$ENV_CFG" bootlimit 3

	env_has_bootcmd || die "bootcmd still missing after seeding U-Boot env"
	log "U-Boot env OK (bootcmd present, bootslot=$slot)"
}

# PARTLABEL node on the same disk as live root (avoid SD/eMMC label clashes).
partlabel_dev() {
	disk="$1"
	label="$2"
	base=$(basename "$disk")
	sys="/sys/block/$base"
	[ -d "$sys" ] || die "missing sysfs for $disk"
	for p in "$sys/${base}"p*; do
		[ -e "$p/partition" ] || continue
		devpath="/dev/$(basename "$p")"
		name=$(lsblk -no PARTLABEL "$devpath" 2>/dev/null || true)
		if [ "$name" = "$label" ]; then
			printf '%s' "$devpath"
			return 0
		fi
	done
	die "partition PARTLABEL=$label not found on $disk"
}

# Ensure /boot is the boot PARTLABEL on the same disk as live root.
# LABEL=boot / by-partlabel/boot are ambiguous when SD and eMMC both carry
# identical GPT PARTLABELs (common after a prior eMMC flash).
ensure_boot_mount() {
	disk="$1"
	boot_dev=$(partlabel_dev "$disk" "boot")
	[ -d "$BOOT_MNT" ] || die "boot mountpoint missing: $BOOT_MNT"

	cur=$(findmnt -n -o SOURCE "$BOOT_MNT" 2>/dev/null || true)
	cur_real=""
	if [ -n "$cur" ]; then
		cur_real=$(readlink -f "$cur" 2>/dev/null || printf '%s' "$cur")
	fi

	if [ "$cur_real" = "$boot_dev" ]; then
		log "Boot mount OK: $BOOT_MNT -> $boot_dev (same disk as root)"
		return 0
	fi

	if [ -n "$cur_real" ]; then
		log "Remounting $BOOT_MNT from $boot_dev (was $cur_real — LABEL clash?)"
		umount "$BOOT_MNT" || die "cannot umount $BOOT_MNT"
	else
		log "Mounting $boot_dev on $BOOT_MNT"
	fi
	mount -t vfat "$boot_dev" "$BOOT_MNT" || die "cannot mount $boot_dev on $BOOT_MNT"
}

part_bytes() {
	blockdev --getsize64 "$1"
}

extract_bundle() {
	bundle="$1"
	workdir="$2"
	if [ -d "$bundle" ]; then
		[ -f "$bundle/rootfs.ext4" ] || die "missing $bundle/rootfs.ext4"
		[ -f "$bundle/fitImage" ] || die "missing $bundle/fitImage"
		cp -a "$bundle/rootfs.ext4" "$workdir/rootfs.ext4"
		cp -a "$bundle/fitImage" "$workdir/fitImage"
		return 0
	fi
	[ -f "$bundle" ] || die "bundle not found: $bundle"
	case "$bundle" in
	*.tar.gz|*.tgz)
		tar -xzf "$bundle" -C "$workdir"
		;;
	*.tar)
		tar -xf "$bundle" -C "$workdir"
		;;
	*)
		die "unsupported bundle type (use dir, .tar, .tar.gz): $bundle"
		;;
	esac
	# Allow a single top-level directory inside the archive.
	if [ ! -f "$workdir/rootfs.ext4" ]; then
		sub=$(find "$workdir" -mindepth 2 -maxdepth 2 -name rootfs.ext4 2>/dev/null | head -n1 || true)
		[ -n "$sub" ] || die "archive missing rootfs.ext4"
		dir=$(dirname "$sub")
		mv "$dir/rootfs.ext4" "$workdir/rootfs.ext4"
		mv "$dir/fitImage" "$workdir/fitImage"
	fi
	[ -f "$workdir/rootfs.ext4" ] || die "archive missing rootfs.ext4"
	[ -f "$workdir/fitImage" ] || die "archive missing fitImage"
}

# --- args ---
while [ $# -gt 0 ]; do
	case "$1" in
	-h|--help) usage; exit 0 ;;
	--yes|-y) YES=1; shift ;;
	--no-reboot) REBOOT=0; shift ;;
	--*) die "unknown option: $1" ;;
	*) break ;;
	esac
done
[ $# -eq 1 ] || { usage >&2; exit 1; }
BUNDLE=$1

[ "$(id -u)" = "0" ] || die "must run as root"

need_cmd findmnt
need_cmd lsblk
need_cmd blockdev
need_cmd dd
need_cmd fw_printenv
need_cmd fw_setenv
need_cmd sync
need_cmd mount
need_cmd umount

WORKDIR=$(mktemp -d /tmp/ab-update.XXXXXX)
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

log "Extracting bundle from $BUNDLE"
extract_bundle "$BUNDLE" "$WORKDIR"

DISK=$(root_disk)
ensure_boot_mount "$DISK"
ACTIVE=$(active_slot)
TARGET=$(inactive_slot "$ACTIVE")
ROOT_LABEL="rootfs_${TARGET}"
FIT_NAME="fitImage_${TARGET}"
ROOT_DEV=$(partlabel_dev "$DISK" "$ROOT_LABEL")

img_bytes=$(wc -c < "$WORKDIR/rootfs.ext4" | tr -d ' \t\n')
part_sz=$(part_bytes "$ROOT_DEV")
[ "$img_bytes" -le "$part_sz" ] || \
	die "rootfs.ext4 ($img_bytes) larger than $ROOT_DEV ($part_sz)"

log "Disk:          $DISK"
log "Active slot:   $ACTIVE"
log "Target slot:   $TARGET  ($ROOT_DEV, $FIT_NAME)"
log "rootfs.ext4:   $img_bytes bytes"
log "fitImage:      $(wc -c < "$WORKDIR/fitImage" | tr -d ' \t\n') bytes"
log ""
confirm

# Refuse to write a mounted partition
if findmnt -n "$ROOT_DEV" >/dev/null 2>&1; then
	die "$ROOT_DEV is mounted — refuse to overwrite"
fi

log "Writing rootfs to $ROOT_DEV"
dd if="$WORKDIR/rootfs.ext4" of="$ROOT_DEV" bs=4M
sync

# Re-check after rootfs write (should still be root-disk boot).
ensure_boot_mount "$DISK"

log "Installing $FIT_NAME on $BOOT_MNT"
cp -f "$WORKDIR/fitImage" "$BOOT_MNT/$FIT_NAME"
sync

log "Setting U-Boot env: bootslot=$TARGET upgrade_available=1 bootcount=0"
fw_setenv_boot "$TARGET"
sync

log ""
log "Update staged for slot $TARGET."
if [ "$REBOOT" = "1" ]; then
	log "Rebooting..."
	sync
	reboot
else
	log "Reboot skipped (--no-reboot). Reboot to try slot $TARGET."
fi
