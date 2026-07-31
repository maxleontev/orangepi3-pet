#!/bin/sh
# Repair a sparse /boot/uboot.env that is missing bootcmd (U-Boot drops to =>).
# Re-seeds from /etc/u-boot-initial-env and preserves bootslot / upgrade flags
# when possible.
set -eu

ENV_CFG="${FW_ENV_CONFIG:-/etc/fw_env.config}"
BOOT_MNT="${BOOT_MNT:-/boot}"

die() { printf 'ab-fixenv: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" = "0" ] || die "must run as root"
[ -d "$BOOT_MNT" ] || die "missing $BOOT_MNT"

# Prefer boot PARTLABEL on the same disk as live root (SD/eMMC clash).
src=$(findmnt -n -o SOURCE / 2>/dev/null || true)
[ -n "$src" ] || die "cannot determine root mount source"
real=$(readlink -f "$src" 2>/dev/null || printf '%s' "$src")
base=$(basename "$real")
case "$base" in
mmcblk*p*) disk="/dev/${base%p*}" ;;
sd*[0-9]) disk="/dev/${base%%[0-9]*}" ;;
*) die "unsupported root device: $real" ;;
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
[ -n "$boot_dev" ] || die "PARTLABEL=boot not found on $disk"
cur=$(findmnt -n -o SOURCE "$BOOT_MNT" 2>/dev/null || true)
cur_real=$(readlink -f "$cur" 2>/dev/null || printf '%s' "$cur")
if [ "$cur_real" != "$boot_dev" ]; then
	printf 'ab-fixenv: remounting %s from %s (was %s)\n' "$BOOT_MNT" "$boot_dev" "${cur_real:-unmounted}"
	if [ -n "$cur" ]; then
		umount "$BOOT_MNT" || die "cannot umount $BOOT_MNT"
	fi
	mount -t vfat "$boot_dev" "$BOOT_MNT" || die "cannot mount $boot_dev"
fi
findmnt -n "$BOOT_MNT" >/dev/null 2>&1 || die "$BOOT_MNT is not mounted"

defenv=""
for f in /etc/u-boot-initial-env /etc/u-boot-initial-env-*; do
	[ -f "$f" ] && [ -r "$f" ] || continue
	defenv=$f
	break
done
[ -n "$defenv" ] || die "missing /etc/u-boot-initial-env"

slot=a
ua=0
bc=0
bl=3
if [ -e "$BOOT_MNT/uboot.env" ]; then
	slot=$(fw_printenv -c "$ENV_CFG" -n bootslot 2>/dev/null || printf 'a')
	ua=$(fw_printenv -c "$ENV_CFG" -n upgrade_available 2>/dev/null || printf '0')
	bc=$(fw_printenv -c "$ENV_CFG" -n bootcount 2>/dev/null || printf '0')
	bl=$(fw_printenv -c "$ENV_CFG" -n bootlimit 2>/dev/null || printf '3')
fi

envsize=65536
if [ -r "$ENV_CFG" ]; then
	sz=$(awk '!/^#/ && NF >= 3 { print $3; exit }' "$ENV_CFG" 2>/dev/null || true)
	case "$sz" in
	0x*|0X*) envsize=$(printf '%d' "$sz") ;;
	[0-9]*) envsize=$sz ;;
	esac
fi

printf 'ab-fixenv: re-seeding from %s (bootslot=%s)\n' "$defenv" "$slot"
rm -f "$BOOT_MNT/uboot.env"
dd if=/dev/zero of="$BOOT_MNT/uboot.env" bs="$envsize" count=1
sync
fw_setenv -c "$ENV_CFG" -f "$defenv" bootslot "$slot"
fw_setenv -c "$ENV_CFG" upgrade_available "$ua"
fw_setenv -c "$ENV_CFG" bootcount "$bc"
fw_setenv -c "$ENV_CFG" bootlimit "$bl"
fw_printenv -c "$ENV_CFG" -n bootcmd >/dev/null 2>&1 || die "bootcmd still missing"
printf 'ab-fixenv: OK — bootcmd restored, bootslot=%s\n' "$slot"
