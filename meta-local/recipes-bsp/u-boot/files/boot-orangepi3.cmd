# Orange Pi 3 (non-LTS) FIT boot script.
#
# MMC numbering differs between U-Boot and Linux on this board:
#   U-Boot mmc0 (4020000) = SD slot   -> Linux mmcblk2
#   U-Boot mmc1 (4022000) = eMMC      -> Linux mmcblk1
#   U-Boot mmc2 (4021000) = WiFi SDIO -> Linux mmcblk0 (no partitions)
#
# The SPL stores the boot source in SRAM at offset 0x28:
#   0x00 = SD (mmc0)  -> rootdev=mmcblk2p2
#   0x02 = eMMC (mmc1) -> rootdev=mmcblk1p2
#
# Boot payload is a single FIT image (kernel + DTB + minimal initramfs).
# Load FIT at kernel_comp_addr_r (0x44000000), NOT kernel_addr_r
# (0x40080000): the gzip-compressed kernel decompresses to ~0x40008000
# and would overwrite a FIT sitting at kernel_addr_r (inflate -3).
rootdev=mmcblk2p2
if itest.b *0x28 == 0x02 ; then
	echo "U-Boot loaded from eMMC"
	rootdev=mmcblk1p2
fi
setenv bootargs console=${console} console=tty1 root=/dev/${rootdev} rootwait panic=10 ${extra}
load mmc ${devnum}:1 ${kernel_comp_addr_r} fitImage || load mmc ${devnum}:1 ${kernel_comp_addr_r} boot/fitImage
bootm ${kernel_comp_addr_r}
