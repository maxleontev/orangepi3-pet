#!/bin/sh
# =============================================================================
# wifi-roam — prefer 5 GHz, fall back to 2.4 when RSSI is weak
# =============================================================================
#
# Why a separate daemon instead of only priority= in wpa_supplicant.conf
# ----------------------------------------------------------------------
# In conf:
#   Chuck Norris_5G  priority=20
#   Chuck Norris     priority=10
#   bgscan="simple:30:-70:300"
#
# priority picks well on *first* association (if 5G is visible, take it). But
# stock wpa_supplicant will NOT leave an already-COMPLETED BSS for another SSID
# just because RSSI is poor: "weak but still holding" on 5G stays put even when
# 2.4 next door is louder and more stable.
#
# Desired product behaviour:
#   - prefer Chuck Norris_5G when it is good enough;
#   - on weak 5G, force Chuck Norris (2.4);
#   - return to 5G only when a scan again shows an acceptable level
#     (hysteresis, no 5G↔2.4 flap).
#
# Scheme
# ------
# After wifi.service (PartOf/After), loop forever:
#   - on 5G and RSSI <= RSSI_BAD  → select_network(2.4);
#   - on 2.4 and scan(5G) >= RSSI_GOOD → select_network(5G).
#
# select_network disables other network{} blocks — intentional:
# if after falling back to 2.4 we enable_network all again while priority=20
# is live, wpa immediately pulls back onto weak 5G and flaps. While we sit on
# the fallback band, 5G stays disabled until a scan confirms RSSI_GOOD.
#
# Problems this closes
# --------------------
# 1. "Two networks in conf, but always 2.4"
#    Early wifi-connect used select_network 0 while 2.4 was network id 0 —
#    5G was effectively disabled during connect and after. Connect no longer
#    pins an id; boot uses priority, then this daemon.
#
# 2. "priority is set — why stay on weak 5G?"
#    wpa_supplicant limit: priority ≠ RSSI roaming across different SSIDs.
#    On the board after boot we saw 5G at RSSI≈-77; this script moved to 2.4
#    (bad=-75); 5G scan -77 < good=-68 — do not return yet.
#
# 3. Band flapping
#    Split bad/good thresholds (default -75 / -68) and INTERVAL_SEC.
#    Switch only from COMPLETED; ignore SCANNING/DISCONNECT.
#
# 4. Address loss after BSS change
#    After a successful switch — short udhcpc (same L2/LAN often keeps the
#    address, but lease/routes may be stale).
#
# 5. Failed switch
#    If COMPLETED never arrives — enable_network all so we do not remain with
#    one disabled set and endless SCANNING.
#
# 6. Dependency on wifi-connect
#    Wait until both network ids appear in list_networks (wpa already on our
#    conf). Unit: After/Requires/PartOf=wifi.service — stopping wifi stops roam.
#
# 7. RF/HDMI context (see wifi-connect)
#    2.4 drop after DRM load is an image-level story. Roam does not fix RF, but
#    on 5G RSSI degradation it gives a predictable fallback to 2.4.
#
# Env: IFACE, SSID_5G, SSID_24, RSSI_BAD, RSSI_GOOD, INTERVAL_SEC
# Thresholds are dBm (more negative = weaker). Example: bad=-75, good=-68.
# =============================================================================
set -eu

IFACE="${IFACE:-wlan0}"
SSID_5G="${SSID_5G:-Chuck Norris_5G}"
SSID_24="${SSID_24:-Chuck Norris}"
# Leave 5G when current RSSI is at or below this threshold.
RSSI_BAD="${RSSI_BAD:--75}"
# Return to 5G only when scan_results level is at least this good.
RSSI_GOOD="${RSSI_GOOD:--68}"
INTERVAL_SEC="${INTERVAL_SEC:-20}"

log() { printf 'wifi-roam: %s\n' "$*"; }

nid_by_ssid() {
	# list_networks: id \t ssid \t ... — SSID may contain spaces (Chuck Norris).
	wpa_cli -i "$IFACE" list_networks 2>/dev/null \
		| awk -F '\t' -v s="$1" 'NR > 1 && $2 == s { print $1; exit }'
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
	log "switching to $label (network $nid)"
	wpa_cli -i "$IFACE" select_network "$nid" >/dev/null 2>&1 || return 1
	if wait_completed; then
		udhcpc -i "$IFACE" -n -q -t 5 -T 2 >/dev/null 2>&1 || true
		log "associated to $label"
		return 0
	fi
	log "switch to $label failed; re-enabling all networks"
	wpa_cli -i "$IFACE" enable_network all >/dev/null 2>&1 || true
	return 1
}

NID_5G=
NID_24=
while [ -z "$NID_5G" ] || [ -z "$NID_24" ]; do
	NID_5G=$(nid_by_ssid "$SSID_5G" || true)
	NID_24=$(nid_by_ssid "$SSID_24" || true)
	if [ -n "$NID_5G" ] && [ -n "$NID_24" ]; then
		break
	fi
	log "waiting for wpa networks ($SSID_5G=$NID_5G $SSID_24=$NID_24)"
	sleep 3
done
log "ready: 5G=id$NID_5G 2.4=id$NID_24 thresholds bad=$RSSI_BAD good=$RSSI_GOOD"

while true; do
	sleep "$INTERVAL_SEC"
	st=$(wpa_cli -i "$IFACE" status 2>/dev/null | sed -n 's/^wpa_state=//p' | tr -d '\r' || true)
	[ "$st" = "COMPLETED" ] || continue

	ssid=$(cur_ssid || true)
	rssi=$(cur_rssi || true)

	case "$ssid" in
		"$SSID_5G")
			if [ -n "$rssi" ] && [ "$rssi" -le "$RSSI_BAD" ]; then
				log "5G weak (RSSI=$rssi <= $RSSI_BAD) -> 2.4"
				switch_to "$NID_24" "$SSID_24" || true
			fi
			;;
		"$SSID_24")
			# On fallback band 5G is disabled (select_network) — judge air via scan.
			wpa_cli -i "$IFACE" scan >/dev/null 2>&1 || true
			sleep 4
			lvl=$(scan_level "$SSID_5G" || true)
			if [ -n "$lvl" ] && [ "$lvl" -ge "$RSSI_GOOD" ]; then
				log "5G recovered (scan=$lvl >= $RSSI_GOOD) -> 5G"
				switch_to "$NID_5G" "$SSID_5G" || true
			fi
			;;
		*)
			;;
	esac
done
