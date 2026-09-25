#!/bin/sh
# =============================================================================
# wifi-watch — recover STA when association or the gateway ping is gone
# =============================================================================
#
# wifi.service is oneshot. wifi-roam only compares RSSI while
# wpa_state=COMPLETED, so a drop to SCANNING keeps a stale IPv4 and
# never comes back.
#
# Every INTERVAL_SEC, unless /run/wifi-mode is the setup AP:
#   - read the IPv4 default gateway on IFACE into GATEWAY
#   - COMPLETED and any reply from that gateway → leave the link alone
#   - otherwise flush IPv4, enable_network all, reassociate
#   - if that reaches COMPLETED and the gateway is still silent, DHCP
#
# GATEWAY is empty until udhcpc installs "default via <addr>". It is not
# a fixed address. Never select_network. That call disables every other
# network{} block. ping -c N returns success when any reply arrives, so
# a few lost packets do not kick the association.
#
# Recoveries since this process started are in COUNT_FILE (one integer).
# Env: IFACE, INTERVAL_SEC, PING_COUNT, PING_WAIT, COUNT_FILE
# =============================================================================
set -eu

IFACE="${IFACE:-wlan0}"
GATEWAY=
INTERVAL_SEC="${INTERVAL_SEC:-20}"
PING_COUNT="${PING_COUNT:-3}"
PING_WAIT="${PING_WAIT:-1}"
COUNT_FILE="${COUNT_FILE:-/run/wifi-watch-count}"

log() { printf 'wifi-watch: %s\n' "$*"; }

mode_ap() {
	[ -f /run/wifi-mode ] && [ "$(cat /run/wifi-mode)" = "ap" ]
}

ctrl_up() {
	[ -S "/var/run/wpa_supplicant/$IFACE" ] || [ -S "/run/wpa_supplicant/$IFACE" ]
}

wpa_state() {
	wpa_cli -i "$IFACE" status 2>/dev/null | sed -n 's/^wpa_state=//p' | tr -d '\r'
}

# Lowest-metric default route that udhcpc added on IFACE.
route_gateway() {
	ip -4 route show default dev "$IFACE" 2>/dev/null \
		| sed -n '/^default via /{s/^default via \([0-9.][0-9.]*\).*/\1/p;q}'
}

note_gateway() {
	gw=$(route_gateway)
	case $gw in
	''|*[!0-9.]*)
		gw=
		return
		;;
	esac
	if [ "$GATEWAY" != "$gw" ]; then
		GATEWAY=$gw
		log "gateway $GATEWAY"
	fi
}

gateway_ok() {
	ping -c "$PING_COUNT" -W "$PING_WAIT" "$gw" >/dev/null 2>&1
}

bump_count() {
	n=0
	if [ -f "$COUNT_FILE" ]; then
		n=$(tr -cd '0-9' < "$COUNT_FILE" || true)
	fi
	n=$(( ${n:-0} + 1 ))
	printf '%s\n' "$n" > "$COUNT_FILE"
	log "count=$n"
}

recover() {
	reason=$1
	bump_count
	log "recover ($reason): flush, enable_network all, reassociate"
	ip -4 addr flush dev "$IFACE" 2>/dev/null || true
	wpa_cli -i "$IFACE" enable_network all >/dev/null 2>&1 || true
	wpa_cli -i "$IFACE" reassociate >/dev/null 2>&1 || true
}

printf '0\n' > "$COUNT_FILE"

while true; do
	sleep "$INTERVAL_SEC"
	if mode_ap || ! ctrl_up; then
		continue
	fi

	st=$(wpa_state || true)
	note_gateway
	if [ "$st" = "COMPLETED" ] && [ -n "$gw" ] && gateway_ok; then
		continue
	fi

	if [ "$st" != "COMPLETED" ]; then
		recover "state=${st:-none}"
	elif [ -z "$gw" ]; then
		recover "no gateway"
	else
		recover "no ping $gw"
	fi

	sleep 5
	st=$(wpa_state || true)
	note_gateway
	if [ "$st" = "COMPLETED" ] && { [ -z "$gw" ] || ! gateway_ok; }; then
		log "associated, gateway still down; dhcp"
		udhcpc -i "$IFACE" -n -q -t 5 -T 2 >/dev/null 2>&1 || true
		note_gateway
	fi
done
