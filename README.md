# Orange Pi 3 Yocto Build

This repository contains a Yocto Project setup for building a custom Linux
distribution for the **Orange Pi 3** single-board computer (image
`core-image-khepri`).

## Scripts

Host-side helpers live under [`meta-local/scripts/`](meta-local/scripts/) —
see [`meta-local/scripts/README.md`](meta-local/scripts/README.md).

On-target tools are installed into the image as `/usr/sbin/*` from
`meta-local/recipes-support/`.

<a id="ab-update"></a>
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

<a id="ab-confirm"></a>
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

<a id="sd-to-emmc"></a>
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

<a id="hdmi-screenshot"></a>
### On target: `hdmi-screenshot` (`/usr/sbin/hdmi-screenshot`)

Dumps the live HDMI info-panel frame (last committed Wayland SHM buffer) to PNG.
Installed by the `info-panel` recipe. `info-panel` must be running.

```bash
hdmi-screenshot                  # TTY: /tmp/hdmi-screenshot.png (prints path)
hdmi-screenshot > /tmp/hdmi.png  # PNG on stdout
hdmi-screenshot /data/hdmi.png
```

| Argument / env | Default | Description |
|----------------|---------|-------------|
| `DEST` (optional positional) | stdout, or `/tmp/hdmi-screenshot.png` on a TTY | Output PNG path |
| `TIMEOUT_SEC` | `8` | Seconds to wait for info-panel to write the frame |

This is the compositor client buffer, not a photograph of the monitor.
Host wrapper: [`pull-hdmi-screenshot.sh`](meta-local/scripts/README.md#pull-hdmi-screenshot).

<a id="ac200-mic-hdmi-play"></a>
### On target: `ac200-mic-hdmi-play` (`/usr/sbin/ac200-mic-hdmi-play`)

Records AC200 MIC1 for `DURATION_SEC` seconds (default **5**), then plays that
WAV over HDMI (monitor speakers). Stops `info-panel` for the capture.
Installed by `ac200-audio`.

```bash
DURATION_SEC=20 ac200-mic-hdmi-play
```

Host wrapper: [`run-ac200-mic-hdmi-play.sh`](meta-local/scripts/README.md#run-ac200-mic-hdmi-play).

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

Then build (`bitbake core-image-khepri`) and flash with
[`push-ab-update.sh`](meta-local/scripts/README.md#push-ab-update).

Expect a larger rootfs than a WiFi-only image (Weston, Mesa, fonts, DRM modules).
HDMI stack details: [`meta-local/recipes-graphics/README.md`](meta-local/recipes-graphics/README.md).
