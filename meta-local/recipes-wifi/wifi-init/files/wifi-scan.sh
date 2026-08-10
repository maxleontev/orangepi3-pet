#!/bin/sh
# Scan visible WiFi SSIDs for setup UI. Cache to /run for AP-mode clients.
# Usage: wifi-scan [--cache-only] [--json]
set -eu

IFACE="${IFACE:-wlan0}"
CACHE="${CACHE:-/run/wifi-setup-scan.txt}"
CACHE_ONLY=0
JSON=0

for arg in "$@"; do
	case "$arg" in
		--cache-only) CACHE_ONLY=1 ;;
		--json) JSON=1 ;;
	esac
done

log() { printf 'wifi-scan: %s\n' "$*" >&2; }

parse_iw_scan() {
	# Prefer strongest signal per SSID; skip empty / hidden.
	awk '
		/^BSS / { sig=""; ssid=""; next }
		/signal:/ {
			# "-62.00 dBm" -> -62
			for (i = 1; i <= NF; i++) {
				if ($i ~ /^-?[0-9]+\./) { sig = int($i); break }
			}
			next
		}
		/SSID:/ {
			sub(/^[[:space:]]*SSID:[[:space:]]*/, "")
			ssid = $0
			if (ssid == "" || ssid == "\\x00") next
			# Drop our own setup AP from the picker
			if (ssid ~ /^Khepri-Setup-/) next
			if (!(ssid in best) || sig > best[ssid]) best[ssid] = sig
			next
		}
		END {
			n = 0
			for (s in best) {
				n++
				ssids[n] = s
				sigs[n] = best[s]
			}
			# Insertion sort by signal desc
			for (i = 2; i <= n; i++) {
				s = ssids[i]; g = sigs[i]; j = i - 1
				while (j >= 1 && sigs[j] < g) {
					ssids[j + 1] = ssids[j]
					sigs[j + 1] = sigs[j]
					j--
				}
				ssids[j + 1] = s
				sigs[j + 1] = g
			}
			for (i = 1; i <= n; i++) printf "%s\t%d\n", ssids[i], sigs[i]
		}
	'
}

do_scan() {
	# Scan needs the iface up; may briefly disrupt AP clients on some chips.
	ip link set "$IFACE" up 2>/dev/null || true
	iw dev "$IFACE" set power_save off 2>/dev/null || true
	# brcmfmac can hang forever in iw scan — hard-cap wait.
	outf=/run/wifi-scan-iw.out
	rm -f "$outf"
	iw dev "$IFACE" scan >"$outf" 2>/dev/null &
	pid=$!
	i=0
	while [ "$i" -lt "${SCAN_TIMEOUT_SEC:-8}" ]; do
		kill -0 "$pid" 2>/dev/null || break
		i=$((i + 1))
		sleep 1
	done
	if kill -0 "$pid" 2>/dev/null; then
		log "iw scan timed out after ${SCAN_TIMEOUT_SEC:-8}s"
		kill "$pid" 2>/dev/null || true
		wait "$pid" 2>/dev/null || true
		rm -f "$outf"
		return 1
	fi
	wait "$pid" 2>/dev/null || true
	out=$(cat "$outf" 2>/dev/null || true)
	rm -f "$outf"
	if [ -z "$out" ]; then
		return 1
	fi
	printf '%s\n' "$out" | parse_iw_scan
}

emit_json() {
	printf '['
	first=1
	while IFS= read -r line || [ -n "$line" ]; do
		[ -n "$line" ] || continue
		ssid=${line%%	*}
		sig=${line#*	}
		[ "$sig" != "$line" ] || sig=""
		# Escape JSON string
		esc=$(printf '%s' "$ssid" | sed 's/\\/\\\\/g; s/"/\\"/g')
		if [ "$first" -eq 1 ]; then
			first=0
		else
			printf ','
		fi
		if [ -n "$sig" ]; then
			printf '{"ssid":"%s","signal":%s}' "$esc" "$sig"
		else
			printf '{"ssid":"%s"}' "$esc"
		fi
	done
	printf ']\n'
}

emit_text() {
	while IFS= read -r line || [ -n "$line" ]; do
		[ -n "$line" ] || continue
		printf '%s\n' "${line%%	*}"
	done
}

mkdir -p "$(dirname "$CACHE")"

result=""
if [ "$CACHE_ONLY" -eq 0 ]; then
	if result=$(do_scan); then
		printf '%s\n' "$result" > "$CACHE.new"
		mv -f "$CACHE.new" "$CACHE"
	else
		log "live scan failed or empty; using cache if present"
	fi
fi

if [ ! -f "$CACHE" ]; then
	: > "$CACHE"
fi

if [ "$JSON" -eq 1 ]; then
	emit_json < "$CACHE"
else
	emit_text < "$CACHE"
fi
