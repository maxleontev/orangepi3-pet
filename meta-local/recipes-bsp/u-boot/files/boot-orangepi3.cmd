# Orange Pi 3 (non-LTS) FIT boot script — GPT partition layout (A/B-ready).
#
# GPT partition names (PARTLABEL / U-Boot part name):
#   boot      — FAT, holds fitImage + boot.scr
#   rootfs_a  — ext4, active system root (slot A), mounted read-only
#   rootfs_b  — ext4, inactive slot B (unused until A/B switching)
#   data      — F2FS, mounted read-write at /data (relatime,discard) by fstab
#
# SPL+U-Boot live at 128 KiB (past the GPT entry array). Load FIT at
# kernel_comp_addr_r so gzip decompress does not overwrite the FIT.

setenv bootpart 1
part number mmc ${devnum} boot bootpart
setenv bootargs console=${console} console=tty1 root=PARTLABEL=rootfs_a rootfstype=ext4 ro rootflags=noatime rootwait panic=10 ${extra}
load mmc ${devnum}:${bootpart} ${kernel_comp_addr_r} fitImage || load mmc ${devnum}#boot ${kernel_comp_addr_r} fitImage
bootm ${kernel_comp_addr_r}
