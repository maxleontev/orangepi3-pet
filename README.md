# Orange Pi 3 Yocto Build

This repository contains a Yocto Project setup for building a custom Linux
distribution for the **Orange Pi 3** single-board computer (image
`core-image-khepri`).

## Scripts

Host-side helpers live under [`meta-local/scripts/`](meta-local/scripts/) —
see [`meta-local/scripts/README.md`](meta-local/scripts/README.md).

On-target tools are installed into the image as `/usr/sbin/*` from
`meta-local/recipes-support/`.

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

## Build & flash

`local.conf` must include the graphics distro fragment:

```bash
# build-orangepi3/conf/local.conf
require conf/distro/include/orangepi3-graphics.inc
```

Then build and push an A/B update over SSH:

```bash
bitbake core-image-khepri
SSH_BIND=192.168.3.37 meta-local/scripts/push-ab-update.sh   # if dual-NIC host
```

Expect a larger rootfs than a WiFi-only image (Weston, Mesa, fonts, DRM modules).
HDMI stack details: [`meta-local/recipes-graphics/README.md`](meta-local/recipes-graphics/README.md).
