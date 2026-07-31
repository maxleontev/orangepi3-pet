#!/bin/sh
# Clone Orange Pi 3 system from SD card to onboard eMMC and make it bootable.
#
# Matches meta-local GPT layout (orangepi3-sdcard.wks.in):
#   LBA0 GPT | SPL+U-Boot @ 128 KiB | boot (FAT) | rootfs_a | rootfs_b | data (F2FS)
#
# Boot uses PARTLABEL=rootfs_a / part name "boot", so no bootargs rewrite is needed.
# Allwinner BROM loads SPL from the eMMC user area at 128 KiB (same as SD).
#
# Defaults match a board where Linux names SD=mmcblk2 and eMMC=mmcblk1.
# Override: SRC=/dev/mmcblk0 DST=/dev/mmcblk1 sd-to-emmc
#
# After success: power off, remove the SD card, power on (BROM prefers SD).

set -eu

SRC="${SRC:-/dev/mmcblk2}"
DST="${DST:-/dev/mmcblk1}"
YES="${YES:-0}"
GROW_DATA="${GROW_DATA:-1}"

usage() {
	cat <<'EOF'
Usage: sd-to-emmc [--yes] [--no-grow] [SRC DST]

  Copy GPT + SPL/U-Boot + boot/rootfs_a/rootfs_b/data from SD to eMMC.
  Default: SRC=/dev/mmcblk2  DST=/dev/mmcblk1

  --yes       skip confirmation prompt
  --no-grow   do not expand the data partition to fill eMMC
  SRC DST     override block devices (or set SRC=/dev/... DST=/dev/...)

Environment: YES=1  GROW_DATA=0  same as the flags above.
EOF
}

log() { printf '%s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

need_cmd() {
	command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

dev_base() {
	basename "$1"
}

dev_sys() {
	printf '/sys/block/%s' "$(dev_base "$1")"
}

dev_type() {
	# SD card -> "SD", eMMC -> "MMC"
	tfile="$(dev_sys "$1")/device/type"
	if [ -r "$tfile" ]; then
		cat "$tfile"
	else
		printf 'unknown'
	fi
}

dev_bytes() {
	blockdev --getsize64 "$1"
}

# Highest exclusive end sector among partitions (512-byte sectors).
last_used_sector() {
	base="$(dev_base "$1")"
	sys="$(dev_sys "$1")"
	end=0
	for p in "$sys/${base}"p*; do
		[ -e "$p/start" ] || continue
		s=$(cat "$p/start")
		n=$(cat "$p/size")
		e=$((s + n))
		[ "$e" -gt "$end" ] && end=$e
	done
	[ "$end" -gt 0 ] || die "no partitions found on $1"
	# Include a little padding; primary GPT + SPL are before p1 and already
	# covered by copying from sector 0. Padding helps if alignment differs.
	printf '%s' "$((end + 34))"
}

part_nodes() {
	base="$(dev_base "$1")"
	for p in /dev/"${base}"p* /dev/"${base}"boot*; do
		[ -e "$p" ] || continue
		printf '%s\n' "$p"
	done
}

umount_dev_parts() {
	dev="$1"
	# Reverse order so dependents unmount first.
	part_nodes "$dev" | sort -r | while read -r p; do
		if mount | grep -q "^$p "; then
			log "Unmounting $p"
			umount "$p" || umount -l "$p" || die "failed to unmount $p"
		fi
	done
}

is_root_on() {
	root_src=$(findmnt -n -o SOURCE / 2>/dev/null || true)
	case "$root_src" in
	"$1"|"$1"p*) return 0 ;;
	esac
	# PARTLABEL=rootfs_a resolves to a path under /dev/disk/by-partlabel
	if [ -n "$root_src" ] && [ -e "$root_src" ]; then
		real=$(readlink -f "$root_src" 2>/dev/null || printf '%s' "$root_src")
		case "$real" in
		"$1"|"$1"p*) return 0 ;;
		esac
	fi
	return 1
}

confirm() {
	[ "$YES" = "1" ] && return 0
	printf 'Type YES to erase %s and write a clone of %s: ' "$DST" "$SRC"
	read -r ans
	[ "$ans" = "YES" ] || die "aborted"
}

fix_gpt_backup() {
	if command -v sgdisk >/dev/null 2>&1; then
		log "Relocating backup GPT to end of $DST (sgdisk -e)"
		sgdisk -e "$DST"
	elif command -v parted >/dev/null 2>&1; then
		log "Asking parted to fix GPT on $DST"
		# parted prints a Fix/Ignore prompt on secondary-header mismatch
		printf 'Fix\n' | parted ---pretend-input-tty "$DST" print >/dev/null \
			|| log "WARNING: parted GPT fix may have failed; primary GPT should still work"
	else
		log "WARNING: neither sgdisk nor parted found; backup GPT may be wrong"
		log "         (Linux still boots from the primary GPT)"
	fi
}

