#!/bin/bash
# Pack a local A/B update bundle from a Yocto deploy directory.
#
# Default deploy path matches this project's build-orangepi3 layout.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
DEPLOY="${DEPLOY:-$ROOT/build-orangepi3/tmp/deploy/images/orange-pi-3}"
OUT="${1:-$PWD/khepri-ab-update.tar.gz}"

IMAGE_BASENAME="core-image-khepri-orange-pi-3.rootfs"
EXT4="$DEPLOY/${IMAGE_BASENAME}.ext4"
# Prefer FIT that embeds the initramfs used by the image.
FIT=$(ls -1 "$DEPLOY"/fitImage-core-image-initramfs-boot-orange-pi-3-orange-pi-3 2>/dev/null | head -n1 || true)
if [ -z "$FIT" ]; then
	FIT=$(readlink -f "$DEPLOY/fitImage" 2>/dev/null || true)
fi

[ -f "$EXT4" ] || { echo "missing $EXT4" >&2; exit 1; }
[ -n "$FIT" ] && [ -f "$FIT" ] || { echo "missing fitImage in $DEPLOY" >&2; exit 1; }

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
# Deploy dir uses symlinks — dereference so the tarball contains real payloads.
cp -L "$EXT4" "$STAGE/rootfs.ext4"
cp -L "$FIT" "$STAGE/fitImage"

mkdir -p "$(dirname "$OUT")"
tar -C "$STAGE" -czf "$OUT" rootfs.ext4 fitImage
echo "wrote $OUT"
echo "  rootfs.ext4=$(wc -c < "$STAGE/rootfs.ext4" | tr -d ' \t\n') bytes"
echo "  fitImage=$(wc -c < "$STAGE/fitImage" | tr -d ' \t\n') bytes"
echo "Apply on device: ab-update $OUT"
