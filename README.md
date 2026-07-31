# Orange Pi 3 Yocto Build

This repository contains a Yocto Project setup for building a custom Linux
distribution for the **Orange Pi 3** single-board computer (image
`core-image-khepri`).

## Scripts

Host-side helpers live under `meta-local/scripts/` and `scripts/`.
On-target tools are installed into the image as `/usr/sbin/*` from
`meta-local/recipes-support/`.

### Host: `meta-local/scripts/make-ab-update-bundle.sh`

Packs a local A/B update bundle (`rootfs.ext4` + `fitImage`) from the Yocto
deploy directory.

```bash
meta-local/scripts/make-ab-update-bundle.sh [OUT.tar.gz]
```

| Argument / env | Default | Description |
|----------------|---------|-------------|
| `OUT` (optional positional) | `$PWD/khepri-ab-update.tar.gz` | Output archive path |
| `DEPLOY` | `build-orangepi3/tmp/deploy/images/orange-pi-3` | Deploy directory with `.ext4` and FIT |

Apply on the board with `ab-update` (see below).

### Host: `meta-local/scripts/push-ab-update.sh`

Builds a bundle, uploads it over SSH as root, syncs the latest `ab-update`
tools to `/data/update/tools/`, runs the update, and reboots the board.

```bash
meta-local/scripts/push-ab-update.sh
```

No positional arguments. Override via environment:

| Env | Default | Description |
|-----|---------|-------------|
| `TARGET` | `root@192.168.3.71` | SSH target |
| `SSH_KEY` | `meta-local/recipes-core/root-ssh-keys/files/id_ed25519` | Private key for root |
| `REMOTE_DIR` | `/data/update` | Remote directory for bundle and tools |
| `BUNDLE_NAME` | `khepri-ab-update.tar.gz` | Bundle file name on the device |

SSH exit code `255` after reboot is treated as success (connection dropped).

### Host: `scripts/cp_d`

Flashes the latest deployed `.wic.gz` to a block device (default `/dev/sda`).

```bash
cd scripts && ./cp_d
```

Uses image
`build-orangepi3/tmp/deploy/images/orange-pi-3/core-image-khepri-orange-pi-3.rootfs.wic.gz`.
Requires `sudo` for `dd`. No CLI flags — edit the script to change the target
device or image name.

### On target: `ab-update` (`/usr/sbin/ab-update`)

Writes a local bundle into the **inactive** A/B slot (`rootfs` + `fitImage_{a|b}`),
sets U-Boot env (`bootslot`, `upgrade_available=1`, `bootcount=0`), then reboots.

```bash
ab-update [--yes] [--no-reboot] BUNDLE
```

| Argument / env | Description |
|----------------|-------------|
| `BUNDLE` | Directory, or `.tar` / `.tar.gz` / `.tgz` containing `rootfs.ext4` and `fitImage` |
| `--yes` / `-y` | Skip confirmation (`YES=1`) |
| `--no-reboot` | Do not reboot after switching slot (`REBOOT=0`) |
| `FW_ENV_CONFIG` | Path to `fw_env.config` (default `/etc/fw_env.config`) |
| `BOOT_MNT` | Boot mountpoint (default `/boot`) |

Must run as root. Remounts `/boot` onto the boot partition of the **same disk
as live root** when `LABEL=boot` is ambiguous (SD + eMMC).

### On target: `ab-confirm` (`/usr/sbin/ab-confirm`)

Clears `upgrade_available` / `bootcount` after a successful boot so U-Boot will
not roll back. Invoked automatically by `ab-confirm.service` at multi-user.

```bash
ab-confirm
```

| Env | Default | Description |
|-----|---------|-------------|
| `FW_ENV_CONFIG` | `/etc/fw_env.config` | libubootenv config |
| `BOOT_MNT` | `/boot` | Boot mountpoint (remounted onto root disk if needed) |

No positional arguments. Exits quietly if there is no pending upgrade.

### On target: `ab-fixenv` (`/usr/sbin/ab-fixenv`)

Repairs a sparse `/boot/uboot.env` that is missing `bootcmd` (U-Boot drops to
the `=>` prompt). Re-seeds from `/etc/u-boot-initial-env` and preserves
`bootslot` / upgrade flags when possible.

```bash
ab-fixenv
```

| Env | Default | Description |
|-----|---------|-------------|
| `FW_ENV_CONFIG` | `/etc/fw_env.config` | libubootenv config |
| `BOOT_MNT` | `/boot` | Boot mountpoint |

Must run as root. No positional arguments.

### On target: `sd-to-emmc` (`/usr/sbin/sd-to-emmc`)

Clones the running SD GPT layout (SPL @ 128 KiB, boot / rootfs_a / rootfs_b /
data) onto onboard eMMC and optionally grows the F2FS data partition.

```bash
sd-to-emmc [--yes] [--no-grow] [SRC DST]
```

| Argument / env | Default | Description |
|----------------|---------|-------------|
| `SRC` | `/dev/mmcblk2` | Source (SD) |
| `DST` | `/dev/mmcblk1` | Destination (eMMC) |
| `--yes` / `-y` | | Skip confirmation (`YES=1`) |
| `--no-grow` | | Do not expand data to end of eMMC (`GROW_DATA=0`) |

Must run as root. After success: power off, remove the SD card, power on
(BROM prefers SD if the card is still inserted).

## Active A/B slot

Boot uses `root=PARTUUID=…` (not `PARTLABEL`) so SD and eMMC do not clash.
Check the running slot with:

```bash
lsblk -no PARTLABEL "$(findmnt -n -o SOURCE / | xargs -r readlink -f)"
# or
fw_printenv -n bootslot
```
