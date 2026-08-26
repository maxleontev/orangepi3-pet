# Host scripts

Helpers for building, flashing, and verifying A/B updates. Run from the
repository root (paths below are relative to the repo root).

On-target tools (`ab-update`, `ab-confirm`, `hdmi-screenshot`, …) are
documented in the top-level [README](../../README.md).

## `make-ab-update-bundle.sh`

Packs a local A/B update bundle (`rootfs.ext4` + `fitImage`) from the Yocto
deploy directory.

```bash
meta-local/scripts/make-ab-update-bundle.sh [OUT.tar.gz]
```

| Argument / env | Default | Description |
|----------------|---------|-------------|
| `OUT` (optional positional) | `$PWD/khepri-ab-update.tar.gz` | Output archive path |
| `DEPLOY` | `build-orangepi3/tmp/deploy/images/orange-pi-3` | Deploy directory with `.ext4` and FIT |

Apply on the board with `ab-update`.

## `push-ab-update.sh`

Builds a bundle, uploads it over SSH as root, runs `/usr/sbin/ab-update` on
the board, waits for reboot, and verifies the new slot booted and was
confirmed (`upgrade_available=0`, `bootcount=0`, slot switched). Prints one of:

- `RESULT: PASS`
- `RESULT: FAIL (SSH unreachable)` — board did not return within `SSH_WAIT_SEC`
- `RESULT: FAIL (verification didn't pass)` — SSH up, but slot/confirm checks failed

```bash
SSH_BIND=192.168.3.6 meta-local/scripts/push-ab-update.sh
```

No positional arguments. Override via environment:

| Env | Default | Description |
|-----|---------|-------------|
| `TARGET` | `root@192.168.3.71` | SSH target |
| `SSH_KEY` | `meta-local/recipes-core/root-ssh-keys/files/id_ed25519` | Private key for root |
| `SSH_BIND` | | Bind address when the host has dual NICs (`192.168.3.6` ethernet, `192.168.3.37` WiFi) |
| `REMOTE_DIR` | `/data/update` | Remote directory for the bundle |
| `BUNDLE_NAME` | `khepri-ab-update.tar.gz` | Bundle file name on the device |
| `SSH_WAIT_SEC` | `300` | Max seconds to wait for SSH after reboot |

SSH exit code `255` from `ab-update` is treated as the expected reboot drop;
final success still requires the post-reboot checks above.

## `pull-hdmi-screenshot.sh`

SSHs to the board, runs `/usr/sbin/hdmi-screenshot` (info-panel SHM dump), and
saves the PNG on the host. Existing files are not overwritten: if `hdmi.png`
is present, the next shot is `hdmi-0001.png`, then `hdmi-0002.png`, and so on.

```bash
SSH_BIND=192.168.3.6 meta-local/scripts/pull-hdmi-screenshot.sh /tmp/hdmi.png
```

| Argument / env | Default | Description |
|----------------|---------|-------------|
| `OUT` (optional positional) | `$PWD/hdmi.png` | Local PNG path (auto-numbered if taken) |
| `TARGET` | `root@192.168.3.71` | SSH target |
| `SSH_KEY` | `meta-local/recipes-core/root-ssh-keys/files/id_ed25519` | Private key for root |
| `SSH_BIND` | | Bind address when the host has dual NICs |
| `TIMEOUT_SEC` | `8` | Seconds for info-panel to write the frame on the board |

Requires a live `info-panel` on the target. This is the compositor client buffer,
not a photograph of the monitor.

## `run-ac200-mic-hdmi-play.sh`

SSHs to the board and runs `/usr/sbin/ac200-mic-hdmi-play`: record AC200 MIC1,
then play that WAV over HDMI (monitor speakers). Stops `info-panel` for the
capture and starts it again after playback.

```bash
DURATION_SEC=20 SSH_BIND=192.168.3.6 meta-local/scripts/run-ac200-mic-hdmi-play.sh
```

| Env | Default | Description |
|-----|---------|-------------|
| `DURATION_SEC` | `5` | Capture length in seconds |
| `STOP_INFO_PANEL` | `1` | Stop info-panel around capture |
| `KEEP_WAV` | `0` | Keep temp WAV on the board |
| `TARGET` | `root@192.168.3.71` | SSH target |
| `SSH_KEY` | `meta-local/recipes-core/root-ssh-keys/files/id_ed25519` | Private key for root |
| `SSH_BIND` | | Bind address when the host has dual NICs |

## `test-ab-update-scheme.sh`

End-to-end A/B verification over SSH against a live board:

1. Build and apply a **good** bundle → expect slot switch and `ab-confirm`
   (`upgrade_available=0`, `bootcount=0`).
2. Build and apply a **bad-rootfs** bundle (valid FIT, corrupt `rootfs.ext4`) →
   expect automatic rollback to the previous healthy slot (initramfs reboot +
   `bootcount` / `bootlimit`).
3. Build and apply a **bad-FIT** bundle (valid `rootfs.ext4`, corrupt `fitImage`)
   → expect the same rollback. Requires `boot.scr` that `reset`s on `bootm`
   failure while `upgrade_available=1` (otherwise U-Boot drops to `=>` and
   never advances `bootcount`).

```bash
meta-local/scripts/test-ab-update-scheme.sh
```

Prints full snapshots (cmdline, PARTLABEL/PARTUUID, U-Boot env, `/boot`
artifacts, mounts). Removes a stale SSH host key for `TARGET` first (common
after reflash).

| Env | Default | Description |
|-----|---------|-------------|
| `TARGET` | `root@192.168.3.71` | SSH target |
| `SSH_KEY` | `meta-local/recipes-core/root-ssh-keys/files/id_ed25519` | Root private key |
| `REMOTE_DIR` | `/data/update` | Remote directory for bundles |
| `DEPLOY` | `build-orangepi3/tmp/deploy/images/orange-pi-3` | Deploy dir for good/bad artifacts |
| `SSH_WAIT_SEC` | `300` | Max seconds to wait for SSH after each reboot |
| `SKIP_GOOD=1` | | Skip the good-bundle test |
| `SKIP_BAD_ROOTFS=1` | | Skip the bad-rootfs rollback test |
| `SKIP_BAD_FIT=1` | | Skip the bad-FIT rollback test |

Exit status is non-zero if any enabled test fails or SSH does not return in time.

## `cp_d`

Flashes the latest deployed `.wic.gz` to a block device (default `/dev/sda`).

```bash
meta-local/scripts/cp_d
```

Uses image
`build-orangepi3/tmp/deploy/images/orange-pi-3/core-image-khepri-orange-pi-3.rootfs.wic.gz`.
Requires `sudo` for `dd`. Override target with `DEST=/dev/sdX` or deploy dir with
`DEPLOY=...`.

## `f_cl_d`

Wipes a block device with zeros (default `/dev/sda`). Destructive; requires
`sudo`. Override with `DEST=/dev/sdX`.

## `instll`

Commented notes for host package install and cloning Poky / OE / meta-sunxi /
meta-arm (scarthgap).
