# Persist selected /var trees on the GPT data partition (F2FS) instead of
# tmpfs. Stock WIC/Poky volatile-binds default to /var/volatile/*; we remap
# lib/log onto /data and keep cache, spool, and /srv RAM-backed.
#
# mount-copybind prefers OverlayFS (lowerdir = RO seed on rootfs, upperdir =
# /data/var/...), falling back to copy+bind if overlay is unavailable.

VOLATILE_BINDS:orange-pi-3 = "\
    /data/var/lib ${localstatedir}/lib\n\
    /data/var/log ${localstatedir}/log\n\
    ${localstatedir}/volatile/spool ${localstatedir}/spool\n\
    ${localstatedir}/volatile/cache ${localstatedir}/cache\n\
    ${localstatedir}/volatile/srv /srv\n\
"
