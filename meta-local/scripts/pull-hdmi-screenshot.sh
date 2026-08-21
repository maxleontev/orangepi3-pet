#!/bin/bash
# Capture the Orange Pi 3 HDMI info-panel over SSH and save the PNG on the host.
#
# Runs /usr/sbin/hdmi-screenshot on the board (info-panel SHM dump) and writes
# the PNG locally. If the destination already exists, picks the next free name
# with a 4-digit suffix (hdmi.png → hdmi-0001.png → hdmi-0002.png …).
# Defaults match push-ab-update.sh:
#   TARGET=root@192.168.3.71  SSH_KEY=...  SSH_BIND=192.168.3.6
#   OUT=hdmi.png  TIMEOUT_SEC=8
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)

TARGET="${TARGET:-root@192.168.3.71}"
SSH_KEY="${SSH_KEY:-$ROOT/meta-local/recipes-core/root-ssh-keys/files/id_ed25519}"
OUT="${OUT:-${1:-$PWD/hdmi.png}}"
TIMEOUT_SEC="${TIMEOUT_SEC:-8}"

# Optional: SSH_BIND=192.168.3.37 when host has dual NICs and the board is on WiFi.
SSH_OPTS=(
	-i "$SSH_KEY"
	-o IdentitiesOnly=yes
	-o StrictHostKeyChecking=accept-new
	-o BatchMode=yes
	-o ConnectTimeout=10
	-o ServerAliveInterval=5
	-o ServerAliveCountMax=2
)
if [ -n "${SSH_BIND:-}" ]; then
	SSH_OPTS+=(-o "BindAddress=$SSH_BIND")
fi

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf '%s\n' "$*"; }

# If PATH exists, use stem-0001.ext, stem-0002.ext, … (never overwrite).
next_out_path() {
	local path=$1
	local dir name stem ext n cand

	dir=$(dirname "$path")
	name=$(basename "$path")
	case "$name" in
	*.*)
		stem=${name%.*}
		ext=.${name##*.}
		;;
	*)
		stem=$name
		ext=
		;;
	esac

	cand="$dir/$stem$ext"
	if [ ! -e "$cand" ]; then
		printf '%s\n' "$cand"
		return
	fi
	n=1
	while true; do
		cand=$(printf '%s/%s-%04d%s' "$dir" "$stem" "$n" "$ext")
		[ ! -e "$cand" ] && break
		n=$((n + 1))
		[ "$n" -le 9999 ] || die "no free name under ${stem}-NNNN${ext}"
	done
	printf '%s\n' "$cand"
}

usage() {
	cat <<'EOF'
Usage: pull-hdmi-screenshot.sh [OUT.png]

  OUT.png   local path for the PNG (default: ./hdmi.png, or OUT=...)
            Existing files are kept; the next free name is used
            (hdmi.png, hdmi-0001.png, hdmi-0002.png, …).

Environment:
  TARGET=root@192.168.3.71
  SSH_KEY=meta-local/recipes-core/root-ssh-keys/files/id_ed25519
  SSH_BIND=192.168.3.6          # dual-NIC: bind to ethernet or wifi address
  TIMEOUT_SEC=8                 # wait for info-panel on the board
  OUT=hdmi.png
EOF
}

case "${1:-}" in
-h|--help)
	usage
	exit 0
	;;
esac

[ -f "$SSH_KEY" ] || die "SSH private key not found: $SSH_KEY"
command -v ssh >/dev/null || die "ssh not found"

out_dir=$(dirname "$OUT")
mkdir -p "$out_dir"
out_base=$(cd "$out_dir" && pwd)/$(basename "$OUT")
out_abs=$(next_out_path "$out_base")
tmp=$(mktemp "${TMPDIR:-/tmp}/hdmi-XXXXXX.png")
trap 'rm -f "$tmp"' EXIT

log "==> SSH $TARGET → hdmi-screenshot → $out_abs"
set +e
ssh "${SSH_OPTS[@]}" "$TARGET" \
	"command -v hdmi-screenshot >/dev/null || exit 127; TIMEOUT_SEC=$TIMEOUT_SEC hdmi-screenshot" \
	>"$tmp"
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
	[ "$rc" = "127" ] && die "hdmi-screenshot not found on target (flash an image that includes info-panel)"
	die "hdmi-screenshot failed on $TARGET (exit $rc)"
fi

# Reject empty / non-PNG so a remote error text is not saved as "success".
[ -s "$tmp" ] || die "empty response from board"
magic=$(od -An -tx1 -N4 "$tmp" | tr -d ' \n')
[ "$magic" = "89504e47" ] || die "remote output is not a PNG (is info-panel running?)"

mv -f "$tmp" "$out_abs"
trap - EXIT
log "wrote $out_abs ($(wc -c <"$out_abs" | tr -d ' \t') bytes)"
printf '%s\n' "$out_abs"
