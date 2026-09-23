#!/bin/bash
# Write the gitignored console password and SHA-256 crypt hash.
#
# core-image-khepri requires the output file and uses KHEPRI_USER_PASSWD
# for root and user max. The plaintext is KHEPRI_CONSOLE_PASSWORD in the
# same file, for the serial console. See
# meta-local/scripts/README.md#gen-khepri-passwd.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)

PASSWD_FILE="${PASSWD_FILE:-$ROOT/meta-local/recipes-core/images/khepri-user-passwd.inc}"
FORCE="${FORCE:-0}"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf '%s\n' "$*"; }

usage() {
	cat <<EOF
Usage: gen-khepri-passwd.sh

Writes the console password and its SHA-256 crypt hash to the gitignored
include that sets KHEPRI_USER_PASSWD. Existing file is kept unless FORCE=1.
Rebuild and flash the image before the board password changes.

Environment:
  PASSWORD=                     # required
  PASSWD_FILE=$ROOT/meta-local/recipes-core/images/khepri-user-passwd.inc
  FORCE=0                       # 1 replaces an existing file
EOF
}

bb_quote() {
	# BitBake treats $ as expansion. Escape \, $, and " for a double-quoted value.
	local s=$1
	s=${s//\\/\\\\}
	s=${s//\$/\\\$}
	s=${s//\"/\\\"}
	printf '%s' "$s"
}

case "${1:-}" in
-h|--help)
	usage
	exit 0
	;;
esac
[ $# -eq 0 ] || die "no positional arguments; see --help"
[ -n "${PASSWORD:-}" ] || die "PASSWORD is required"
command -v openssl >/dev/null 2>&1 || die "openssl not found"

if [ -e "$PASSWD_FILE" ]; then
	[ "$FORCE" = 1 ] || die "password file already exists ($PASSWD_FILE); set FORCE=1 to replace it"
fi

hash=$(openssl passwd -5 "$PASSWORD")
[ -n "$hash" ] || die "openssl passwd failed"

mkdir -p "$(dirname "$PASSWD_FILE")"
umask 077
cat >"$PASSWD_FILE" <<EOF
# Local console password for root and user max. Not committed.
# Regenerate with meta-local/scripts/gen-khepri-passwd.sh.
KHEPRI_CONSOLE_PASSWORD = "$(bb_quote "$PASSWORD")"
KHEPRI_USER_PASSWD = "$(bb_quote "$hash")"
EOF
chmod 600 "$PASSWD_FILE"
log "wrote $PASSWD_FILE"
