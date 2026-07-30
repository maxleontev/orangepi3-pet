#
# SPDX-License-Identifier: MIT
#
# Create an empty labeled F2FS filesystem for a WIC partition.
#
# Stock WIC does not accept --fstype=f2fs, so use:
#   part data --source empty-f2fs --fstype=ext4 --label data ...
# (--fstype=ext4 only selects a Linux GPT type; content is F2FS.)
# Prefer a non-/ mountpoint (e.g. "data") so WIC does not write a wrong
# fstab fstype; add the real LABEL=data f2fs line from the image recipe.
#
# Requires f2fs-tools-native on WKS_FILE_DEPENDS.
#

import logging
import os

from wic import WicError
from wic.pluginbase import SourcePlugin
from wic.misc import exec_native_cmd

logger = logging.getLogger('wic')


class EmptyF2FSPlugin(SourcePlugin):
    """Populate an empty F2FS partition image."""

    name = 'empty-f2fs'

    @classmethod
    def do_prepare_partition(cls, part, source_params, cr, cr_workdir,
                             oe_builddir, bootimg_dir, kernel_dir,
                             rootfs_dir, native_sysroot):
        size_kb = part.disk_size
        if not size_kb:
            raise WicError("empty-f2fs: partition size is zero; "
                           "set --size or --fixed-size")

        # F2FS overprovisioning is unreliable well below ~512 MiB.
        if size_kb < 512 * 1024:
            logger.warning("empty-f2fs: size %d KiB is below the usual "
                           "512 MiB F2FS minimum; mkfs.f2fs may fail",
                           size_kb)

        rootfs = os.path.join(cr_workdir, "fs_%s.%s.f2fs" %
                              (part.label or "data", part.lineno))
        if os.path.isfile(rootfs):
            os.remove(rootfs)

        with open(rootfs, 'wb') as sparse:
            os.ftruncate(sparse.fileno(), size_kb * 1024)

        label_str = "-l %s" % part.label if part.label else ""
        uuid_str = "-U %s" % part.fsuuid if part.fsuuid else ""
        extra = part.mkfs_extraopts or ""

        mkfs_cmd = "mkfs.f2fs -f %s %s %s %s" % \
            (label_str, uuid_str, extra, rootfs)
        exec_native_cmd(mkfs_cmd, native_sysroot)

        part.size = size_kb
        part.source_file = rootfs
