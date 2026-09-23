#!/bin/bash
# Generate the local root SSH key for host scripts and the root-ssh-keys recipe.
#
# Writes three gitignored files under the recipe files/ directory:
#   id_ed25519, id_ed25519.pub, authorized_keys
# authorized_keys is a copy of the public key. Existing files are kept
# unless FORCE=1. See meta-local/scripts/README.md#gen-root-ssh-key.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)

KEY_DIR="${KEY_DIR:-$ROOT/meta-local/recipes-core/root-ssh-keys/files}"
KEY_COMMENT="${KEY_COMMENT:-root@orange-pi-3}"
FORCE="${FORCE:-0}"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf '%s\n' "$*"; }

usage() {
	cat <<EOF
Usage: gen-root-ssh-key.sh

Writes id_ed25519, id_ed25519.pub, and authorized_keys. Existing files are
kept unless FORCE=1. After replacing a key, rebuild and flash the image so
the board accepts it.

Environment:
  KEY_DIR=$ROOT/meta-local/recipes-core/root-ssh-keys/files
  KEY_COMMENT=root@orange-pi-3
  FORCE=0                       # 1 replaces an existing key
EOF
}

case "${1:-}" in
-h|--help)
	usage
	exit 0
	;;
esac
[ $# -eq 0 ] || die "no positional arguments; see --help"
command -v ssh-keygen >/dev/null 2>&1 || die "ssh-keygen not found"

priv="$KEY_DIR/id_ed25519"
pub="$KEY_DIR/id_ed25519.pub"
auth="$KEY_DIR/authorized_keys"

if [ -e "$priv" ] || [ -e "$pub" ] || [ -e "$auth" ]; then
	[ "$FORCE" = 1 ] || die "keys already exist in $KEY_DIR (set FORCE=1 to replace them)"
	rm -f "$priv" "$pub" "$auth"
fi

mkdir -p "$KEY_DIR"
ssh-keygen -t ed25519 -f "$priv" -N "" -C "$KEY_COMMENT" -q
cp "$pub" "$auth"
chmod 600 "$priv"
chmod 644 "$pub" "$auth"

log "wrote $priv"
log "wrote $pub"
log "wrote $auth"
ssh-keygen -lf "$pub"
