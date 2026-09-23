# Orange Pi 3 Yocto Build

This repository contains a Yocto Project setup for building a custom Linux
distribution for the **Orange Pi 3** single-board computer (image
`core-image-khepri`).

## First-time setup

After a clone, two local files are missing on purpose (they are gitignored)
and the board does not yet run this image. Create the files, build in
`build-orangepi3/`, and write the WIC image to an SD card. Later updates go
over SSH; that path is not the first flash.

1. Create the root SSH key
   ([`gen-root-ssh-key.sh`](meta-local/scripts/README.md#gen-root-ssh-key)).
   The image installs the public half as root's `authorized_keys`. SSH is
   key-only.

2. Create the console password
   ([`gen-khepri-passwd.sh`](meta-local/scripts/README.md#gen-khepri-passwd)).
   The image recipe refuses to parse until
   `meta-local/recipes-core/images/khepri-user-passwd.inc` exists. The same
   password is set for `root` and user `max`. Console login is `root` with
   that password. Do not commit the file.

3. Install the host packages required to build:

```bash
sudo apt install -y build-essential gawk wget git-core diffstat unzip texinfo \
  chrpath socat cpio python3 python3-pip python3-pexpect xz-utils debianutils \
  iputils-ping python3-git python3-jinja2 python3-subunit zstd liblz4-tool \
  file locales ca-certificates
```

4. Build. Poky, the layers, and `build-orangepi3/conf/` are already in the
   clone, including
   `require conf/distro/include/orangepi3-graphics.inc`. Do not create a
   second build directory.

```bash
source poky/oe-init-build-env build-orangepi3
bitbake core-image-khepri
```

5. Flash the deployed `.wic.gz` to an SD card with
   [`cp_d`](meta-local/scripts/README.md#cp_d) (`DEST` defaults to
   `/dev/sda`). Insert the card and power on.

6. On first boot `/data` has no Wi-Fi networks, so the board opens the setup
   AP (`Khepri-Setup-<mac4>`, `http://192.168.4.1/`). Save a network there;
   see [WiFi](meta-local/recipes-wifi/README.md#setup-web-ui). After it joins
   the LAN, SSH to `root@192.168.3.71` with the key from step 1.

7. To move the install onto onboard eMMC, run
   [`sd-to-emmc`](#sd-to-emmc) from the booted SD system, power off, remove
   the card, and power on.

After this, rebuilds are flashed with
[`push-ab-update.sh`](meta-local/scripts/README.md#push-ab-update), which
needs the board already up and reachable by SSH.

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

Dumps the live HDMI panel frame (last committed Wayland SHM buffer) to PNG.
Installed by whichever panel recipe is in the image (`info-panel` or
`info-panel-camera`). That panel process must be running.
`info-panel-camera` also draws a yellow motion bbox (densest changed
blob; ignores weak/global noise) and, when a hobby servo is on CON12
pin 7 (HW PWM0 / PD22), PID-pans only on fresh blob measurements
(`INFO_PANEL_SERVO=0` disables; `INFO_PANEL_SERVO_INVERT=1` flips pan
direction from the camera-on-servo default).

```bash
hdmi-screenshot                  # TTY: /tmp/hdmi-screenshot.png (prints path)
hdmi-screenshot > /tmp/hdmi.png  # PNG on stdout
hdmi-screenshot /data/hdmi.png
```

| Argument / env | Default | Description |
|----------------|---------|-------------|
| `DEST` (optional positional) | stdout, or `/tmp/hdmi-screenshot.png` on a TTY | Output PNG path |
| `TIMEOUT_SEC` | `8` | Seconds to wait for the panel to write the frame |

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

First clone, first SD flash, and moving the system to eMMC are in
[First-time setup](#first-time-setup). `build-orangepi3/conf/local.conf`
already includes `conf/distro/include/orangepi3-graphics.inc`.

Once the board is up, rebuild with `bitbake core-image-khepri` in
`build-orangepi3/` and flash with
[`push-ab-update.sh`](meta-local/scripts/README.md#push-ab-update).

Expect a larger rootfs than a WiFi-only image (Weston, Mesa, fonts, DRM modules).
HDMI stack details: [`meta-local/recipes-graphics/README.md`](meta-local/recipes-graphics/README.md).
