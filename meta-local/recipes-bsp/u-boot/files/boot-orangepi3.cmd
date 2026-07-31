# Orange Pi 3 (non-LTS) FIT boot script — GPT A/B layout.
#
# GPT partition names (on the MMC device that U-Boot is booting from):
#   boot      — FAT: boot.scr, fitImage_a/b, uboot.env
#   rootfs_a  — ext4 slot A (RO)
#   rootfs_b  — ext4 slot B (RO)
#   data      — F2FS R/W at /data (fstab)
#
# Root is passed as PARTUUID of the slot partition on *this* MMC (${devnum}),
# not PARTLABEL — identical labels on SD and eMMC would otherwise race.
#
# Slot selection (U-Boot env on FAT uboot.env, also writable via fw_setenv):
#   bootslot           — a|b (default a)
#   upgrade_available  — 1 while a newly selected slot is unconfirmed
#   bootcount          — increments each boot while upgrade_available=1
#   bootlimit          — rollback after this many unconfirmed boots (default 3)
#
# SPL+U-Boot live at 128 KiB. Load FIT at kernel_comp_addr_r so gzip
# decompress does not overwrite the FIT.

setenv bootpart 1
part number mmc ${devnum} boot bootpart

if test -z "${bootslot}"; then setenv bootslot a; fi
if test -z "${upgrade_available}"; then setenv upgrade_available 0; fi
if test -z "${bootcount}"; then setenv bootcount 0; fi
if test -z "${bootlimit}"; then setenv bootlimit 3; fi

if test "${upgrade_available}" = "1"; then
	setexpr bootcount ${bootcount} + 1
	saveenv
	if test ${bootcount} -gt ${bootlimit}; then
		echo "A/B: bootlimit exceeded, rolling back from slot ${bootslot}"
		if test "${bootslot}" = "a"; then
			setenv bootslot b
		else
			setenv bootslot a
		fi
		setenv upgrade_available 0
		setenv bootcount 0
		saveenv
		echo "A/B: now using slot ${bootslot}"
	fi
fi

if test "${bootslot}" = "b"; then
	setenv root_partname rootfs_b
	setenv fitfile fitImage_b
else
	setenv root_partname rootfs_a
	setenv fitfile fitImage_a
fi

# Resolve GPT name → partition number → PARTUUID on the boot MMC only.
part number mmc ${devnum} ${root_partname} rootpart
part uuid mmc ${devnum}:${rootpart} rootuuid

setenv bootargs console=${console} console=tty1 root=PARTUUID=${rootuuid} rootfstype=ext4 ro rootflags=noatime rootwait panic=10 ${extra}

echo "A/B: booting slot ${bootslot} (${fitfile}, ${root_partname} PARTUUID=${rootuuid} on mmc ${devnum})"
load mmc ${devnum}:${bootpart} ${kernel_comp_addr_r} ${fitfile}
bootm ${kernel_comp_addr_r}
