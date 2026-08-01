# Host scripts

Helpers for building, flashing, and verifying A/B updates. Run from the
repository root (paths below are relative to the repo root).

On-target tools (`ab-update`, `ab-confirm`, …) are documented in the top-level
[README](../../README.md).

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
meta-local/scripts/push-ab-update.sh
```

No positional arguments. Override via environment:

| Env | Default | Description |
|-----|---------|-------------|
| `TARGET` | `root@192.168.3.71` | SSH target |
| `SSH_KEY` | `meta-local/recipes-core/root-ssh-keys/files/id_ed25519` | Private key for root |
| `REMOTE_DIR` | `/data/update` | Remote directory for the bundle |
| `BUNDLE_NAME` | `khepri-ab-update.tar.gz` | Bundle file name on the device |
| `SSH_WAIT_SEC` | `300` | Max seconds to wait for SSH after reboot |

SSH exit code `255` from `ab-update` is treated as the expected reboot drop;
final success still requires the post-reboot checks above.

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