grow_data_partition() {
	[ "$GROW_DATA" = "1" ] || return 0

	partprobe "$DST" 2>/dev/null || true
	sleep 1

	# Do not use /dev/disk/by-partlabel: SD and eMMC share the same labels.
	base="$(dev_base "$DST")"
	sys="$(dev_sys "$DST")"
	data_dev=""
	partnum=""
	for p in "$sys/${base}"p*; do
		[ -e "$p" ] || continue
		name=""
		if [ -r "$p/partition" ]; then
			# Prefer GPT partition name via lsblk if available
			devpath="/dev/$(basename "$p")"
			if command -v lsblk >/dev/null 2>&1; then
				name=$(lsblk -no PARTNAME "$devpath" 2>/dev/null || true)
			fi
		fi
		if [ "$name" = "data" ]; then
			data_dev="/dev/$(basename "$p")"
			partnum=$(cat "$p/partition")
			break
		fi
	done

	if [ -z "$data_dev" ]; then
		# Fallback: last partition on DST
		last=""
		lastn=""
		for p in "$sys/${base}"p*; do
			[ -e "$p/partition" ] || continue
			last="/dev/$(basename "$p")"
			lastn=$(cat "$p/partition")
		done
		data_dev=$last
		partnum=$lastn
	fi

	[ -n "$data_dev" ] && [ -n "$partnum" ] || {
		log "WARNING: could not find data partition; skip grow"
		return 0
	}

	log "Growing partition $data_dev (part $partnum) to end of eMMC"

	if command -v parted >/dev/null 2>&1; then
		parted -s "$DST" resizepart "$partnum" 100%
	elif command -v sgdisk >/dev/null 2>&1; then
		start=$(cat "$sys/$(basename "$data_dev")/start")
		sgdisk -d "$partnum" "$DST"
		sgdisk -n "${partnum}:${start}:0" -c "${partnum}:data" -t "${partnum}:8300" "$DST"
	else
		log "WARNING: no parted/sgdisk; cannot grow data partition"
		return 0
	fi

	partprobe "$DST" 2>/dev/null || true
	sleep 1

	if command -v resize.f2fs >/dev/null 2>&1; then
		log "Resizing F2FS on $data_dev"
		resize.f2fs "$data_dev"
	else
		log "WARNING: resize.f2fs not found; partition table grown but FS not resized"
	fi
}

# --- args ---
while [ $# -gt 0 ]; do
	case "$1" in
	-h|--help) usage; exit 0 ;;
	--yes|-y) YES=1; shift ;;
	--no-grow) GROW_DATA=0; shift ;;
	--*) die "unknown option: $1" ;;
	*) break ;;
	esac
done
if [ $# -eq 2 ]; then
	SRC=$1
	DST=$2
elif [ $# -ne 0 ]; then
	usage >&2
	exit 1
fi

# --- preflight ---
[ "$(id -u)" = "0" ] || die "must run as root"
need_cmd dd
need_cmd blockdev
need_cmd sync

[ -b "$SRC" ] || die "source not a block device: $SRC"
[ -b "$DST" ] || die "destination not a block device: $DST"
[ "$SRC" != "$DST" ] || die "SRC and DST must differ"

src_type=$(dev_type "$SRC")
dst_type=$(dev_type "$DST")
log "Source:      $SRC  (type=$src_type)"
log "Destination: $DST  (type=$dst_type)"

[ "$dst_type" = "MMC" ] || log "WARNING: $DST type is '$dst_type' (expected MMC for eMMC)"
[ "$src_type" = "SD" ] || log "WARNING: $SRC type is '$src_type' (expected SD)"

is_root_on "$DST" && die "root filesystem is on $DST — refuse to overwrite"

src_bytes=$(dev_bytes "$SRC")
dst_bytes=$(dev_bytes "$DST")
end_sect=$(last_used_sector "$SRC")
need_bytes=$((end_sect * 512))

log "SD size:     $src_bytes bytes"
log "eMMC size:   $dst_bytes bytes"
log "Used image:  $need_bytes bytes (through sector $end_sect)"

[ "$need_bytes" -le "$dst_bytes" ] || die "image ($need_bytes) does not fit on eMMC ($dst_bytes)"

# Soft check for ~8 GiB eMMC (accept 7–8.5 GiB marketed sizes)
if [ "$dst_bytes" -lt $((6 * 1024 * 1024 * 1024)) ] || \
   [ "$dst_bytes" -gt $((9 * 1024 * 1024 * 1024)) ]; then
	log "WARNING: eMMC size is not ~8 GiB; continuing anyway"
fi

log ""
log "This will ERASE all data on $DST."
confirm

# Avoid inconsistent /data while copying from the live SD
data_src=$(findmnt -n -o SOURCE /data 2>/dev/null || true)
if [ -n "$data_src" ]; then
	data_real=$(readlink -f "$data_src" 2>/dev/null || printf '%s' "$data_src")
	case "$data_real" in
	"$SRC"|"$SRC"p*)
		log "Remounting /data read-only for consistent copy"
		mount -o remount,ro /data || log "WARNING: could not remount /data ro"
		;;
	esac
fi
sync

log "Unmounting any filesystems on $DST"
umount_dev_parts "$DST"

# Drop partition mappings briefly so dd is clean
if command -v partx >/dev/null 2>&1; then
	partx -d "$DST" 2>/dev/null || true
fi

log "Copying $need_bytes bytes: $SRC -> $DST"
# BusyBox dd supports only if/of/bs/count/skip/seek — no conv= or status=.
mib=$((end_sect / 2048))
rem=$((end_sect % 2048))
if [ "$mib" -gt 0 ]; then
	dd if="$SRC" of="$DST" bs=1M count="$mib"
fi
if [ "$rem" -gt 0 ]; then
	dd if="$SRC" of="$DST" bs=512 \
		skip=$((mib * 2048)) seek=$((mib * 2048)) count="$rem"
fi
sync

if command -v partprobe >/dev/null 2>&1; then
	partprobe "$DST" 2>/dev/null || true
fi

fix_gpt_backup
grow_data_partition
sync

log ""
log "Done. eMMC clone is bootable (SPL @ 128 KiB, GPT PARTLABELs preserved)."
log "Next steps:"
log "  1. poweroff"
log "  2. remove the SD card"
log "  3. power on — board should boot from eMMC ($DST)"
log ""
log "If it still boots the SD image, the card was left inserted (BROM prefers SD)."
