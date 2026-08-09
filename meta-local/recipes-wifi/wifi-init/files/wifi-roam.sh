#!/bin/sh
# =============================================================================
# wifi-roam — pick the strongest configured WiFi network by measured RSSI
# =============================================================================
#
# Why a separate daemon instead of only priority= in wpa_supplicant.conf
# ----------------------------------------------------------------------
# priority= helps the *first* association. Stock wpa_supplicant will not leave
# an already-COMPLETED BSS for another configured SSID just because that one
# is louder in scan. This daemon periodically compares real levels across
# every network block in wpa_supplicant and switches when another is
# meaningfully stronger.
#
# Scheme
# ------
# Every INTERVAL_SEC (while wpa_state=COMPLETED):
#   1) trigger a scan and wait briefly for results;
#   2) for each configured network (wpa_cli list_networks), take best scan
#      RSSI for its SSID;
#   3) for the *current* SSID prefer signal_poll AVG_RSSI/RSSI when available;
#   4) if another network beats the current one by at least MARGIN_DB →
#      select_network(that id).
#
# select_network disables other network{} blocks on purpose so wpa priority
# cannot yank us back before the next compare cycle. After a failed switch,
# enable_network all restores all candidates.
#
# MARGIN_DB hysteresis avoids flapping when levels are within a few dB.
# On a tie (difference < margin), stay on the current association.
#
# Env: IFACE, MARGIN_DB, INTERVAL_SEC, SCAN_WAIT_SEC
# =============================================================================
set -eu

IFACE="${IFACE:-wlan0}"
# Switch only if another network is at least this many dB stronger.
MARGIN_DB="${MARGIN_DB:-6}"
INTERVAL_SEC="${INTERVAL_SEC:-20}"
SCAN_WAIT_SEC="${SCAN_WAIT_SEC:-4}"

log() { printf 'wifi-roam: %s\n' "$*"; }

# Configured networks: "id<TAB>ssid" (ssid may contain spaces).
list_nets() {
	wpa_cli -i "$IFACE" list_networks 2>/dev/null | awk -F '\t' '
		NR > 1 && $2 != "" { print $1 "\t" $2 }
	'
}

net_count() {
	list_nets | wc -l | tr -d ' \t'
}

cur_ssid() {
	wpa_cli -i "$IFACE" status 2>/dev/null | sed -n 's/^ssid=//p' | tr -d '\r'
}

cur_rssi() {
	# AVG_RSSI is steadier than instant RSSI on brcmfmac with sparse polls.
	poll=$(wpa_cli -i "$IFACE" signal_poll 2>/dev/null || true)
	avg=$(printf '%s\n' "$poll" | sed -n 's/^AVG_RSSI=//p' | tr -d '\r' | head -n1)
	if [ -n "$avg" ]; then
		printf '%s\n' "$avg"
	else
		printf '%s\n' "$poll" | sed -n 's/^RSSI=//p' | tr -d '\r' | head -n1
	fi
}

scan_level() {
	# Best (least negative) level for SSID from the last scan_results.
	# Format: bssid / freq / signal / flags / ssid (may contain spaces).
	ssid=$1
	wpa_cli -i "$IFACE" scan_results 2>/dev/null | awk -v s="$ssid" '
		NR > 1 {
			level = $3
			name = $5
			for (i = 6; i <= NF; i++) name = name " " $i
			if (name == s) {
				if (best == "" || level + 0 > best + 0) best = level
			}
		}
		END { if (best != "") print best }
	'
}

wait_completed() {
	i=0
	while [ "$i" -lt 30 ]; do
		st=$(wpa_cli -i "$IFACE" status 2>/dev/null | sed -n 's/^wpa_state=//p' | tr -d '\r' || true)
		[ "$st" = "COMPLETED" ] && return 0
		i=$((i + 1))
		sleep 1
	done
	return 1
}

switch_to() {
	# select_network: pick one network and disable the rest — see header on flap.
	nid=$1
	label=$2
	[ -n "$nid" ] || return 1
	log "switching to '$label' (network $nid)"
	wpa_cli -i "$IFACE" select_network "$nid" >/dev/null 2>&1 || return 1
	if wait_completed; then
		udhcpc -i "$IFACE" -n -q -t 5 -T 2 >/dev/null 2>&1 || true
		log "associated to '$label'"
		return 0
	fi
	log "switch to '$label' failed; re-enabling all networks"
	wpa_cli -i "$IFACE" enable_network all >/dev/null 2>&1 || true
	return 1
}

# Return 0 if $1 is stronger than $2 by at least MARGIN_DB (dBm; higher = better).
stronger_by_margin() {
	cand=$1
	cur=$2
	[ -n "$cand" ] && [ -n "$cur" ] || return 1
	[ "$((cand - cur))" -ge "$MARGIN_DB" ]
}

while true; do
	n=$(net_count || echo 0)
	if [ "$n" -ge 1 ]; then
		break
	fi
	log "waiting for configured wpa networks"
	sleep 3
done
log "ready: $(net_count) configured network(s), margin=${MARGIN_DB}dB interval=${INTERVAL_SEC}s"

while true; do
	sleep "$INTERVAL_SEC"
	st=$(wpa_cli -i "$IFACE" status 2>/dev/null | sed -n 's/^wpa_state=//p' | tr -d '\r' || true)
	[ "$st" = "COMPLETED" ] || continue

	cur=$(cur_ssid || true)
	[ -n "$cur" ] || continue

	wpa_cli -i "$IFACE" scan >/dev/null 2>&1 || true
	sleep "$SCAN_WAIT_SEC"

	assoc=$(cur_rssi || true)
	best_id=
	best_ssid=
	best_lvl=
	cur_lvl=
	levels=

	# IFS=tab so SSID may contain spaces.
	while IFS="$(printf '\t')" read -r id ssid; do
		[ -n "$id" ] && [ -n "$ssid" ] || continue
		lvl=$(scan_level "$ssid" || true)
		if [ "$ssid" = "$cur" ] && [ -n "$assoc" ]; then
			lvl=$assoc
		fi
		[ -n "$lvl" ] || continue

		levels="${levels}${levels:+ }'${ssid}'=${lvl}dBm"
		if [ "$ssid" = "$cur" ]; then
			cur_lvl=$lvl
		fi
		if [ -z "$best_lvl" ] || [ "$lvl" -gt "$best_lvl" ]; then
			best_lvl=$lvl
			best_id=$id
			best_ssid=$ssid
		fi
	done <<EOF
$(list_nets)
EOF

	log "levels:${levels:- none} current='$cur'"

	[ -n "$best_id" ] && [ -n "$best_lvl" ] || continue
	[ -n "$cur_lvl" ] || continue
	[ "$best_ssid" != "$cur" ] || continue

	if stronger_by_margin "$best_lvl" "$cur_lvl"; then
		log "'$best_ssid' stronger ($best_lvl vs $cur_lvl, margin=${MARGIN_DB}) -> switch"
		switch_to "$best_id" "$best_ssid" || true
	fi
done
