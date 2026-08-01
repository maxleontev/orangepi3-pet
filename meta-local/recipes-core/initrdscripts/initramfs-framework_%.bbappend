# Override stock initramfs-framework init so fatal() reboots instead of hanging.
# Required for A/B: corrupt inactive rootfs must reboot so U-Boot bootcount
# can exceed bootlimit and roll back.
FILESEXTRAPATHS:prepend := "${THISDIR}/initramfs-framework:"
