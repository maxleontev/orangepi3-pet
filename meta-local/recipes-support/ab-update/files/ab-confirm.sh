#!/bin/sh
# Confirm a successful A/B boot: clear upgrade_available / bootcount so U-Boot
# will not roll back on the next reboot.
set -eu

ENV_CFG="${FW_ENV_CONFIG:-/etc/fw_env.config}"

need_cmd() {
	command -v "$1" >/dev/null 2>&1 || {
		printf 'ab-confirm: required command not found: %s\n' "$1" >&2
		exit 1
	}
}

need_cmd fw_printenv
need_cmd fw_setenv
need_cmd findmnt
need_cmd lsblk
need_cmd mount
need_cmd umount

BOOT_MNT="${BOOT_MNT:-/boot}"

# Bind /boot to root-disk boot partition when LABEL=boot is ambiguous.
ensure_boot_on_root_disk() {
	src=$(findmnt -n -o SOURCE / 2>/dev/null || true)
	[ -n "$src" ] || return 0
	real=$(readlink -f "$src" 2>/dev/null || printf '%s' "$src")
	base=$(basename "$real")
	case "$base" in
	mmcblk*p*) disk="/dev/${base%p*}" ;;
	sd*[0-9]) disk="/dev/${base%%[0-9]*}" ;;
	*) return 0 ;;
	esac
	boot_dev=""
	sys="/sys/block/$(basename "$disk")"
	for p in "$sys/$(basename "$disk")"p*; do
		[ -e "$p/partition" ] || continue
		devpath="/dev/$(basename "$p")"
		name=$(lsblk -no PARTLABEL "$devpath" 2>/dev/null || true)
		if [ "$name" = "boot" ]; then
			boot_dev=$devpath
			break
		fi
	done
	[ -n "$boot_dev" ] || return 0
	cur=$(findmnt -n -o SOURCE "$BOOT_MNT" 2>/dev/null || true)
	cur_real=$(readlink -f "$cur" 2>/dev/null || printf '%s' "$cur")
	[ "$cur_real" = "$boot_dev" ] && return 0
	printf 'ab-confirm: remounting %s from %s (was %s)\n' "$BOOT_MNT" "$boot_dev" "${cur_real:-unmounted}"
	if [ -n "$cur" ]; then
		umount "$BOOT_MNT" || true
	fi
	mount -t vfat "$boot_dev" "$BOOT_MNT" || true
}

ensure_boot_on_root_disk

if [ ! -e "$BOOT_MNT/uboot.env" ]; then
	# No env file yet — nothing to confirm (still on factory defaults / slot A).
	exit 0
fi

ua=$(fw_printenv -c "$ENV_CFG" -n upgrade_available 2>/dev/null || printf '0')
[ "$ua" = "1" ] || exit 0

slot=$(fw_printenv -c "$ENV_CFG" -n bootslot 2>/dev/null || printf 'a')
printf 'ab-confirm: confirming boot slot %s\n' "$slot"
fw_setenv -c "$ENV_CFG" upgrade_available 0
fw_setenv -c "$ENV_CFG" bootcount 0
