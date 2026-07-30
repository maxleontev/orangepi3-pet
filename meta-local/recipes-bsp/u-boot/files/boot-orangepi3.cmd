# Orange Pi 3 (non-LTS) FIT boot script — GPT partition layout.
#
# GPT partition names (PARTLABEL / U-Boot part name):
#   boot   — FAT, holds fitImage + boot.scr
#   rootfs — ext4, mounted read-only by the kernel
#   data   — ext4, mounted read-write at /data by fstab
#
# SPL+U-Boot live at 128 KiB (past the GPT entry array). Load FIT at
# kernel_comp_addr_r so gzip decompress does not overwrite the FIT.

setenv bootpart 1
part number mmc ${devnum} boot bootpart
setenv bootargs console=${console} console=tty1 root=PARTLABEL=rootfs rootfstype=ext4 ro rootflags=noatime rootwait panic=10 ${extra}
load mmc ${devnum}:${bootpart} ${kernel_comp_addr_r} fitImage || load mmc ${devnum}#boot ${kernel_comp_addr_r} fitImage
bootm ${kernel_comp_addr_r}
